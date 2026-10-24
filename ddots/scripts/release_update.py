"""Prepare signed ddots assets locally, or explicitly publish a prepared release.

Publishing is a separate, approved remote write; prepare never writes to a remote.
Feed commits are created in a disposable repository, never in the source checkout.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

from update_installed import verify

ROOT = Path(__file__).resolve().parents[1]
SOURCE_ROOT = ROOT.parent
SOURCE_REPOSITORY = 'jinoisfree/hermes-ddots-p'
REPOSITORY = 'jinoisfree/hermes-ddots-p'
RELEASE_REMOTE = f'https://github.com/{REPOSITORY}.git'
ACCOUNT = os.environ.get('DDOTS_SPARKLE_ACCOUNT', 'io.github.hermes-ddots-p.ddots.updates')
CHANNEL = 'private'
SPARKLE = ROOT / '.build/sparkle-2.10.0/bin'
NAMESPACE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NAMESPACE)


def select_channel(channel):
    global CHANNEL, SOURCE_REPOSITORY, REPOSITORY, RELEASE_REMOTE
    if channel not in ('private', 'public'):
        raise ValueError('알 수 없는 배포 채널입니다.')
    CHANNEL = channel
    SOURCE_REPOSITORY = 'jinoisfree/hermes-ddots-p' if channel == 'public' else 'jinoisfree/hermes-ddots-p'
    REPOSITORY = 'jinoisfree/hermes-ddots-p' if channel == 'public' else 'jinoisfree/hermes-ddots-p'
    RELEASE_REMOTE = f'https://github.com/{REPOSITORY}.git'


def verify_app(app):
    if CHANNEL == 'private':
        verify(app)
    else:
        verify(app, channel='public')


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True, **kwargs).stdout.strip()


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest() if hasattr(hashlib, 'file_digest') else hashlib.sha256(stream.read()).hexdigest()


def prepare(app, destination):
    app = app.resolve()
    verify_app(app)
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    public = run(SPARKLE / 'generate_keys', '--account', ACCOUNT, '-p')
    if not public or public != info.get('SUPublicEDKey'):
        raise ValueError('앱과 릴리스 서명 키가 다릅니다.')
    version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
    if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}', version) or not re.fullmatch(r'[0-9]+', build):
        raise ValueError('배포 버전과 빌드 번호를 확인하세요.')
    source = json.loads((app / 'Contents/Resources/BuildInfo.json').read_text())
    if CHANNEL == 'public':
        from update_channel import PUBLIC_BUNDLE, PUBLIC_REPOSITORY
        if (info.get('CFBundleIdentifier') != PUBLIC_BUNDLE or
                info.get('DDotsUpdateRepository') != PUBLIC_REPOSITORY or
                info.get('DDotsUpdateRequiresToken') is not False):
            raise ValueError('공개 빌드의 업데이트 채널이 다릅니다.')
        top = Path(run('git', 'rev-parse', '--show-toplevel', cwd=ROOT)).resolve()
        if top != SOURCE_ROOT.resolve() or run('git', 'status', '--porcelain', '--untracked-files=all', cwd=top):
            raise ValueError('공개 소스 저장소 전체가 커밋된 상태여야 합니다.')
        head = run('git', 'rev-parse', 'HEAD', cwd=top)
        if source != dict(commit=head, dirty=False):
            raise ValueError('빌드 소스와 공개 저장소 HEAD가 다릅니다.')
    destination.mkdir(parents=True, exist_ok=False)
    archive = destination / f'ddots-{version}-arm64.zip'
    run('/usr/bin/ditto', '-c', '-k', '--keepParent', '--norsrc', '--noextattr', '--noqtn', app, archive)
    with tempfile.TemporaryDirectory(prefix='ddots-release-check-') as temporary:
        run('/usr/bin/ditto', '-x', '-k', archive, temporary)
        verify_app(Path(temporary) / app.name)
    signature = run(SPARKLE / 'sign_update', '--account', ACCOUNT, '-p', archive)
    manifest = dict(version=version, build=build, minimumSystem=info['LSMinimumSystemVersion'],
                    archive=archive.name, sha256=digest(archive), length=archive.stat().st_size,
                    signature=signature, publicKey=public, source=source)
    if CHANNEL == 'public': manifest['channel'] = 'public'
    (destination / 'prepared.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print(f'로컬 배포 파일 준비: {destination.name}/{archive.name}')
    print(f'소스 커밋: {source.get("commit")}; 미커밋 소스 포함: {source.get("dirty")}')
    print('GitHub 업로드·릴리스 공개·git push는 실행하지 않았습니다.')
    return manifest


def appcast(manifest, asset_id):
    if not isinstance(asset_id, int) or asset_id <= 0:
        raise ValueError('올바른 GitHub 배포 파일 ID가 필요합니다.')
    root = ET.Element('rss', {'version': '2.0'})
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'ddots 업데이트'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = 'ddots ' + manifest['version']
    ET.SubElement(item, f'{{{NAMESPACE}}}version').text = manifest['build']
    ET.SubElement(item, f'{{{NAMESPACE}}}shortVersionString').text = manifest['version']
    ET.SubElement(item, f'{{{NAMESPACE}}}minimumSystemVersion').text = manifest['minimumSystem']
    ET.SubElement(item, 'description').text = '설치를 누르면 ddots를 교체하고 다시 실행합니다. 설정과 대화 기록은 유지합니다.'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://api.github.com/repos/{REPOSITORY}/releases/assets/{asset_id}',
        'length': str(manifest['length']), 'type': 'application/zip',
        f'{{{NAMESPACE}}}edSignature': manifest['signature'],
        f'{{{NAMESPACE}}}installationType': 'application',
    })
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def check_prepared(destination, approval):
    manifest = json.loads((destination / 'prepared.json').read_text())
    if manifest.get('channel', 'private') != CHANNEL:
        raise ValueError('준비물과 선택한 배포 채널이 다릅니다.')
    commit = manifest['source'].get('commit')
    if not commit or not re.fullmatch(r'[a-f0-9]{40}', commit) or manifest['source'].get('dirty') is not False:
        raise ValueError('커밋된 소스로 다시 빌드한 앱만 배포할 수 있습니다.')
    if approval != commit:
        raise ValueError('대상 저장소·커밋·릴리스 배포 승인 후 --approve-commit에 정확한 커밋을 지정하세요.')
    archive = destination / manifest['archive']
    if archive.parent != destination or archive.is_symlink() or digest(archive) != manifest['sha256']:
        raise ValueError('준비한 ZIP의 지문이 달라졌습니다.')
    if archive.stat().st_size != manifest['length']:
        raise ValueError('ZIP 크기가 달라졌습니다.')
    run(SPARKLE / 'sign_update', '--account', ACCOUNT, '--verify', archive, manifest['signature'])
    return manifest, archive


def publish(destination, approval):
    manifest, archive = check_prepared(destination, approval)
    commit = manifest['source']['commit']
    # Require this exact commit to have been pushed to the only allowed remote.
    remote = run('git', 'remote', 'get-url', 'origin', cwd=SOURCE_ROOT)
    if remote not in (f'https://github.com/{SOURCE_REPOSITORY}.git', f'git@github.com:{SOURCE_REPOSITORY}.git'):
        raise ValueError('origin이 비공개 Hermes-ddots 소스 저장소가 아닙니다.')
    remote_heads = run('git', 'ls-remote', 'origin', 'refs/heads/main', cwd=SOURCE_ROOT).split()
    remote_head = remote_heads[0] if remote_heads else None
    if remote_head != commit:
        raise ValueError('승인된 커밋이 origin/main에 반영된 뒤 배포하세요.')
    tag = 'v' + manifest['version']
    # The source SHA is not present in the distribution-only repository.
    # Anchor the release tag to its existing main; provenance stays in BuildInfo
    # and the release notes. Never send source objects to that repository.
    target_refs = run('git', 'ls-remote', RELEASE_REMOTE, 'refs/heads/main', cwd=SOURCE_ROOT).split()
    if not target_refs or not re.fullmatch(r'[a-f0-9]{40}', target_refs[0]):
        raise ValueError('배포 저장소 main 커밋을 확인하지 못했습니다.')
    release_target = target_refs[0]
    if CHANNEL == 'public' and release_target != commit:
        raise ValueError('공개 릴리스 태그 대상이 승인된 소스 커밋과 다릅니다.')
    existing = run('git', 'ls-remote', RELEASE_REMOTE, 'refs/tags/' + tag,
                   'refs/tags/' + tag + '^{}', cwd=SOURCE_ROOT)
    if existing:
        raise ValueError('같은 버전의 배포 태그가 이미 있습니다. 기존 태그를 변경하지 않았습니다.')
    # Keep incomplete uploads invisible to automatic checks. Never replace an
    # existing release or upload with --clobber. A failed draft needs review
    # before retrying; this command never silently deletes it.
    run('gh', 'release', 'create', tag, archive, '--repo', REPOSITORY,
        '--target', release_target, '--draft', '--title', 'ddots ' + manifest['version'],
        '--notes', f'앱 내 업데이트용 서명 배포입니다. 소스: {SOURCE_REPOSITORY}@{commit}. 설치하면 기존 앱을 교체하고 다시 실행합니다.')
    # REST's by-tag endpoint only finds published releases. gh also looks up
    # pending draft tags; use its numeric ID to inspect the just-created draft.
    draft_id = run('gh', 'release', 'view', tag, '--repo', REPOSITORY, '--json', 'databaseId', '--jq', '.databaseId')
    if not draft_id.isdigit() or int(draft_id) <= 0:
        raise ValueError('만든 초안의 ID를 확인하지 못했습니다.')
    release = json.loads(run('gh', 'api', f'repos/{REPOSITORY}/releases/{draft_id}'))
    if not release.get('draft') or release.get('tag_name') != tag or release.get('target_commitish') != release_target:
        raise ValueError('릴리스 초안의 태그·소스 커밋이 다릅니다. 공개하지 않았습니다.')
    assets = [a for a in release['assets'] if a['name'] == archive.name]
    if len(assets) != 1:
        raise ValueError('업로드한 ZIP을 확인하지 못했습니다. 릴리스는 초안으로 남겼습니다.')
    asset = assets[0]
    if asset.get('state') != 'uploaded' or asset.get('size') != manifest['length'] or (
            asset.get('digest') and asset['digest'] != 'sha256:' + manifest['sha256']):
        raise ValueError('업로드한 ZIP의 크기·지문이 다릅니다. 릴리스는 초안으로 남겼습니다.')
    feed = destination / 'appcast.xml'
    feed.write_bytes(appcast(manifest, assets[0]['id']))
    run(SPARKLE / 'sign_update', '--account', ACCOUNT, feed)
    run(SPARKLE / 'sign_update', '--account', ACCOUNT, '--verify', feed)
    run('gh', 'release', 'upload', tag, feed, '--repo', REPOSITORY)
    run('gh', 'release', 'edit', tag, '--repo', REPOSITORY, '--draft=false', '--latest')
    publish_feed(feed, manifest['version'])
    print(f'서명된 업데이트 릴리스 공개: https://github.com/{REPOSITORY}/releases/tag/{tag}')


def publish_feed(feed, version):
    """Sparkle's feed request carries `Accept: application/rss+xml`, which GitHub's asset API answers with JSON.
    The app reads the feed from the `update-feed` branch's raw address instead; that branch holds only the signed
    appcast.xml, one commit per release, never merged into main."""
    with tempfile.TemporaryDirectory(prefix='ddots-feed-') as temporary:
        repository = Path(temporary)
        run('git', 'init', '--bare', repository)
        remote = run('git', 'ls-remote', RELEASE_REMOTE, 'refs/heads/update-feed', cwd=repository).split()
        parent = []
        if remote:
            # Fetch the actual parent object before commit-tree. A hash obtained
            # from ls-remote alone does not put that object in a fresh repository.
            run('git', 'fetch', '--no-tags', RELEASE_REMOTE, 'refs/heads/update-feed', cwd=repository)
            parent = ['-p', run('git', 'rev-parse', 'FETCH_HEAD', cwd=repository)]
        blob = run('git', 'hash-object', '-w', str(feed.resolve()), cwd=repository)
        tree = run('git', 'mktree', cwd=repository, input=f'100644 blob {blob}\tappcast.xml\n')
        commit = run('git', '-c', 'user.name=ddots release', '-c',
                     'user.email=ddots-release@users.noreply.github.com',
                     'commit-tree', tree, *parent, '-m', f'업데이트 목록 v{version}', cwd=repository)
        run('git', 'push', RELEASE_REMOTE, f'{commit}:refs/heads/update-feed', cwd=repository)
        result = run('git', 'ls-remote', RELEASE_REMOTE, 'refs/heads/update-feed', cwd=repository).split()
        if not result or result[0] != commit:
            raise ValueError('update-feed 브랜치가 새 목록을 가리키지 않습니다.')
    print(f'업데이트 목록 갱신: update-feed {commit}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    local = sub.add_parser('prepare', help='로컬 ZIP과 서명만 준비')
    local.add_argument('--app', type=Path, required=True)
    local.add_argument('--output', type=Path, required=True)
    remote = sub.add_parser('publish', help='별도 승인을 받은 릴리스 공개')
    remote.add_argument('--prepared', type=Path, required=True)
    remote.add_argument('--approve-commit', required=True)
    for command in (local, remote):
        command.add_argument('--channel', choices=('private', 'public'), default='private')
    args = parser.parse_args()
    select_channel(args.channel)
    if args.command == 'prepare': prepare(args.app, args.output.resolve())
    else: publish(args.prepared.resolve(), args.approve_commit)


if __name__ == '__main__':
    main()
