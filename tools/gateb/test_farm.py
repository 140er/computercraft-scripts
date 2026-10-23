"""C6 regressions against saved Anvil blocks, without a Minecraft process."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
from unittest.mock import patch
import zlib

from checks import c6
from checks.context import Context
from checks.model import Blocked
from fixtures import farm_allowlist
import nbt
from test_runtime import compound, root, string
from world import Runtime, atomic


ROOTS = [[5,64,5], [9,64,5], [5,64,9], [9,64,9]]
AUDITED_LEAVES = [(3,65,5), (3,65,6), (3,65,7), (5,65,6),
                  (5,65,7), (6,65,6), (6,65,9), (7,65,6),
                  (7,65,9), (8,65,6), (9,65,6), (9,65,7)]
NON_TREE = {(4,67,4):'dirt', (4,68,4):'stone', (4,69,4):'chest',
            (6,68,6):'spruce_log'}


def save_blocks(world, blocks):
    """Write one real, compressed Anvil chunk with modern packed block states."""
    names = ['air'] + sorted(set(blocks.values()) - {'air'})
    palette = b''.join(compound([(8,'Name',string('minecraft:' + name))]) for name in names)
    sections = []
    for sy in sorted({y // 16 for x,y,z in blocks}):
        packed = [0] * 256
        for (x,y,z), name in blocks.items():
            if y // 16 != sy:
                continue
            index = (y % 16) * 256 + (z % 16) * 16 + x % 16
            packed[index // 16] |= names.index(name) << ((index % 16) * 4)
        data = struct.pack('>i',len(packed)) + b''.join(v.to_bytes(8,'big') for v in packed)
        states = compound([(9,'palette',b'\x0a' + struct.pack('>i',len(names)) + palette), (12,'data',data)])
        sections.append(compound([(1,'Y',struct.pack('>b',sy)), (10,'block_states',states)]))
    payload = root([(9,'sections',b'\x0a' + struct.pack('>i',len(sections)) + b''.join(sections))])
    compressed = zlib.compress(payload)
    body = struct.pack('>i',len(compressed) + 1) + b'\x02' + compressed
    sectors = (len(body) + 4095) // 4096
    header = bytearray(8192)
    header[:4] = b'\x00\x00\x02' + bytes([sectors])
    region = world/'region'
    region.mkdir(parents=True,exist_ok=True)
    (region/'r.0.0.mca').write_bytes(header + body + bytes(sectors * 4096 - len(body)))


class FarmTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.runtime = Runtime(self.temp.name)
        self.template = self.runtime.home/'template'
        self.world = self.template/'world'
        self.blocks, old_cells = {}, set()
        for rx,_,rz in ROOTS:
            for x in range(rx-1,rx+2):
                for y in range(67,70):
                    for z in range(rz-1,rz+2):
                        self.blocks[x,y,z] = 'oak_leaves'
                        old_cells.add((x,y,z))
            for y in range(64,69):
                self.blocks[rx,y,rz] = 'oak_log'
                old_cells.add((rx,y,rz))
        self.blocks.update({p:'oak_leaves' for p in AUDITED_LEAVES + [(4,65,5)]})
        self.blocks.update(NON_TREE)
        self.blocks[6,69,6] = 'air'
        self.blocks[7,75,7] = 'oak_log'
        self.blocks[15,65,15] = 'oak_leaves'
        save_blocks(self.world,self.blocks)
        self.manifest = {'version':1, 'prepared':True,
                         'computers':{'1':{'name':'server','role':'server','pos':[0,64,0]},
                                      '6':{'name':'lumber','role':'worker','pos':[3,64,7]}},
                         'farm':{'area':[5,5,9,9], 'ground':63, 'species':'minecraft:oak',
                                 'dig_cells':sorted(old_cells)}}
        atomic(self.template/'manifest.json',self.manifest)
        (self.template/'server.properties').write_text('server-ip=127.0.0.1\n')

    def test_cold_allowlist_includes_all_twelve_audited_leaves_and_only_connected_tree_blocks(self):
        with patch('nbt.chunk',wraps=nbt.chunk) as chunk:
            proof = self.runtime.farm_allowlist()
        self.assertEqual(chunk.call_count,1)
        allowed = {tuple(b['pos']):b['block']['Name'] for b in proof['blocks']}
        for pos in AUDITED_LEAVES:
            self.assertEqual(allowed[pos],'minecraft:oak_leaves')
            self.assertNotIn(pos,self.manifest['farm']['dig_cells'])
        for pos in (*NON_TREE, (6,69,6), (7,75,7), (15,65,15)):
            self.assertNotIn(pos,allowed)
        self.assertEqual(allowed[5,64,5],'minecraft:oak_log')
        self.assertEqual(proof['trees'],ROOTS)
        self.assertEqual(proof['source'],str(self.world))

    def test_explicit_tree_declarations_do_not_admit_other_roots(self):
        farm = {**self.manifest['farm'], 'trees':[ROOTS[0]]}
        allowed = {tuple(b['pos']) for b in farm_allowlist(self.world,farm)['blocks']}
        self.assertIn((3,65,5),allowed)
        self.assertNotIn((9,64,9),allowed)

    def test_clone_and_reset_upgrade_legacy_manifest_without_changing_template(self):
        original_manifest = (self.template/'manifest.json').read_bytes()
        original_world = (self.world/'region/r.0.0.mca').read_bytes()
        self.runtime.clone('copy')
        clone = self.runtime.manifest('copy')
        expected = self.runtime.farm_allowlist()
        self.assertEqual(clone['farm']['dig_cells'],[b['pos'] for b in expected['blocks']])
        self.assertEqual(clone['farm']['trees'],ROOTS)
        atomic(self.runtime.run('copy')/'manifest.json',self.manifest)
        save_blocks(self.runtime.run('copy')/'world',{(5,64,5):'stone'})
        with patch.object(self.runtime,'status',return_value={}), patch.object(self.runtime,'stop'):
            self.runtime.reset('copy')
        self.assertEqual(self.runtime.manifest('copy')['farm'],clone['farm'])
        self.assertEqual((self.template/'manifest.json').read_bytes(),original_manifest)
        self.assertEqual((self.world/'region/r.0.0.mca').read_bytes(),original_world)

    def context(self, dug):
        ctx = Context(self.runtime,'unused',self.manifest,self.runtime.home/'evidence','a'*40)
        frame = {'rot':0, 'ox':0, 'oy':0, 'oz':0}
        rows = [{'lumber':{'spots':{str(i):{'plantedAt':1} for i in range(4)}, 'turtle':{'frame':frame}},
                 'workers':{'6':{'dug':list(dug)}}}]
        return ctx, rows

    def run_c6(self, dug):
        ctx, rows = self.context(dug)
        with patch.object(ctx,'lumber'), patch.object(ctx,'sample',return_value=rows), \
             patch.object(ctx,'count_items',side_effect=[0,5]):
            verdict = c6.run(ctx)
        return ctx, verdict

    def test_c6_accepts_audited_leaves_and_saves_cold_evidence_before_harvest(self):
        ctx, rows = self.context(AUDITED_LEAVES)
        def harvest():
            path = ctx.output/'C6-cold-allowed-cells.json'
            self.assertTrue(path.exists())
            proof = json.loads(path.read_text())
            self.assertTrue(set(AUDITED_LEAVES) <= {tuple(b['pos']) for b in proof['blocks']})
            save_blocks(self.world,{(5,64,5):'air'})
        with patch.object(ctx,'lumber',side_effect=harvest), patch.object(ctx,'sample',return_value=rows), \
             patch.object(ctx,'count_items',side_effect=[0,5]):
            verdict = c6.run(ctx)
        self.assertEqual(verdict.status,'pass')
        self.assertIn('C6-cold-allowed-cells.json',ctx.evidence)

    def test_c6_rejects_non_tree_blocks_even_in_old_dig_cells(self):
        for pos in (*NON_TREE, (6,69,6)):
            with self.subTest(pos=pos):
                self.assertIn(pos,self.manifest['farm']['dig_cells'])
                _, verdict = self.run_c6(AUDITED_LEAVES + [pos])
                self.assertEqual(verdict.status,'fail')
                self.assertEqual(verdict.metrics['unsafe_digs'],[pos])

    def test_missing_cold_stem_blocks_before_starting_lumber(self):
        self.blocks[5,64,5] = 'dirt'
        save_blocks(self.world,self.blocks)
        ctx, _ = self.context(AUDITED_LEAVES)
        with patch.object(ctx,'lumber') as lumber:
            with self.assertRaisesRegex(Blocked,'missing a declared tree stem'):
                c6.run(ctx)
        lumber.assert_not_called()


if __name__ == '__main__':
    unittest.main()
