"""Fast stdlib-only checks: python3 -m unittest discover -s tools/gateb."""
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import socket
import signal
import shutil
import struct
import subprocess
import sys
import time
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

    def test_discovered_fixture_catalog_matches_native_tree_geometry(self):
        natives=[]
        for cid,pos in ((1,[0,64,0]),(2,[-3,64,0]),(4,[-21,48,17]),(5,[-21,48,21]),(6,[12,65,11]),(9,[-12,64,4]),(10,[-8,64,0])):
            natives.append((cid,{'pos':pos,'block':{'Name':'computercraft:computer_advanced','Properties':{'facing':'south'}}}))
        world=Path(self.temp.name)/'fixture-world'
        (world/'playerdata').mkdir(parents=True)
        (world/'playerdata/9026426a-c1c1-3dac-8bb3-4c5121e010ce.dat').write_bytes(b'fixture')
        for cid,_ in natives:
            disk=world/'computercraft/computer'/str(cid);disk.mkdir(parents=True)
            (disk/'.so-role').write_text('server' if cid==1 else 'worker' if cid in (4,5,6) else 'display')
        with patch('nbt.computers',return_value=iter(natives)),patch('nbt.loads',return_value={'Pos':[-4.5,68,3.5]}):
            manifest=self.runtime.discover(world)
        self.assertEqual(manifest['computers']['3']['pos'],[-5,68,3])
        self.assertEqual(manifest['computers']['10']['name'],'probe')
        self.assertEqual(manifest['fixtures']['wood']['pos'],[3,64,3])
        self.assertEqual(manifest['mine']['home'],[-5,64,4,'s'])
        cells=set(map(tuple,manifest['farm']['dig_cells']))
        self.assertEqual(len(cells),120)
        self.assertIn((4,69,4),cells)
        self.assertNotIn((7,64,7),cells)

    def test_native_fixture_commands_keep_the_run_name(self):
        from fixtures import prepare
        manifest={'computers':{str(cid):{'role':'worker','pos':[-21,48,z]} for cid,z in ((4,17),(5,21),(6,25))},
                  'fixtures':{'ore':{'kind':'chest','pos':[-4,64,4]}},'mine':{},'forceload':[-16,-64,31,31]}
        manifest['computers'].update({'1':{'name':'server','role':'server'},'10':{'name':'probe','role':'display'}})
        positions={'-5 64 3':'4','-7 64 3':'5','3 64 7':'6'}
        def command(name,text):
            self.assertEqual(name,'one')
            for pos,cid in positions.items():
                if text==f'data get block {pos} ComputerId': return {'output':'has the following block data: '+cid}
            return {'output':'command complete'}
        with patch.object(self.runtime,'manifest',return_value=manifest),patch.object(self.runtime,'command',side_effect=command),patch.object(self.runtime,'request',return_value={'values':[True]}) as request:
            result=prepare(self.runtime,'one')
            request.assert_called_once_with('one',{'op':'lua','computer':'1','code':'return SO.pair.remember(10,nil)'})
        self.assertTrue(result['prepared'])
        self.assertTrue((self.runtime.run('one')/'fixture-proof.json').exists())

    def test_pool_prefix_isolates_start_status_and_stop(self):
        for name in ('driver-123-1','driver-123-2','pool-1','driver-123-other-1'):
            self.runtime.run(name).mkdir()
            atomic(self.runtime.run(name)/'run.json',{'port':25600})
        with patch('os.getloadavg',return_value=(0,0,0)),patch.object(self.runtime,'serve') as serve,patch.object(self.runtime,'status',return_value={'driver-123-1':999999,'pool-1':999998}):
            result=self.runtime.pool('up',2,prefix='driver-123')
            self.assertEqual([call.args[0] for call in serve.call_args_list],['driver-123-1','driver-123-2'])
            self.assertEqual([row['run'] for row in result],['driver-123-1'])
        with patch.object(self.runtime,'stop') as stop:
            self.runtime.pool('down',prefix='driver-123')
            self.assertEqual(set(call.args[0] for call in stop.call_args_list),{'driver-123-1','driver-123-2'})
        with self.assertRaises(ValueError): self.runtime.pool('up',1,prefix='../bad')

    def test_pool_refuses_its_first_world_before_cloning_when_overloaded(self):
        with patch.object(self.runtime,'status',return_value={}),patch('os.getloadavg',return_value=(8,8,8)),patch.object(self.runtime,'clone') as clone:
            with self.assertRaisesRegex(RuntimeError,'load1=8.00'): self.runtime.pool('up',1,prefix='driver')
            clone.assert_not_called()

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

    def test_snapshot_read_retries_a_concurrent_bridge_replacement(self):
        terminal={'width':2,'height':1,'lines':[]}
        responses=iter([FileNotFoundError(),'{',json.dumps({'at':time.time()*1000,'terminal':terminal})])
        original=Path.read_text
        def read(path,*args,**kwargs):
            if path.name!='screen.json': return original(path,*args,**kwargs)
            value=next(responses)
            if isinstance(value,Exception): raise value
            return value
        with patch.object(Path,'read_text',read):
            self.assertEqual(self.runtime.request('one',{'op':'terminal','computer':1}),terminal)

    def test_reboot_uses_native_shutdown_then_turn_on(self):
        with patch.object(self.runtime,'command',return_value={}) as command:
            self.runtime.request('one',{'op':'power','computer':1,'action':'reboot'})
        self.assertEqual([call.args[1] for call in command.call_args_list],['computercraft shutdown #1','computercraft turn-on #1'])

    def test_pocket_reboot_restores_the_bridge_before_native_reboot(self):
        self.manifest['computers']['1'].update(kind='pocket',role='display')
        atomic(self.runtime.run('one')/'manifest.json',self.manifest)
        with patch.object(self.runtime,'bridge',return_value={'action':'reboot'}) as bridge,patch.object(self.runtime,'command') as command:
            self.runtime.request('one',{'op':'power','computer':1,'action':'reboot'})
        command.assert_not_called()
        bridge.assert_called_once_with('one',{'op':'power','computer':1,'action':'reboot'},15)
        self.assertIn('gateb-bridge.lua',(self.runtime.computer_disk('one',1)/'startup.lua').read_text())

    def test_installer_role_manifest(self):
        source=Path(self.temp.name)/'source';source.mkdir()
        (source/'install.lua').write_text('local ROLES={common={"install.lua","lib/a.lua"},worker={program="worker.lua","worker.lua"}}')
        self.assertEqual(installer_manifest(source,'worker'),['install.lua','lib/a.lua','worker.lua'])

    def test_parallel_installers_publish_only_a_complete_commit_cache(self):
        repo=Path(self.temp.name)/'repo';repo.mkdir()
        subprocess.run(['git','init','-q',str(repo)],check=True)
        (repo/'install.lua').write_text('return true')
        subprocess.run(['git','add','.'],cwd=repo,check=True)
        subprocess.run(['git','-c','user.name=Test','-c','user.email=test@example.invalid','commit','-qm','fixture'],cwd=repo,check=True)
        sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip()
        source=self.runtime.home/'sources'/sha
        original_run,original_popen=subprocess.run,subprocess.Popen
        def fail_extract(argv,**kwargs):
            if argv[0]=='tar': raise OSError('interrupted extraction')
            return original_run(argv,**kwargs)
        def slow_archive(argv,**kwargs):
            if argv[:2]==['git','archive']: time.sleep(.1)
            return original_popen(argv,**kwargs)
        with patch('world.REPO',repo),patch.object(self.runtime,'manifest',return_value={'computers':{}}):
            with patch('world.subprocess.run',side_effect=fail_extract):
                with self.assertRaisesRegex(OSError,'interrupted extraction'):
                    self.runtime.install('one',sha)
            self.assertFalse(source.exists())
            self.assertEqual(list(source.parent.glob('*.tmp')),[])
            def install(index):
                self.runtime.install('install-'+str(index),sha)
                return (source/'install.lua').read_text()
            with patch('world.subprocess.Popen',side_effect=slow_archive),concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                self.assertEqual(list(pool.map(install,range(4))),['return true']*4)

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




class AdmissionTests(unittest.TestCase):
    def test_parallel_guard_boundaries(self):
        from keeper import admit
        gib=1024*1024
        admit(3*gib,8*gib+1,7.99,True)
        admit(3*gib,3*gib,20,False)
        with self.assertRaisesRegex(RuntimeError,'load1=8.00'): admit(3*gib,9*gib,8,True)
        with self.assertRaisesRegex(RuntimeError,'MemAvailable=8.00'): admit(3*gib,8*gib,0,True)
        with self.assertRaisesRegex(RuntimeError,'at least 3'): admit(3*gib,3*gib-1,0,False)


class BridgeTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which('lua5.2'), 'Lua 5.2 is not installed')
    def test_role_globals_and_async_cancellation(self):
        from world import REPO
        result=subprocess.run(['lua5.2','tools/gateb/test_bridge.lua'],cwd=REPO,capture_output=True,text=True,timeout=10)
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertIn('PASS bridge',result.stdout)


class KeeperTests(unittest.TestCase):
    def test_blocking_console_and_crash_keeps_children_owned(self):
        import keeper
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp);lock=home/'suite.lock';log=home/'keeper.log'
            with log.open('wb') as out:
                process=subprocess.Popen([sys.executable,str(Path(keeper.__file__)),temp,str(lock)],stdout=out,stderr=subprocess.STDOUT)
            try:
                deadline=time.monotonic()+5
                while not (home/'keeper.sock').exists() and time.monotonic()<deadline: time.sleep(.02)
                self.assertTrue((home/'keeper.sock').exists())
                # A disconnected caller must not stop an owned server.
                with socket.socket(socket.AF_UNIX) as sock: sock.connect(str(home/'keeper.sock'))
                time.sleep(.05)
                self.assertEqual(keeper.call(home,{'op':'status'}),{})
                fifo=home/'console';os.mkfifo(fifo)
                script='import os,time; print(os.get_blocking(0),flush=True); print(input(),flush=True); time.sleep(60)'
                info=keeper.call(home,{'op':'start','key':'dummy','argv':[sys.executable,'-c',script],'cwd':temp,'log':str(home/'child.log'),'fifo':str(fifo)})
                with fifo.open('w') as handle: handle.write('console alive\n')
                deadline=time.monotonic()+5
                while time.monotonic()<deadline:
                    if (home/'child.log').exists() and 'console alive' in (home/'child.log').read_text(): break
                    time.sleep(.02)
                self.assertEqual((home/'child.log').read_text(),'True\nconsole alive\n')
                with lock.open('a') as handle:
                    with self.assertRaises(BlockingIOError): fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
                process.kill();process.wait(timeout=5)
                deadline=time.monotonic()+5
                released=False
                while time.monotonic()<deadline:
                    with lock.open('a') as handle:
                        try: fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB);released=True;break
                        except BlockingIOError: time.sleep(.02)
                self.assertTrue(released,'child should exit and release inherited suite lock after keeper death')
            finally:
                if process.poll() is None: process.terminate();process.wait(timeout=10)


if __name__=='__main__': unittest.main()
