import Foundation

/// Launch and input rules for Herdr's interactive direct-attach client.
public enum HerdrAttach {
    public static func environment(socket: String, inherited: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var result = inherited
        for key in ["HERDR_ENV", "HERDR_PANE_ID", "HERDR_WORKSPACE_ID", "HERDR_TAB_ID", "HERDR_SESSION"] {
            result.removeValue(forKey: key)
        }
        result["HERDR_SOCKET_PATH"] = socket
        result["TERM"] = "xterm-256color"
        result["COLORTERM"] = "truecolor"
        return result
    }

    /// The island owns Ctrl+B shortcuts; double literal prefixes for the nested client.
    public static func escapeInput(_ input: Data) -> Data {
        Data(input.flatMap { $0 == 2 ? [UInt8(2), 2] : [$0] })
    }
}
