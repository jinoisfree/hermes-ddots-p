// Opens a saved Windows App device and waits for its session window. It never types a credential or accepts a
// certificate: any prompt is read, cancelled, and reported, so a person decides.
ObjC.import('Foundation');
const pause = seconds => $.NSThread.sleepForTimeInterval(seconds);
const PAINT_SECONDS = 12;

function run(argv) {
  const device = argv[0], waitSeconds = Number(argv[1]), minWidth = Number(argv[2]), minHeight = Number(argv[3]);
  const events = Application('System Events');
  const proc = events.processes.byName('Windows App');
  // The caller starts the app just before this; a cold start takes a few seconds to show up.
  for (let tries = 0; tries < 20 && !proc.exists(); tries += 1) pause(1);
  if (!proc.exists()) return JSON.stringify({state: 'no_app'});
  proc.frontmost = true;

  const roles = (element, name, depth) => {
    if (depth > 9) return null;
    let description = '';
    try { description = element.description(); } catch (error) {}
    if (description === name) return element;
    let children = [];
    try { children = element.uiElements(); } catch (error) {}
    for (const child of children) {
      const found = roles(child, name, depth + 1);
      if (found) return found;
    }
    return null;
  };
  const hasInput = (element, depth) => {
    if (depth > 5) return false;
    let role = '';
    try { role = element.role(); } catch (error) {}
    if (role === 'AXTextField' || role === 'AXSecureTextField') return true;
    let children = [];
    try { children = element.uiElements(); } catch (error) {}
    return children.some(child => hasInput(child, depth + 1));
  };
  const texts = (element, depth, out) => {
    if (depth > 6) return out;
    let role = '';
    try { role = element.role(); } catch (error) {}
    if (role === 'AXStaticText') { try { out.push(String(element.value())); } catch (error) {} }
    let children = [];
    try { children = element.uiElements(); } catch (error) {}
    children.forEach(child => texts(child, depth + 1, out));
    return out;
  };
  const cancel = (container) => {
    const buttons = (element, depth) => {
      if (depth > 4) return null;
      let children = [];
      try { children = element.uiElements(); } catch (error) {}
      for (const child of children) {
        let role = '', title = '';
        try { role = child.role(); title = child.title(); } catch (error) {}
        if (role === 'AXButton' && title === 'Cancel') return child;
        const found = buttons(child, depth + 1);
        if (found) return found;
      }
      return null;
    };
    const button = buttons(container, 0);
    if (button) button.actions.byName('AXPress').perform();
  };

  let library = null;
  for (let tries = 0; tries < 15 && !library; tries += 1) {
    library = proc.windows().find(w => w.name() === 'Windows App') || null;
    if (!library) {
      try { proc.menuBars[0].menuBarItems.byName('Window').menus[0].menuItems.byName('Connection Center').click(); } catch (error) {}
      pause(1);
    }
  }
  if (!library) return JSON.stringify({state: 'no_app'});
  const tile = roles(library, device, 0);
  if (!tile) return JSON.stringify({state: 'no_device'});
  tile.actions.byName('AXPress').perform();

  for (let second = 0; second < waitSeconds; second += 1) {
    pause(1);
    let windows = [];
    try { windows = proc.windows(); } catch (error) {}
    for (const window of windows) {
      // Windows come and go while a session opens; one that vanishes between the listing and the read is skipped.
      let name = '', prompt = null, size = [0, 0];
      try {
        name = window.name();
        if (name === 'Windows App') continue;
        const sheets = window.sheets();
        if (sheets.length) prompt = sheets[0];
        else if (hasInput(window, 0)) prompt = window;
        size = window.size();
      } catch (error) { continue; }
      if (prompt) {
        // Whatever fails while reading or cancelling, the person still hears that a prompt appeared.
        let text = '';
        try { text = texts(prompt, 0, []).join(' '); } catch (error) {}
        try { cancel(prompt); } catch (error) {}
        return JSON.stringify({state: 'prompt', text: text});
      }
      if (name.toLowerCase().indexOf(device.toLowerCase()) >= 0 && size[0] >= minWidth && size[1] >= minHeight) {
        // The window opens before the remote desktop paints (the first capture came out black), so wait for it.
        pause(PAINT_SECONDS);
        return JSON.stringify({state: 'connected'});
      }
    }
  }
  return JSON.stringify({state: 'timeout'});
}
