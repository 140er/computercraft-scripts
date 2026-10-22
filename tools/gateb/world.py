#!/usr/bin/env python3
"""Reusable local Minecraft runtime for Gate B. See API.md."""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import time
import uuid

import keeper
import nbt

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
WORK = Path.home() / 'work'


def atomic(path, value):
    path = Path(path);path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    tmp.write_text(json.dumps(value, indent=2) + '\n');tmp.replace(path)


@contextmanager
def locked(path):
    path = Path(path);path.parent.mkdir(parents=True, exist_ok=True)
    with path.open('a') as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        yield


def copytree(source, target):
    """Reflink when available; cp never hardlinks mutable files."""
    target = Path(target);target.mkdir(parents=True, exist_ok=True)
    subprocess.run(['cp','-a','--reflink=auto',str(Path(source))+'/.',str(target)], check=True)


def safe_relative(path):
    value = Path(path)
    if value.is_absolute() or '..' in value.parts or not value.parts:
        raise ValueError('Expected a relative path')
    if any('so-keys' in p or p.startswith('private-') for p in value.parts):
        raise ValueError('Pairing secrets are excluded')
    return value


def validate_manifest(value):
    if value.get('version') != 1 or not isinstance(value.get('computers'), dict):
        raise ValueError('Expected version 1 manifest with computers')
    names = set()
    for cid, computer in value['computers'].items():
        if not str(cid).isdigit() or computer['role'] not in ('server','display','worker','fixture'):
            raise ValueError('Invalid computer ID or role')
        if len(computer['pos']) != 3 or any(type(v) is not int for v in computer['pos']):
            raise ValueError('Expected three integer coordinates')
        if computer['name'] in names:
            raise ValueError('Duplicate computer name')
        names.add(computer['name'])
    if 'server' not in names:
        raise ValueError('Missing server computer')
    return value


def installer_manifest(source, role):
    text = (Path(source) / 'install.lua').read_text()
    groups = {}
    for name, body in re.findall(r'\b(common|server|worker|display)\s*=\s*\{(.*?)\}', text, re.S):
        body = re.sub(r'program\s*=\s*"[^"]+"\s*,?', '', body)
        groups[name] = re.findall(r'"([^"]+)"', body)
    if 'common' not in groups or role not in groups:
        raise ValueError('Unsupported installer role manifest')
    return list(dict.fromkeys(groups['common'] + groups[role]))


class Runtime:
    def __init__(self, home=None):
        self.home = Path(home or os.environ.get('GATEB_HOME', WORK / 'gateb-runtime2')).expanduser().resolve()
        for protected in (WORK/'mc-serverfiles',WORK/'gateb-livefiles'):
            if self.home.is_relative_to(protected.resolve()):
                raise ValueError('Runtime output must be outside reference and active Gate B directories')
        self.home.mkdir(parents=True, exist_ok=True);os.chmod(self.home, 0o700)
        config = self.home / 'config.json'
        self.config = json.loads(config.read_text()) if config.exists() else {}
        self.suite_lock = WORK / 'test-suite.lock'

    def run(self, name):
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', str(name)):
            raise ValueError('Invalid run name')
        return self.home / 'runs' / name

    def lock_path(self, name):
        self.run(name)
        return self.home/'locks'/f'{name}.lock'

    def state(self, name):
        return json.loads((self.run(name) / 'run.json').read_text())

    def manifest(self, name):
        return validate_manifest(json.loads((self.run(name) / 'manifest.json').read_text()))

    def status(self):
        try:
            return keeper.call(self.home, {'op':'status'})
        except (OSError, RuntimeError):
            return {}

    def ensure_keeper(self):
        with locked(self.home / 'keeper-start.lock'):
            try:
                return keeper.call(self.home, {'op':'status'})
            except OSError:
                pass
            error = self.home / 'keeper-error';error.unlink(missing_ok=True)
            with (self.home / 'keeper.log').open('ab') as out:
                subprocess.Popen([sys.executable,str(HERE/'keeper.py'),str(self.home),str(self.suite_lock)], stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
            for _ in range(100):
                if error.exists():
                    raise RuntimeError(error.read_text())
                try:
                    return keeper.call(self.home, {'op':'status'})
                except OSError:
                    time.sleep(.05)
            raise RuntimeError('Keeper did not start')

    def allocate_port(self, name):
        with locked(self.home / 'ports.lock'):
            path = self.home / 'ports.json'
            ports = json.loads(path.read_text()) if path.exists() else {}
            if name in ports:
                return ports[name]
            for port in range(self.config.get('port_start',25600), self.config.get('port_end',25700)):
                if port in ports.values():
                    continue
                with socket.socket() as sock:
                    try:
                        sock.bind(('127.0.0.1',port))
                    except OSError:
                        continue
                ports[name] = port;atomic(path,ports);return port
            raise RuntimeError('No free Gate B ports')

    def distribution(self, destination):
        source = Path(self.config.get('server_source', WORK/'gateb-livefiles/server')).resolve()
        for name in ('mods','libraries','config','defaultconfigs'):
            if (source/name).exists():
                copytree(source/name, destination/name)
        for name in ('run.sh','eula.txt'):
            if (source/name).exists():
                shutil.copy2(source/name,destination/name)
        properties = (source/'server.properties').read_text()
        properties = re.sub(r'(?m)^(rcon\.password|rcon\.port|enable-rcon|enable-query|query.port|server-ip|server-port|level-name|online-mode|max-players|motd)=.*\n?', '', properties)
        (destination/'server.properties').write_text(properties + '\nenable-rcon=false\nenable-query=false\nserver-ip=127.0.0.1\nlevel-name=world\nonline-mode=false\nmax-players=4\nmotd=Gate B runtime test only\n')
        (destination/'eula.txt').write_text('eula=true\n')
        web=destination/'config/bluemap/webserver.conf'
        if web.exists(): web.write_text(re.sub(r'(?m)^enabled:.*$', 'enabled: false', web.read_text()))
        voice=destination/'config/voicechat/voicechat-server.properties'
        if voice.exists():
            text=re.sub(r'(?m)^port=.*$', 'port=-1', voice.read_text())
            voice.write_text(re.sub(r'(?m)^bind_address=.*$', 'bind_address=127.0.0.1', text))
        (destination/'user_jvm_args.txt').write_text('-Xms512M\n-Xmx2G\n-XX:MaxDirectMemorySize=256M\n-XX:ActiveProcessorCount=2\n')

    def build_template(self, snapshot=None):
        with locked(self.home/'template.lock'):
            target = self.home/'template'
            if target.exists():
                raise RuntimeError('Template already exists; move it aside before rebuilding')
            source = Path(snapshot or self.config.get('snapshot',WORK/'gateb-livefiles/archives/pre-4b6ba5b-world')).resolve()
            if not (source/'level.dat').exists():
                raise RuntimeError('Supply a saved test world snapshot with level.dat')
            # Minecraft uses a POSIX record lock, rather than flock, on session.lock.
            with (source/'session.lock').open('rb') as session:
                try:
                    fcntl.lockf(session,fcntl.LOCK_SH|fcntl.LOCK_NB)
                except BlockingIOError:
                    raise RuntimeError('Snapshot is in use by a Minecraft server')
                stage = self.home/('template-'+uuid.uuid4().hex)
                stage.mkdir()
                try:
                    self.distribution(stage)
                    copytree(source,stage/'world')
                    (stage/'world/session.lock').unlink(missing_ok=True)
                    manifest = self.discover(stage/'world')
                    manifest['artifacts']={'snapshot':str(source),'server_source':str(Path(self.config.get('server_source',WORK/'gateb-livefiles/server')).resolve()),'mod_count':len(list((stage/'mods').glob('*.jar')))}
                    atomic(stage/'manifest.json',manifest)
                    # Import only native installed startups, never per-run helpers.
                    for cid, comp in manifest['computers'].items():
                        disk = stage/'world/computercraft/computer'/cid
                        for helper in list(disk.glob('gateb-*')) + [disk/'.gateb']:
                            if helper.is_dir(): shutil.rmtree(helper)
                            else: helper.unlink(missing_ok=True)
                        if comp['name']=='probe':
                            for key in disk.glob('so-keys*'): key.unlink()
                        if comp['role'] in ('server','display','worker'):
                            self.instrument(disk,comp['role'])
                    stage.rename(target)
                except Exception:
                    shutil.rmtree(stage,ignore_errors=True);raise
            manifest=self.prepare_template()
            return {'template':str(target),'manifest':manifest}

    def prepare_template(self):
        from fixtures import clean_disks, prepare
        name='template-build'
        run=self.run(name)
        if run.exists():
            if name in self.status(): raise RuntimeError('Template build is already running')
            shutil.rmtree(run)
        copytree(self.home/'template',run)
        port=self.allocate_port(name)
        with (run/'server.properties').open('a') as handle: handle.write(f'\nserver-port={port}\n')
        atomic(run/'run.json',{'version':1,'name':name,'port':port})
        clean_disks(self,name)
        try:
            self.serve(name)
            manifest=prepare(self,name)
        finally:
            self.stop(name)
        target=self.home/'template'
        shutil.rmtree(target/'world');copytree(run/'world',target/'world')
        shutil.copy2(run/'manifest.json',target/'manifest.json')
        shutil.copy2(run/'fixture-proof.json',target/'fixture-proof.json')
        return manifest

    def discover(self, world):
        names = {1:'server',2:'wall',3:'pocket',4:'miner1',5:'miner2',6:'lumber',9:'storage',10:'probe'}
        comps = {}
        for cid, native in nbt.computers(world):
            if cid not in names:
                continue
            disk = Path(world)/'computercraft/computer'/str(cid)
            role = (disk/'.so-role').read_text().strip() if (disk/'.so-role').exists() else 'fixture'
            if cid==9: role='fixture'
            if cid==10: role='display'
            props = native['block'].get('Properties',{})
            comps[str(cid)] = {'name':names[cid],'role':role,'kind':'turtle' if 'turtle' in native['block']['Name'] else 'computer','pos':native['pos'],'facing':props.get('facing')}
            if {'1','2','4','5','6','9','10'} <= comps.keys(): break
        # Pocket computers tick only in a player's inventory, on client login.
        player=Path(world)/'playerdata/9026426a-c1c1-3dac-8bb3-4c5121e010ce.dat'
        pocket_pos=[math.floor(v) for v in nbt.loads(player.read_bytes())['Pos']]
        comps['3'] = {'name':'pocket','role':'display','kind':'pocket','pos':pocket_pos,'facing':None,'requires_client':True}
        fixtures = {name:{'kind':kind,'pos':pos} for name,kind,pos in [
            ('ore','chest',[-4,64,4]),('fuel','chest',[-6,64,4]),
            ('wood','chest',[3,64,3]),('saplings','chest',[3,64,5]),
            ('storage_output','chest',[-12,64,7]),('storage_stock','chest',[-11,66,4]),
            ('ar','cc_ar:ar_controller',[0,64,1]),('wall','monitor',[-3,64,-1]) ]}
        for fixture in fixtures.values():
            fixture['side']='front'
        value = {'version':1,'dimension':'minecraft:overworld','computers':comps,'fixtures':fixtures,
                 'wall':{'from':[-3,64,-1],'to':[-1,65,-1],'size':[3,2]},
                 'mine':{'home':[-5,64,4,'s'],'facing':'south','bottom':48,'length':16,'starts':{cid:{'pos':comps[cid]['pos'],'facing':comps[cid]['facing']} for cid in ('4','5') if cid in comps}},
                 'farm':{'area':[5,5,9,9],'ground':63,'dig_cells':sorted({(x,y,z) for rx,rz in ((5,5),(9,5),(5,9),(9,9)) for x,y,z in ([(rx,y,rz) for y in range(64,69)]+[(x,y,z) for x in range(rx-1,rx+2) for y in range(67,70) for z in range(rz-1,rz+2)])}),'species':'minecraft:oak'},
                 'forceload':[-16,-64,31,31],'prepared':False,'source':'copied saved Gate B snapshot'}
        return validate_manifest(value)

    def instrument(self, disk, role):
        disk.mkdir(parents=True,exist_ok=True)
        (disk/'.so-role').write_text(role)
        shutil.copy2(HERE/'bridge.lua',disk/'gateb-bridge.lua')
        (disk/'startup.lua').write_text('if shell.run("/install.lua", "recover") then shell.run("/gateb-bridge.lua") end\n')

    def clone(self, name):
        with locked(self.home/'template.lock'), locked(self.lock_path(name)):
            target = self.run(name)
            if target.exists():
                raise RuntimeError('Run already exists')
            if not (self.home/'template/manifest.json').exists():
                raise RuntimeError('Build the template first')
            manifest=json.loads((self.home/'template/manifest.json').read_text())
            if not manifest.get('prepared'): raise RuntimeError('Template preparation did not finish')
            try:
                copytree(self.home/'template', target)
                port = self.allocate_port(name)
                with (target/'server.properties').open('a') as handle:
                    handle.write(f'\nserver-port={port}\n')
                atomic(target/'run.json',{'version':1,'name':name,'port':port})
            except Exception:
                shutil.rmtree(target,ignore_errors=True);raise
            return {'run':name,'path':str(target),'port':port}

    def serve(self, name, timeout=180):
        run = self.run(name);state=self.state(name)
        with locked(self.lock_path(name)):
            self.ensure_keeper()
            if name in self.status():
                pid=self.status()[name]
                log=run/'console.log'
                if state.get('pid')==pid and state.get('ready'):
                    return {'run':name,'pid':pid,'warm':True}
                raise RuntimeError('Server exists but has not reached its ready marker')
            for cid in self.manifest(name)['computers']:
                base=self.computer_disk(name,cid)/'.gateb'
                (base/'screen.json').unlink(missing_ok=True)
                shutil.rmtree(base/'in',ignore_errors=True)
                shutil.rmtree(base/'out',ignore_errors=True)
            fifo=run/'console.fifo'
            fifo.unlink(missing_ok=True);os.mkfifo(fifo,0o600)
            log=run/'console.log'
            start=log.stat().st_size if log.exists() else 0
            java = Path(self.config.get('java',WORK/'gateb-runtime/java/bin/java'))
            argv=[str(java),'@user_jvm_args.txt']
            args=list((run/'libraries/net/neoforged/neoforge').glob('*/unix_args.txt'))
            if len(args)!=1: raise RuntimeError('Expected one NeoForge unix_args.txt')
            argv+=['@'+str(args[0]),'nogui']
            info=keeper.call(self.home,{'op':'start','key':name,'argv':argv,'cwd':str(run),'log':str(log),'fifo':str(fifo),'memory_kib':3*1024*1024,'server':True})
            state.update(pid=info['pid'],ready=False);atomic(run/'run.json',state)
            deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                if name not in self.status(): raise RuntimeError('Server exited; inspect '+str(log))
                with log.open(errors='replace') as handle:
                    handle.seek(start);text=handle.read()
                if re.search(r'Done \([\d.]+s\)!',text):
                    self.command(name,'forceload add '+' '.join(map(str,self.manifest(name)['forceload'])))
                    state['ready']=True;atomic(run/'run.json',state)
                    return {**info,'run':name,'port':state['port'],'warm':True}
                time.sleep(.25)
            self.stop(name)
            raise RuntimeError('Server startup timed out; inspect '+str(log))

    def command(self, name, command, timeout=15):
        if name not in self.status(): raise RuntimeError('Server is not running')
        if '\n' in command or '\r' in command: raise ValueError('One console command per request')
        run=self.run(name);log=run/'console.log';tag='GATEB_'+uuid.uuid4().hex
        with locked(run/'console.lock'):
            offset=log.stat().st_size
            fd=os.open(run/'console.fifo',os.O_WRONLY|os.O_NONBLOCK)
            try: os.write(fd,(command.lstrip('/')+'\nsay '+tag+'\n').encode())
            finally: os.close(fd)
            deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                with log.open(errors='replace') as handle:
                    handle.seek(offset);value=re.sub(r'\x1b\[[0-9;]*[A-Za-z]','',handle.read())
                if '[Server] '+tag in value:
                    return {'output':value.replace(tag,'<completion>')}
                time.sleep(.05)
            raise RuntimeError('Console command timed out')

    def stopped_result(self, name):
        path=self.home/'exits.json'
        info=json.loads(path.read_text()).get(name,{}) if path.exists() else {}
        return {'run':name,'stopped':True,**info}

    def stop(self, name):
        self.client_stop(name)
        if name not in self.status(): return self.stopped_result(name)
        try:
            self.command(name,'stop',timeout=3)
        except RuntimeError:
            pass
        deadline=time.monotonic()+60
        while time.monotonic()<deadline:
            if name not in self.status(): return self.stopped_result(name)
            time.sleep(.2)
        raise RuntimeError('Server did not stop cleanly; process retained for inspection')

    def reset(self, name):
        with locked(self.lock_path(name)):
            running=name in self.status();self.stop(name)
            run=self.run(name)
            shutil.rmtree(run/'world');copytree(self.home/'template/world',run/'world')
            shutil.copy2(self.home/'template/manifest.json',run/'manifest.json')
            (run/'install.json').unlink(missing_ok=True)
        if running: self.serve(name)
        return {'run':name,'restarted':running}

    def computer_disk(self, name, computer):
        if not str(computer).isdigit():
            computer=next(cid for cid,v in self.manifest(name)['computers'].items() if v['name']==computer)
        if str(computer) not in self.manifest(name)['computers']: raise ValueError('Unknown computer')
        return self.run(name)/'world/computercraft/computer'/str(computer)

    def bridge(self, name, q, timeout):
        disk=self.computer_disk(name,q['computer']);base=disk/'.gateb'
        if (base/'disabled').exists(): raise RuntimeError('Bridge is disabled; enable and reboot first')
        token=uuid.uuid4().hex+'.json';target=base/'in'/token;response=base/'out'/token
        atomic(target,q)
        try:
            deadline=time.monotonic()+timeout
            while time.monotonic()<deadline:
                if response.exists():
                    result=json.loads(response.read_text());response.unlink()
                    if not result['ok']: raise RuntimeError(result.get('error','Bridge failed'))
                    return result['result']
                time.sleep(.05)
            raise RuntimeError('Computer bridge timed out; input removed')
        finally:
            target.unlink(missing_ok=True);response.unlink(missing_ok=True)

    def request(self, name, q, timeout=15):
        op=q['op']
        if op=='manifest': return self.manifest(name)
        if op=='command': return self.command(name,q['command'],timeout)
        if op=='save': return self.command(name,'save-all flush',timeout)
        if op in ('terminal','monitors','frame'):
            disk=self.computer_disk(name,q['computer'])
            snap=json.loads((disk/'.gateb/screen.json').read_text())
            if time.time()*1000-snap['at']>5000: raise RuntimeError('Computer snapshot is stale')
            return snap.get(op) if op=='frame' else snap[op]
        if op=='files':
            disk=self.computer_disk(name,q['computer']).resolve();relative=safe_relative(q['path']);path=(disk/relative).resolve()
            if not path.is_relative_to(disk): raise ValueError('Path leaves computer disk')
            if path.is_dir():
                result={}
                for entry in sorted(path.rglob('*')):
                    if entry.is_file():
                        rel=entry.relative_to(disk);safe_relative(rel)
                        if not entry.resolve().is_relative_to(disk): raise ValueError('Path leaves computer disk')
                        result[str(rel)]=entry.read_text()
                return result
            return {'path':str(relative),'content':path.read_text()}
        if op in ('block','chest','turtle'):
            world=self.run(name)/'world'
            if op=='turtle':
                cid=str(q['computer']);comp=self.manifest(name)['computers'].get(cid)
                if not comp: cid=next(k for k,v in self.manifest(name)['computers'].items() if v['name']==q['computer'])
                position=self.manifest(name)['computers'][cid]['pos']
                try: result=nbt.block(world,position)
                except FileNotFoundError: result=None
                if result is None or str(result['nbt'].get('ComputerId'))!=cid:
                    result=next((v for computer,v in nbt.computers(world,near=position) if str(computer)==cid),None)
                if result is None: raise RuntimeError('Computer not found in saved chunks')
                result['facing']=result['block'].get('Properties',{}).get('facing')
                return result
            result=nbt.block(world,q['pos'])
            if op=='chest': result['items']=result['nbt'].get('Items',[])
            return result
        if op=='power':
            action=q['action'];disk=self.computer_disk(name,q['computer']);cid=disk.name
            commands={'on':'turn-on','off':'shutdown','reboot':'reboot'}
            if action not in commands: raise ValueError('Invalid power action')
            if action in ('on','reboot'):
                comp=self.manifest(name)['computers'][cid]
                if comp['role'] in ('server','display','worker'): self.instrument(disk,comp['role'])
                (disk/'.gateb/screen.json').unlink(missing_ok=True)
                shutil.rmtree(disk/'.gateb/in',ignore_errors=True)
            self.command(name,'computercraft '+commands[action]+' #'+cid,timeout)
            return {'action':action,'computer':int(cid)}
        if op=='helpers':
            enabled=q.get('enabled',False)
            for cid in self.manifest(name)['computers']:
                disk=self.computer_disk(name,cid);base=disk/'.gateb'
                shutil.rmtree(base/'in',ignore_errors=True);(base/'in').mkdir(parents=True)
                if enabled: (base/'disabled').unlink(missing_ok=True)
                else: (base/'disabled').touch()
            return {'enabled':enabled,'pending_inputs':0,'enable_requires_reboot':True}
        if op in ('input','lua','lua_async','lua_job','lua_cancel'): return self.bridge(name,q,timeout)
        raise ValueError('Unknown operation '+op)

    def install(self, name, sha, mode='copy'):
        if not re.fullmatch(r'[a-fA-F0-9]{40}',sha): raise ValueError('Install requires a full commit SHA')
        source=self.home/'sources'/sha
        if not source.exists():
            subprocess.run(['git','cat-file','-e',sha+'^{commit}'],cwd=REPO,check=True)
            source.mkdir(parents=True)
            archive=subprocess.Popen(['git','archive',sha],cwd=REPO,stdout=subprocess.PIPE)
            try:
                subprocess.run(['tar','-x','-C',str(source)],stdin=archive.stdout,check=True)
            finally:
                archive.stdout.close()
            if archive.wait(): raise RuntimeError('git archive failed')
        installed={};errors=[]
        if mode=='http':
            current=subprocess.check_output(['git','ls-remote','origin','refs/heads/server-only'],cwd=REPO,text=True).split()[0]
            if current!=sha: raise RuntimeError('HTTP normal update requires the current server-only tip')
        if mode in ('http','installer'):
            unavailable=[cid for cid,comp in self.manifest(name)['computers'].items() if comp['role'] in ('server','display','worker') and (name not in self.status() or (comp.get('requires_client') and name+':client' not in self.status()))]
            if unavailable: raise RuntimeError('HTTP install needs running computers; connect the client for pockets: '+','.join(unavailable))
        try:
            with locked(self.lock_path(name)):
                for cid,comp in self.manifest(name)['computers'].items():
                    role=comp['role']
                    if role not in ('server','display','worker'): continue
                    disk=self.computer_disk(name,cid)
                    online=name in self.status() and (not comp.get('requires_client') or name+':client' in self.status())
                    if mode in ('installer','http') and not online:
                        raise RuntimeError('Normal installer mode needs online computers; connect the client for pockets')
                    if online:
                        self.request(name,{'op':'power','computer':cid,'action':'off'})
                        time.sleep(.2)
                    if mode in ('installer','http'):
                        if not online: raise RuntimeError('Normal installer mode needs an online computer, including a client for pockets')
                        # Execute the exact installer with a pinned resolver response.
                        (disk/'gateb-install.lua').write_text((source/'install.lua').read_text())
                        self.instrument(disk,role)
                        self.request(name,{'op':'power','computer':cid,'action':'on'})
                        code='''local old=http.get
    http.get=function(url,...) if url:find('/branches/server%-only$') then
    return {getResponseCode=function() return 200 end,readAll=function() return '{"commit":{"sha":"SHA"}}' end,close=function() end}
    end return old(url,...) end
    local ok,why=pcall(shell.run,'/gateb-install.lua','update');http.get=old
    if not ok then error(why) end
    return true'''.replace('SHA',sha)
                        if mode=='http': code='return shell.run("/install.lua","update")'
                        job=self.request(name,{'op':'lua_async','computer':cid,'code':code})['job']
                        deadline=time.monotonic()+180
                        while time.monotonic()<deadline:
                            status=self.request(name,{'op':'lua_job','computer':cid,'job':job})
                            if status['state'] in ('done','failed'): break
                            time.sleep(.1)
                        else:
                            self.request(name,{'op':'lua_cancel','computer':cid,'job':job})
                            errors.append({'computer':cid,'error':'HTTP installer timed out'})
                        if status.get('state')=='failed': errors.append({'computer':cid,'error':status.get('error')})
                    else:
                        if (disk/'.so-old').exists() or (disk/'.so-new').exists():
                            raise RuntimeError('Recover the interrupted installer before using file-copy mode')
                        files=installer_manifest(source,role)
                        oldfiles=[]
                        if (disk/'.so-files').exists(): oldfiles=re.findall(r'"([^"]+)"',(disk/'.so-files').read_text())
                        for rel in oldfiles+[p.name for p in disk.glob('so-mod-*.lua')]:
                            if rel not in files:
                                (disk/safe_relative(rel)).unlink(missing_ok=True)
                        hashes={}
                        for rel in files:
                            dest=disk/safe_relative(rel);dest.parent.mkdir(parents=True,exist_ok=True)
                            shutil.copy2(source/rel,dest);hashes[rel]=hashlib.sha256(dest.read_bytes()).hexdigest()
                        (disk/'.so-files').write_text('{'+','.join(json.dumps(v) for v in files)+'}')
                        (disk/'.so-revision').write_text(sha)
                        installed[cid]={'role':role,'files':hashes}
                    expected=installer_manifest(source,role)
                    if (disk/'.so-revision').read_text().strip()!=sha:
                        raise RuntimeError('Installer did not record the requested revision on '+cid)
                    hashes={rel:hashlib.sha256((disk/rel).read_bytes()).hexdigest() for rel in expected}
                    if any((disk/rel).read_bytes()!=(source/rel).read_bytes() for rel in expected):
                        raise RuntimeError('Installed file mismatch on '+cid)
                    installed[cid]={'role':role,'files':hashes}
                    self.instrument(disk,role)
                    if online: self.request(name,{'op':'power','computer':cid,'action':'reboot' if mode in ('http','installer') else 'on'})
        except (OSError,ValueError,RuntimeError,KeyError) as exc:
            errors.append({'computer':cid,'error':str(exc)})
        atomic(self.run(name)/'install.json',{'sha':sha,'mode':mode,'computers':installed,'errors':errors})
        return {'sha':sha,'mode':mode,'computers':list(installed),'errors':errors}

    def client_stop(self, name):
        for key in (name+':client',name+':xvfb'):
            if key in self.status():
                keeper.call(self.home,{'op':'signal','key':key})
                deadline=time.monotonic()+15
                while key in self.status() and time.monotonic()<deadline: time.sleep(.1)
                if key in self.status():
                    keeper.call(self.home,{'op':'signal','key':key,'force':True})
                    deadline=time.monotonic()+5
                    while key in self.status() and time.monotonic()<deadline: time.sleep(.1)
                    if key in self.status(): raise RuntimeError('Client process could not be stopped')
        return {'run':name,'client':'stopped'}

    def client(self, name, action):
        from client import client_action
        return client_action(self,name,action)

    def pool(self, action, count=0, prefix=None):
        owner=prefix or 'pool'
        self.run(owner+'-1')
        def owned(name):
            return re.fullmatch(re.escape(owner)+r'-[1-4]',name) is not None
        if action=='up':
            if not 1<=count<=4: raise ValueError('Pool size must be 1..4')
            for i in range(1,count+1):
                name=owner+'-'+str(i)
                if name not in self.status():
                    available=int(next(v.split()[1] for v in Path('/proc/meminfo').read_text().splitlines() if v.startswith('MemAvailable:')))
                    keeper.admit(3*1024*1024,available,os.getloadavg()[0],True)
                if not self.run(name).exists(): self.clone(name)
                self.serve(name)
        elif action=='down':
            for run in (self.home/'runs').glob('*'):
                if owned(run.name): self.stop(run.name)
        status=[]
        for key,pid in self.status().items():
            if prefix is not None and not owned(key.partition(':')[0]): continue
            try: rss=int(next(v.split()[1] for v in Path(f'/proc/{pid}/status').read_text().splitlines() if v.startswith('VmRSS:')))
            except (OSError,StopIteration): rss=None
            status.append({'run':key,'pid':pid,'rss_kib':rss,'port':self.state(key)['port'] if ':' not in key else None})
        return status


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--home')
    sub=parser.add_subparsers(dest='command',required=True)
    p=sub.add_parser('build-template');p.add_argument('--snapshot')
    for command in ('clone','serve','reset','stop'):
        p=sub.add_parser(command);p.add_argument('run')
    p=sub.add_parser('install');p.add_argument('run');p.add_argument('sha');p.add_argument('--mode',choices=['copy','installer','http'],default='copy')
    p=sub.add_parser('api');p.add_argument('run');p.add_argument('request');p.add_argument('--timeout',type=float,default=15)
    p=sub.add_parser('client');p.add_argument('run');p.add_argument('action',choices=['start','shot','stop'])
    p=sub.add_parser('pool');p.add_argument('action',choices=['up','down','status']);p.add_argument('count',type=int,nargs='?',default=0);p.add_argument('--prefix')
    args=parser.parse_args();start=time.monotonic()
    try:
        runtime=Runtime(args.home)
        if args.command=='build-template': result=runtime.build_template(args.snapshot)
        elif args.command=='api': result=runtime.request(args.run,json.loads(args.request),args.timeout)
        elif args.command=='install': result=runtime.install(args.run,args.sha,args.mode)
        elif args.command=='pool': result=runtime.pool(args.action,args.count,args.prefix)
        elif args.command=='client': result=runtime.client(args.run,args.action)
        else: result=getattr(runtime,args.command)(args.run)
        print(json.dumps({'ok':True,'result':result,'elapsed_s':round(time.monotonic()-start,3)}))
    except (OSError,ValueError,RuntimeError,KeyError,StopIteration,subprocess.SubprocessError) as exc:
        print(json.dumps({'ok':False,'error':str(exc)}));return 1
    return 0


if __name__=='__main__':
    raise SystemExit(main())
