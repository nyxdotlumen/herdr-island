import AppKit
import SwiftUI
import IslandCore

struct NewAgentView: View {
    @ObservedObject var model: IslandModel
    @FocusState private var directoryFocused: Bool
    @State private var zone = 1
    @State private var folders: [ProjectFolder] = []
    @State private var selectedPath: String?
    @State private var folderError: String?
    private let mint = Color(red: 0.65, green: 0.94, blue: 0.78)
    private let muted = Color.white.opacity(0.42)
    private var canStart: Bool { !model.launchingAgent && !model.launchAttempted && model.connected && !model.demo && !model.newAgentDirectory.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 4) {
                ForEach(["claude", "codex", "terminal"], id: \.self) { kind in
                    Button { model.newAgentKind = kind; focus(0) } label: {
                        HStack(spacing: 10) {
                            Text(kind == "claude" ? "Claude" : kind == "codex" ? "Codex" : "Terminal").fontWeight(.medium)
                            Text(kind == "claude" ? "⌘1" : kind == "codex" ? "⌘2" : "⌘3").foregroundStyle(muted)
                        }.font(.system(size: 12)).frame(maxWidth: .infinity).frame(height: 34)
                            .foregroundStyle(model.newAgentKind == kind ? mint : muted)
                            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(model.newAgentKind == kind ? 0.09 : 0)))
                    }.buttonStyle(.plain).accessibilityAddTraits(model.newAgentKind == kind ? .isSelected : [])
                }
            }.animation(.easeInOut(duration: 0.16), value: model.newAgentKind).padding(4).background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.035)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(zone == 0 ? mint.opacity(0.5) : .clear))
            HStack(spacing: 10) {
                Image(systemName: "folder").foregroundStyle(muted)
                TextField("~/Projects", text: $model.newAgentDirectory)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .focused($directoryFocused).accessibilityLabel("Project folder")
                Button(action: parentFolder) { Image(systemName: "arrow.up").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).foregroundStyle(muted).help("Parent folder · ⌘↑")
            }.padding(.horizontal, 12).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(zone == 1 ? mint.opacity(0.35) : .clear))
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(folders) { folder in
                            Button { open(folder) } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "folder").foregroundStyle(muted)
                                    Text(folder.name).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(muted)
                                }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 30)
                                    .background(RoundedRectangle(cornerRadius: 7).fill(.white.opacity(selectedPath == folder.path ? 0.08 : 0)))
                                    .contentShape(Rectangle())
                            }.buttonStyle(.plain).id(folder.path)
                        }
                        if folders.isEmpty {
                            Text(folderError ?? "No subfolders · use this folder or type a path")
                                .font(.system(size: 11)).foregroundStyle(muted).padding(.vertical, 16)
                        }
                    }
                }.onChange(of: selectedPath) { _, value in if let value { scroll.scrollTo(value) } }
            }.frame(maxHeight: .infinity)
            if let error = model.launchError {
                Text(error).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(3)
            }
            HStack {
                Button { model.cancelAddingAgent() } label: { Text("Back  esc").foregroundStyle(muted) }.buttonStyle(.plain)
                Spacer()
                if model.launchingAgent { ProgressView().controlSize(.small) }
                Button { model.launchAgent() } label: {
                    Text(model.launchingAgent ? "Starting…" : (model.newAgentKind == "terminal" ? "Open terminal  ⌘↵" : "Start agent  ⌘↵"))
                        .foregroundStyle(canStart ? mint : muted).padding(.horizontal, 14).frame(height: 32)
                        .background(RoundedRectangle(cornerRadius: 8).fill(mint.opacity(canStart ? 0.12 : 0.03)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(zone == 2 ? mint.opacity(0.5) : .clear))
                }.buttonStyle(.plain).disabled(!canStart)
            }.font(.system(size: 11))
            Text("tab focus · ←→ agent · ↑↓ folders · ↵ open · ⌘↑ parent")
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
        }
        .padding(.horizontal, 23).padding(.vertical, 14)
        .disabled(model.launchingAgent)
        .onAppear {
            if model.newAgentDirectory.isEmpty { model.newAgentDirectory = NSHomeDirectory() }
            focus(1)
            model.newAgentKey = handleKey
        }
        .onDisappear { model.newAgentKey = nil }
        .onChange(of: directoryFocused) { _, focused in if focused { zone = 1 } }
        .onChange(of: zone) { _, _ in model.newAgentKey = handleKey }
        .onChange(of: folders) { _, _ in model.newAgentKey = handleKey }
        .onChange(of: selectedPath) { _, _ in model.newAgentKey = handleKey }
        .task(id: model.newAgentDirectory) {
            let path = model.newAgentDirectory
            let result = await Task.detached(priority: .userInitiated) { Result { try ProjectFolders.list(path) } }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let values): folders = values; selectedPath = values.first?.path; folderError = nil
            case .failure: folders = []; selectedPath = nil; folderError = "Cannot read this folder. Type another path."
            }
        }
    }

    private func focus(_ value: Int) { zone = value; directoryFocused = value == 1 }
    private func open(_ folder: ProjectFolder) { model.newAgentDirectory = folder.path; focus(1) }
    private func parentFolder() {
        model.newAgentDirectory = (NSString(string: model.newAgentDirectory).expandingTildeInPath as NSString).deletingLastPathComponent
        if model.newAgentDirectory.isEmpty { model.newAgentDirectory = "/" }
        focus(1)
    }
    private func handleKey(_ key: IslandKey) -> Bool {
        guard !model.launchingAgent else { return false }
        if key.key == "tab", key.modifiers.isEmpty || key.modifiers == .shift {
            focus((zone + (key.modifiers == .shift ? 2 : 1)) % 3); return true
        }
        if key.key == "up", key.modifiers == .command { parentFolder(); return true }
        guard key.modifiers.isEmpty else { return false }
        if zone == 0, ["left", "right", "space"].contains(key.key) {
            let kinds = ["claude", "codex", "terminal"]
            let index = kinds.firstIndex(of: model.newAgentKind) ?? 0
            model.newAgentKind = kinds[(index + (key.key == "left" ? 2 : 1)) % kinds.count]
            return true
        }
        if zone == 1, ["up", "down"].contains(key.key) {
            guard !folders.isEmpty else { return true }
            let index = folders.firstIndex { $0.path == selectedPath } ?? 0
            selectedPath = folders[(index + (key.key == "down" ? 1 : folders.count - 1)) % folders.count].path
            return true
        }
        if key.key == "return" {
            if zone == 2 { if canStart { model.launchAgent() } }
            else if zone == 0 { focus(1) }
            else if let folder = folders.first(where: { $0.path == selectedPath }) { open(folder) }
            return true
        }
        return false
    }
}
