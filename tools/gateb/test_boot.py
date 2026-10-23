"""Fixture boot identity and bounded readiness regressions."""
import json
import tempfile
import time
import unittest
from unittest.mock import patch

from world import Runtime, atomic


class BootTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.runtime=Runtime(self.temp.name)
        self.manifest={'version':1,'computers':{'1':{'name':'server','role':'server','pos':[0,64,0]}}}
        atomic(self.runtime.run('one')/'manifest.json',self.manifest)
        self.disk=self.runtime.computer_disk('one',1)
        self.base=self.disk/'.gateb'

    def snapshot(self,boot_id='expected',at=None,uptime=0.1):
        atomic(self.base/'screen.json',{'boot_id':boot_id,'at':time.time()*1000 if at is None else at,'uptime':uptime})

    def proof(self):
        return {'boot_id':'expected','requested_at':time.time()*1000-100,'commands':[]}

    def test_power_and_helpers_preserve_the_live_inbox_directory(self):
        inbox=self.base/'in';inbox.mkdir(parents=True)
        inode=inbox.stat().st_ino
        with patch.object(self.runtime,'command',return_value={}):
            for request in ({'op':'power','computer':1,'action':'on'},
                            {'op':'power','computer':1,'action':'reboot'},
                            {'op':'helpers','enabled':False},
                            {'op':'helpers','enabled':True}):
                (inbox/'queued.json').write_text('{}')
                self.runtime.request('one',request)
                self.assertTrue(inbox.is_dir())
                self.assertEqual(inbox.stat().st_ino,inode)
                self.assertEqual(list(inbox.iterdir()),[])

    def test_instrument_rotates_a_nonsecret_boot_identity(self):
        first=self.runtime.instrument(self.disk,'server')
        second=self.runtime.instrument(self.disk,'server')
        self.assertRegex(first,r'^[a-f0-9]{32}$')
        self.assertNotEqual(first,second)
        self.assertEqual((self.base/'boot-id').read_text(),second)

    def test_wait_accepts_only_a_fresh_snapshot_from_the_requested_boot(self):
        self.snapshot()
        proof=self.proof()
        with patch.object(self.runtime,'command') as command:
            self.runtime.wait_boot('one','1',proof,timeout=.001)
        command.assert_not_called()
        self.assertEqual(proof['state'],'ready')
        self.assertEqual(proof['snapshot']['boot_id'],'expected')
        self.assertEqual(proof['snapshot']['uptime'],.1)

    def test_missing_old_stale_or_incomplete_boots_fail_after_one_turn_on_retry(self):
        for snapshot in (None,{}, {'boot_id':'old','at':time.time()*1000,'uptime':.1},
                         {'boot_id':'expected','at':0,'uptime':.1},
                         {'boot_id':'expected','at':time.time()*1000},
                         {'boot_id':'expected','at':time.time()*1000,'uptime':-1}):
            with self.subTest(snapshot=snapshot):
                (self.base/'screen.json').unlink(missing_ok=True)
                if snapshot is not None: atomic(self.base/'screen.json',snapshot)
                proof=self.proof()
                with patch.object(self.runtime,'command',return_value={'output':'turn-on'}) as command,patch('world.time.sleep'):
                    with self.assertRaisesRegex(RuntimeError,'fresh bridge boot'):
                        self.runtime.wait_boot('one','1',proof,timeout=.001)
                self.assertEqual(proof['state'],'failed')
                self.assertEqual(proof['commands'],[{'action':'turn-on','result':{'output':'turn-on'}}])
                command.assert_called_once_with('one','computercraft turn-on #1')

    def test_lost_native_start_can_recover_with_one_turn_on_retry(self):
        self.snapshot(boot_id='old')
        proof=self.proof()
        def turn_on(*args):
            self.snapshot()
            return {'output':'turn-on'}
        with patch.object(self.runtime,'command',side_effect=turn_on) as command,patch('world.time.sleep'):
            self.runtime.wait_boot('one','1',proof,timeout=.001)
        self.assertEqual(proof['state'],'ready')
        self.assertEqual(len(proof['commands']),1)
        self.assertEqual(command.call_count,1)

    def test_pocket_boot_timeout_does_not_use_native_turn_on(self):
        self.manifest['computers']['1']['kind']='pocket'
        atomic(self.runtime.run('one')/'manifest.json',self.manifest)
        with patch.object(self.runtime,'command') as command,patch('world.time.sleep'):
            with self.assertRaisesRegex(RuntimeError,'fresh bridge boot'):
                self.runtime.wait_boot('one','1',self.proof(),timeout=.001)
        command.assert_not_called()

    def install_source(self):
        sha='a'*40
        source=self.runtime.home/'sources'/sha;source.mkdir(parents=True)
        (source/'install.lua').write_text('local ROLES={common={"install.lua"},server={program="so-server.lua","so-server.lua"}}')
        (source/'so-server.lua').write_text('return true')
        return sha

    def test_online_copy_install_reboots_then_saves_matching_boot_proof(self):
        sha=self.install_source()
        original=self.runtime.request
        actions=[]
        def request(name,q,*args,**kwargs):
            actions.append(q['action'])
            return original(name,q,*args,**kwargs)
        def command(name,text,*args):
            if 'turn-on' in text:
                self.snapshot(boot_id=(self.base/'boot-id').read_text())
            return {'output':text}
        with patch.object(self.runtime,'status',return_value={'one':123}),patch.object(self.runtime,'command',side_effect=command),patch.object(self.runtime,'request',side_effect=request),patch('world.time.sleep'):
            result=self.runtime.install('one',sha)
        self.assertEqual(result['errors'],[])
        self.assertEqual(actions,['off','reboot'])
        proof=json.loads((self.runtime.run('one')/'install.json').read_text())['computers']['1']['boot']
        self.assertEqual(proof['state'],'ready')
        self.assertEqual(proof['boot_id'],proof['snapshot']['boot_id'])
        self.assertEqual([entry['action'] for entry in proof['commands']],['shutdown','turn-on'])
        self.assertEqual(result['boots'],{'1':proof})

    def test_online_pocket_copy_turns_on_before_its_bridge_reboot(self):
        sha=self.install_source()
        self.manifest['computers']['1'].update(kind='pocket',requires_client=True)
        atomic(self.runtime.run('one')/'manifest.json',self.manifest)
        powered=[True]
        actions=[]
        def request(name,q):
            action=q['action'];actions.append(action)
            if action=='reboot':
                self.assertTrue(powered[0], 'A stopped pocket cannot answer its bridge')
            powered[0]=action!='off'
            proof=self.proof()
            if action=='reboot': self.snapshot()
            return proof
        with patch.object(self.runtime,'status',return_value={'one':123,'one:client':124}), \
                patch.object(self.runtime,'request',side_effect=request),patch('world.time.sleep'):
            result=self.runtime.install('one',sha)
        self.assertEqual(actions,['off','on','reboot'])
        self.assertEqual(result['errors'],[])
        self.assertEqual(result['boots']['1']['state'],'ready')

    def test_failed_boot_is_an_install_error_with_saved_proof(self):
        sha=self.install_source()
        def fail(name,cid,proof):
            proof['state']='failed'
            raise RuntimeError('No fresh bridge boot on '+cid)
        with patch.object(self.runtime,'status',return_value={'one':123}),patch.object(self.runtime,'command',return_value={}),patch.object(self.runtime,'wait_boot',side_effect=fail),patch('world.time.sleep'):
            result=self.runtime.install('one',sha)
        self.assertIn('fresh bridge boot',result['errors'][0]['error'])
        saved=json.loads((self.runtime.run('one')/'install.json').read_text())
        self.assertEqual(saved['computers']['1']['boot']['state'],'failed')
        self.assertEqual(saved['errors'],result['errors'])
        self.assertEqual(result['boots'],{'1':saved['computers']['1']['boot']})

    def test_offline_copy_install_does_not_wait_for_a_pocket(self):
        sha=self.install_source()
        self.manifest['computers']['1'].update(kind='pocket',requires_client=True)
        atomic(self.runtime.run('one')/'manifest.json',self.manifest)
        with patch.object(self.runtime,'status',return_value={'one':123}),patch.object(self.runtime,'wait_boot') as wait,patch.object(self.runtime,'request') as request:
            result=self.runtime.install('one',sha)
        self.assertEqual(result['errors'],[])
        self.assertEqual(result['boots'],{})
        wait.assert_not_called();request.assert_not_called()


if __name__=='__main__': unittest.main()
