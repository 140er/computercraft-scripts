"""Prepare a copied Gate B world with native Minecraft fixture commands."""
import json
from pathlib import Path
import shutil
import time


def farm_allowlist(world, farm):
    """Read connected oak stems and canopies from the cold template only."""
    import nbt
    ground = farm['ground']
    x1, z1, x2, z2 = farm['area']
    # Older prepared templates declared their four roots through the farm corners.
    roots = farm.get('trees', [[x, ground + 1, z] for x, z in ((x1,z1),(x2,z1),(x1,z2),(x2,z2))])
    species = farm['species']
    chunks, blocks = {}, {}
    for root in roots:
        rx, ry, rz = root
        if nbt.block(world, root, chunks)['block']['Name'] != species + '_log':
            raise ValueError('Cold farm template is missing a declared tree stem')
        pending, seen = [tuple(root)], set()
        while pending:
            pos = pending.pop()
            if pos in seen:
                continue
            seen.add(pos)
            x, y, z = pos
            # The fixture declares small oaks, with a two-block canopy radius.
            if abs(x-rx) > 2 or abs(z-rz) > 2 or not ground < y <= ground + 64:
                continue
            state = nbt.block(world, pos, chunks)['block']
            if state['Name'] not in (species + '_log', species + '_leaves'):
                continue
            blocks[pos] = state
            pending.extend((x+dx,y+dy,z+dz) for dx,dy,dz in ((1,0,0),(-1,0,0),(0,1,0),(0,-1,0),(0,0,1),(0,0,-1)))
    return {'source':str(world), 'trees':roots,
            'blocks':[{'pos':list(pos), 'block':blocks[pos]} for pos in sorted(blocks)]}


def lua(value):
    if value is None: return 'nil'
    if value is True: return 'true'
    if value is False: return 'false'
    if isinstance(value,str): return json.dumps(value)
    if isinstance(value,(float,int)): return str(value)
    if isinstance(value,list): return '{'+','.join(lua(v) for v in value)+'}'
    return '{'+','.join('['+lua(k)+']='+lua(v) for k,v in value.items())+'}'


def store(path, value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text(lua({'schema':1,'generation':1,'value':value}))


def clean_disks(runtime, name):
    manifest=runtime.manifest(name)
    for cid,comp in manifest['computers'].items():
        disk=runtime.computer_disk(name,cid)
        if comp['role']=='fixture': continue
        for path in list(disk.glob('so-journal*'))+list(disk.glob('so-code*')):
            path.unlink(missing_ok=True)
        shutil.rmtree(disk/'so-data',ignore_errors=True)
        shutil.rmtree(disk/'.gateb',ignore_errors=True)
        if comp['name']=='probe':
            from world import installer_manifest
            source=runtime.computer_disk(name,'wall')
            for relative in installer_manifest(source,'display'):
                target=disk/relative;target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(source/relative,target)
            for metadata in ('.so-files','.so-revision'):
                shutil.copy2(source/metadata,disk/metadata)
            for path in disk.glob('so-keys*'): path.unlink()
        runtime.instrument(disk,comp['role'])
    server=runtime.computer_disk(name,'server')
    store(server/'so-data/mine/job',{'homeSet':True,'dim':'minecraft:overworld','home':{'x':-5,'y':64,'z':4,'facing':2},'bottom':48,'length':16,'mode':'thorough','ores':{},'turtles':{},'progress':{'nextBranch':0,'done':0},'running':False})
    store(server/'so-data/lumber/job',{'dim':'minecraft:overworld','spots':{},'running':False,'phase':'scan','cursor':1,'logs':0,'inv':{},'fuel':0,'area':{'x1':5,'z1':5,'x2':9,'z2':9},'ground':63})


def prepare(runtime, name):
    proof=[]
    def command(text):
        result=runtime.command(name,text)
        deadline=time.monotonic()+15
        while 'not loaded' in result['output'].lower() and time.monotonic()<deadline:
            time.sleep(.1);result=runtime.command(name,text)
        if any(error in result['output'].lower() for error in ('not loaded','unknown or incomplete command','expected whitespace','incorrect argument','unknown block type')):
            raise RuntimeError('Native fixture command failed: '+text)
        proof.append({'command':text,'output':result['output']})
        return result['output']
    manifest=runtime.manifest(name)
    command('forceload add -32 -64 31 31')
    for cid in manifest['computers']:
        command('computercraft shutdown #'+cid)
    # Remove the native old turtle blocks before filling fresh mining branches.
    for cid in ('4','5','6'):
        old=manifest['computers'][cid]['pos']
        command('setblock '+' '.join(map(str,old))+' minecraft:air')
    command('fill -22 47 5 -4 50 24 minecraft:stone')
    command('fill -5 48 5 -5 64 5 minecraft:air')
    for z in (13,17): command(f'fill -11 48 {z} -6 48 {z} minecraft:iron_ore')
    starts={'4':([-5,64,3],'south','diamond_pickaxe'),'5':([-7,64,3],'north','diamond_pickaxe'),'6':([3,64,7],'east','diamond_axe')}
    for cid,(pos,facing,tool) in starts.items():
        xyz=' '.join(map(str,pos))
        command(f'setblock {xyz} computercraft:turtle_advanced[facing={facing}]'+'{ComputerId:'+cid+',On:0b,Fuel:10000,LeftUpgrade:{id:"minecraft:'+tool+'"},RightUpgrade:{id:"computercraft:wireless_modem_normal"},Items:[]}')
        output=command(f'data get block {xyz} ComputerId')
        if f'has the following block data: {cid}' not in output:
            raise RuntimeError('Native turtle placement failed for '+cid)
        command(f'data get block {xyz} Fuel')
        command(f'data get block {xyz} LeftUpgrade')
        command(f'data get block {xyz} RightUpgrade')
        manifest['computers'][cid].update(pos=pos,facing=facing)
    for fixture_name,fixture in manifest['fixtures'].items():
        if fixture['kind']!='chest': continue
        xyz=' '.join(map(str,fixture['pos']))
        command(f'setblock {xyz} minecraft:chest')
        command(f'data merge block {xyz} '+'{Items:[]}')
    for slot in range(4): command(f'item replace block -6 64 4 container.{slot} with minecraft:coal 64')
    command('item replace block 3 64 5 container.0 with minecraft:oak_sapling 64')
    command('item replace block -11 66 4 container.0 with minecraft:diamond 48')
    command('fill 5 63 5 9 63 9 minecraft:dirt')
    for x,z in ((5,5),(9,5),(5,9),(9,9)):
        command(f'fill {x-1} 67 {z-1} {x+1} 69 {z+1} minecraft:oak_leaves[persistent=true]')
        command(f'fill {x} 64 {z} {x} 68 {z} minecraft:oak_log')
    command('gamerule doDaylightCycle false');command('gamerule doWeatherCycle false')
    command('time set day');command('weather clear')
    manifest['mine']['starts']={cid:{'pos':starts[cid][0],'facing':starts[cid][1]} for cid in ('4','5')}
    manifest['prepared']=True
    from world import atomic
    atomic(runtime.run(name)/'manifest.json',manifest)
    for cid,comp in manifest['computers'].items():
        if comp['role']!='fixture' and not comp.get('requires_client'):
            command('computercraft turn-on #'+cid)
    probes=[cid for cid,comp in manifest['computers'].items() if comp.get('name')=='probe']
    for probe in probes:
        server=next(cid for cid,comp in manifest['computers'].items() if comp.get('name')=='server')
        deadline=time.monotonic()+30
        while True:
            try:
                result=runtime.request(name,{'op':'lua','computer':server,'code':f'return SO.pair.remember({int(probe)},nil)'})
                if result.get('values')==[True]: break
            except RuntimeError:
                pass
            if time.monotonic()>=deadline: raise RuntimeError('Could not clear the native pairing probe')
            time.sleep(.1)
    command('forceload remove all')
    command('forceload add '+' '.join(map(str,manifest['forceload'])))
    command('save-all flush')
    atomic(runtime.run(name)/'fixture-proof.json',{'at':time.time(),'commands':proof})
    return manifest
