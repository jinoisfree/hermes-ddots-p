"""Build-time update and signing policy; private defaults remain unchanged."""
import argparse
import os
from pathlib import Path
import plistlib

PUBLIC_REPOSITORY = 'jinoisfree/hermes-ddots-p'
PUBLIC_BUNDLE = 'io.github.hermes-ddots-p.ddots'
PUBLIC_IDENTITY = 'ddots Public Signing'


def policy(channel):
    if channel == 'private':
        return 'jinoisfree/hermes-ddots-p', 'io.github.hermes-ddots-p.ddots', 'ddots Public Signing'
    if channel == 'public':
        return PUBLIC_REPOSITORY, PUBLIC_BUNDLE, PUBLIC_IDENTITY
    raise ValueError('unknown update channel')


def configure(path, channel):
    policy(channel)
    if channel == 'private':
        return  # Preserve even the exact XML bytes of the existing plist.
    path = Path(path)
    info = plistlib.loads(path.read_bytes())
    info.update(CFBundleIdentifier=PUBLIC_BUNDLE, DDotsUpdateRepository=PUBLIC_REPOSITORY,
                DDotsUpdateRequiresToken=False)
    path.write_bytes(plistlib.dumps(info))


if __name__ == '__main__':
    p = argparse.ArgumentParser()
    p.add_argument('plist', type=Path)
    p.add_argument('--channel', choices=('private', 'public'), default='private')
    a = p.parse_args()
    configure(a.plist, a.channel)
