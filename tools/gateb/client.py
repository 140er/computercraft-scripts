"""Launch the installed local test client in a private Xvfb session."""
import hashlib
import json
import os
from pathlib import Path
import socket
import subprocess
import time
import uuid

import keeper
from world import WORK, copytree, locked


def arguments(entries, values):
    def subst(value):
        for key, replacement in values.items():
            value=value.replace('${'+key+'}',str(replacement))
        return value
    result=[]
    for entry in entries:
        if isinstance(entry,str): result.append(subst(entry));continue
        allowed=False
        for rule in entry.get('rules',[]):
            system=rule.get('os',{})
            if system.get('name','linux')=='linux' and system.get('arch','x86_64') in ('x86_64','amd64') and not any(rule.get('features',{}).values()):
                allowed=rule['action']=='allow'
        if allowed:
            value=entry['value'];result.extend(subst(v) for v in (value if isinstance(value,list) else [value]))
    return result


def client_action(runtime,name,action):
    run=runtime.run(name);state=runtime.state(name)
    if action=='stop': return runtime.client_stop(name)
    if name not in runtime.status(): raise RuntimeError('Start the run server first')
    with locked(run/'client.lock'):
        if action=='shot':
            if name+':client' not in runtime.status() or name+':xvfb' not in runtime.status():
                raise RuntimeError('Client or Xvfb is down; use client start to recover')
            display=(run/'display').read_text()
            target=run/'shots'/f'{time.time_ns()}.png';target.parent.mkdir(exist_ok=True)
            subprocess.run(['import','-window','root',str(target)],env={**os.environ,'DISPLAY':display},timeout=15,check=True)
            return {'path':str(target),'display':display}
        if name+':client' in runtime.status() and name+':xvfb' in runtime.status():
            return {'run':name,'client':'running','display':(run/'display').read_text()}
        runtime.client_stop(name)
        source=Path(runtime.config.get('client_source',WORK/'gateb-modpack/client')).resolve()
        client=run/'client'
        if not client.exists():
            client.mkdir()
            for directory in ('versions','libraries','assets','natives','mods','config'):
                copytree(source/directory,client/directory)
            for filename in ('gateb-libraries.json','options.txt'):
                if (source/filename).exists():
                    import shutil
                    shutil.copy2(source/filename,client/filename)
        # Choose and spawn the display while holding the pool allocation lock.
        with locked(runtime.home/'displays.lock'):
            used=[p.read_text() for p in (runtime.home/'runs').glob('*/display')]
            display=next((':'+str(n) for n in range(110,150) if ':'+str(n) not in used and not Path(f'/tmp/.X{n}-lock').exists()),None)
            if display is None: raise RuntimeError('No free Xvfb display')
            (run/'display').write_text(display)
            keeper.call(runtime.home,{'op':'start','key':name+':xvfb','argv':['Xvfb',display,'-screen','0','1280x720x24','-nolisten','tcp'],'cwd':str(run),'log':str(run/'xvfb.log')})
        deadline=time.monotonic()+10
        while time.monotonic()<deadline:
            try:
                with socket.socket(socket.AF_UNIX) as sock: sock.connect('/tmp/.X11-unix/X'+display[1:])
                break
            except OSError: time.sleep(.1)
        else:
            runtime.client_stop(name);raise RuntimeError('Xvfb did not become ready')
        try:
            version=json.loads((client/'versions/1.21.1/1.21.1.json').read_text())
            neo_paths=list((client/'versions').glob('neoforge-*/*.json'))
            if len(neo_paths)!=1: raise RuntimeError('Expected one installed NeoForge client version')
            neo=json.loads(neo_paths[0].read_text());libs=json.loads((client/'gateb-libraries.json').read_text())
            cp=[str(client/'libraries'/a['downloads']['artifact']['path']) for a in libs if a.get('downloads',{}).get('artifact')]
            user='GateBTester';uid=str(uuid.UUID(bytes=hashlib.md5(('OfflinePlayer:'+user).encode()).digest(),version=3))
            values={'auth_player_name':user,'version_name':neo_paths[0].parent.name,'game_directory':client,'assets_root':client/'assets','assets_index_name':version['assetIndex']['id'],'auth_uuid':uid,'auth_access_token':'0','clientid':'0','auth_xuid':'0','user_type':'legacy','version_type':'release','natives_directory':client/'natives','launcher_name':'gateb-local-test','launcher_version':'1','classpath':os.pathsep.join(cp),'library_directory':client/'libraries','classpath_separator':os.pathsep}
            java=runtime.config.get('java',str(WORK/'gateb-runtime/java/bin/java'))
            argv=[java,'-Xms512M','-Xmx2G','-XX:MaxDirectMemorySize=256M','-XX:ActiveProcessorCount=2']+arguments(version['arguments']['jvm'],values)+arguments(neo['arguments']['jvm'],values)+[neo['mainClass']]+arguments(version['arguments']['game'],values)+arguments(neo['arguments']['game'],values)+['--width','1280','--height','720','--quickPlayMultiplayer',f'127.0.0.1:{state["port"]}']
            result=keeper.call(runtime.home,{'op':'start','key':name+':client','argv':argv,'cwd':str(client),'log':str(run/'client.log'),'env':{**os.environ,'DISPLAY':display,'LIBGL_ALWAYS_SOFTWARE':'1'},'memory_kib':3*1024*1024})
            return {**result,'display':display,'client':'starting','log':str(run/'client.log')}
        except Exception:
            runtime.client_stop(name);raise
