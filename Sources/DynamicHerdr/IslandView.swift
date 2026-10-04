import SwiftUI
import IslandCore

private let mint = Color(red: 0.65, green: 0.94, blue: 0.78)
private let amber = Color(red: 1, green: 0.77, blue: 0.42)
private let muted = Color.white.opacity(0.42)

struct IslandView: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var presentation: NotchPresentation

    var body: some View {
        let phase = presentation.phase
        let geometry = presentation.geometry
        let size = geometry.size(for: phase)
        ZStack(alignment: .top) {
            Color.black
            VStack(spacing: 0) {
                Color.clear.frame(height: geometry.notchHeight)
                if phase == .expanded { expanded }
                else if phase == .compact { compact }
            }
            .opacity(phase == .hidden ? 0 : 1)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .foregroundStyle(.white)
        .clipShape(NotchShape(shoulder: phase == .hidden ? 0 : 10, radius: phase == .expanded ? 26 : 18))
        .overlay {
            if phase == .compact {
                Button {
                    model.expand(); model.onTerminalFocus?()
                } label: {
                    NotchShape(shoulder: 10, radius: 18)
                        .fill(.clear)
                        .contentShape(NotchShape(shoulder: 10, radius: 18))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open \(model.selected?.displayName ?? "Herdr") terminal")
            }
        }
        .shadow(color: .black.opacity(phase == .hidden ? 0 : 0.35), radius: 16, y: 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }
    private var accent: Color { model.selected?.agentStatus == .blocked ? amber : mint }
    private var compact: some View {
        HStack(spacing: 10) {
                Circle().fill(accent).frame(width: 5, height: 5)
                Text(model.selected?.displayName ?? "herdr").fontWeight(.medium)
                Text(model.selected?.agentStatus == .blocked ? "needs you" : "finished").foregroundStyle(muted)
                Spacer()
                Text("⌃⌥Space").font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
        }.font(.system(size: 12)).padding(.horizontal, 24).frame(height: 44)
            .allowsHitTesting(false)
    }
    private var expanded: some View {
        VStack(spacing: 0) {
            agentRow
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            ZStack {
                if model.addingAgent {
                    NewAgentView(model: model)
                } else if let agent = model.selected {
                    NativeTerminal(model: model, agent: agent)
                        .id(agent.paneID + "|" + agent.terminalID + "|" + String(model.terminalGeneration))
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                        .opacity(model.showingHelp ? 0 : 1)
                        .allowsHitTesting(!model.showingHelp)
                    if !model.terminalReady && model.terminalError == nil && !model.showingHelp {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    home
                }
                if model.showingHelp { keyboardHelp.background(.black) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 8) {
                if let error = model.terminalError ?? model.error {
                    Text(error).foregroundStyle(amber).lineLimit(2)
                } else {
                    Text(model.prefixPending ? "⌃B  0 home · n/p switch · s settings · q close" :
                            model.addingAgent ? "" : model.isHome ? "↑↓ choose   ·   ↵ open   ·   esc close" : "⌃B 0 home   ·   ⌃B n/p switch   ·   ⌃B q close")
                        .foregroundStyle(model.prefixPending ? amber : muted)
                    Spacer()
                    Text(model.demo ? "demo" : "⌃B ?").foregroundStyle(muted)
                }
            }.font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 23).frame(height: 34)
        }.frame(width: presentation.geometry.expandedWidth - 24, height: presentation.geometry.contentHeight)
    }
    private var agentRow: some View {
        HStack(spacing: 8) {
            if model.isHome {
                Text(model.addingAgent ? "New terminal" : "Terminals").fontWeight(.medium)
                if !model.addingAgent { Text("\(model.agents.count)").foregroundStyle(muted) }
            } else {
                Button { model.showHome() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .medium))
                        .frame(width: 24, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain).help("All terminals · ⌃B 0").accessibilityLabel("All terminals")
                Circle().fill(accent).frame(width: 5, height: 5)
                Text(model.selected?.displayName ?? "herdr").fontWeight(.medium)
            }
            Text(model.selected?.project ?? "").foregroundStyle(muted)
            Spacer()
            if let agent = model.selected {
                Text(agent.agent == nil ? "terminal" : agent.agentStatus == .blocked ? "needs you" : agent.agentStatus == .done ? "finished" : agent.agentStatus.rawValue)
                    .foregroundStyle(accent).font(.system(size: 10))
            }
            if model.isHome && !model.addingAgent {
                Button { model.beginAddingAgent() } label: {
                    Image(systemName: "plus").font(.system(size: 13, weight: .medium))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain).help("New terminal · ⌘N").accessibilityLabel("New terminal")
                    .disabled(!model.connected)
            }
            if !model.isHome && model.visibleAgents.count > 1 {
                let index = model.visibleAgents.firstIndex { $0.identity == model.selected?.identity } ?? 0
                Text("\(index + 1)/\(model.visibleAgents.count)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted).padding(.leading, 8)
            }
        }.font(.system(size: 12)).padding(.horizontal, 23).frame(height: 38)
    }
    private var home: some View {
        Group {
            if model.agents.isEmpty {
                Text(model.connected ? "No open terminals" : "Connect to Herdr in Settings · ⌘,")
                    .font(.system(size: 13)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(model.agents) { agent in
                                Button {
                                    model.select(agent)
                                    model.onTerminalFocus?()
                                } label: {
                                    HStack(spacing: 12) {
                                        Circle().fill(statusColor(agent)).frame(width: 6, height: 6)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(agent.displayName).font(.system(size: 13, weight: .medium))
                                            Text(agent.project).font(.system(size: 11)).foregroundStyle(muted)
                                        }
                                        Spacer()
                                        Text(statusLabel(agent)).font(.system(size: 11)).foregroundStyle(statusColor(agent))
                                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .medium)).foregroundStyle(muted)
                                    }
                                    .padding(.horizontal, 14).frame(height: 58)
                                    .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(model.homeSelection?.id == agent.id ? 0.08 : 0)))
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain).disabled(!model.connected)
                                    .accessibilityLabel("\(agent.displayName), \(agent.project), \(statusLabel(agent))")
                                    .id(agent.id)
                            }
                        }.padding(.horizontal, 10).padding(.vertical, 8)
                    }
                    .onChange(of: model.homeSelectionID) { _, id in
                        if let id { scroll.scrollTo(id) }
                    }
                }
            }
        }
    }
    private func statusLabel(_ agent: Agent) -> String {
        guard agent.agent != nil else { return "terminal" }
        switch agent.agentStatus {
        case .blocked: return "needs you"
        case .done: return "finished"
        case .working: return "working"
        case .idle: return "idle"
        case .unknown: return "unknown"
        }
    }
    private func statusColor(_ agent: Agent) -> Color {
        switch agent.agentStatus {
        case .blocked: return amber
        case .working, .done: return mint
        case .idle, .unknown: return muted
        }
    }
    private var keyboardHelp: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Keyboard").font(.system(size: 14, weight: .medium)).padding(.bottom, 4)
            ForEach([
                ["⌃B 0", "All terminals"], ["⌃B n / p", "Switch terminal"], ["⌃B 1–9", "Jump to terminal"],
                ["⌃B q", "Close island"], ["⌃B s  or  ⌘,", "Settings"],
                ["⌃B o", "Open in Herdr"], ["⌃B z / x", "Snooze / dismiss"],
                ["⌃B r", "Reconnect terminal"], ["⌃B ⌃B", "Send literal Ctrl+B"]
            ], id: \.first) { pair in
                HStack { Text(pair[0]).font(.system(size: 11, design: .monospaced)).frame(width: 150, alignment: .leading); Text(pair[1]).foregroundStyle(muted) }
            }
            Text("Everything else goes straight to the terminal.\nEsc returns from this reference.")
                .foregroundStyle(muted).lineSpacing(5).padding(.top, 6)
        }.font(.system(size: 12)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
