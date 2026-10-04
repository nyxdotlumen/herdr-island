import Foundation
import IslandCore

final class TerminalSessionTests {
    func testAttachEnvironmentAndLiteralPrefix() {
        let env = HerdrAttach.environment(socket: "/tmp/test.sock", inherited: [
            "HERDR_SOCKET_PATH": "/wrong.sock", "HERDR_ENV": "1", "HERDR_SESSION": "user",
            "HERDR_PANE_ID": "w1:p1", "PATH": "/usr/bin"
        ])
        expectEqual(env["HERDR_SOCKET_PATH"], "/tmp/test.sock")
        expectEqual(env["PATH"], "/usr/bin")
        expectEqual(env["TERM"], "xterm-256color")
        expect(env["HERDR_ENV"] == nil && env["HERDR_SESSION"] == nil && env["HERDR_PANE_ID"] == nil)
        expectEqual(HerdrAttach.escapeInput(Data([2, 113, 3, 27, 91, 65])), Data([2, 2, 113, 3, 27, 91, 65]))
        let mouse = Data("\u{1B}[<0;5;3M\u{1B}[<0;5;3m\u{1B}[<64;5;3M".utf8)
        expectEqual(HerdrAttach.escapeInput(mouse), mouse)
    }

    func testStreamDecodesFragmentedAndCoalescedFrames() throws {
        let data = Data("\u{1B}[2J\u{1B}[Hhello שלום".utf8)
        let frame: [String: Any] = ["type": "terminal.frame", "encoding": "ansi", "bytes": data.base64EncodedString(), "width": 80, "height": 24, "seq": 1, "full": true]
        let wire = try JSONSerialization.data(withJSONObject: frame) + Data([10]) + Data("{\"type\":\"terminal.closed\",\"reason\":\"detached\"}\n".utf8)
        var decoder = TerminalStreamDecoder()
        var results: [TerminalEvent] = []
        for n in stride(from: 0, to: wire.count, by: 7) { results += try decoder.append(wire.subdata(in: n..<min(n+7, wire.count))) }
        expectEqual(results.count, 2)
        if case .frame(let result) = results[0] { expectEqual(result.bytes, data); expectEqual(result.width, 80) } else { fail("Missing frame") }
        if case .closed(let reason) = results[1] { expectEqual(reason, "detached") } else { fail("Missing closure") }
        var whole = TerminalStreamDecoder()
        let decoded = try whole.append(wire)
        expectEqual(decoded.count, 2)
    }
    func testInvalidFramesAreRejected() throws {
        for line in ["not json\n", "{\"type\":\"unexpected\"}\n", "{\"type\":\"terminal.frame\",\"encoding\":\"binary\"}\n"] {
            var decoder = TerminalStreamDecoder()
            expectThrows(try decoder.append(Data(line.utf8)))
        }
        var bounded = TerminalStreamDecoder()
        expectThrows(try bounded.append(Data(repeating: 65, count: 4 * 1024 * 1024 + 1)))
    }
    func testTerminalCommandsPreserveRawBytes() throws {
        let bytes = Data([27, 91, 66, 13, 3, 9, 127, 0, 255])
        let input = try JSONSerialization.jsonObject(with: TerminalCommand.input(bytes)) as! [String: Any]
        expectEqual(input["type"] as? String, "terminal.input")
        expectEqual(Data(base64Encoded: input["bytes"] as! String), bytes)
        let resize = try JSONSerialization.jsonObject(with: TerminalCommand.resize(cols: 0, rows: 24)) as! [String: Any]
        expectEqual(resize["cols"] as? Int, 1)
        expectEqual(resize["rows"] as? Int, 24)
        let release = try JSONSerialization.jsonObject(with: TerminalCommand.release) as! [String: Any]
        expectEqual(release["type"] as? String, "terminal.release")
    }
}
