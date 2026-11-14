// Only right/left/double clicks and Escape. Session focus and restoration belong to the wake-up context.
ObjC.import('Cocoa');
ObjC.import('CoreGraphics');
ObjC.import('ApplicationServices');
function run(argv) {
  const command = argv[0];
  if (!((command === 'escape' && argv.length === 1) ||
        ((command === 'right' || command === 'left' || command === 'double') && argv.length === 3 &&
         argv.slice(1).every(v => String(v).trim() !== '' && Number.isFinite(Number(v)))))) {
    throw new Error('INPUT_COMMAND_INVALID');
  }
  if (!$.AXIsProcessTrusted()) throw new Error('ACCESSIBILITY_PERMISSION_REQUIRED');
  const workspace = $.NSWorkspace.sharedWorkspace;
  const target = ObjC.unwrap(workspace.runningApplications).find(app => ObjC.unwrap(app.localizedName) === 'Windows App');
  if (!target) throw new Error('WINDOWS_APP_MISSING');
  if (workspace.frontmostApplication.processIdentifier !== target.processIdentifier) throw new Error('WINDOWS_APP_NOT_FRONT');
  const all = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, $.kCGNullWindowID)));
  const front = all.find(w => w.kCGWindowLayer === 0);
  if (!front || front.kCGWindowOwnerPID !== Number(target.processIdentifier)) throw new Error('SESSION_WINDOW_NOT_FRONT');
  // Windows App also owns a separate fullscreen toolbar; use the named session bounds, not that thin toolbar.
  const session = all.find(w => w.kCGWindowLayer === 0 && w.kCGWindowOwnerPID === Number(target.processIdentifier) &&
    (w.kCGWindowName || '').length > 0 && w.kCGWindowName !== 'Windows App');
  if (!session) throw new Error('SESSION_WINDOW_REQUIRED');
  const bounds = session.kCGWindowBounds;
  if (bounds.Width <= 0 || bounds.Height <= 0) throw new Error('SESSION_WINDOW_REQUIRED');
  const source = $.CGEventSourceCreate($.kCGEventSourceStateHIDSystemState);
  if (command === 'escape') {
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(source, 53, true));
    $.CGEventPost($.kCGHIDEventTap, $.CGEventCreateKeyboardEvent(source, 53, false));
  } else {
    const x = Number(argv[1]), y = Number(argv[2]);
    if (x < bounds.X || x >= bounds.X + bounds.Width || y < bounds.Y || y >= bounds.Y + bounds.Height) throw new Error('INPUT_OUTSIDE_SESSION');
    const point = $.CGPointMake(x, y);
    const right = command === 'right';
    const button = right ? $.kCGMouseButtonRight : $.kCGMouseButtonLeft;
    const down = $.CGEventCreateMouseEvent(source, right ? $.kCGEventRightMouseDown : $.kCGEventLeftMouseDown, point, button);
    const up = $.CGEventCreateMouseEvent(source, right ? $.kCGEventRightMouseUp : $.kCGEventLeftMouseUp, point, button);
    const count = command === 'double' ? 2 : 1;
    for (let click=1;click<=count;click++) {
      $.CGEventSetIntegerValueField(down, $.kCGMouseEventClickState, click);
      $.CGEventSetIntegerValueField(up, $.kCGMouseEventClickState, click);
      $.CGEventPost($.kCGHIDEventTap, down);
      $.NSThread.sleepForTimeInterval(0.08);
      $.CGEventPost($.kCGHIDEventTap, up);
      if (click<count) $.NSThread.sleepForTimeInterval(0.1);
    }
  }
  return JSON.stringify({state: 'sent', command: command});
}
