#!/usr/bin/env python3
"""Import missing hash-pinned assets from an existing unpacked PKG110 kit."""
import argparse
import hashlib
from pathlib import Path
import re
import uuid

PROJECT=Path(__file__).resolve().parent.parent


def digest(path):
    sha=hashlib.sha256()
    with path.open('rb') as stream:
        for data in iter(lambda:stream.read(8*1024*1024),b''): sha.update(data)
    return sha.hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source',type=Path)
    args=parser.parse_args()
    root=PROJECT/'installer'
    if (root/'.installer.lock').exists(): raise SystemExit('Close the installer first.')
    for line in (root/'SHA256SUMS.txt').read_text(encoding='ascii').splitlines():
        match=re.fullmatch(r'([0-9a-f]{64})  \./([A-Za-z0-9_./-]+)',line)
        if not match: raise SystemExit('Invalid checksum entry')
        expected,name=match.groups()
        relative=Path(name)
        if relative.is_absolute() or '..' in relative.parts: raise SystemExit('Unsafe path')
        target=root/relative
        if target.is_file():
            if digest(target)!=expected: raise SystemExit('Existing checksum mismatch: '+name)
            continue
        if relative.parts[0] not in ('images','bin','tools'): raise SystemExit('Missing source: '+name)
        source=args.source/relative
        if not source.is_file(): raise SystemExit('Missing asset: '+str(source))
        target.parent.mkdir(parents=True,exist_ok=True)
        temporary=target.with_name(target.name+'.part-'+uuid.uuid4().hex[:8])
        sha=hashlib.sha256()
        print('Importing '+name,flush=True)
        try:
            with source.open('rb') as src,temporary.open('xb') as dst:
                for data in iter(lambda:src.read(8*1024*1024),b''): sha.update(data); dst.write(data)
            if sha.hexdigest()!=expected: raise RuntimeError('Asset checksum mismatch: '+name)
            temporary.replace(target)
        finally:
            if temporary.exists(): temporary.unlink()
    print('All checksums match. No device commands were run.',flush=True)


if __name__=='__main__': main()
