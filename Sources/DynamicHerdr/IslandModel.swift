import AppKit
import Combine
import IslandCore

@MainActor
final class IslandModel: ObservableObject {
    @Published var addingAgent = false
    @Published var newAgentKind = "claude"
    @Published var newAgentDirectory = ""
    @Published var launchingAgent = false
    @Published var launchError: String?
    @Published var launchAttempted = false
    @Published var agents: [Agent] = []
    @Published var homeSelectionID: String?
    @Published var items: [AttentionItem] = []
    @Published var selectedID: String?
    @Published var activeAgent: Agent?
    @Published var expanded = false
    @Published var connected = false
    @Published var error: String?
    @Published var terminalError: String?
    @Published var terminalReady = false
    @Published var terminalGeneration = 0
    @Published var terminalAvailable = true
    @Published var pausedUntil: Date?
    @Published var keyboardActive = false
    @Published var showingHelp = false
    @Published var prefixPending = false
    @Published var focusRequest = 0
    let demo: Bool
    var onPresent: (() -> Void)?
    var onNotification: (() -> Void)?
    var onCollapse: (() -> Void)?
    var onChange: (() -> Void)?
    var onSettings: (() -> Void)?
    var onTerminalFocus: (() -> Void)?
    var newAgentKey: ((IslandKey) -> Bool)?
    var editTerminal: ((IslandCommand) -> Void)?
    var sendLiteralPrefix: (() -> Void)?
    private var queue = AttentionQueue()
    private var task: Task<Void, Never>?
    private var demoAgents: [Agent] = []
    private var generation = 0
    private var refreshInFlight = false

    var selected: Agent? { expanded ? activeAgent : items.first(where: { $0.id == selectedID })?.agent ?? items.first?.agent }
    var isHome: Bool { expanded && activeAgent == nil }
    var visibleAgents: [Agent] { agents }
    var homeSelection: Agent? { agents.first { $0.id == homeSelectionID } ?? agents.first }
    var isPaused: Bool { (pausedUntil ?? .distantPast) > Date() }
    var socketPath: String {
        if let i = CommandLine.arguments.firstIndex(of: "--socket"), CommandLine.arguments.count > i + 1 {
            return NSString(string: CommandLine.arguments[i + 1]).expandingTildeInPath
        }
        return UserDefaults.standard.string(forKey: "socketPath") ?? HerdrClient.defaultSocket()
    }
    var executablePath: String {
        if let i = CommandLine.arguments.firstIndex(of: "--herdr"), CommandLine.arguments.count > i + 1 { return CommandLine.arguments[i + 1] }
        if let saved = UserDefaults.standard.string(forKey: "herdrExecutable"), !saved.isEmpty { return NSString(string: saved).expandingTildeInPath }
        let candidates = [ProcessInfo.processInfo.environment["HERDR_BIN_PATH"], NSHomeDirectory() + "/.local/bin/herdr", "/opt/homebrew/bin/herdr", "/usr/local/bin/herdr"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? NSHomeDirectory() + "/.local/bin/herdr"
    }
    var client: HerdrClient { HerdrClient(socketPath: socketPath) }
    init(demo: Bool) { self.demo = demo }

    func start() {
        task?.cancel()
        if demo { demoAgents = Demo.agents }
        task = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .milliseconds(self.connected ? (self.expanded ? 500 : 2000) : 5000))
            }
        }
    }
    func reconnect() {
        generation += 1
        queue.reset(); items = []; agents = []; homeSelectionID = nil; selectedID = nil; activeAgent = nil
        error = nil; terminalError = nil; connected = false
        terminalGeneration += 1
        start()
    }
    func refresh() async {
        guard !refreshInFlight else { return }
        refreshInFlight = true
        defer { refreshInFlight = false }
        let token = generation
        do {
            let agents = demo ? demoAgents : try await client.terminals()
            guard token == generation else { return }
            connected = true; error = nil
            if self.agents != agents { self.agents = agents }
            if !agents.contains(where: { $0.id == homeSelectionID }) { homeSelectionID = agents.first?.id }
            let arrivals = queue.reconcile(agents.filter { $0.agent != nil })
            if items != queue.items { items = queue.items }
            if expanded, let pinned = activeAgent {
                if let latest = agents.first(where: { $0.terminalID == pinned.terminalID && $0.id == pinned.id }) {
                    if latest.resolvesAttention(since: pinned) { collapse() }
                    else if activeAgent != latest { activeAgent = latest }
                } else {
                    terminalAvailable = false
                    terminalError = "This terminal has left the pane. Choose another pane with ⌃B n."
                }
            } else if !items.contains(where: { $0.id == selectedID }) { selectedID = items.first?.id }
            if !expanded, let first = arrivals.first { selectedID = first.id }
            let bundle = UserDefaults.standard.string(forKey: "terminalBundle") ?? "com.mitchellh.ghostty"
            let watching = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundle
            if arrivals.contains(where: { !(watching && $0.agent.focused) }), !isPaused, !expanded { onNotification?() }
            onChange?()
        } catch {
            guard token == generation else { return }
            connected = false; self.error = error.localizedDescription
            onChange?()
        }
    }
    func expand() {
        if !expanded {
            activeAgent = selected
            terminalAvailable = true; terminalError = nil; terminalReady = false
        }
        expanded = true
        onPresent?()
    }
    func collapse() {
        expanded = false; showingHelp = false; prefixPending = false
        activeAgent = nil; terminalReady = false
        onCollapse?()
    }
    func select(_ agent: Agent) {
        guard activeAgent?.identity != agent.identity else { return }
        selectedID = agent.id; homeSelectionID = agent.id; activeAgent = agent
        terminalAvailable = true; terminalError = nil; terminalReady = false
        showingHelp = false; focusRequest += 1
    }
    func beginAddingAgent() {
        showHome()
        launchError = nil; launchAttempted = false
        addingAgent = true
    }
    func cancelAddingAgent() {
        guard !launchingAgent else { return }
        addingAgent = false
    }
    func launchAgent() {
        guard !launchingAgent, !launchAttempted, connected, !demo else { return }
        let directory = NSString(string: newAgentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard directory.hasPrefix("/"), FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            launchError = "Choose an existing project folder."; return
        }
        let kind = newAgentKind
        let connection = client
        launchingAgent = true; launchError = nil; launchAttempted = true
        Task {
            var paneID: String?
            do {
                let pane = try await connection.createAgentWorkspace(directory: directory)
                paneID = pane
                let agent: Agent
                if kind == "terminal" {
                    agent = try await connection.pane(pane)
                } else {
                    agent = try await connection.startAgent(kind: kind, paneID: pane,
                        name: kind + "-" + String(UUID().uuidString.prefix(8)).lowercased())
                }
                await refresh()
                addingAgent = false
                if !agents.contains(where: { $0.id == agent.id }) { agents.append(agent) }
                select(agent)
            } catch {
                // A startup/trust prompt may be reported as blocked rather than ready.
                if let paneID, let agent = try? await connection.agent(paneID), agent.agent == kind {
                    await refresh(); addingAgent = false
                    if !agents.contains(where: { $0.id == agent.id }) { agents.append(agent) }
                    select(agent)
                } else {
                    launchError = error.localizedDescription + (paneID.map { " Workspace kept (\($0)). Check it in Herdr before starting another agent." } ?? " Check Herdr before starting again.")
                }
            }
            launchingAgent = false
        }
    }
    func showHome() {
        guard !launchingAgent else { return }
        addingAgent = false
        activeAgent = nil; terminalReady = false; terminalError = nil
        showingHelp = false; prefixPending = false
        // Dismantling the terminal releases its controller; ordinary keys now navigate the list.
    }
    func moveHomeSelection(_ offset: Int) {
        guard !agents.isEmpty else { return }
        let index = agents.firstIndex { $0.id == homeSelection?.id } ?? 0
        homeSelectionID = agents[(index + offset % agents.count + agents.count) % agents.count].id
    }
    func openHomeSelection() {
        guard let agent = homeSelection else { return }
        select(agent)
    }
    func selectRelative(_ offset: Int) {
        if isHome { moveHomeSelection(offset); return }
        let agents = visibleAgents
        guard !agents.isEmpty else { return }
        let index = agents.firstIndex { $0.identity == selected?.identity } ?? 0
        select(agents[(index + offset % agents.count + agents.count) % agents.count])
    }
    func selectIndex(_ index: Int) {
        guard visibleAgents.indices.contains(index) else { return }
        select(visibleAgents[index])
    }
    func reconnectTerminal() {
        terminalGeneration += 1; terminalError = nil; terminalReady = false
        focusRequest += 1
    }
    func toggleHelp() {
        showingHelp.toggle()
        if !showingHelp { focusRequest += 1 }
    }
    func openAgent() {
        guard let agent = selected, connected, !demo else { return }
        Task {
            do {
                try await client.focusPane(agent)
                let bundle = UserDefaults.standard.string(forKey: "terminalBundle") ?? "com.mitchellh.ghostty"
                collapse()
                NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate()
            } catch { self.terminalError = error.localizedDescription }
        }
    }
    func dismiss() {
        if let item = items.first(where: { $0.agent.identity == activeAgent?.identity }) { queue.dismiss(item) }
        removeSelection()
    }
    func snooze() {
        if let item = items.first(where: { $0.agent.identity == activeAgent?.identity }) { queue.snooze(item, until: Date().addingTimeInterval(600)) }
        removeSelection()
    }
    private func removeSelection() {
        items = queue.items
        if let agent = items.first?.agent { activeAgent = nil; select(agent) }
        else { collapse() }
        onChange?()
    }
    func togglePause() { pausedUntil = isPaused ? nil : Date().addingTimeInterval(1800); onChange?() }
    func replayDemo() {
        guard demo else { return }
        queue.reset(); demoAgents = Demo.agents; activeAgent = nil
        Task { await refresh(); if let first = items.first { select(first.agent) }; onPresent?() }
    }

    func submitDemoResponse(to agent: Agent) {
        guard demo else { return }
        demoAgents = demoAgents.map { $0.identity == agent.identity ? Demo.working($0) : $0 }
        Task { await refresh() }
    }
}

enum Demo {
    static var agents: [Agent] {
        let data = Data("""
        [
          {"pane_id":"w1:p1","terminal_id":"demo-codex","workspace_id":"w1","tab_id":"w1:t1","agent":"codex","name":"frontend","title":"A little more room to breathe","cwd":"/Projects/orbit","agent_status":"blocked","focused":false,"revision":42,"state_change_seq":3},
          {"pane_id":"w2:p3","terminal_id":"demo-claude","workspace_id":"w2","tab_id":"w2:t1","agent":"claude","name":"api","title":"Search is ready for a spin","cwd":"/Projects/atlas","agent_status":"done","focused":false,"revision":18,"state_change_seq":5},
          {"pane_id":"w2:p4","terminal_id":"demo-working","workspace_id":"w2","tab_id":"w2:t1","agent":"codex","name":"tests","cwd":"/Projects/atlas","agent_status":"working","focused":false,"revision":20,"state_change_seq":2},
          {"pane_id":"w3:p5","terminal_id":"demo-idle","workspace_id":"w3","tab_id":"w3:t1","agent":"claude","name":"review","cwd":"/Projects/folio","agent_status":"idle","focused":false,"revision":10,"state_change_seq":1},
          {"pane_id":"w3:p6","terminal_id":"demo-shell","workspace_id":"w3","tab_id":"w3:t1","label":"dev server","cwd":"/Projects/folio","agent_status":"unknown","focused":false,"revision":1}
        ]
        """.utf8)
        return try! JSONDecoder().decode([Agent].self, from: data)
    }

    static func working(_ agent: Agent) -> Agent {
        var json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(agent)) as! [String: Any]
        json["agent_status"] = "working"
        json["state_change_seq"] = (agent.stateChangeSeq ?? 0) + 1
        return try! JSONDecoder().decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func output(for agent: Agent, selection: Int = 1) -> String {
        if agent.agentStatus == .blocked {
            return """
            The new layout is in place. The content area now adapts
            to the sidebar, and the mobile navigation is ready.

            I'd like to run the browser checks before wrapping up.

              $ npm run test:e2e

            Would you like to run this command?

            \(selection == 1 ? "›" : " ") 1. Yes, run once
            \(selection == 2 ? "›" : " ") 2. No, and tell the agent what to do differently

            Press Enter to select · Esc to cancel
            """
        }
        return """
        Search is ready. You can now filter results by project,
        status, and date without losing your place.

        ✓ Added cursor pagination to /api/search
        ✓ Kept filters in the URL for shareable views
        ✓ Added coverage for empty and partial results

        Tests: 24 passed · Typecheck: passed

        Next step: try the search flow with a larger dataset.
        """
    }
}
