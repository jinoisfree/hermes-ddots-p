"""Build-time update and signing policy; private defaults remain unchanged."""
import argparse
import os
from pathlib import Path
import plistlib
import re

PUBLIC_REPOSITORY = 'jinoisfree/hermes-ddots-p'
PUBLIC_BUNDLE = 'io.github.hermes-ddots-p.ddots'
PUBLIC_IDENTITY = 'ddots Public Signing'


def policy(channel):
    if channel == 'private':
        return 'jinoisfree/hermes-ddots-p', 'io.github.hermes-ddots-p.ddots', 'ddots Public Signing'
    if channel == 'public':
        return PUBLIC_REPOSITORY, PUBLIC_BUNDLE, PUBLIC_IDENTITY
    raise ValueError('unknown update channel')


def configure(path, channel, previous_bundle=None):
    policy(channel)
    if previous_bundle and (channel != 'public' or previous_bundle == PUBLIC_BUNDLE or
                            not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+){2,}', previous_bundle)):
        raise ValueError('이전 설치의 번들 ID를 확인하세요.')
    if channel == 'private':
        return  # Preserve even the exact XML bytes of the existing plist.
    path = Path(path)
    info = plistlib.loads(path.read_bytes())
    info.update(CFBundleIdentifier=PUBLIC_BUNDLE, DDotsUpdateRepository=PUBLIC_REPOSITORY,
                DDotsUpdateRequiresToken=False)
    if previous_bundle:
        info['DDotsPreviousBundleIdentifiers'] = [previous_bundle]
    path.write_bytes(plistlib.dumps(info))


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('plist', type=Path)
    p.add_argument('--channel', choices=('private', 'public'), default='private')
    p.add_argument('--previous-bundle-id')
    a = p.parse_args()
    configure(a.plist, a.channel, a.previous_bundle_id)
