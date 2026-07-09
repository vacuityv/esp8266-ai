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
    // Everything runs on this background queue, never the main thread: gathering
    // a snapshot rescans the CLI session logs, which would jank the menu bar if
    // done on main. The data producers are all lock-guarded (and already called
    // off-main by the local HTTP server), so this is safe.
    private let queue = DispatchQueue(label: "aiclock.relay", qos: .utility)
    private var timer: DispatchSourceTimer?
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
        guard let baseStr = AppConfig.string("RELAY_BASE"),
              let token = AppConfig.string("RELAY_TOKEN"),
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

    func start() {
        FileHandle.standardError.write(Data("[relay] pushing to \(base.absoluteString)/ingest/*\n".utf8))
        // Every 5s on the background queue, matching the clock's poll cadence to
        // keep relay traffic low. /net's tail carries 28 samples (7s @ 4Hz) — a
        // bit more than one 5s push — so no samples are lost between pushes and
        // the clock's draw queue never starves.
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 5.0)
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
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
