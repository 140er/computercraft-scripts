#!/usr/bin/env python3
"""Build, clone and exercise two native worlds, saving timings outside the repo."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import subprocess
import time

from world import REPO, Runtime, atomic


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--home');parser.add_argument('--reuse-template',action='store_true')
    args=parser.parse_args();runtime=Runtime(args.home)
    evidence=runtime.home/'evidence'/('smoke-'+time.strftime('%Y%m%d-%H%M%S'))
    evidence.mkdir(parents=True)
    report={'timings':{},'checks':{},'errors':[]}
    names=['smoke-'+str(time.time_ns())+'-'+str(i) for i in (1,2)]
    def timed(label, function):
        start=time.monotonic()
        try: return function()
        finally:
            report['timings'][label]=round(time.monotonic()-start,3)
            atomic(evidence/'result.json',report)
            print(label,report['timings'][label],flush=True)
    try:
        if not args.reuse_template:
            timed('build_template',runtime.build_template)
        else:
            report['template_reused']=True
        for name in names:
            timed('clone_'+name,lambda:runtime.clone(name))
        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda name:timed('serve_'+name,lambda:runtime.serve(name)),names))
        subprocess.run(['git','fetch','origin','server-only'],cwd=REPO,check=True)
        sha=subprocess.check_output(['git','rev-parse','origin/server-only'],cwd=REPO,text=True).strip()
        report['sha']=sha
        for name in names:
            timed('serve_warm_'+name,lambda:runtime.serve(name))
            installed=timed('install_'+name,lambda:runtime.install(name,sha))
            if installed['errors']: raise RuntimeError('Install reported errors: '+json.dumps(installed['errors']))
            deadline=time.monotonic()+30
            while True:
                try:
                    screen=runtime.request(name,{'op':'terminal','computer':1})
                    text='\n'.join(row['text'] for row in screen['lines'])
                    if not any(word in text.lower() for word in ('status','press p','turtles','leases')):
                        raise RuntimeError('Server status has not appeared')
                    break
                except (OSError,RuntimeError):
                    if time.monotonic()>deadline: raise
                    time.sleep(.2)
            atomic(evidence/(name+'-terminal.json'),screen)
            runtime.request(name,{'op':'save'})
            turtle=runtime.request(name,{'op':'turtle','computer':4})
            if turtle['pos']!=[-5,64,3] or turtle['facing']!='south':
                raise RuntimeError('Native turtle pose differs from prepared fixture')
            report['checks'][name]={'terminal_status':True,'turtle_pos':turtle['pos'],'turtle_facing':turtle['facing'],'installed_computers':installed['computers']}
        report['resources']=runtime.pool('status')
    except Exception as exc:
        report['errors'].append(str(exc))
        raise
    finally:
        for name in names:
            try: runtime.stop(name)
            except Exception as exc: report['errors'].append('Stop '+name+': '+str(exc))
        atomic(evidence/'result.json',report)
        print('Evidence:',evidence,flush=True)
    return bool(report['errors'])


if __name__=='__main__': raise SystemExit(main())
