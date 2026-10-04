import Foundation
import CoreGraphics
import IslandCore

final class InteractionTests {
    func testHomeNavigationDoesNotCaptureTerminalKeys() {
        var keyboard = IslandKeyboard()
        let home = KeyboardContext(home: true)
        expectEqual(keyboard.route(IslandKey("down"), context: home), .highlightRelative(1))
        expectEqual(keyboard.route(IslandKey("up"), context: home), .highlightRelative(-1))
        expectEqual(keyboard.route(IslandKey("tab", modifiers: .shift), context: home), .highlightRelative(-1))
        expectEqual(keyboard.route(IslandKey("return"), context: home), .activateSelection)
        expectEqual(keyboard.route(IslandKey("escape"), context: home), .collapse)
        expectEqual(keyboard.route(IslandKey("q", modifiers: .command), context: home), .passThrough)
        expectEqual(keyboard.route(IslandKey("v", modifiers: .command), context: KeyboardContext(help: true, home: true)), .consume)
        expectEqual(keyboard.route(IslandKey("down"), context: KeyboardContext()), .passThrough)
        expectEqual(keyboard.route(IslandKey("return"), context: KeyboardContext()), .passThrough)
        _ = keyboard.route(IslandKey("b", modifiers: .control), context: KeyboardContext())
        expectEqual(keyboard.route(IslandKey("0"), context: KeyboardContext()), .home)
        expectEqual(keyboard.route(IslandKey("0", modifiers: .command), context: KeyboardContext()), .home)
        expectEqual(keyboard.route(IslandKey("2", modifiers: .command), context: home), .selectIndex(1))
    }

    func testHerdrPrefixRoutesWithoutTypingIntoAgent() {
        var keyboard = IslandKeyboard()
        let context = KeyboardContext()
        expectEqual(keyboard.route(IslandKey("b", modifiers: .control), context: context), .prefix)
        expectEqual(keyboard.route(IslandKey("n"), context: context), .selectRelative(1))
        expect(!keyboard.prefixPending)
        _ = keyboard.route(IslandKey("b", modifiers: .control), context: context)
        expectEqual(keyboard.route(IslandKey("s"), context: context), .settings)
        _ = keyboard.route(IslandKey("b", modifiers: .control), context: context)
        expectEqual(keyboard.route(IslandKey("q"), context: context), .collapse)
    }
    func testTerminalOwnsTypingNavigationAndControlKeys() {
        var keyboard = IslandKeyboard()
        for key in ["return", "escape", "tab", "up", "down", "1", "n", "i", "?", "א"] {
            expectEqual(keyboard.route(IslandKey(key), context: KeyboardContext()), .passThrough)
        }
        for key in ["c", "d", "a", "e", "r"] {
            expectEqual(keyboard.route(IslandKey(key, modifiers: .control), context: KeyboardContext()), .passThrough)
        }
        expectEqual(keyboard.route(IslandKey("return", modifiers: .shift), context: KeyboardContext()), .passThrough)
        expectEqual(keyboard.route(IslandKey("a", repeating: true), context: KeyboardContext()), .passThrough)
    }
    func testClipboardActionsAreNativeAndHelpDoesNotPaste() {
        var keyboard = IslandKeyboard()
        expectEqual(keyboard.route(IslandKey("v", modifiers: .command), context: KeyboardContext()), .paste)
        expectEqual(keyboard.route(IslandKey("c", modifiers: .command), context: KeyboardContext()), .copySelection)
        expectEqual(keyboard.route(IslandKey("a", modifiers: .command), context: KeyboardContext()), .selectAll)
        expectEqual(keyboard.route(IslandKey("v", modifiers: .command), context: KeyboardContext(help: true)), .consume)
    }
    func testLiteralPrefixAndHelpIsolation() {
        var keyboard = IslandKeyboard()
        _ = keyboard.route(IslandKey("b", modifiers: .control), context: KeyboardContext())
        expectEqual(keyboard.route(IslandKey("b", modifiers: .control), context: KeyboardContext()), .literalPrefix)
        expectEqual(keyboard.route(IslandKey("return"), context: KeyboardContext(help: true)), .consume)
        expectEqual(keyboard.route(IslandKey("escape"), context: KeyboardContext(help: true)), .help)
        _ = keyboard.route(IslandKey("b", modifiers: .control), context: KeyboardContext())
        expectEqual(keyboard.route(IslandKey("n", repeating: true), context: KeyboardContext()), .consume)
    }
    func testDisplaySelectionUsesActiveWindowThenPointerThenPrimary() {
        let screens = [CGRect(x: 0, y: 0, width: 1512, height: 982),
                       CGRect(x: -2560, y: 200, width: 2560, height: 1440),
                       CGRect(x: 0, y: 982, width: 1920, height: 1080)]
        let leftWindow = CGRect(x: -2200, y: 500, width: 1600, height: 900)
        expectEqual(DisplaySelection.index(screens: screens, window: leftWindow, pointer: .zero), 1)
        expectEqual(DisplaySelection.index(screens: screens, window: nil, pointer: CGPoint(x: 400, y: 1200)), 2)
        expectEqual(DisplaySelection.index(screens: screens, window: nil, pointer: CGPoint(x: 9000, y: 9000)), 0)
        expectEqual(DisplaySelection.index(screens: screens, window: leftWindow, pointer: .zero, usePrimary: true), 0)
        expectEqual(DisplaySelection.index(screens: [], window: nil, pointer: .zero), nil)
        let spanning = CGRect(x: -900, y: 250, width: 1200, height: 600)
        expectEqual(DisplaySelection.index(screens: screens, window: spanning, pointer: .zero), 1)
        expectEqual(DisplaySelection.index(screens: [screens[0]], window: leftWindow, pointer: .zero), 0)
    }
    func testQuartzWindowCoordinatesHandleDisplaysAboveAndLeft() {
        let rect = DisplaySelection.appKitRect(quartz: CGRect(x: -2200, y: -418, width: 1600, height: 900), primaryHeight: 982)
        expectEqual(rect, CGRect(x: -2200, y: 500, width: 1600, height: 900))
    }
    func testNotchUsesHardwareGapAndKeepsEveryTransitionAttached() {
        let screen = CGRect(x: -1728, y: 900, width: 1728, height: 1117)
        let geometry = NotchGeometry(screen: screen, safeTop: 38,
            leftArea: CGRect(x: -1728, y: 1979, width: 774, height: 38),
            rightArea: CGRect(x: -774, y: 1979, width: 774, height: 38))
        expect(geometry.hasNotch)
        expectEqual(geometry.notchWidth, 180)
        expectEqual(geometry.centerX, -864)
        for from in [IslandPhase.hidden, .compact, .expanded] {
            for to in [IslandPhase.hidden, .compact, .expanded] {
                let frame = geometry.panelFrame(from: from, to: to)
                expectEqual(frame.maxY, screen.maxY)
                expectEqual(frame.midX, geometry.centerX)
                expect(frame.width >= geometry.size(for: from).width)
                expect(frame.width >= geometry.size(for: to).width)
            }
        }
    }

    func testFlatDisplayFallsBackToTopEdgeAndBoundsHeight() {
        let screen = CGRect(x: 0, y: -768, width: 1024, height: 768)
        let geometry = NotchGeometry(screen: screen, safeTop: 0)
        expect(!geometry.hasNotch)
        expectEqual(geometry.centerX, 512)
        expectEqual(geometry.panelFrame(from: .hidden, to: .expanded).maxY, 0)
        expect(geometry.panelFrame(from: .expanded, to: .expanded).height < screen.height)
    }
}
