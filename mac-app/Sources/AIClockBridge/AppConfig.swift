import Foundation

// Small shared config reader used by both the relay pusher and the entry point.
// Precedence: process environment overrides the file. File is
// ~/.config/aiclock/relay.env with KEY=VALUE lines ('#' comments and blank
// lines ignored). Keeping this in one place means the relay settings and the
// local-server toggle read from the exact same source.
enum AppConfig {
    static let filePath = ("~/.config/aiclock/relay.env" as NSString).expandingTildeInPath

    /// All resolved keys, env winning over the file.
    static func all() -> [String: String] {
        var cfg: [String: String] = [:]
        if let text = try? String(contentsOfFile: filePath, encoding: .utf8) {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"),
                      let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                cfg[key] = val
            }
        }
        for (k, v) in ProcessInfo.processInfo.environment where cfg[k] != nil || Self.envKeys.contains(k) {
            cfg[k] = v
        }
        return cfg
    }

    /// Env keys we always want to pick up even if absent from the file.
    private static let envKeys: Set<String> = ["RELAY_BASE", "RELAY_TOKEN", "LOCAL_HTTP"]

    static func string(_ key: String) -> String? {
        let v = all()[key]?.trimmingCharacters(in: .whitespaces)
        return (v?.isEmpty ?? true) ? nil : v
    }

    /// Truthy: on/1/true/yes; falsy: off/0/false/no; anything else => default.
    static func bool(_ key: String, default def: Bool) -> Bool {
        guard let v = string(key)?.lowercased() else { return def }
        if ["0", "off", "false", "no"].contains(v) { return false }
        if ["1", "on", "true", "yes"].contains(v) { return true }
        return def
    }
}
