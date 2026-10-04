import Foundation
import Darwin

enum Checks {
    static let lock = NSLock()
    static var failures: [String] = []
    static var total = 0
    static func record(_ message: String, file: StaticString, line: UInt) {
        lock.lock(); defer { lock.unlock() }
        failures.append("\(file):\(line): \(message)")
    }
}
func expect(_ condition: @autoclosure () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
    if !condition() { Checks.record("Expected true", file: file, line: line) }
}
func expectEqual<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, file: StaticString = #filePath, line: UInt = #line) {
    let left = a(), right = b()
    if left != right { Checks.record("Expected \(left) == \(right)", file: file, line: line) }
}
func expectThrows<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try body(); Checks.record("Expected an error", file: file, line: line) } catch {}
}
func expectNoThrow<T>(_ body: @autoclosure () throws -> T, file: StaticString = #filePath, line: UInt = #line) {
    do { _ = try body() } catch { Checks.record("Unexpected error: \(error)", file: file, line: line) }
}
func fail(_ text: String, file: StaticString = #filePath, line: UInt = #line) { Checks.record(text, file: file, line: line) }

@main struct TestRunner {
    static func run(_ name: String, body: () async throws -> Void) async {
        let before = Checks.failures.count
        do { try await body() } catch { fail("\(name): \(error)") }
        Checks.total += 1
        print("\(Checks.failures.count == before ? "PASS" : "FAIL") \(name)")
    }
    static func main() async {
        await run("testTerminalInventoryIncludesShellsAndAgentNames") { try await HerdrClientTests().testTerminalInventoryIncludesShellsAndAgentNames() }
        await run("testFolderBrowserFiltersAndExcludesFiles") { try ProjectFoldersTests().testFolderBrowserFiltersAndExcludesFiles() }
        await run("testCreateAgentUsesReturnedPaneAndStructuredDirectory") { try await HerdrClientTests().testCreateAgentUsesReturnedPaneAndStructuredDirectory() }
        await run("testAgentStartFailureIsNotRetried") { try await HerdrClientTests().testAgentStartFailureIsNotRetried() }
        await run("testHomeNavigationDoesNotCaptureTerminalKeys") { InteractionTests().testHomeNavigationDoesNotCaptureTerminalKeys() }
        await run("testHerdrPrefixRoutesWithoutTypingIntoAgent") { InteractionTests().testHerdrPrefixRoutesWithoutTypingIntoAgent() }
        await run("testTerminalOwnsTypingNavigationAndControlKeys") { InteractionTests().testTerminalOwnsTypingNavigationAndControlKeys() }
        await run("testClipboardActionsAreNativeAndHelpDoesNotPaste") { InteractionTests().testClipboardActionsAreNativeAndHelpDoesNotPaste() }
        await run("testLiteralPrefixAndHelpIsolation") { InteractionTests().testLiteralPrefixAndHelpIsolation() }
        await run("testDisplaySelectionUsesActiveWindowThenPointerThenPrimary") { InteractionTests().testDisplaySelectionUsesActiveWindowThenPointerThenPrimary() }
        await run("testQuartzWindowCoordinatesHandleDisplaysAboveAndLeft") { InteractionTests().testQuartzWindowCoordinatesHandleDisplaysAboveAndLeft() }
        await run("testNotchUsesHardwareGapAndKeepsEveryTransitionAttached") { InteractionTests().testNotchUsesHardwareGapAndKeepsEveryTransitionAttached() }
        await run("testFlatDisplayFallsBackToTopEdgeAndBoundsHeight") { InteractionTests().testFlatDisplayFallsBackToTopEdgeAndBoundsHeight() }
        await run("testTypedAnswerChecksContextAndUsesLogicalKeys") { try await HerdrClientTests().testTypedAnswerChecksContextAndUsesLogicalKeys() }
        await run("testChangedQuestionNeverReceivesTypedAnswer") { try await HerdrClientTests().testChangedQuestionNeverReceivesTypedAnswer() }
        await run("testMultilineBlockedAnswerDoesNotWriteAnyKeys") { await HerdrClientTests().testMultilineBlockedAnswerDoesNotWriteAnyKeys() }
        await run("testListAndFragmentedContextUseRealProtocolFields") { try await HerdrClientTests().testListAndFragmentedContextUseRealProtocolFields() }
        await run("testPromptPreservesTextAndUsesIdentityPreflight") { try await HerdrClientTests().testPromptPreservesTextAndUsesIdentityPreflight() }
        await run("testStaleAgentNeverReceivesInput") { try await HerdrClientTests().testStaleAgentNeverReceivesInput() }
        await run("testBlockedKeyUsesAgentSurface") { try await HerdrClientTests().testBlockedKeyUsesAgentSurface() }
        await run("testServerRejectionIsSurfaced") { try await HerdrClientTests().testServerRejectionIsSurfaced() }
        await run("testUncertainMutationIsNeverRetried") { try await HerdrClientTests().testUncertainMutationIsNeverRetried() }
        await run("testMissingSocketFailsCleanly") { await HerdrClientTests().testMissingSocketFailsCleanly() }
        await run("testResolvedAttentionClosesOnWorkOrSeenIdle") { AttentionQueueTests().testResolvedAttentionClosesOnWorkOrSeenIdle() }
        await run("testOtherAgentsCannotResolveTheOpenNotification") { AttentionQueueTests().testOtherAgentsCannotResolveTheOpenNotification() }
        await run("testResumedAgentLeavesInboxWithoutDismissingOtherQuestions") { AttentionQueueTests().testResumedAgentLeavesInboxWithoutDismissingOtherQuestions() }
        await run("testSeenCompletionLeavesInboxWithoutDismissingOtherQuestions") { AttentionQueueTests().testSeenCompletionLeavesInboxWithoutDismissingOtherQuestions() }
        await run("testStartupCompletionGoesToInboxWithoutPopup") { AttentionQueueTests().testStartupCompletionGoesToInboxWithoutPopup() }
        await run("testStartupBlockRequiresAttention") { AttentionQueueTests().testStartupBlockRequiresAttention() }
        await run("testWorkingToDoneNotifiesOnce") { AttentionQueueTests().testWorkingToDoneNotifiesOnce() }
        await run("testDismissalSurvivesTerminalRedraw") { AttentionQueueTests().testDismissalSurvivesTerminalRedraw() }
        await run("testNextRunNotifiesAfterDismissal") { AttentionQueueTests().testNextRunNotifiesAfterDismissal() }
        await run("testNewSequenceNotifiesEvenWhenPollMissesWorking") { AttentionQueueTests().testNewSequenceNotifiesEvenWhenPollMissesWorking() }
        await run("testMissingSequenceSupportsObservedTransitions") { AttentionQueueTests().testMissingSequenceSupportsObservedTransitions() }
        await run("testSnoozeReturnsExactlyOnceAtDeadline") { AttentionQueueTests().testSnoozeReturnsExactlyOnceAtDeadline() }
        await run("testSnoozeDoesNotHideANewQuestion") { AttentionQueueTests().testSnoozeDoesNotHideANewQuestion() }
        await run("testClosedOrResumedAgentsLeaveInbox") { AttentionQueueTests().testClosedOrResumedAgentsLeaveInbox() }
        await run("testBlockedTakesPriorityOverCompletion") { AttentionQueueTests().testBlockedTakesPriorityOverCompletion() }
        await run("testReplacementIsNotHiddenByPriorDismissal") { AttentionQueueTests().testReplacementIsNotHiddenByPriorDismissal() }
        await run("testUnknownNeverProducesFinishedNotification") { AttentionQueueTests().testUnknownNeverProducesFinishedNotification() }
        await run("testActionRejectsReplacedAgentAndStaleState") { AttentionQueueTests().testActionRejectsReplacedAgentAndStaleState() }
        await run("testActionAllowsRedrawButNeverPromptsBlockedAgent") { AttentionQueueTests().testActionAllowsRedrawButNeverPromptsBlockedAgent() }
        await run("testTerminalCleaningPreservesReadableText") { AttentionQueueTests().testTerminalCleaningPreservesReadableText() }
        await run("testSocketResolutionRespectsExplicitAndNamedSessions") { AttentionQueueTests().testSocketResolutionRespectsExplicitAndNamedSessions() }
        await run("testAttachEnvironmentAndLiteralPrefix") { TerminalSessionTests().testAttachEnvironmentAndLiteralPrefix() }
        await run("testStreamDecodesFragmentedAndCoalescedFrames") { try TerminalSessionTests().testStreamDecodesFragmentedAndCoalescedFrames() }
        await run("testInvalidFramesAreRejected") { try TerminalSessionTests().testInvalidFramesAreRejected() }
        await run("testTerminalCommandsPreserveRawBytes") { try TerminalSessionTests().testTerminalCommandsPreserveRawBytes() }
        for failure in Checks.failures { print(failure) }
        print("\(Checks.total) checks, \(Checks.failures.count) failures")
        exit(Checks.failures.isEmpty ? 0 : 1)
    }
}
