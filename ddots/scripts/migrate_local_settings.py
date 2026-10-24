#!/usr/bin/env python3
"""Explicit one-time local UI settings migration. No built-in organization values."""
import argparse,json,subprocess
from pathlib import Path
from export_config import atomic_json, mapping, picked, strings

def migrate(value):
    value=mapping(value)
    three=mapping(value.get('threeTap'))
    return dict(schemaVersion=1, order=strings(value.get('order')), excluded=strings(value.get('excluded')),
                colors=picked(value.get('colors'),mapping(value.get('colors')).keys()),
                roomPictures=picked(value.get('roomPictures'),mapping(value.get('roomPictures')).keys()),
                roomLabels=picked(value.get('roomLabels'),mapping(value.get('roomLabels')).keys()),
                homePicture=str(value.get('homePicture') or ''), homeLabel=str(value.get('homeLabel') or ''),
                senderPictures=picked(value.get('senderPictures'),mapping(value.get('senderPictures')).keys()),
                threeTap=picked(three,('channel','profile')),
                vaultBotUserID=str(value.get('vaultBotUserID') or ''))

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--input',type=Path);p.add_argument('--output',type=Path,required=True)
    p.add_argument('--from-defaults',action='store_true',help='Read only the existing shrimpBotUserID preference')
    a=p.parse_args();value=json.loads(a.input.read_text()) if a.input else {}
    if a.output.exists():p.error('기존 파일은 덮어쓰지 않습니다. 새 --output 경로를 지정하세요.')
    if a.from_defaults:
        result=subprocess.run(['defaults','read','io.github.hermes-ddots-p.ddots','shrimpBotUserID'],capture_output=True,text=True)
        if result.returncode==0:value.setdefault('vaultBotUserID',result.stdout.strip())
    try:atomic_json(a.output,migrate(value))
    except (ValueError,OSError) as exc:p.exit(1,str(exc)+'\n')
if __name__=='__main__':main()
