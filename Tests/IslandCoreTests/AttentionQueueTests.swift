import Foundation
import IslandCore

func agent(_ status: AgentStatus = .done, pane: String = "w1:p1", terminal: String = "terminal-1", seq: Int? = 1, revision: Int = 10, session: String? = nil) -> Agent {
    var json: [String: Any] = ["pane_id": pane, "terminal_id": terminal, "workspace_id": "w1", "tab_id": "w1:t1", "agent": "codex", "agent_status": status.rawValue, "focused": false, "revision": revision, "cwd": "/Projects/orbit"]
    if let seq { json["state_change_seq"] = seq }
    if let session { json["agent_session"] = ["source": "codex", "agent": "codex", "kind": "session_id", "value": session] }
    return try! JSONDecoder().decode(Agent.self, from: JSONSerialization.data(withJSONObject: json))
}

final class AttentionQueueTests {
    func testResolvedAttentionClosesOnWorkOrSeenIdle() {
        for status in [AgentStatus.blocked, .done, .idle, .unknown] {
            expect(agent(.working, seq: 2).resolvesAttention(since: agent(status)))
        }
        for status in [AgentStatus.blocked, .done, .unknown] {
            expect(!agent(status, seq: 2).resolvesAttention(since: agent(.blocked)))
            expect(!agent(status, seq: 2).resolvesAttention(since: agent(.done)))
        }
        expect(!agent(.working, seq: 2).resolvesAttention(since: agent(.working)))
        expect(!agent(.idle).resolvesAttention(since: agent(.idle)))
        expect(!agent(.idle).resolvesAttention(since: agent(.unknown)))
        for previous in [AgentStatus.blocked, .done] {
            // Marking seen changes status without changing the run sequence.
            expect(agent(.idle).resolvesAttention(since: agent(previous)))
        }
    }

    func testOtherAgentsCannotResolveTheOpenNotification() {
        let previous = agent(.blocked, session: "run-a")
        expect(!agent(.working, pane: "w1:p2", session: "run-a").resolvesAttention(since: previous))
        expect(!agent(.working, terminal: "replacement", session: "run-a").resolvesAttention(since: previous))
        expect(!agent(.working, session: "run-b").resolvesAttention(since: previous))
    }

    func testResumedAgentLeavesInboxWithoutDismissingOtherQuestions() {
        var queue = AttentionQueue()
        let selected = agent(.blocked)
        let other = agent(.blocked, pane: "w1:p2", terminal: "terminal-2")
        queue.reconcile([selected, other])
        let resumed = agent(.working, seq: 2)
        expect(resumed.resolvesAttention(since: selected))
        expect(queue.reconcile([resumed, other]).isEmpty)
        expectEqual(queue.items.map(\.id), [other.id])
        expectEqual(queue.reconcile([agent(.done, seq: 3), other]).count, 1)
    }

    func testSeenCompletionLeavesInboxWithoutDismissingOtherQuestions() {
        var queue = AttentionQueue()
        let completed = agent(.done)
        let other = agent(.blocked, pane: "w1:p2", terminal: "terminal-2")
        queue.reconcile([completed, other])
        let seen = agent(.idle)
        expect(seen.resolvesAttention(since: completed))
        expect(queue.reconcile([seen, other]).isEmpty)
        expectEqual(queue.items.map(\.id), [other.id])
        expectEqual(queue.reconcile([agent(.done, seq: 2), other]).count, 1)
    }

    func testStartupCompletionGoesToInboxWithoutPopup() {
        var queue = AttentionQueue()
        expect(queue.reconcile([agent()]).isEmpty)
        expectEqual(queue.items.count, 1)
    }

    func testStartupBlockRequiresAttention() {
        var queue = AttentionQueue()
        expectEqual(queue.reconcile([agent(.blocked)]).count, 1)
    }

    func testWorkingToDoneNotifiesOnce() {
        var queue = AttentionQueue()
        queue.reconcile([agent(.working)])
        expectEqual(queue.reconcile([agent(.done, seq: 2)]).count, 1)
        expect(queue.reconcile([agent(.done, seq: 2, revision: 100)]).isEmpty)
        expectEqual(queue.items.count, 1)
    }

    func testDismissalSurvivesTerminalRedraw() {
        var queue = AttentionQueue()
        queue.reconcile([agent()])
        queue.dismiss(queue.items[0])
        expect(queue.reconcile([agent(revision: 200)]).isEmpty)
        expect(queue.items.isEmpty)
    }

    func testNextRunNotifiesAfterDismissal() {
        var queue = AttentionQueue()
        queue.reconcile([agent()])
        queue.dismiss(queue.items[0])
        queue.reconcile([agent(.working, seq: 2)])
        expectEqual(queue.reconcile([agent(.done, seq: 3)]).count, 1)
    }

    func testNewSequenceNotifiesEvenWhenPollMissesWorking() {
        var queue = AttentionQueue()
        queue.reconcile([agent()])
        queue.dismiss(queue.items[0])
        expectEqual(queue.reconcile([agent(seq: 3)]).count, 1)
    }

    func testMissingSequenceSupportsObservedTransitions() {
        var queue = AttentionQueue()
        queue.reconcile([agent(seq: nil)])
        queue.dismiss(queue.items[0])
        queue.reconcile([agent(.working, seq: nil)])
        expectEqual(queue.reconcile([agent(.done, seq: nil)]).count, 1)
    }

    func testSnoozeReturnsExactlyOnceAtDeadline() {
        var queue = AttentionQueue()
        let now = Date(timeIntervalSince1970: 100)
        queue.reconcile([agent(.blocked)], now: now)
        queue.snooze(queue.items[0], until: now.addingTimeInterval(600))
        expect(queue.reconcile([agent(.blocked)], now: now.addingTimeInterval(599)).isEmpty)
        expect(queue.items.isEmpty)
        expectEqual(queue.reconcile([agent(.blocked)], now: now.addingTimeInterval(600)).count, 1)
        expect(queue.reconcile([agent(.blocked)], now: now.addingTimeInterval(601)).isEmpty)
    }

    func testSnoozeDoesNotHideANewQuestion() {
        var queue = AttentionQueue()
        queue.reconcile([agent(.blocked)])
        queue.snooze(queue.items[0], until: Date().addingTimeInterval(600))
        expectEqual(queue.reconcile([agent(.blocked, seq: 4)]).count, 1)
    }

    func testClosedOrResumedAgentsLeaveInbox() {
        var queue = AttentionQueue()
        queue.reconcile([agent(.blocked), agent(.done, pane: "w1:p2")])
        queue.reconcile([agent(.working)])
        expect(queue.items.isEmpty)
    }

    func testBlockedTakesPriorityOverCompletion() {
        var queue = AttentionQueue()
        queue.reconcile([agent(.done), agent(.blocked, pane: "w1:p2")])
        expectEqual(queue.items.first?.id, "w1:p2")
    }

    func testReplacementIsNotHiddenByPriorDismissal() {
        var queue = AttentionQueue()
        queue.reconcile([agent()])
        queue.dismiss(queue.items[0])
        expectEqual(queue.reconcile([agent(terminal: "replacement")]).count, 1)
    }

    func testUnknownNeverProducesFinishedNotification() {
        var queue = AttentionQueue()
        queue.reconcile([agent(.working)])
        expect(queue.reconcile([agent(.unknown)]).isEmpty)
        expect(queue.items.isEmpty)
    }

    func testActionRejectsReplacedAgentAndStaleState() {
        expectThrows(try ActionGuard.validate(expected: agent(), current: agent(terminal: "replacement"), prompt: true))
        expectThrows(try ActionGuard.validate(expected: agent(), current: agent(seq: 2), prompt: true))
        expectThrows(try ActionGuard.validate(expected: agent(session: "old"), current: agent(session: "new"), prompt: true))
        expectThrows(try ActionGuard.validate(expected: agent(.blocked), current: agent(.working), prompt: false))
    }

    func testActionAllowsRedrawButNeverPromptsBlockedAgent() {
        expectNoThrow(try ActionGuard.validate(expected: agent(), current: agent(revision: 200), prompt: true))
        expectThrows(try ActionGuard.validate(expected: agent(.blocked), current: agent(.blocked), prompt: true))
        expectThrows(try ActionGuard.validate(expected: agent(), current: agent(), prompt: false))
        expectNoThrow(try ActionGuard.validate(expected: agent(.blocked), current: agent(.blocked), prompt: false))
    }

    func testTerminalCleaningPreservesReadableText() {
        expectEqual(TerminalText.clean("\u{1b}[32mHello\u{1b}[0m\n\tWorld\u{07}"), "Hello\n\tWorld")
        expectEqual(TerminalText.clean("\u{1b}]0;title\u{07}Visible"), "Visible")
    }

    func testSocketResolutionRespectsExplicitAndNamedSessions() {
        expectEqual(HerdrClient.defaultSocket(environment: ["HERDR_SOCKET_PATH": "/tmp/test.sock", "HERDR_SESSION": "work"]), "/tmp/test.sock")
        expectEqual(HerdrClient.defaultSocket(environment: ["XDG_CONFIG_HOME": "/custom", "HERDR_SESSION": "work"]), "/custom/herdr/sessions/work/herdr.sock")
    }
}
