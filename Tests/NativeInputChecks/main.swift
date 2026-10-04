import AppKit
import SwiftTerm

final class Recorder: TerminalViewDelegate {
    var bytes = Data()
    func send(source: TerminalView, data: ArraySlice<UInt8>) { bytes.append(contentsOf: data) }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func bell(source: TerminalView) {}
}

let app = NSApplication.shared
let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
let recorder = Recorder()
view.terminalDelegate = recorder
// Mouse modes emitted by the official interactive attach client.
view.feed(text: "\u{1B}[?1049h\u{1B}[?1003h\u{1B}[?1006h")
func wheel(_ delta: Int32, pixels: Bool) {
    let cg = CGEvent(scrollWheelEvent2Source: nil, units: pixels ? .pixel : .line,
                     wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0)!
    cg.location = CGPoint(x: 40, y: 40)
    view.scrollWheel(with: NSEvent(cgEvent: cg)!)
}
func check(_ condition: Bool, _ name: String) {
    guard condition else { print("FAIL \(name)"); exit(1) }
    print("PASS \(name)")
}
recorder.bytes.removeAll()
wheel(1, pixels: true)
check(recorder.bytes.isEmpty, "sub-line trackpad motion is accumulated")
for _ in 0..<30 { wheel(1, pixels: true) }
let tracks = String(decoding: recorder.bytes, as: UTF8.self).components(separatedBy: "\u{1B}[<64;").count - 1
check((1...3).contains(tracks), "31 trackpad pixels produce only a few wheel reports")
recorder.bytes.removeAll()
wheel(1, pixels: false)
check(String(decoding: recorder.bytes, as: UTF8.self).contains("\u{1B}[<64;"), "mouse-wheel notch reports immediately")
recorder.bytes.removeAll()
for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
    let event = NSEvent.mouseEvent(with: type, location: NSPoint(x: 40, y: 350),
        modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
        eventNumber: 0, clickCount: 1, pressure: 1)!
    if type == .leftMouseDown { view.mouseDown(with: event) }
    else { view.mouseUp(with: event) }
}
let click = String(decoding: recorder.bytes, as: UTF8.self)
check(click.contains("\u{1B}[<0;") && click.contains("M") && click.contains("m"), "native click reports press and release")
