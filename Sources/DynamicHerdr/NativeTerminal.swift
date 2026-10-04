import AppKit
import SwiftUI
import SwiftTerm
import IslandCore

final class IslandTerminalView: TerminalView {
    override func insertText(_ string: Any, replacementRange: NSRange) {
        // AppKit can commit IME/dictation text as an attributed string.
        super.insertText((string as? NSAttributedString)?.string ?? string, replacementRange: replacementRange)
    }
}

struct NativeTerminal: NSViewRepresentable {
    @ObservedObject var model: IslandModel
    let agent: Agent

    @MainActor final class Coordinator: NSObject, @preconcurrency TerminalViewDelegate, @preconcurrency LocalProcessDelegate {
        var parent: NativeTerminal
        weak var view: TerminalView?
        var process: LocalProcess?
        var attachTask: Task<Void, Never>?
        var stopped = false
        var focusRequest = -1
        var dimensions = (cols: 0, rows: 0)
        var receivedFrame = false
        var feeding = false
        var demoInput = ""
        var demoChoice = 1
        var demoAnswered = false
        init(_ parent: NativeTerminal) { self.parent = parent }

        func start(_ view: TerminalView) {
            self.view = view
            view.terminalDelegate = self
            parent.model.editTerminal = { [weak self] command in
                guard let self, !self.stopped, let view = self.view else { return }
                switch command {
                case .copySelection: view.copy(self)
                case .paste: view.paste(self)
                case .selectAll: view.selectAll(self)
                default: break
                }
            }
            parent.model.sendLiteralPrefix = { [weak self] in self?.sendBytes(Data([2])) }
            attachTask = Task { [weak self] in
                // Wait one layout pass so Herdr receives the final terminal cell dimensions.
                await Task.yield()
                guard let self, !self.stopped else { return }
                if self.parent.model.demo {
                    self.renderDemo(); self.parent.model.terminalReady = true
                    self.focusIfNeeded()
                    return
                }
                do {
                    let latest = try await self.parent.model.client.pane(self.parent.agent.id)
                    guard !Task.isCancelled, !self.stopped else { return }
                    guard latest.terminalID == self.parent.agent.terminalID else { throw HerdrError.message("This terminal has left the pane.") }
                    let terminal = view.getTerminal()
                    self.dimensions = (terminal.cols, terminal.rows)
                    guard FileManager.default.isExecutableFile(atPath: self.parent.model.executablePath) else {
                        throw HerdrError.message("Herdr executable not found. Check Settings.")
                    }
                    let process = LocalProcess(delegate: self)
                    self.process = process
                    process.startProcess(executable: self.parent.model.executablePath,
                        args: ["terminal", "attach", self.parent.agent.terminalID],
                        environment: HerdrAttach.environment(socket: self.parent.model.socketPath)
                            .map { "\($0.key)=\($0.value)" })
                    self.focusIfNeeded()
                    try? await Task.sleep(for: .seconds(8))
                    if !self.stopped, !self.receivedFrame, self.parent.model.terminalError == nil {
                        self.parent.model.terminalError = "Terminal did not connect. Check the Herdr executable in Settings; ⌃B r retries."
                        self.stopProcess()
                    }
                } catch {
                    guard !self.stopped else { return }
                    self.parent.model.terminalError = error.localizedDescription
                }
            }
        }
        func dataReceived(slice: ArraySlice<UInt8>) {
            guard !stopped, let view else { return }
            receivedFrame = true
            if !parent.model.terminalReady { parent.model.terminalReady = true }
            feeding = true
            view.feed(byteArray: slice)
            feeding = false
            focusIfNeeded()
        }
        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {
            guard !stopped else { return }
            parent.model.terminalReady = false
            parent.model.terminalError = "Terminal detached. ⌃B r reconnects."
        }
        func getWindowSize() -> winsize {
            let terminal = view?.getTerminal()
            return winsize(ws_row: UInt16(clamping: terminal?.rows ?? 24),
                           ws_col: UInt16(clamping: terminal?.cols ?? 80), ws_xpixel: 0, ws_ypixel: 0)
        }
        func focusIfNeeded() {
            guard let view, parent.model.keyboardActive, !parent.model.showingHelp,
                  focusRequest != parent.model.focusRequest, view.window?.isKeyWindow == true else { return }
            focusRequest = parent.model.focusRequest
            view.window?.makeFirstResponder(view)
        }
        func stop() {
            guard !stopped else { return }
            stopped = true; attachTask?.cancel()
            // Terminate only our local attach client; Herdr keeps the agent running.
            stopProcess()
        }
        private func stopProcess() {
            guard let process else { return }
            self.process = nil
            guard process.running else { return }
            let pid = process.shellPid
            process.terminate()
            // Some Herdr clients retain SIGTERM handlers. Reap our child and
            // bound shutdown so it cannot retain the direct controller lease.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.5) {
                var status: Int32 = 0
                if waitpid(pid, &status, WNOHANG) == 0 {
                    kill(pid, SIGKILL)
                    _ = waitpid(pid, &status, 0)
                }
            }
        }
        func sendBytes(_ data: Data) {
            guard !stopped, !feeding, parent.model.expanded, parent.model.terminalAvailable,
                  parent.model.keyboardActive, !parent.model.showingHelp, parent.model.terminalReady else { return }
            if parent.model.demo { demoSend(data); return }
            process?.send(data: Array(HerdrAttach.escapeInput(data))[...])
        }
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            if feeding {
                // Terminal capability replies must reach the client even without keyboard focus.
                if !stopped { process?.send(data: data) }
            } else { sendBytes(Data(data)) }
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard !stopped, newCols > 0, newRows > 0, dimensions != (newCols, newRows) else { return }
            dimensions = (newCols, newRows)
            if let process, process.running {
                var size = getWindowSize()
                _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
            }
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func bell(source: TerminalView) {} // The island stays quiet.

        private func renderDemo() {
            guard let view else { return }
            let text: String
            if demoAnswered { text = "\u{1B}[38;5;115m● Working\u{1B}[0m\r\n\r\nContinuing with your response…\r\n\r\n› " + demoInput }
            else { text = Demo.output(for: parent.agent, selection: demoChoice).replacingOccurrences(of: "\n", with: "\r\n") + "\r\n\r\n\u{1B}[38;5;115m›\u{1B}[0m " + demoInput }
            feeding = true
            view.feed(text: "\u{1B}[?2004h\u{1B}[2J\u{1B}[H" + text)
            feeding = false
        }
        private func demoSend(_ data: Data) {
            let text = String(decoding: data, as: UTF8.self)
            if ["\u{1B}[A", "\u{1B}[B", "\u{1B}OA", "\u{1B}OB"].contains(text), parent.agent.agentStatus == .blocked, !demoAnswered {
                demoChoice = demoChoice == 1 ? 2 : 1
            } else if text == "\r" {
                demoAnswered = true; demoInput = ""
                parent.model.submitDemoResponse(to: parent.agent)
            }
            else if text == "\u{7F}" { if !demoInput.isEmpty { demoInput.removeLast() } }
            else if text == "\u{03}" || text == "\u{1B}" { demoInput = "" }
            else if !text.hasPrefix("\u{1B}") { demoInput += text }
            renderDemo()
        }
    }
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> TerminalView {
        let view = IslandTerminalView(frame: NSRect(x: 0, y: 0, width: 580, height: 375))
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .black
        view.nativeForegroundColor = NSColor.white.withAlphaComponent(0.88)
        view.caretColor = NSColor(red: 0.65, green: 0.94, blue: 0.78, alpha: 1)
        view.setAccessibilityLabel("\(agent.displayName) terminal")
        context.coordinator.start(view)
        return view
    }
    func updateNSView(_ view: TerminalView, context: Context) {
        context.coordinator.parent = self
        if !model.expanded || !model.terminalAvailable { context.coordinator.stop() }
        DispatchQueue.main.async { context.coordinator.focusIfNeeded() }
    }
    static func dismantleNSView(_ view: TerminalView, coordinator: Coordinator) { coordinator.stop() }
}
