import Foundation
import Darwin
import IslandCore

/// A real Unix-socket peer. No installed Herdr session is touched by these tests.
final class MockHerdr {
    let path = "/tmp/island-test-\(UUID().uuidString).sock"
    private let fd: Int32
    private let worker = DispatchQueue(label: "island.mock")
    private let lock = NSLock()
    private var history: [[String: Any]] = []
    var requests: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return history }

    init(handler: @escaping ([String: Any]) -> [String: Any]?) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, listen(fd, 10) == 0 else { Darwin.close(fd); throw HerdrError.message("Mock bind failed: \(errno)") }
        worker.async { [self] in
            while true {
                let connection = accept(fd, nil, nil)
                if connection < 0 { break }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while !bytes.contains(10) {
                    let n = recv(connection, &buffer, buffer.count, 0)
                    if n <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(n))
                }
                if let request = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] {
                    lock.lock(); history.append(request); lock.unlock()
                    if var reply = handler(request) {
                        reply["id"] = request["id"]
                        if let response = try? JSONSerialization.data(withJSONObject: reply) {
                            let line = response + Data([10])
                            // Fragment replies to exercise framing and partial reads.
                            for chunk in stride(from: 0, to: line.count, by: 13) {
                                let part = line.subdata(in: chunk..<min(chunk + 13, line.count))
                                _ = part.withUnsafeBytes { send(connection, $0.baseAddress!, part.count, 0) }
                            }
                        }
                    }
                }
                Darwin.close(connection)
            }
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        worker.sync {}
        unlink(path)
    }
}

final class HerdrClientTests {
    func testTerminalInventoryIncludesShellsAndAgentNames() async throws {
        var shell = try JSONSerialization.jsonObject(with: JSONEncoder().encode(agent(.unknown, pane: "w2:p4", terminal: "shell-terminal"))) as! [String: Any]
        shell.removeValue(forKey: "agent")
        shell["label"] = "dev server"
        var named = try JSONSerialization.jsonObject(with: JSONEncoder().encode(agent(.working))) as! [String: Any]
        named["name"] = "builder"
        let shellReply = shell, agentReply = named
        let server = try MockHerdr { request in
            switch request["method"] as? String {
            case "pane.list": return ["result": ["panes": [shellReply, agentReply]]]
            case "pane.get": return ["result": ["pane": shellReply]]
            default: return ["result": ["agents": [agentReply]]]
            }
        }
        defer { server.stop() }
        let client = HerdrClient(socketPath: server.path)
        let terminals = try await client.terminals()
        expectEqual(terminals.count, 2)
        expectEqual(terminals[0].displayName, "dev server")
        expect(terminals[0].agent == nil)
        expectEqual(terminals[1].displayName, "builder")
        let shellPane = try await client.pane("w2:p4")
        expectEqual(shellPane.terminalID, "shell-terminal")
    }

    func testCreateAgentUsesReturnedPaneAndStructuredDirectory() async throws {
        let directory = "/tmp/project with spaces;literal"
        let fixture = agent(.idle, pane: "w9:p7")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture))
        let server = try MockHerdr { request in
            if request["method"] as? String == "workspace.create" {
                return ["result": ["root_pane": ["pane_id": "w9:p7"]]]
            }
            return ["result": ["agent": encoded]]
        }
        defer { server.stop() }
        let client = HerdrClient(socketPath: server.path)
        let pane = try await client.createAgentWorkspace(directory: directory)
        let created = try await client.startAgent(kind: "codex", paneID: pane, name: "codex-test")
        expectEqual(created.id, "w9:p7")
        expectEqual(server.requests.count, 2)
        let workspace = server.requests[0]["params"] as! [String: Any]
        expectEqual(workspace["cwd"] as? String, directory)
        expectEqual(workspace["focus"] as? Bool, false)
        let start = server.requests[1]["params"] as! [String: Any]
        expectEqual(start["pane_id"] as? String, "w9:p7")
        expectEqual(start["kind"] as? String, "codex")
        expectEqual(start["timeout_ms"] as? Int, 30000)
    }

    func testAgentStartFailureIsNotRetried() async throws {
        let server = try MockHerdr { _ in ["error": ["message": "Agent requires setup"]] }
        defer { server.stop() }
        do {
            _ = try await HerdrClient(socketPath: server.path).startAgent(kind: "claude", paneID: "w9:p7", name: "claude-test")
            fail("Expected startup failure")
        } catch { expectEqual(error.localizedDescription, "Agent requires setup") }
        expectEqual(server.requests.count, 1)
    }

    private func encoded(_ a: Agent) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
    }

    func testListAndFragmentedContextUseRealProtocolFields() async throws {
        let info = encoded(agent())
        let server = try MockHerdr { request in
            switch request["method"] as? String {
            case "agent.list": return ["result": ["type": "agent_list", "agents": [info]]]
            case "agent.read": return ["result": ["type": "pane_read", "read": ["text": "\u{1b}[32mAll tests passed\u{1b}[0m"]]]
            default: return nil
            }
        }
        defer { server.stop() }
        let client = HerdrClient(socketPath: server.path)
        let agents = try await client.agents()
        expectEqual(agents.count, 1)
        let text = try await client.read(agents[0].paneID)
        expectEqual(text, "All tests passed")
        let params = server.requests.last?["params"] as? [String: Any]
        expectEqual(params?["source"] as? String, "recent_unwrapped")
        expectEqual(params?["target"] as? String, "w1:p1")
    }

    func testPromptPreservesTextAndUsesIdentityPreflight() async throws {
        let expected = agent()
        let info = encoded(expected)
        let server = try MockHerdr { request in
            ["result": (request["method"] as? String == "agent.get") ? ["type": "agent_info", "agent": info] : ["type": "agent_prompted", "agent": info]]
        }
        defer { server.stop() }
        let text = "Review `$(do not execute)`\nwith \"quotes\" and emojis ✨"
        try await HerdrClient(socketPath: server.path).prompt(expected, text: text)
        expectEqual(server.requests.compactMap { $0["method"] as? String }, ["agent.get", "agent.prompt"])
        expectEqual((server.requests.last?["params"] as? [String: Any])?["text"] as? String, text)
    }

    func testStaleAgentNeverReceivesInput() async throws {
        let info = encoded(agent(terminal: "new"))
        let server = try MockHerdr { _ in ["result": ["type": "agent_info", "agent": info]] }
        defer { server.stop() }
        do { try await HerdrClient(socketPath: server.path).prompt(agent(), text: "hello"); fail("Expected identity rejection") }
        catch { expect(error.localizedDescription.contains("another agent")) }
        expectEqual(server.requests.count, 1)
    }

    func testBlockedKeyUsesAgentSurface() async throws {
        let expected = agent(.blocked)
        let info = encoded(expected)
        let server = try MockHerdr { request in
            if request["method"] as? String == "agent.get" {
                return ["result": ["type": "agent_info", "agent": info]]
            }
            return ["result": ["type": "ok"]]
        }
        defer { server.stop() }
        try await HerdrClient(socketPath: server.path).sendKey(expected, key: "enter")
        expectEqual(server.requests.compactMap { $0["method"] as? String }, ["agent.get", "agent.send_keys"])
        let params = server.requests.last?["params"] as? [String: Any]
        expectEqual(params?["keys"] as? [String], Optional(["enter"]))
    }

    func testServerRejectionIsSurfaced() async throws {
        let server = try MockHerdr { _ in ["error": ["code": "agent_blocked", "message": "Agent is blocked"]] }
        defer { server.stop() }
        do { _ = try await HerdrClient(socketPath: server.path).agents(); fail("Expected server error") }
        catch { expectEqual(error.localizedDescription, "Agent is blocked") }
    }

    func testTypedAnswerChecksContextAndUsesLogicalKeys() async throws {
        let expected = agent(.blocked)
        let info = encoded(expected)
        let server = try MockHerdr { request in
            switch request["method"] as? String {
            case "agent.read": return ["result": ["type": "pane_read", "read": ["text": "What should I do?"]]]
            case "agent.get": return ["result": ["type": "agent_info", "agent": info]]
            default: return ["result": ["type": "ok"]]
            }
        }
        defer { server.stop() }
        try await HerdrClient(socketPath: server.path).answer(expected, text: "A + B", reviewedContext: "What should I do?")
        expectEqual(server.requests.compactMap { $0["method"] as? String }, ["agent.read", "agent.get", "agent.send_keys"])
        let params = server.requests.last?["params"] as? [String: Any]
        expectEqual(params?["keys"] as? [String], Optional(["A", "space", "plus", "space", "B", "enter"]))
    }

    func testChangedQuestionNeverReceivesTypedAnswer() async throws {
        let server = try MockHerdr { _ in ["result": ["type": "pane_read", "read": ["text": "A different question"]]] }
        defer { server.stop() }
        do {
            try await HerdrClient(socketPath: server.path).answer(agent(.blocked), text: "yes", reviewedContext: "Old question")
            fail("Expected changed-question rejection")
        } catch { expect(error.localizedDescription.contains("question changed")) }
        expectEqual(server.requests.count, 1)
    }

    func testMultilineBlockedAnswerDoesNotWriteAnyKeys() async {
        do {
            try await HerdrClient(socketPath: "/tmp/not-connected.sock").answer(agent(.blocked), text: "first\nsecond", reviewedContext: "")
            fail("Expected single-line rejection")
        } catch { expect(error.localizedDescription.contains("single line")) }
    }

    func testUncertainMutationIsNeverRetried() async throws {
        let info = encoded(agent())
        let server = try MockHerdr { request in
            if request["method"] as? String == "agent.get" { return ["result": ["type": "agent_info", "agent": info]] }
            return nil
        }
        defer { server.stop() }
        do { try await HerdrClient(socketPath: server.path).prompt(agent(), text: "hello"); fail("Expected closed connection") }
        catch { expect(error.localizedDescription.contains("before trying again")) }
        expectEqual(server.requests.filter { $0["method"] as? String == "agent.prompt" }.count, 1)
    }

    func testMissingSocketFailsCleanly() async {
        do { _ = try await HerdrClient(socketPath: "/tmp/island-does-not-exist.sock").agents(); fail("Expected connection error") }
        catch { expect(error.localizedDescription.contains("Herdr is unavailable")) }
    }
}
