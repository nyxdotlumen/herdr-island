import Foundation

public enum AgentStatus: String, Codable, Sendable {
    case idle, working, blocked, done, unknown
    public var needsAttention: Bool { self == .blocked || self == .done }
}

public struct AgentSession: Codable, Equatable, Sendable {
    public let source: String
    public let agent: String
    public let kind: String
    public let value: String
}

public struct Agent: Codable, Identifiable, Equatable, Sendable {
    public let paneID: String
    public let terminalID: String
    public let workspaceID: String
    public let tabID: String
    public let agent: String?
    public let displayAgent: String?
    public let name: String?
    public let label: String?
    public let title: String?
    public let cwd: String?
    public let foregroundCwd: String?
    public let terminalTitleStripped: String?
    public let agentSession: AgentSession?
    public let agentStatus: AgentStatus
    public let focused: Bool
    public let revision: UInt64
    public let stateChangeSeq: UInt64?

    public var id: String { paneID }
    public var identity: String { "\(terminalID)|\(agent ?? "")|\(agentSession?.value ?? "")" }
    public var displayName: String { name ?? label ?? displayAgent ?? agent ?? terminalTitleStripped ?? "Terminal" }
    public var project: String {
        guard let path = foregroundCwd ?? cwd, !path.isEmpty else { return workspaceID }
        return URL(fileURLWithPath: path).lastPathComponent
    }
    public var taskTitle: String {
        for candidate in [title, terminalTitleStripped] {
            if let candidate, !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return candidate }
        }
        return agentStatus == .blocked ? "Your input is needed" : "Ready for your next step"
    }
    public var attentionKey: String { "\(paneID)|\(identity)|\(agentStatus.rawValue)|\(stateChangeSeq ?? 0)" }

    /// Herdr resolves attention by resuming work or clearing it to seen/idle.
    /// A seen completion need not increment the agent's state-change sequence.
    public func resolvesAttention(since previous: Agent) -> Bool {
        guard paneID == previous.paneID, identity == previous.identity else { return false }
        return (agentStatus == .working && previous.agentStatus != .working) ||
            (agentStatus == .idle && previous.agentStatus.needsAttention)
    }

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id", terminalID = "terminal_id", workspaceID = "workspace_id", tabID = "tab_id"
        case agent, displayAgent = "display_agent", name, label, title, cwd, foregroundCwd = "foreground_cwd"
        case terminalTitleStripped = "terminal_title_stripped", agentSession = "agent_session"
        case agentStatus = "agent_status", focused, revision, stateChangeSeq = "state_change_seq"
    }
}

public struct AttentionItem: Identifiable, Equatable, Sendable {
    public var agent: Agent
    public let arrivedAt: Date
    public var id: String { agent.paneID }
    public var key: String { agent.attentionKey }
}

/// State changes, not terminal redraws, define a new notification. Everything stays in memory.
public struct AttentionQueue: Sendable {
    public private(set) var items: [AttentionItem] = []
    private var previous: [String: Agent] = [:]
    private var dismissed: Set<String> = []
    private var snoozed: [String: Date] = [:]
    private var initialized = false

    public init() {}

    @discardableResult
    public mutating func reconcile(_ agents: [Agent], now: Date = Date()) -> [AttentionItem] {
        let liveIDs = Set(agents.map(\.paneID))
        let liveKeys = Set(agents.map(\.attentionKey))
        dismissed.formIntersection(liveKeys)
        snoozed = snoozed.filter { liveKeys.contains($0.key) }
        items.removeAll { !liveIDs.contains($0.id) }
        var arrivals: [AttentionItem] = []
        for agent in agents {
            let old = previous[agent.paneID]
            let sameRun = old?.attentionKey == agent.attentionKey
            if !agent.agentStatus.needsAttention {
                items.removeAll { $0.id == agent.paneID }
                continue
            }
            if dismissed.contains(agent.attentionKey) { continue }
            if let until = snoozed[agent.attentionKey], until > now {
                items.removeAll { $0.id == agent.paneID }
                continue
            }
            let waking = snoozed.removeValue(forKey: agent.attentionKey) != nil
            if let index = items.firstIndex(where: { $0.id == agent.paneID }), sameRun {
                items[index].agent = agent
            } else {
                items.removeAll { $0.id == agent.paneID }
                let item = AttentionItem(agent: agent, arrivedAt: now)
                items.append(item)
                // Existing completions are available in the inbox without a launch-time flood.
                if initialized || agent.agentStatus == .blocked || waking { arrivals.append(item) }
            }
        }
        previous = Dictionary(uniqueKeysWithValues: agents.map { ($0.paneID, $0) })
        initialized = true
        items.sort {
            if $0.agent.agentStatus != $1.agent.agentStatus { return $0.agent.agentStatus == .blocked }
            return $0.arrivedAt > $1.arrivedAt
        }
        return arrivals
    }

    public mutating func dismiss(_ item: AttentionItem) {
        dismissed.insert(item.key)
        items.removeAll { $0.key == item.key }
    }

    public mutating func snooze(_ item: AttentionItem, until: Date) {
        snoozed[item.key] = until
        items.removeAll { $0.key == item.key }
    }

    public mutating func reset() { self = AttentionQueue() }
}

public enum ActionGuard {
    public static func validate(expected: Agent, current: Agent, prompt: Bool) throws {
        guard current.paneID == expected.paneID, current.identity == expected.identity else {
            throw HerdrError.message("This pane now belongs to another agent. Reopen it before responding.")
        }
        guard current.agentStatus == expected.agentStatus,
              current.stateChangeSeq == expected.stateChangeSeq else {
            throw HerdrError.message("The agent has moved on. Refresh its context before responding.")
        }
        if prompt && current.agentStatus != .idle && current.agentStatus != .done {
            throw HerdrError.message("The agent is not ready for a follow-up. Review its current state first.")
        }
        if !prompt && current.agentStatus != .blocked {
            throw HerdrError.message("That question is no longer waiting for a response.")
        }
    }
}

public enum TerminalText {
    public static func clean(_ text: String) -> String {
        let noANSI = text.replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{7}\u{1B}]*(?:\u{7}|\u{1B}\\\\)", with: "", options: .regularExpression)
        return String(String.UnicodeScalarView(noANSI.unicodeScalars.filter {
            $0.value == 10 || $0.value == 9 || ($0.value >= 32 && $0.value != 127)
        })).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
