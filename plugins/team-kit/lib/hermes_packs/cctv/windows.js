// Lists the Windows App windows of this login session as JSON. Needs Screen Recording for window titles.
ObjC.import('CoreGraphics');
function run(argv) {
  const all = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionAll, $.kCGNullWindowID)));
  const owner = argv[0];
  return JSON.stringify(all.filter(w => (w.kCGWindowOwnerName || '') === owner).map(w => ({
    number: w.kCGWindowNumber, name: w.kCGWindowName || '', layer: w.kCGWindowLayer,
    x: w.kCGWindowBounds.X, y: w.kCGWindowBounds.Y, width: w.kCGWindowBounds.Width, height: w.kCGWindowBounds.Height, onscreen: w.kCGWindowIsOnscreen === true })));
}
