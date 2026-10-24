#!/usr/bin/env python3
"""Optional isolated Sparkle integration test; requires macOS GUI + cryptography.
Run from the repository root after scripts/build.sh has fetched Sparkle.
Only temporary test apps, a generated test key and loopback HTTP are used.
--tamper checks rejection of an archive altered after signing.
"""
import base64, pathlib, plistlib, subprocess, tempfile, threading, http.server, time, os, json, sys, atexit
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization
root=pathlib.Path.cwd(); base=pathlib.Path(tempfile.mkdtemp(prefix='ddots-update-e2e-')); print('temporary root:',base,flush=True)
framework=root/'ddots/.build/sparkle-2.10.0/Sparkle.framework'
key=Ed25519PrivateKey.generate(); seed=key.private_bytes(serialization.Encoding.Raw,serialization.PrivateFormat.Raw,serialization.NoEncryption()); public=key.public_key().public_bytes(serialization.Encoding.Raw,serialization.PublicFormat.Raw)
keyfile=base/'test-key';keyfile.write_bytes(base64.b64encode(seed));keyfile.chmod(0o600); atexit.register(lambda: keyfile.unlink(missing_ok=True))
feed=base/'feed';feed.mkdir();home=base/'home';home.mkdir(); log=base/'events.log'
class Handler(http.server.SimpleHTTPRequestHandler):
 def __init__(self,*a,**kw):super().__init__(*a,directory=str(feed),**kw)
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler); port=server.server_port;threading.Thread(target=server.serve_forever,daemon=True).start()
source=base/'main.swift'
source.write_text('''import AppKit
import Sparkle
func report(_ s: String) { let u=URL(fileURLWithPath: "'''+str(log)+'''"); if !FileManager.default.fileExists(atPath:u.path) { FileManager.default.createFile(atPath:u.path,contents:nil) }; if let h=try? FileHandle(forWritingTo:u) { try? h.seekToEnd(); try? h.write(contentsOf:(s+"\\n").data(using:.utf8)!);try? h.close() } }
@MainActor final class Delegate: NSObject, NSApplicationDelegate, SPUUpdaterDelegate {
 var updater:SPUUpdater?; var driver:UpdateUserDriver?; var visibilityTimer:Timer?
 func applicationDidFinishLaunching(_ n:Notification) {
  let version=Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as! String; report("launched "+version)
  if version == "2" { report("PASS replacement relaunched");NSApp.terminate(nil);return }
  visibilityTimer=Timer.scheduledTimer(withTimeInterval:0.02,repeats:true) { _ in
   if NSApp.windows.contains(where: { $0.isVisible }) { report("ERROR unexpected window");NSApp.terminate(nil) }
  }
  let d=UpdateUserDriver(hostBundle:.main,delegate:nil);d.silent=true
  d.waitForIdle={ reply in
   let decision=UpdateIdlePolicy.decide(.init(idleSeconds:301,hasDrafts:false,transferring:false),elapsed:0)
   report("ready gate "+String(describing:decision));reply(decision == .install ? .install:.skip)
  };driver=d
  let u=SPUUpdater(hostBundle:.main,applicationBundle:.main,userDriver:d,delegate:self);updater=u
  do { try u.start();u.checkForUpdatesInBackground() } catch { report("ERROR "+error.localizedDescription);NSApp.terminate(nil) }
 }
 func updater(_ updater:SPUUpdater,didAbortWithError error:Error) { report("ERROR "+String(describing:error));NSApp.terminate(nil) }
 func applicationWillTerminate(_ n:Notification) { report("terminated") }
}
MainActor.assumeIsolated { let delegate=Delegate();let app=NSApplication.shared;app.delegate=delegate;app.setActivationPolicy(.prohibited);app.run() }
''')
def run(args,**kw):subprocess.run(list(map(str,args)),check=True,**kw)
for version in ('1','2'):
 app=base/('installed' if version=='1' else 'next')/'UpdateHarness.app';contents=app/'Contents';(contents/'MacOS').mkdir(parents=True);(contents/'Frameworks').mkdir()
 run(['ditto',framework,contents/'Frameworks/Sparkle.framework'])
 plist={'CFBundleIdentifier':'org.ddots.test.silent.'+base.name,'CFBundleName':'UpdateHarness','CFBundleExecutable':'UpdateHarness','CFBundleVersion':version,'CFBundleShortVersionString':version+'.0','CFBundlePackageType':'APPL','LSUIElement':True,'SUFeedURL':f'http://127.0.0.1:{port}/appcast.xml','SUPublicEDKey':base64.b64encode(public).decode(),'SUEnableAutomaticChecks':False,'SUAllowsAutomaticUpdates':False,'SUVerifyUpdateBeforeExtraction':True,'SURequireSignedFeed':True,'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True,'NSAllowsArbitraryLoads':True}}
 (contents/'Info.plist').write_bytes(plistlib.dumps(plist))
 run(['xcrun','swiftc','-swift-version','5','-F',framework.parent,'-framework','Sparkle','-Xlinker','-rpath','-Xlinker','@executable_path/../Frameworks',root/'ddots/Sources/UpdateUserDriver.swift',root/'ddots/Sources/UpdateIdlePolicy.swift',source,'-o',contents/'MacOS/UpdateHarness'])
 run(['codesign','--force','--deep','--sign','-',app])
archive=feed/'update.zip';run(['ditto','-c','-k','--keepParent',base/'next/UpdateHarness.app',archive])
signer=root/'ddots/.build/sparkle-2.10.0/bin/sign_update'
signature=subprocess.check_output([str(signer),'--ed-key-file',str(keyfile),'-p',str(archive)],text=True).strip()
(feed/'appcast.xml').write_text(f'''<?xml version="1.0" encoding="utf-8"?><rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Isolated test</title><item><title>2.0</title><sparkle:version>2</sparkle:version><sparkle:shortVersionString>2.0</sparkle:shortVersionString><enclosure url="http://127.0.0.1:{port}/update.zip" length="{archive.stat().st_size}" type="application/octet-stream" sparkle:edSignature="{signature}"/></item></channel></rss>''')
run([signer,'--ed-key-file',keyfile,feed/'appcast.xml']);keyfile.unlink()
if '--tamper' in sys.argv:
 with archive.open('ab') as stream: stream.write(b'tampered test archive')
env=dict(os.environ,HOME=str(home),CFFIXED_USER_HOME=str(home));process=subprocess.Popen([str(base/'installed/UpdateHarness.app/Contents/MacOS/UpdateHarness')],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
result='TIMEOUT'
for _ in range(120):
 time.sleep(1);text=log.read_text() if log.exists() else ''
 if 'PASS replacement relaunched' in text:result='PASS';break
 if 'ERROR' in text:result='FAIL';break
if process.poll() is None:process.terminate()
try:out,err=process.communicate(timeout=10)
except subprocess.TimeoutExpired:process.kill();out,err=process.communicate()
installed_version=plistlib.loads((base/'installed/UpdateHarness.app/Contents/Info.plist').read_bytes())['CFBundleVersion']
if '--tamper' in sys.argv and result == 'FAIL' and installed_version == '1' and 'Code=4005' in text and 'EdDSA signature does not match' in text and 'launched 2' not in text and 'unexpected window' not in text: result='PASS rejection'
if result == 'PASS' and installed_version != '2': result='FAIL wrong installed version'
server.shutdown();print(log.read_text() if log.exists() else 'no events',flush=True);print(err.decode()[-4000:],flush=True)
print('RESULT',result,flush=True)
(base/'result.json').write_text(json.dumps({'result':result,'events':log.read_text() if log.exists() else ''}))
raise SystemExit(0 if result.startswith('PASS') else 1)
