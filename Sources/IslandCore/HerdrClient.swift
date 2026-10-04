import Foundation
import Darwin

public enum HerdrError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

public struct HerdrClient: Sendable {
    public let socketPath: String
    public init(socketPath: String) { self.socketPath = socketPath }

    public static func defaultSocket(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let path = environment["HERDR_SOCKET_PATH"], !path.isEmpty { return path }
        let config = environment["XDG_CONFIG_HOME"] ?? NSHomeDirectory() + "/.config"
        if let session = environment["HERDR_SESSION"], !session.isEmpty {
            return config + "/herdr/sessions/" + session + "/herdr.sock"
        }
        return config + "/herdr/herdr.sock"
    }

    public func agents() async throws -> [Agent] {
        struct Result: Decodable { let agents: [Agent] }
        return try await decode("agent.list", params: [:], as: Result.self).agents
    }

    public func panes() async throws -> [Agent] {
        struct Result: Decodable { let panes: [Agent] }
        return try await decode("pane.list", params: [:], as: Result.self).panes
    }

    public func pane(_ id: String) async throws -> Agent {
        struct Result: Decodable { let pane: Agent }
        return try await decode("pane.get", params: ["pane_id": id], as: Result.self).pane
    }

    public func terminals() async throws -> [Agent] {
        async let paneList = panes()
        async let agentList = agents()
        let (panes, agents) = try await (paneList, agentList)
        return panes.map { pane in
            agents.first { $0.paneID == pane.paneID && $0.terminalID == pane.terminalID && $0.agent == pane.agent } ?? pane
        }
    }

    public func focusPane(_ expected: Agent) async throws {
        let current = try await pane(expected.paneID)
        guard current.terminalID == expected.terminalID else { throw HerdrError.message("This terminal has left the pane.") }
        _ = try await request("pane.focus", params: ["pane_id": expected.paneID])
    }

    public func agent(_ target: String) async throws -> Agent {
        struct Result: Decodable { let agent: Agent }
        return try await decode("agent.get", params: ["target": target], as: Result.self).agent
    }

    public func createAgentWorkspace(directory: String) async throws -> String {
        struct Pane: Decodable { let pane_id: String }
        struct Result: Decodable { let root_pane: Pane }
        return try await decode("workspace.create", params: ["cwd": directory,
            "label": URL(fileURLWithPath: directory).lastPathComponent, "focus": false], as: Result.self).root_pane.pane_id
    }

    public func startAgent(kind: String, paneID: String, name: String) async throws -> Agent {
        guard ["claude", "codex"].contains(kind) else { throw HerdrError.message("Choose Claude or Codex.") }
        struct Result: Decodable { let agent: Agent }
        let data = try await request("agent.start", params: ["pane_id": paneID, "kind": kind,
            "name": name, "timeout_ms": 30000], timeout: 35)
        return try JSONDecoder().decode(Result.self, from: data).agent
    }

    public func read(_ target: String, visible: Bool = false) async throws -> String {
        struct Read: Decodable { let text: String }
        struct Result: Decodable { let read: Read }
        let result = try await decode("agent.read", params: ["target": target, "source": visible ? "visible" : "recent_unwrapped", "lines": 100, "format": "text", "strip_ansi": true], as: Result.self)
        return TerminalText.clean(result.read.text)
    }

    public func prompt(_ expected: Agent, text: String) async throws {
        let current = try await agent(expected.paneID)
        try ActionGuard.validate(expected: expected, current: current, prompt: true)
        _ = try await request("agent.prompt", params: ["target": expected.paneID, "text": text])
    }

    public func sendKey(_ expected: Agent, key: String) async throws {
        guard ["up", "down", "left", "right", "enter", "esc", "space", "1", "2", "3", "4", "5", "y", "n"].contains(key) else {
            throw HerdrError.message("Unsupported response key.")
        }
        let current = try await agent(expected.paneID)
        try ActionGuard.validate(expected: expected, current: current, prompt: false)
        _ = try await request("agent.send_keys", params: ["target": expected.paneID, "keys": [key]])
    }

    public func answer(_ expected: Agent, text: String, reviewedContext: String) async throws {
        guard !text.isEmpty, text.count <= 1000, text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw HerdrError.message("Use a single line of up to 1,000 characters for a waiting prompt.")
        }
        let latest = try await read(expected.paneID, visible: true)
        guard latest == reviewedContext else { throw HerdrError.message("The question changed. Refresh and review it before sending your answer.") }
        let current = try await agent(expected.paneID)
        try ActionGuard.validate(expected: expected, current: current, prompt: false)
        // Herdr validates the complete key list before writing. No shell or raw pane input.
        let keys = text.map { character -> String in
            switch character { case " ": return "space"; case "+": return "plus"; case "-": return "minus"; default: return String(character) }
        } + ["enter"]
        _ = try await request("agent.send_keys", params: ["target": expected.paneID, "keys": keys])
    }

    public func focus(_ expected: Agent) async throws {
        let current = try await agent(expected.paneID)
        guard current.identity == expected.identity else { throw HerdrError.message("This agent has left the pane.") }
        _ = try await request("agent.focus", params: ["target": expected.paneID])
    }

    private func decode<T: Decodable>(_ method: String, params: [String: Any], as type: T.Type) async throws -> T {
        try JSONDecoder().decode(type, from: await request(method, params: params))
    }

    private func request(_ method: String, params: [String: Any], timeout: TimeInterval = 5) async throws -> Data {
        let id = UUID().uuidString
        let payload = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params]) + Data([10])
        let path = socketPath
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let response = try SocketTransport.exchange(path: path, payload: payload, timeout: timeout)
                    guard let envelope = try JSONSerialization.jsonObject(with: response) as? [String: Any], envelope["id"] as? String == id else {
                        throw HerdrError.message("Herdr returned an invalid response.")
                    }
                    if let error = envelope["error"] as? [String: Any] {
                        throw HerdrError.message(error["message"] as? String ?? "Herdr could not complete that request.")
                    }
                    guard let result = envelope["result"] else { throw HerdrError.message("Herdr returned no result.") }
                    continuation.resume(returning: try JSONSerialization.data(withJSONObject: result))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

/// One bounded request per connection. Mutations are never retried automatically.
enum SocketTransport {
    static func exchange(path: String, payload: Data, timeout: TimeInterval = 5) throws -> Data {
        var address = sockaddr_un()
        let pathBytes = Array(path.utf8) + [0]
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw HerdrError.message("The Herdr socket path is too long.") }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HerdrError.message("Could not create a local connection.") }
        defer { Darwin.close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw HerdrError.message("Could not configure the local connection.") }
        let deadline = Date().addingTimeInterval(timeout)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { throw HerdrError.message("Herdr is unavailable. Start your session, or check the socket path in Settings.") }
            try wait(fd, for: Int16(POLLOUT), until: deadline)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout.size(ofValue: error))
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else { throw HerdrError.message("Could not connect to Herdr.") }
        }
        var offset = 0
        while offset < payload.count {
            try wait(fd, for: Int16(POLLOUT), until: deadline)
            let count = payload.withUnsafeBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: offset), payload.count - offset, 0) }
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw HerdrError.message("Connection interrupted. Check the agent before trying again.") }
            offset += count
        }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while result.count < 4 * 1024 * 1024 {
            try wait(fd, for: Int16(POLLIN), until: deadline)
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw HerdrError.message("Herdr closed the connection. Check the agent before trying again.") }
            result.append(contentsOf: buffer.prefix(count))
            if let newline = result.firstIndex(of: 10) { return result.prefix(upTo: newline) }
        }
        throw HerdrError.message("Herdr's response exceeded the size limit.")
    }

    private static func wait(_ fd: Int32, for event: Int16, until deadline: Date) throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw HerdrError.message("Herdr did not respond in time. Check the agent before retrying an action.") }
            var descriptor = pollfd(fd: fd, events: event, revents: 0)
            let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 5000)))
            if ready < 0 && errno == EINTR { continue }
            if ready > 0 { return }
            if ready == 0 { continue }
            throw HerdrError.message("Herdr did not respond in time. Check the agent before retrying an action.")
        }
    }
}
