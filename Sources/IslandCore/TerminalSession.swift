import Foundation

public struct TerminalFrame: Decodable, Sendable {
    public let bytes: Data
    public let width: Int
    public let height: Int
    public let seq: UInt64
    public let full: Bool
}

public enum TerminalEvent: Sendable {
    case frame(TerminalFrame)
    case closed(String)
}

/// Incremental NDJSON decoder: frame boundaries need not match pipe reads.
public struct TerminalStreamDecoder {
    private var buffer = Data()
    public init() {}
    public mutating func append(_ data: Data) throws -> [TerminalEvent] {
        buffer.append(data)
        var events: [TerminalEvent] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end)
            guard line.count <= 4 * 1024 * 1024 else { throw HerdrError.message("Terminal frame is too large.") }
            buffer.removeSubrange(...end)
            if line.isEmpty { continue }
            struct Header: Decodable { let type: String; let reason: String?; let encoding: String? }
            let header = try JSONDecoder().decode(Header.self, from: line)
            switch header.type {
            case "terminal.frame":
                guard header.encoding == "ansi" else { throw HerdrError.message("Unsupported terminal encoding.") }
                let frame = try JSONDecoder().decode(TerminalFrame.self, from: line)
                guard (1...1000).contains(frame.width), (1...1000).contains(frame.height) else {
                    throw HerdrError.message("Invalid terminal dimensions.")
                }
                events.append(.frame(frame))
            case "terminal.closed": events.append(.closed(header.reason ?? "Terminal disconnected."))
            default: throw HerdrError.message("Unrecognized terminal stream. Check your Herdr version.")
            }
        }
        guard buffer.count <= 4 * 1024 * 1024 else { throw HerdrError.message("Terminal frame is too large.") }
        return events
    }
}

public enum TerminalCommand {
    public static func input(_ bytes: Data) -> Data { encode(["type": "terminal.input", "bytes": bytes.base64EncodedString()]) }
    public static func resize(cols: Int, rows: Int) -> Data {
        encode(["type": "terminal.resize", "cols": max(1, cols), "rows": max(1, rows)])
    }
    public static func scroll(up: Bool, lines: Int) -> Data {
        encode(["type": "terminal.scroll", "direction": up ? "up" : "down", "lines": max(1, lines)])
    }
    public static var release: Data { encode(["type": "terminal.release"]) }
    private static func encode(_ value: [String: Any]) -> Data { (try! JSONSerialization.data(withJSONObject: value)) + Data([10]) }
}
