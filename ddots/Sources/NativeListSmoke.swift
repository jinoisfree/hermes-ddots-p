import AppKit
import SwiftUI

private final class NativeDisclosureControl {
    var setExpanded: ((Bool) -> Void)?
    var expanded = false
}

private typealias NativeDisclosureState = SwiftUI.State<Bool>

private struct NativeDisclosureFixture: View {
    let control: NativeDisclosureControl
    @NativeDisclosureState private var expanded = false
    var body: some View {
        DisclosureGroup("합성 공동 기록", isExpanded: $expanded) {
            Text(String(repeating: "합성 기록의 높이 검사\n", count: 12))
        }
        .onAppear {
            control.expanded = expanded
            control.setExpanded = { expanded = $0 }
        }
        .onChange(of: expanded) { control.expanded = $0 }
    }
}

extension AppDelegate {
    /// No transport: a real reusable hosting cell and a real table observe local SwiftUI state.
    @MainActor func verifyNativeCellState(destination: URL) async {
        func settle() async { try? await Task.sleep(nanoseconds: 250_000_000) }
        let fixture = NativeDisclosureControl()
        func row(_ id: String) -> NativeThreadRow {
            NativeThreadRow(id: id, content: { AnyView(NativeDisclosureFixture(control: fixture)) })
        }
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let cell = NativeThreadList.Cell(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
        window.contentView = cell; window.orderFront(nil)
        cell.configure(row("first"), width: 296)
        await settle()
        smokeCheck(fixture.setExpanded != nil && !fixture.expanded, "A reusable card starts collapsed")
        fixture.setExpanded?(true); await settle()
        smokeCheck(fixture.expanded, "The card holds local disclosure state")
        cell.configure(row("first"), width: 296); await settle()
        smokeCheck(fixture.expanded, "Updating the same card preserves its local state")
        cell.configure(row("second"), width: 296); await settle()
        smokeCheck(!fixture.expanded, "Reusing the cell for another card resets local state")

        let isolated = SlackModel()
        let coordinator = NativeThreadList.Coordinator(model: isolated)
        defer { coordinator.disconnect() }
        let scroll = coordinator.makeScroll()
        window.contentView = scroll
        scroll.frame = NSRect(x: 0, y: 0, width: 320, height: 400)
        let heightControl = NativeDisclosureControl()
        let heightRow = NativeThreadRow(id: "height", content: { AnyView(NativeDisclosureFixture(control: heightControl)) })
        coordinator.update(rows: [heightRow], stamp: isolated.entryViewportStamp)
        await settle()
        let before = coordinator.table.rect(ofRow: 0).height
        heightControl.setExpanded?(true); await settle()
        let expanded = coordinator.table.rect(ofRow: 0).height
        let live = coordinator.table.view(atColumn: 0, row: 0, makeIfNecessary: false) as? NativeThreadList.Cell
        try? "state=\(heightControl.expanded) before=\(before) expanded=\(expanded) fitting=\(String(describing: live?.host.fittingSize)) attached=\(live?.window != nil)\n"
            .write(to: destination.appendingPathComponent("native-height-diagnostic.txt"), atomically: true, encoding: .utf8)
        smokeCheck(expanded > before + 50, "Local DisclosureGroup expansion increases only its table row height")
        heightControl.setExpanded?(false); await settle()
        let collapsed = coordinator.table.rect(ofRow: 0).height
        smokeCheck(abs(collapsed - before) < 2, "Local disclosure collapse restores the table row height")
        try? "PASS: reuse resets state; same ID retains state; heights=\(before),\(expanded),\(collapsed)\n"
            .write(to: destination.appendingPathComponent("native-cell-state.txt"), atomically: true, encoding: .utf8)
    }
}
