// Mac application/Space focus only. No Windows mouse/keyboard events, credentials or reconnection.
ObjC.import('Cocoa'); ObjC.import('CoreGraphics');
// Pump AppKit notifications: blocking NSThread sleep leaves frontmostApplication stale.
const pause = seconds => $.NSRunLoop.currentRunLoop.runUntilDate($.NSDate.dateWithTimeIntervalSinceNow(seconds));
function run(argv) {
  const ws = $.NSWorkspace.sharedWorkspace;
  const apps = () => ObjC.unwrap(ws.runningApplications);
  if (argv[0] === 'remember' && argv.length === 1) return JSON.stringify({pid:Number(ws.frontmostApplication.processIdentifier)});
  if (argv[0] === 'restore' && argv.length === 2 && /^\d+$/.test(argv[1])) {
    const previous = apps().find(app => Number(app.processIdentifier) === Number(argv[1]));
    if (!previous) return JSON.stringify({ok:false, reason:'PREVIOUS_APP_GONE'});
    if (Number(ws.frontmostApplication.processIdentifier) !== Number(argv[1])) {
      // Apple-event activation also returns to the app's Space; NSRunningApplication only changes focus.
      const bundle = ObjC.unwrap(previous.bundleIdentifier);
      if (!bundle) return JSON.stringify({ok:false, reason:'PREVIOUS_APP_UNIDENTIFIED'});
      Application(bundle).activate();
    }
    for (let n=0;n<10;n++) {
      if (Number(ws.frontmostApplication.processIdentifier) === Number(argv[1])) return JSON.stringify({ok:true});
      pause(1);
    }
    return JSON.stringify({ok:false,reason:'RESTORE_TIMEOUT'});
  }
  if (argv[0] !== 'focus' || argv.length !== 4 || !argv[1] || !argv.slice(2).every(v=>/^\d+$/.test(v))) throw Error('FOCUS_ARGUMENT_INVALID');
  const previous = {pid:Number(ws.frontmostApplication.processIdentifier)};
  try {
    const target = apps().find(app=>ObjC.unwrap(app.localizedName)==='Windows App');
    if (!target) return JSON.stringify({ok:false,previous:previous,reason:'WINDOWS_APP_MISSING'});
    target.activateWithOptions($.NSApplicationActivateIgnoringOtherApps);
    pause(0.3);
    const proc = Application('System Events').processes.byName('Windows App');
    proc.menuBars[0].menuBarItems.byName('Window').menus[0].menuItems.byName(argv[1]).actions.byName('AXPress').perform();
    for (let n=0;n<10;n++) {
      const windows=ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly,$.kCGNullWindowID)));
      if (Number(ws.frontmostApplication.processIdentifier)===Number(target.processIdentifier) && windows.some(w=>
        w.kCGWindowOwnerPID===Number(target.processIdentifier) && w.kCGWindowLayer===0 &&
        (w.kCGWindowName||'').toLowerCase().includes(argv[1].toLowerCase()) &&
        w.kCGWindowBounds.Width>=Number(argv[2]) && w.kCGWindowBounds.Height>=Number(argv[3]))) return JSON.stringify({ok:true,previous:previous});
      pause(1);
    }
    return JSON.stringify({ok:false,previous:previous,reason:'FOCUS_TIMEOUT'});
  } catch(error) {
    return JSON.stringify({ok:false,previous:previous,reason:'FOCUS_FAILED:'+String(error)});
  }
}
