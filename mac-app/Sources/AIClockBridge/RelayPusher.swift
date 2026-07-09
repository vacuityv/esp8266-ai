import Foundation

// When the clock and the Mac are on different LANs, the clock can't reach the
// Mac's local HTTP server. This pusher mirrors the exact same bytes that server
// would return up to a public relay (see ../../../relay/relay.py), which the
// clock then polls instead. The relay stores only the latest blob per route, so
// we just POST the current snapshot on a timer — the clock's /net seq logic
// keeps working because we forward the Mac's JSON verbatim.
//
// Opt-in (unset => this whole feature is dormant and the app behaves exactly
// as before). Config is resolved from, in order of precedence:
//   1. environment  RELAY_BASE / RELAY_TOKEN   (handy for `swift run` / testing)
//   2. file  ~/.config/aiclock/relay.env  with KEY=VALUE lines:
//        RELAY_BASE=http://<your-vps-ip>:<port>
//        RELAY_TOKEN=<the PUSH_TOKEN configured on the relay>
// A file is used because `open`-launched .app bundles don't inherit the shell
// environment, and the app has no bundle id to hang UserDefaults off of.
final class RelayPusher {
    private let base: URL
    private let token: String
    private let statusJSON: () -> Data
    private let netJSON: () -> Data
    private let musicJSON: () -> Data
    private let coverRaw: () -> Data
    private let textRaw: () -> Data

    private let session: URLSession
    private var timer: Timer?
    // Binary blobs (cover art / rendered text) rarely change — only push on
    // change so we don't re-upload the same few KB every tick.
    private var lastCoverHash = 0
    private var lastTextHash = 0
    private var loggedError = false

    /// Returns nil when RELAY_BASE / RELAY_TOKEN aren't set, so callers can
    /// simply skip starting it.
    init?(statusJSON: @escaping () -> Data, netJSON: @escaping () -> Data,
          musicJSON: @escaping () -> Data, coverRaw: @escaping () -> Data,
          textRaw: @escaping () -> Data) {
        let cfg = Self.resolveConfig()
        guard let baseStr = cfg["RELAY_BASE"]?.trimmingCharacters(in: .whitespaces), !baseStr.isEmpty,
              let token = cfg["RELAY_TOKEN"], !token.isEmpty,
              let url = URL(string: baseStr.hasPrefix("http") ? baseStr : "http://\(baseStr)") else {
            return nil
        }
        self.base = url
        self.token = token
        self.statusJSON = statusJSON
        self.netJSON = netJSON
        self.musicJSON = musicJSON
        self.coverRaw = coverRaw
        self.textRaw = textRaw
        let sessionCfg = URLSessionConfiguration.ephemeral
        sessionCfg.timeoutIntervalForRequest = 5
        sessionCfg.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: sessionCfg)
    }

    /// env overrides file. File is `~/.config/aiclock/relay.env`, KEY=VALUE per
    /// line, '#' comments and blank lines ignored.
    private static func resolveConfig() -> [String: String] {
        var cfg: [String: String] = [:]
        let path = ("~/.config/aiclock/relay.env" as NSString).expandingTildeInPath
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            for raw in text.split(whereSeparator: \.isNewline) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty, !line.hasPrefix("#"),
                      let eq = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                let val = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                cfg[key] = val
            }
        }
        let env = ProcessInfo.processInfo.environment
        if let v = env["RELAY_BASE"] { cfg["RELAY_BASE"] = v }
        if let v = env["RELAY_TOKEN"] { cfg["RELAY_TOKEN"] = v }
        return cfg
    }

    func start() {
        FileHandle.standardError.write(Data("[relay] pushing to \(base.absoluteString)/ingest/*\n".utf8))
        tick()
        // 1 Hz: /net's tail carries 12 samples (3s @ 4Hz), so a clock polling
        // every 2s never misses a sample even with relay/network jitter.
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        post("status", statusJSON())
        post("net", netJSON())
        post("music", musicJSON())
        // Only re-send binary blobs when their contents actually change.
        let cover = coverRaw()
        let coverHash = cover.hashValue
        if coverHash != lastCoverHash {
            lastCoverHash = coverHash
            post("cover.raw", cover)
        }
        let text = textRaw()
        let textHash = text.hashValue
        if textHash != lastTextHash {
            lastTextHash = textHash
            post("text.raw", text)
        }
    }

    private func post(_ key: String, _ body: Data) {
        var req = URLRequest(url: base.appendingPathComponent("ingest/\(key)"))
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        session.dataTask(with: req) { [weak self] _, resp, error in
            guard let self = self else { return }
            if let error = error {
                if !self.loggedError { // avoid spamming stderr every second while down
                    self.loggedError = true
                    FileHandle.standardError.write(Data("[relay] push failed (\(key)): \(error.localizedDescription); silencing further errors\n".utf8))
                }
            } else if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                self.loggedError = false
            }
        }.resume()
    }
}
