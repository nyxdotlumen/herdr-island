import Foundation

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = Self(rawValue: 1)
    public static let control = Self(rawValue: 2)
    public static let option = Self(rawValue: 4)
    public static let shift = Self(rawValue: 8)
}
public struct IslandKey: Sendable {
    public let key: String
    public let modifiers: KeyModifiers
    public let repeating: Bool
    public init(_ key: String, modifiers: KeyModifiers = [], repeating: Bool = false) {
        self.key = key; self.modifiers = modifiers; self.repeating = repeating
    }
}
public enum IslandCommand: Equatable, Sendable {
    case passThrough, consume, prefix, cancelPrefix, literalPrefix, copySelection, paste, selectAll
    case home, activateSelection, highlightRelative(Int)
    case collapse, help, settings, refresh, openAgent, dismiss, snooze, toggleQuiet, replayDemo
    case selectRelative(Int), selectIndex(Int)
}
public struct KeyboardContext: Sendable {
    public var help: Bool
    public var home: Bool
    public init(help: Bool = false, home: Bool = false) { self.help = help; self.home = home }
}

/// Only the explicit island prefix is captured. The terminal owns ordinary input.
public struct IslandKeyboard: Sendable {
    public private(set) var prefixPending = false
    public init() {}
    public mutating func reset() { prefixPending = false }
    public mutating func route(_ input: IslandKey, context: KeyboardContext) -> IslandCommand {
        let key = input.key.lowercased(), mods = input.modifiers
        if key == "b" && mods == .control {
            if input.repeating { return .consume }
            if prefixPending { prefixPending = false; return context.help ? .consume : .literalPrefix }
            prefixPending = true
            return .prefix
        }
        if prefixPending {
            if input.repeating { return .consume }
            prefixPending = false
            switch key {
            case "escape": return .cancelPrefix
            case "n", "l", "right": return .selectRelative(1)
            case "p", "h", "left": return .selectRelative(-1)
            case "tab": return .selectRelative(mods.contains(.shift) ? -1 : 1)
            case "0", "home": return .home
            case "q": return .collapse
            case "o": return .openAgent
            case "s": return .settings
            case "?", "/": return .help
            case "r": return .refresh
            case "x": return .dismiss
            case "z": return .snooze
            case "m": return .toggleQuiet
            case "d": return .replayDemo
            default:
                if let index = Int(key), (1...9).contains(index) { return .selectIndex(index - 1) }
                return .cancelPrefix
            }
        }
        if context.help { return key == "escape" ? .help : .consume }
        if mods == .command {
            if key == "c" { return .copySelection }
            if key == "v" { return .paste }
            if key == "a" { return .selectAll }
            if key == "," { return .settings }
            if key == "0" { return .home }
            if let index = Int(key), (1...9).contains(index) { return .selectIndex(index - 1) }
        }
        if context.home {
            if mods.contains(.command) { return .passThrough }
            if mods.isEmpty {
                switch key {
                case "up", "k": return .highlightRelative(-1)
                case "down", "j": return .highlightRelative(1)
                case "return", "space": return .activateSelection
                case "escape": return .collapse
                default: break
                }
            }
            if key == "tab", mods.isEmpty || mods == .shift { return .highlightRelative(mods == .shift ? -1 : 1) }
            return .consume
        }
        return .passThrough
    }
}
