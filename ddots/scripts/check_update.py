"""Exercise real Sparkle replacement using disposable apps and a loopback server.

No installed ddots, real account, Keychain credential, or remote release is used.
Run on a logged-in macOS desktop after scripts/fetch_sparkle.sh.
"""
import argparse
import base64
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import threading
import time
import uuid
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPARKLE = ROOT / '.build/sparkle-2.10.0'
NS = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', NS)


def run(*args):
    return subprocess.run([str(a) for a in args], check=True, capture_output=True, text=True).stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--framework', type=Path, default=SPARKLE / 'Sparkle.framework',
                        help='최종 앱에 포함한 프레임워크로도 검사 가능')
    parser.add_argument('--cases', nargs='+', choices=['success', 'cancel', 'bad-archive', 'bad-feed', 'download-failure', 'prepare-failure'],
                        default=['success', 'cancel', 'bad-archive', 'bad-feed', 'download-failure', 'prepare-failure'])
    args = parser.parse_args()
    framework = args.framework.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    executable = output / 'fixture'
    run('xcrun', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', ROOT / '.build/module-cache',
        '-F', framework.parent, '-framework', 'Sparkle', '-Xlinker', '-rpath', '-Xlinker', '@executable_path/../Frameworks',
        ROOT / 'Sources/UpdateUserDriver.swift', ROOT / 'Tests/UpdateSmoke.swift', '-o', executable)
    # The fixture's utility mode also needs the framework before it is bundled.
    environment = dict(os.environ, DYLD_FRAMEWORK_PATH=str(framework.parent))
    results = []
    for mode in args.cases:
        directory = output / mode
        directory.mkdir()
        key = directory / 'temporary.key'
        key.write_text(base64.b64encode(os.urandom(32)).decode())
        key.chmod(0o600)
        public = subprocess.check_output([str(executable), '--public-key', str(key)], env=environment, text=True).strip()
        identifier = 'io.github.hermes-ddots-p.ddots.update-smoke.' + uuid.uuid4().hex
        events = directory / 'events.txt'
        requests = []
        payloads = {}

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args): pass

            def do_GET(self):
                requests.append(dict(path=self.path, host=self.headers.get('Host'),
                                     authenticated=self.headers.get('Authorization') == 'Bearer synthetic-test',
                                     anyAuthorization=self.headers.get('Authorization') is not None))
                if self.path in ('/feed-api', '/asset-api'):
                    if self.headers.get('Authorization') != 'Bearer synthetic-test':
                        self.send_error(401); return
                    if self.path == '/asset-api' and mode == 'download-failure':
                        self.send_error(503); return
                    self.send_response(302)
                    target = '/feed.xml' if self.path == '/feed-api' else '/payload.zip'
                    self.send_header('Location', f'http://localhost:{self.server.server_port}{target}')
                    self.end_headers(); return
                body = payloads.get(self.path)
                if body is None: self.send_error(404); return
                self.send_response(200)
                self.send_header('Content-Type', 'application/octet-stream')
                self.send_header('Content-Length', str(len(body)))
                self.send_header('Content-Disposition', 'attachment; filename="' + self.path[1:] + '"')
                self.end_headers(); self.wfile.write(body)

        server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        base = f'http://127.0.0.1:{server.server_port}'
        installed = directory / 'installed/ddots Update Test.app'
        new = directory / 'new/ddots Update Test.app'
        for version, app in [('1', installed), ('2', new)]:
            macos = app / 'Contents/MacOS'; resources = app / 'Contents/Resources'
            macos.mkdir(parents=True); resources.mkdir()
            shutil.copy2(executable, macos / 'fixture')
            frameworks = app / 'Contents/Frameworks'; frameworks.mkdir()
            run('/usr/bin/ditto', framework, frameworks / 'Sparkle.framework')
            (resources / ('old-only.txt' if version == '1' else 'new-only.txt')).write_text(version)
            info = dict(CFBundleIdentifier=identifier, CFBundleExecutable='fixture', CFBundleName='ddots Update Test',
                        CFBundlePackageType='APPL', CFBundleVersion=version, CFBundleShortVersionString=version + '.0',
                        LSUIElement=True, LSMinimumSystemVersion='13.0', SUEnableAutomaticChecks=False,
                        SUAllowsAutomaticUpdates=False, SURequireSignedFeed=True, SUVerifyUpdateBeforeExtraction=True,
                        SUFeedURL=base + '/feed-api', SUPublicEDKey=public, FixtureLog=str(events), FixtureMode=mode,
                        NSAppTransportSecurity=dict(NSAllowsArbitraryLoads=True))
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            run('/usr/bin/codesign', '--force', '--sign', '-', app)
            run('/usr/bin/codesign', '--verify', '--deep', '--strict', app)
        archive = directory / 'new.zip'
        run('/usr/bin/ditto', '-c', '-k', '--keepParent', new, archive)
        signature = run(SPARKLE / 'bin/sign_update', '--ed-key-file', key, '-p', archive)
        feed = ET.Element('rss', {'version': '2.0'})
        channel = ET.SubElement(feed, 'channel')
        ET.SubElement(channel, 'title').text = 'ddots update fixture'
        item = ET.SubElement(channel, 'item')
        ET.SubElement(item, f'{{{NS}}}version').text = '2'
        ET.SubElement(item, f'{{{NS}}}shortVersionString').text = '2.0'
        ET.SubElement(item, 'description').text = 'Synthetic update'
        ET.SubElement(item, 'enclosure', {'url': base + '/asset-api', 'length': str(archive.stat().st_size),
                                        'type': 'application/zip', f'{{{NS}}}edSignature': signature})
        feed_file = directory / 'appcast.xml'
        feed_file.write_bytes(ET.tostring(feed, encoding='utf-8', xml_declaration=True))
        run(SPARKLE / 'bin/sign_update', '--ed-key-file', key, feed_file)
        payloads['/feed.xml'] = feed_file.read_bytes()
        payloads['/payload.zip'] = archive.read_bytes()
        if mode == 'bad-feed': payloads['/feed.xml'] = payloads['/feed.xml'].replace(b'Synthetic update', b'Tampered update!')
        if mode == 'bad-archive':
            body = bytearray(payloads['/payload.zip']); body[-1] ^= 1; payloads['/payload.zip'] = bytes(body)
        started = time.monotonic()
        try:
            with (directory / 'process.log').open('w') as log:
                process = subprocess.Popen([str(installed / 'Contents/MacOS/fixture')], stdout=log, stderr=subprocess.STDOUT)
                process.wait(timeout=55)
            if mode == 'success':
                deadline = time.monotonic() + 15
                while time.monotonic() < deadline and 'launched:2' not in events.read_text(): time.sleep(0.1)
            trace = events.read_text()
            actual = plistlib.loads((installed / 'Contents/Info.plist').read_bytes())['CFBundleVersion']
            redirected = [r for r in requests if r['path'] in ('/feed.xml', '/payload.zip')]
            assert redirected and not any(r['anyAuthorization'] for r in redirected), 'Authorization leaked on redirect'
            assert process.returncode == 0 and 'timeout' not in trace, trace
            if mode == 'success':
                assert actual == '2' and 'launched:2' in trace, trace
                assert not (installed / 'Contents/Resources/old-only.txt').exists(), 'old bundle was merged instead of replaced'
                assert (installed / 'Contents/Resources/new-only.txt').exists()
            else:
                assert actual == '1' and (installed / 'Contents/Resources/old-only.txt').exists(), trace
                assert 'launched:2' not in trace, trace
                if mode in ('cancel', 'prepare-failure'):
                    assert not any(r['path'] == '/asset-api' for r in requests), 'download started without permission'
                    assert 'skipped:none' in trace, 'temporary failure permanently skipped the release'
                else: assert 'error:' in trace, trace
            result = dict(mode=mode, passed=True, seconds=round(time.monotonic() - started, 3),
                          installedVersion=actual, requests=requests)
            results.append(result)
            (directory / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
            print(mode + ': PASS', flush=True)
        finally:
            if 'process' in locals() and process.poll() is None: process.terminate(); process.wait(timeout=5)
            server.shutdown(); server.server_close()
            key.unlink(missing_ok=True)
            # Only this fixture's preferences are removed; user app preferences are untouched.
            subprocess.run(['/usr/bin/defaults', 'delete', identifier], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    (output / 'summary.json').write_text(json.dumps(results, indent=2) + '\n')


if __name__ == '__main__': main()
