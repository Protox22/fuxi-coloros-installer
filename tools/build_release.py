#!/usr/bin/env python3
"""Build verified FULL/INSTALLER ZIPs. Never execute adb or fastboot."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import zipfile

PROJECT=Path(__file__).resolve().parent.parent


def build(kind,version,root,out):
    names={}
    manifest=root/'SHA256SUMS.txt'
    for line in manifest.read_text(encoding='ascii').splitlines():
        match=re.fullmatch(r'([0-9a-f]{64})  \./([A-Za-z0-9_./-]+)',line)
        if not match: raise ValueError('Invalid checksum entry')
        expected,name=match.groups()
        path=Path(name)
        if path.is_absolute() or '..' in path.parts or '.' in path.parts or name in names: raise ValueError('Unsafe/duplicate path: '+name)
        names[name]=expected
    omitted=[]
    if kind=='installer':
        del names['images/super.img.zst']; omitted=['images/super.img.zst']
    names['SHA256SUMS.txt']=hashlib.sha256(manifest.read_bytes()).hexdigest()
    destination=out/f'FUXI-INSTALLER-{version}-PKG110-{kind.upper()}.zip'
    temporary=destination.with_suffix('.pending.zip')
    if destination.exists() or temporary.exists(): raise FileExistsError(str(destination))
    for name in names:
        path=root/name
        if not path.is_file() or path.is_symlink(): raise ValueError('Missing/unsafe file: '+name)
    print('Building '+destination.name,flush=True)
    with zipfile.ZipFile(temporary,'x',allowZip64=True) as archive:
        for name,expected in sorted(names.items()):
            path=root/name
            info=zipfile.ZipInfo('FUXI-INSTALLER/'+name)
            info.create_system=3
            info.external_attr=(stat.S_IFREG|(0o755 if name.endswith('.sh') else 0o644))<<16
            info.compress_type=zipfile.ZIP_STORED if name.endswith('.zst') else zipfile.ZIP_DEFLATED
            sha=hashlib.sha256()
            with path.open('rb') as src,archive.open(info,'w',force_zip64=path.stat().st_size>=2**31) as dst:
                for data in iter(lambda:src.read(8*1024*1024),b''): sha.update(data); dst.write(data)
            if sha.hexdigest()!=expected: raise ValueError('Source checksum mismatch: '+name)
    print('Checking ZIP CRC and every member SHA-256...',flush=True)
    with zipfile.ZipFile(temporary) as archive:
        if len(archive.infolist())!=len(names): raise ValueError('Incorrect member count')
        for name,expected in sorted(names.items()):
            sha=hashlib.sha256()
            with archive.open('FUXI-INSTALLER/'+name) as stream:
                for data in iter(lambda:stream.read(8*1024*1024),b''): sha.update(data)
            if sha.hexdigest()!=expected: raise ValueError('ZIP checksum mismatch: '+name)
    sha=hashlib.sha256()
    with temporary.open('rb') as stream:
        for data in iter(lambda:stream.read(8*1024*1024),b''): sha.update(data)
    temporary.replace(destination)
    return dict(file=destination.name,bytes=destination.stat().st_size,sha256=sha.hexdigest(),members=len(names),omitted=omitted,zip_crc_sha256_verified=True,device_commands_executed=False)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--kind',choices=['full','installer','both'],default='both')
    args=parser.parse_args()
    version=(PROJECT/'VERSION').read_text(encoding='ascii').strip()
    if not re.fullmatch(r'\d+\.\d+\.\d+',version): raise SystemExit('Invalid VERSION')
    out=PROJECT/'releases'; out.mkdir(exist_ok=True)
    kinds=['installer','full'] if args.kind=='both' else [args.kind]
    records=[build(kind,version,PROJECT/'installer',out) for kind in kinds]
    (out/f'FUXI-INSTALLER-{version}-build.json').write_text(json.dumps(records,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    checksums=out/'SHA256SUMS.txt'; existing={}
    if checksums.exists():
        for line in checksums.read_text(encoding='ascii').splitlines():
            value,name=line.split('  ',1); existing[name]=value
    for record in records: existing[record['file']]=record['sha256']
    checksums.write_text(''.join(existing[name]+'  '+name+'\n' for name in sorted(existing)),encoding='ascii')
    print(json.dumps(records,ensure_ascii=False,indent=2),flush=True)


if __name__=='__main__': main()
