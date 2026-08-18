import Foundation

// Real quota ("额度") for both CLIs, fetched the same way CodexBar does it —
// by reusing the OAuth tokens the CLIs already store locally, no extra login:
//   Claude: token from macOS Keychain item "Claude Code-credentials" (or
//           ~/.claude/.credentials.json), then GET
//           https://api.anthropic.com/api/oauth/usage  (5h + 7d windows)
//   Codex:  token from ~/.codex/auth.json, then GET
//           https://chatgpt.com/backend-api/wham/usage (5h + weekly windows)
// Tokens never leave this machine except toward their own vendor's API.

struct ProviderUsage {
    var primaryPct: Double?     // 5h window used %
    var primaryResetMin: Int?   // minutes until it resets
    var weeklyPct: Double?      // 7d / weekly window used %
    var weeklyResetMin: Int?
    var error: String?
    var fetchedAt: Date?
    var rateLimited = false
    var retryAfter: TimeInterval?  // server-dictated cooldown from a 429
}

final class UsageFetcher {
    private let lock = NSLock()
    private var _claude = ProviderUsage()
    private var _codex = ProviderUsage()
    private var timer: Timer?
    private var fetching = false
    private var nextAllowedFetch = Date.distantPast // ordinary in-memory throttle

    /// A 429 cooldown outlives the process, so it is persisted: a restart used to
    /// wipe it and start knocking again, which is what kept the penalty alive.
    /// Gates only the network call — reading CodexBar's snapshot stays free.
    private static let blockedUntilKey = "claudeUsageBlockedUntil"
    private var claudeBlockedUntil: Date {
        get { Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: Self.blockedUntilKey)) }
        set { UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: Self.blockedUntilKey) }
    }

    private let minFetchInterval: TimeInterval = 60
    private let rateLimitBackoff: TimeInterval = 300

    var claude: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _claude }
    var codex: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _codex }

    /// Called on the main thread after either provider updates.
    var onUpdate: (() -> Void)?

    func startAutoRefresh(interval: TimeInterval = 120) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        lock.lock()
        let blocked = fetching || Date() < nextAllowedFetch
        if !blocked { fetching = true }
        lock.unlock()
        if blocked { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            let claude = self.fetchClaude()
            let codex = self.fetchCodex()
            self.lock.lock()
            // Keep the last good numbers when a refresh only produced an
            // error (network hiccup / 429) - stale quota beats no quota.
            self._claude = Self.merge(old: self._claude, new: claude)
            self._codex = Self.merge(old: self._codex, new: codex)
            self.fetching = false
            // Obey the server's own cooldown. Retrying every 5 min while it asks
            // for ~1h just keeps the penalty alive, which is what left the clock
            // with no Claude figures for hours.
            self.nextAllowedFetch = Date().addingTimeInterval(self.minFetchInterval)
            if claude.rateLimited {
                self.claudeBlockedUntil = Date().addingTimeInterval(
                    claude.retryAfter ?? self.rateLimitBackoff)
            }
            self.lock.unlock()
            if let e = claude.error { FileHandle.standardError.write(Data("[usage] claude: \(e)\n".utf8)) }
            if let e = codex.error { FileHandle.standardError.write(Data("[usage] codex: \(e)\n".utf8)) }
            DispatchQueue.main.async { self.onUpdate?() }
        }
    }

    /// How long a last-known-good reading may stand in for a failed refresh.
    private static let maxStaleAge: TimeInterval = 30 * 60

    private static func merge(old: ProviderUsage, new: ProviderUsage) -> ProviderUsage {
        if new.primaryPct == nil && new.weeklyPct == nil && old.primaryPct != nil {
            // Stale beats nothing, but only for a while. Keeping the last good
            // numbers indefinitely is what let the clock show 6% for hours while
            // the real figure had climbed to 41%: wrong data that looks live is
            // worse than no data.
            if let at = old.fetchedAt, Date().timeIntervalSince(at) > maxStaleAge {
                return new
            }
            var kept = old
            kept.error = new.error
            return kept
        }
        return new
    }

    // MARK: - Claude (api.anthropic.com/api/oauth/usage)

    private func fetchClaude() -> ProviderUsage {
        // Prefer CodexBar's snapshot when it's around: it polls the same
        // endpoint but paces itself, whereas our own 2-minute cadence earned a
        // 429 with an hour-long retry-after and left the clock blank. Reading
        // its file costs no request and touches no credentials.
        if let snapshot = Self.claudeFromCodexBar() { return snapshot }

        var usage = ProviderUsage()
        // No usable snapshot, so ask the API ourselves - but not while the server
        // still wants us quiet. Deliberately not flagged as rateLimited: this is
        // us honouring an existing cooldown, not earning a fresh one.
        guard Date() >= claudeBlockedUntil else {
            usage.error = "Claude 用量接口限流中，等待冷却"
            return usage
        }
        guard let token = Self.claudeAccessToken() else {
            usage.error = "未找到 Claude Code 登录凭据"
            return usage
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, code, retryAfter) = Self.syncRequest(req) else {
            usage.error = "Claude 用量请求失败"
            return usage
        }
        guard code == 200 else {
            usage.rateLimited = code == 429
            usage.retryAfter = code == 429 ? retryAfter : nil
            usage.error = code == 401 ? "Claude 凭据过期，运行 claude 重新登录"
                : code == 429 ? "Claude 用量接口限流，稍后自动重试"
                : "Claude 用量接口 HTTP \(code)"
            return usage
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            usage.error = "Claude 用量响应解析失败"
            return usage
        }
        let now = Date().timeIntervalSince1970
        if let w = obj["five_hour"] as? [String: Any] {
            usage.primaryPct = (w["utilization"] as? NSNumber)?.doubleValue
            usage.primaryResetMin = Self.minutesUntil(iso: w["resets_at"] as? String, now: now)
        }
        if let w = obj["seven_day"] as? [String: Any] {
            usage.weeklyPct = (w["utilization"] as? NSNumber)?.doubleValue
            usage.weeklyResetMin = Self.minutesUntil(iso: w["resets_at"] as? String, now: now)
        }
        usage.fetchedAt = Date()
        return usage
    }

    /// Claude Code stores OAuth credentials in the login Keychain on macOS
    /// (file fallback for older setups). JSON: {"claudeAiOauth":{"accessToken":…}}
    static func claudeAccessToken() -> String? {
        var raw: Data?
        let credFile = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
        if let data = FileManager.default.contents(atPath: credFile) {
            raw = data
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            // If the Keychain ever puts up an access prompt (the CLI rewrites
            // this item on token refresh, which can drop our ACL entry), a
            // background agent can never answer it and would block here
            // forever, freezing all later refreshes. Cap the wait instead.
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10, execute: killer)
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            guard p.terminationStatus == 0 else { return nil }
            raw = Data(String(decoding: out, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        guard let data = raw,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    // MARK: - Codex (chatgpt.com/backend-api/wham/usage)

    private func fetchCodex() -> ProviderUsage {
        var usage = ProviderUsage()
        guard let creds = Self.codexCredentials() else {
            usage.error = "未找到 Codex 登录凭据 (~/.codex/auth.json)"
            return usage
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AIClockBridge", forHTTPHeaderField: "User-Agent")
        if let account = creds.accountId {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        guard let (data, code, _) = Self.syncRequest(req) else {
            usage.error = "Codex 用量请求失败"
            return usage
        }
        guard (200...299).contains(code) else {
            usage.error = code == 401 || code == 403 ? "Codex 凭据过期，运行 codex 重新登录" : "Codex 用量接口 HTTP \(code)"
            return usage
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = obj["rate_limit"] as? [String: Any] else {
            usage.error = "Codex 用量响应解析失败"
            return usage
        }
        let now = Date().timeIntervalSince1970
        if let w = rateLimit["primary_window"] as? [String: Any] {
            usage.primaryPct = (w["used_percent"] as? NSNumber)?.doubleValue
            if let reset = (w["reset_at"] as? NSNumber)?.doubleValue {
                usage.primaryResetMin = max(0, Int((reset - now) / 60))
            }
        }
        if let w = rateLimit["secondary_window"] as? [String: Any] {
            usage.weeklyPct = (w["used_percent"] as? NSNumber)?.doubleValue
            if let reset = (w["reset_at"] as? NSNumber)?.doubleValue {
                usage.weeklyResetMin = max(0, Int((reset - now) / 60))
            }
        }
        usage.fetchedAt = Date()
        return usage
    }

    private static func codexCredentials() -> (accessToken: String, accountId: String?)? {
        let path = ("~/.codex/auth.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        var accountId = tokens["account_id"] as? String
        if accountId == nil, let idToken = tokens["id_token"] as? String {
            accountId = Self.accountIdFromJWT(idToken)
        }
        return (access, accountId)
    }

    /// auth.json without a top-level account_id keeps it inside the id_token
    /// JWT claims (https://api.openai.com/auth -> chatgpt_account_id).
    private static func accountIdFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let auth = obj["https://api.openai.com/auth"] as? [String: Any] {
            return auth["chatgpt_account_id"] as? String
        }
        return nil
    }

    // MARK: - Claude via CodexBar's widget snapshot

    /// CodexBar writes this for its own widget, so it is a stable, structured
    /// hand-off rather than something we reverse-engineered. Only used while
    /// fresh; otherwise we fall back to asking the API ourselves.
    private static let codexBarSnapshotPath =
        ("~/Library/Group Containers/Y5PE65HELJ.com.steipete.codexbar/widget-snapshot.json"
            as NSString).expandingTildeInPath
    private static let snapshotMaxAge: TimeInterval = 20 * 60

    private static func claudeFromCodexBar() -> ProviderUsage? {
        guard let data = FileManager.default.contents(atPath: codexBarSnapshotPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = obj["entries"] as? [[String: Any]],
              let entry = entries.first(where: { $0["provider"] as? String == "claude" }),
              let updated = parseISO(entry["updatedAt"] as? String),
              Date().timeIntervalSince(updated) < snapshotMaxAge
        else { return nil }

        var usage = ProviderUsage()
        let now = Date().timeIntervalSince1970
        if let p = entry["primary"] as? [String: Any] {
            usage.primaryPct = (p["usedPercent"] as? NSNumber)?.doubleValue
            usage.primaryResetMin = minutesUntil(iso: p["resetsAt"] as? String, now: now)
        }
        if let s = entry["secondary"] as? [String: Any] {
            usage.weeklyPct = (s["usedPercent"] as? NSNumber)?.doubleValue
            usage.weeklyResetMin = minutesUntil(iso: s["resetsAt"] as? String, now: now)
        }
        guard usage.primaryPct != nil || usage.weeklyPct != nil else { return nil }
        usage.fetchedAt = updated
        return usage
    }

    // MARK: - helpers

    private static func parseISO(_ iso: String?) -> Date? {
        guard let iso = iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)
    }

    private static func minutesUntil(iso: String?, now: Double) -> Int? {
        guard let d = parseISO(iso) else { return nil }
        return max(0, Int((d.timeIntervalSince1970 - now) / 60))
    }

    private static func syncRequest(_ req: URLRequest) -> (Data, Int, TimeInterval?)? {
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, Int, TimeInterval?)?
        let task = URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data = data, let http = resp as? HTTPURLResponse {
                let retry = (http.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init)
                result = (data, http.statusCode, retry)
            }
            sem.signal()
        }
        task.resume()
        // Never wait forever. A completion that never fires (sleep/wake races,
        // a stalled connection) would strand `fetching` and silently freeze
        // every later refresh until the app is restarted.
        if sem.wait(timeout: .now() + req.timeoutInterval + 10) == .timedOut {
            task.cancel()
            return nil
        }
        return result
    }
}
