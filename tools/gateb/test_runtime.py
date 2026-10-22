"""Fast stdlib-only checks: python3 -m unittest discover -s tools/gateb."""
import concurrent.futures
import json
import os
from pathlib import Path
import socket
import struct
import tempfile
import unittest
import zlib
from unittest.mock import patch

import nbt
from world import Runtime, atomic, installer_manifest, safe_relative, validate_manifest


def string(value):
    value=value.encode();return struct.pack('>H',len(value))+value


def compound(entries):
    return b''.join(bytes([tag])+string(name)+value for tag,name,value in entries)+b'\x00'


def root(entries):
    return b'\x0a\x00\x00'+compound(entries)


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.runtime=Runtime(self.temp.name)
        self.manifest={'prepared':True,'version':1,'computers':{'1':{'name':'server','role':'server','pos':[0,64,0]}}}
        run=self.runtime.run('one');run.mkdir(parents=True)
        atomic(run/'manifest.json',self.manifest)

    def test_manifest(self):
        self.assertEqual(validate_manifest(self.manifest),self.manifest)
        self.manifest['computers']['2']=dict(self.manifest['computers']['1'])
        with self.assertRaisesRegex(ValueError,'Duplicate'): validate_manifest(self.manifest)
        self.manifest['computers']['2']['name']='wall';self.manifest['computers']['2']['pos']=[0,False,0]
        with self.assertRaisesRegex(ValueError,'integer'): validate_manifest(self.manifest)

    def test_ports_are_unique_under_concurrency_and_skip_bound_socket(self):
        with socket.socket() as occupied:
            occupied.bind(('127.0.0.1',0));port=occupied.getsockname()[1]
            self.runtime.config.update(port_start=port,port_end=port+30)
            with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                ports=list(pool.map(lambda i:self.runtime.allocate_port('run-'+str(i)),range(16)))
            self.assertEqual(len(set(ports)),16);self.assertNotIn(port,ports)
            self.assertEqual(self.runtime.allocate_port('run-0'),ports[0])

    def test_port_exhaustion(self):
        self.runtime.config.update(port_start=30000,port_end=30000)
        with self.assertRaisesRegex(RuntimeError,'No free'): self.runtime.allocate_port('none')

    def test_names_and_private_files(self):
        for name in ('../bad','bad/name',''):
            with self.assertRaises(ValueError): self.runtime.run(name)
        for name in ('so-keys','so-keys.bak','../keys','/absolute','so-data/so-keys.tmp'):
            with self.assertRaises(ValueError): safe_relative(name)

    def test_files_read_without_running_computer_and_block_symlinks(self):
        disk=self.runtime.computer_disk('one',1);(disk/'so-data').mkdir(parents=True)
        (disk/'so-journal').write_text('{value={park=true}}')
        (disk/'so-data/a').write_text('saved state')
        self.assertEqual(self.runtime.request('one',{'op':'files','computer':1,'path':'so-journal'})['content'],'{value={park=true}}')
        self.assertEqual(self.runtime.request('one',{'op':'files','computer':1,'path':'so-data'}),{'so-data/a':'saved state'})
        (disk/'escape').symlink_to('/etc/passwd')
        with self.assertRaises(ValueError): self.runtime.request('one',{'op':'files','computer':1,'path':'escape'})

    def test_terminal_and_colours(self):
        disk=self.runtime.computer_disk('one',1)
        import time
        terminal={'at':time.time()*1000,'width':2,'height':1,'lines':[{'text':'Hi','fg':'01','bg':'ff'}]}
        atomic(disk/'.gateb/screen.json',{'at':terminal['at'],'terminal':terminal,'monitors':{}})
        self.assertEqual(self.runtime.request('one',{'op':'terminal','computer':1}),terminal)
        atomic(disk/'.gateb/screen.json',{'at':0,'terminal':terminal})
        with self.assertRaisesRegex(RuntimeError,'stale'): self.runtime.request('one',{'op':'terminal','computer':1})

    def test_bridge_timeout_does_not_replay_input(self):
        disk=self.runtime.computer_disk('one',1)
        with self.assertRaisesRegex(RuntimeError,'timed out'):
            self.runtime.bridge('one',{'op':'input','computer':1,'event':'key','args':[25]},.02)
        self.assertEqual(list((disk/'.gateb/in').iterdir()),[])

    def test_installer_role_manifest(self):
        source=Path(self.temp.name)/'source';source.mkdir()
        (source/'install.lua').write_text('local ROLES={common={"install.lua","lib/a.lua"},worker={program="worker.lua","worker.lua"}}')
        self.assertEqual(installer_manifest(source,'worker'),['install.lua','lib/a.lua','worker.lua'])

    def test_copy_clone_is_independent(self):
        template=Path(self.temp.name)/'template';template.mkdir()
        atomic(template/'manifest.json',self.manifest)
        (template/'server.properties').write_text('server-ip=127.0.0.1\n')
        (template/'test').write_text('original')
        clone=self.runtime.clone('copy');path=Path(clone['path'])
        self.assertNotEqual((template/'test').stat().st_ino,(path/'test').stat().st_ino)
        (path/'test').write_text('changed');self.assertEqual((template/'test').read_text(),'original')


class NBTTests(unittest.TestCase):
    def test_compound_numeric_types_and_arrays(self):
        value=nbt.loads(root([(1,'on',b'\x01'),(3,'id',struct.pack('>i',42)),(8,'name',string('turtle')),(12,'data',struct.pack('>iq',1,-1))]))
        self.assertEqual(value,{'on':1,'id':42,'name':'turtle','data':[-1]})
        with self.assertRaises(ValueError): nbt.loads(b'\x0a')

    def test_saved_block_palette_and_turtle_facing(self):
        entity=compound([(3,'x',struct.pack('>i',-1)),(3,'y',struct.pack('>i',64)),(3,'z',struct.pack('>i',-1)),(3,'ComputerId',struct.pack('>i',4))])
        palette=compound([(8,'Name',string('computercraft:turtle_advanced')),(10,'Properties',compound([(8,'facing',string('south'))]))])
        section=compound([(1,'Y',b'\x04'),(10,'block_states',compound([(9,'palette',b'\x0a'+struct.pack('>i',1)+palette)]))])
        data=root([(9,'sections',b'\x0a'+struct.pack('>i',1)+section),(9,'block_entities',b'\x0a'+struct.pack('>i',1)+entity)])
        compressed=zlib.compress(data);body=struct.pack('>i',len(compressed)+1)+b'\x02'+compressed
        with tempfile.TemporaryDirectory() as temp:
            region=Path(temp)/'region';region.mkdir()
            header=bytearray(8192);header[1023*4:1023*4+4]=b'\x00\x00\x02\x01'
            (region/'r.-1.-1.mca').write_bytes(header+body+bytes(4096-len(body)))
            result=nbt.block(temp,[-1,64,-1])
            self.assertEqual(result['nbt']['ComputerId'],4)
            self.assertEqual(result['block']['Properties']['facing'],'south')
            self.assertEqual(next(nbt.computers(temp))[0],4)


if __name__=='__main__': unittest.main()
