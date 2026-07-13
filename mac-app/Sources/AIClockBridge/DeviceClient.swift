import Foundation

// Talks to the ESP8266 clock's own HTTP API, so everything the device's web
// page can do (switch display, set bridge host, upload/reset pet GIFs) is
// available straight from the menu bar. Device address persists in defaults.

struct DeviceInfo {
    var ip = ""
    var ssid = ""
    var bridge = ""
    var mode = "auto"       // configured: auto | claude | codex | net | music
    var effective = "auto"  // what's actually on screen (AUTO may promote to music)
    var showing = ""
    var lastUpdateS = -1    // seconds since the device last got /status data, -1 = never
    var spriteRev = 0       // bumped by the device on animation change
    var claudeCustomSprite = false
    var codexCustomSprite = false
    var claudeW = 111, claudeH = 120
    var codexW = 120, codexH = 120
}

final class DeviceClient {
    private static let hostKey = "device_host"
    private static let lastSeenKey = "device_last_seen"

    static var host: String {
        get { UserDefaults.standard.string(forKey: hostKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: hostKey) }
    }

    /// Last LAN address that polled our /status — i.e. the clock itself.
    static var lastSeenIP: String {
        get { UserDefaults.standard.string(forKey: lastSeenKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: lastSeenKey) }
    }

    static var baseURL: URL? {
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        return URL(string: h.hasPrefix("http") ? h : "http://\(h)")
    }

    /// GET /api/info (direct), or the relay's /control/deviceinfo when the
    /// device is on another LAN (see `relayControl`).
    static func fetchInfo(completion: @escaping (Result<DeviceInfo, Error>) -> Void) {
        if let relay = relayControl {
            fetchInfoViaRelay(relay, completion: completion)
            return
        }
        guard let base = baseURL else {
            completion(.failure(Self.noHostError))
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("api/info"))
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req) { data, _, error in
            var result: Result<DeviceInfo, Error>
            if let error = error {
                result = .failure(error)
            } else if let data = data, let info = parseDeviceInfo(data) {
                result = .success(info)
            } else {
                result = .failure(Self.badResponseError)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// Maps an /api/info JSON body to DeviceInfo. Shared by the direct and the
    /// relay paths (the device reports the exact same JSON to the relay).
    static func parseDeviceInfo(_ data: Data) -> DeviceInfo? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var info = DeviceInfo()
        info.ip = obj["ip"] as? String ?? ""
        info.ssid = obj["ssid"] as? String ?? ""
        info.bridge = obj["bridge"] as? String ?? ""
        info.mode = obj["mode"] as? String ?? "auto"
        info.effective = obj["effective"] as? String ?? info.mode
        info.showing = obj["showing"] as? String ?? ""
        info.lastUpdateS = (obj["last_update_s"] as? NSNumber)?.intValue ?? -1
        info.spriteRev = (obj["sprite_rev"] as? NSNumber)?.intValue ?? 0
        let claude = obj["claude"] as? [String: Any]
        let codex = obj["codex"] as? [String: Any]
        info.claudeCustomSprite = claude?["custom_sprite"] as? Bool ?? false
        info.codexCustomSprite = codex?["custom_sprite"] as? Bool ?? false
        info.claudeW = (claude?["w"] as? NSNumber)?.intValue ?? 111
        info.claudeH = (claude?["h"] as? NSNumber)?.intValue ?? 120
        info.codexW = (codex?["w"] as? NSNumber)?.intValue ?? 120
        info.codexH = (codex?["h"] as? NSNumber)?.intValue ?? 120
        return info
    }

    /// POST /api/display  mode=auto|claude|codex|net|music
    static func setDisplayMode(_ mode: String, completion: @escaping (Error?) -> Void) {
        if let relay = relayControl {
            sendCommand(relay, ["type": "display", "mode": mode], completion: completion)
            return
        }
        postForm(path: "api/display", fields: ["mode": mode], completion: completion)
    }

    /// POST /api/bridge  host=ip:port
    static func setBridgeHost(_ bridgeHost: String, completion: @escaping (Error?) -> Void) {
        if let relay = relayControl {
            sendCommand(relay, ["type": "bridge", "host": bridgeHost], completion: completion)
            return
        }
        postForm(path: "api/bridge", fields: ["host": bridgeHost], completion: completion)
    }

    /// POST /sprite/{claude|codex}  multipart GIF upload — the device decodes
    /// and rescales the GIF on-board, then swaps the animation immediately.
    static func uploadGif(_ gif: Data, slot: String, completion: @escaping (Error?) -> Void) {
        if let relay = relayControl {
            uploadGifViaRelay(relay, gif, slot: slot, completion: completion)
            return
        }
        guard let base = baseURL else {
            completion(Self.noHostError)
            return
        }
        var req = URLRequest(url: base.appendingPathComponent("sprite/\(slot)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 60 // on-device decode takes a few seconds
        let boundary = "aiclock-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"pet.gif\"\r\n".utf8))
        body.append(Data("Content-Type: image/gif\r\n\r\n".utf8))
        body.append(gif)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body
        run(req, completion: completion)
    }

    /// POST /sprite/{claude|codex}/reset — back to the compiled-in animation.
    static func resetSprite(slot: String, completion: @escaping (Error?) -> Void) {
        if let relay = relayControl {
            sendCommand(relay, ["type": "reset", "slot": slot], completion: completion)
            return
        }
        postForm(path: "sprite/\(slot)/reset", fields: [:], completion: completion)
    }

    /// GET /sprite/{claude|codex}/raw — the animation the device is actually
    /// using, wire format [1 byte frame count][RGB565 big-endian frames...].
    static func fetchSpriteRaw(slot: String, completion: @escaping (Result<Data, Error>) -> Void) {
        let url: URL
        var bearer: String? = nil
        if let relay = relayControl {
            url = relayURL(relay.base, "control/sprite/\(slot)")
            bearer = relay.token
        } else if let base = baseURL {
            url = base.appendingPathComponent("sprite/\(slot)/raw")
        } else {
            completion(.failure(Self.noHostError))
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        if let bearer = bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        URLSession.shared.dataTask(with: req) { data, resp, error in
            var result: Result<Data, Error>
            if let error = error {
                result = .failure(error)
            } else if let data = data, (resp as? HTTPURLResponse)?.statusCode == 200, data.count > 1 {
                result = .success(data)
            } else {
                result = .failure(Self.badResponseError)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    // MARK: - relay control routing

    /// When the relay is configured the device is (typically) on another LAN and
    /// unreachable directly, so control goes through the relay: the device
    /// reports its info there and polls it for commands. nil => direct mode.
    private static var relayControl: (base: URL, token: String)? {
        guard let baseStr = AppConfig.string("RELAY_BASE"),
              let token = AppConfig.string("RELAY_TOKEN"),
              let url = URL(string: baseStr.hasPrefix("http") ? baseStr : "http://\(baseStr)") else {
            return nil
        }
        return (url, token)
    }

    /// Device stale after this long without reporting to the relay => "offline".
    private static let relayInfoStaleSeconds = 30

    /// Which device the relay control ops target (its chip id). Persisted so the
    /// user's pick sticks. Multiple clocks share telemetry but are controlled
    /// individually by id.
    static var selectedDeviceId: String {
        get { UserDefaults.standard.string(forKey: "selected_device_id") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "selected_device_id") }
    }

    private static func relayURL(_ base: URL, _ path: String) -> URL {
        let id = selectedDeviceId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return URL(string: base.appendingPathComponent(path).absoluteString + "?id=\(id)")
            ?? base.appendingPathComponent(path)
    }

    struct DeviceSummary { var id: String; var name: String; var ip: String; var mode: String; var age: Int }

    /// Lists every clock that has reported to the relay (for the device picker).
    static func fetchDevices(completion: @escaping ([DeviceSummary]) -> Void) {
        guard let relay = relayControl else { completion([]); return }
        var req = URLRequest(url: relay.base.appendingPathComponent("control/devices"))
        req.timeoutInterval = 8
        req.setValue("Bearer \(relay.token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, _, _ in
            var list: [DeviceSummary] = []
            if let data = data,
               let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                list = arr.map {
                    DeviceSummary(id: $0["_id"] as? String ?? $0["id"] as? String ?? "",
                                  name: $0["name"] as? String ?? "",
                                  ip: $0["ip"] as? String ?? "",
                                  mode: $0["mode"] as? String ?? "",
                                  age: ($0["_age"] as? NSNumber)?.intValue ?? 999)
                }
            }
            DispatchQueue.main.async { completion(list) }
        }.resume()
    }

    private static func fetchInfoViaRelay(_ relay: (base: URL, token: String),
                                          completion: @escaping (Result<DeviceInfo, Error>) -> Void) {
        var req = URLRequest(url: relayURL(relay.base, "control/deviceinfo"))
        req.timeoutInterval = 8
        req.setValue("Bearer \(relay.token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, resp, error in
            var result: Result<DeviceInfo, Error>
            let http = resp as? HTTPURLResponse
            if let error = error {
                result = .failure(error)
            } else if http?.statusCode == 200, let data = data, let info = parseDeviceInfo(data) {
                // The device reports periodically; if we haven't heard from it
                // in a while treat it as offline rather than showing stale data.
                let age = Int(http?.value(forHTTPHeaderField: "X-Relay-Age") ?? "") ?? 0
                if age > relayInfoStaleSeconds {
                    result = .failure(NSError(domain: "DeviceClient", code: 3,
                        userInfo: [NSLocalizedDescriptionKey: "设备 \(age)s 未上报（可能离线）"]))
                } else {
                    result = .success(info)
                }
            } else {
                // 404 => the device has never reported (never connected via relay).
                result = .failure(Self.badResponseError)
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }

    /// POST a control command to the relay's queue; the device drains it on its
    /// next poll and applies it locally.
    private static func sendCommand(_ relay: (base: URL, token: String), _ cmd: [String: Any],
                                    completion: @escaping (Error?) -> Void) {
        var req = URLRequest(url: relayURL(relay.base, "control/command"))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("Bearer \(relay.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: cmd)
        run(req, completion: completion)
    }

    /// Upload the GIF blob to the relay, then queue a "sprite" command telling
    /// the device to fetch and decode it for the given slot.
    private static func uploadGifViaRelay(_ relay: (base: URL, token: String), _ gif: Data,
                                          slot: String, completion: @escaping (Error?) -> Void) {
        var req = URLRequest(url: relayURL(relay.base, "control/gif/\(slot)"))
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("Bearer \(relay.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.httpBody = gif
        run(req) { error in
            if let error = error { completion(error); return }
            sendCommand(relay, ["type": "sprite", "slot": slot], completion: completion)
        }
    }

    // MARK: - internals

    private static func postForm(path: String, fields: [String: String],
                                 completion: @escaping (Error?) -> Void) {
        guard let base = baseURL else {
            completion(Self.noHostError)
            return
        }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        req.httpBody = Data(fields.map { k, v in
            "\(k)=\(v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)"
        }.joined(separator: "&").utf8)
        run(req, completion: completion)
    }

    private static func run(_ req: URLRequest, completion: @escaping (Error?) -> Void) {
        URLSession.shared.dataTask(with: req) { data, resp, error in
            var err = error
            if err == nil, let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let msg = data.map { String(decoding: $0, as: UTF8.self) } ?? ""
                err = NSError(domain: "DeviceClient", code: http.statusCode,
                              userInfo: [NSLocalizedDescriptionKey: "设备返回 HTTP \(http.statusCode) \(msg)"])
            }
            DispatchQueue.main.async { completion(err) }
        }.resume()
    }

    private static var noHostError: NSError {
        NSError(domain: "DeviceClient", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "未设置设备地址，请先在菜单里填写设备 IP"])
    }

    private static var badResponseError: NSError {
        NSError(domain: "DeviceClient", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "设备响应解析失败"])
    }

    // MARK: - discovery / pairing

    /// Checks whether `ip` answers like our clock (GET /api/info with the
    /// expected JSON shape).
    static func verifyDevice(ip: String, timeout: TimeInterval = 2,
                             completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "http://\(ip)/api/info") else {
            completion(false)
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        URLSession.shared.dataTask(with: req) { data, _, _ in
            let ok = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .map { $0["mode"] is String && $0["sprite_rev"] != nil } ?? false
            DispatchQueue.main.async { completion(ok) }
        }.resume()
    }

    /// Finds the clock and pairs (sets `host`). Strategy:
    ///  1. the address that most recently polled our /status (no scanning);
    ///  2. the currently configured host, re-verified;
    ///  3. sweep this Mac's /24 subnet for /api/info (covers a factory-fresh
    ///     device that has WiFi but no bridge configured yet).
    static func autoPair(progress: @escaping (String) -> Void,
                         completion: @escaping (String?) -> Void) {
        var candidates: [String] = []
        if !lastSeenIP.isEmpty { candidates.append(lastSeenIP) }
        let configured = host.split(separator: ":").first.map(String.init) ?? host
        if !configured.isEmpty, !candidates.contains(configured) { candidates.append(configured) }

        func tryNext() {
            guard let ip = candidates.first else {
                scanSubnet(progress: progress, completion: completion)
                return
            }
            candidates.removeFirst()
            progress("验证 \(ip)…")
            verifyDevice(ip: ip) { ok in
                if ok {
                    host = ip
                    completion(ip)
                } else {
                    tryNext()
                }
            }
        }
        tryNext()
    }

    /// Parallel sweep of the local /24 (254 hosts, ~0.8s timeout each,
    /// 32-wide). Only used when the passive route came up empty.
    private static func scanSubnet(progress: @escaping (String) -> Void,
                                   completion: @escaping (String?) -> Void) {
        guard let myIP = localIPv4(),
              let prefixEnd = myIP.range(of: ".", options: .backwards)?.lowerBound else {
            completion(nil)
            return
        }
        let prefix = String(myIP[..<prefixEnd])
        progress("扫描 \(prefix).1-254…")
        let session: URLSession = {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 0.8
            cfg.httpMaximumConnectionsPerHost = 1
            return URLSession(configuration: cfg)
        }()
        let group = DispatchGroup()
        let lock = NSLock()
        var found: String?
        let sem = DispatchSemaphore(value: 32)
        DispatchQueue.global(qos: .utility).async {
            for n in 1...254 {
                let ip = "\(prefix).\(n)"
                if ip == myIP { continue }
                sem.wait()
                lock.lock()
                let alreadyFound = found != nil
                lock.unlock()
                if alreadyFound { sem.signal(); continue }
                group.enter()
                let task = session.dataTask(with: URL(string: "http://\(ip)/api/info")!) { data, _, _ in
                    let ok = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                        .map { $0["mode"] is String && $0["sprite_rev"] != nil } ?? false
                    if ok {
                        lock.lock()
                        if found == nil { found = ip }
                        lock.unlock()
                    }
                    sem.signal()
                    group.leave()
                }
                task.resume()
            }
            group.notify(queue: .main) {
                if let ip = found { host = ip }
                completion(found)
            }
        }
    }

    // MARK: - pairing watchdog

    /// Stamped on every device poll of our /status|/net|/music (see main.swift).
    static var devicePollAt = Date.distantPast

    private static var healInFlight = false
    private static var lastHealAttempt = Date.distantPast

    /// Self-healing for the fresh-device chicken-and-egg: after a full flash
    /// erase the clock knows no bridge host, so it never polls us and passive
    /// discovery never fires. When we haven't heard from the device for a few
    /// minutes, actively find it (last-seen IP, configured host, then /24
    /// scan) and, if its bridge is unset or it can't reach the one it has,
    /// point it at this Mac. Called from a 60s timer; the /24 scan is
    /// rate-limited to once per 5 minutes.
    static func healPairingIfNeeded(port: UInt16) {
        guard Date().timeIntervalSince(devicePollAt) > 180 else { return } // device is polling us
        guard !healInFlight, Date().timeIntervalSince(lastHealAttempt) > 300 else { return }
        healInFlight = true
        lastHealAttempt = Date()
        autoPair(progress: { _ in }) { ip in
            guard ip != nil else { healInFlight = false; return }
            fetchInfo { result in
                defer { healInFlight = false }
                guard case let .success(info) = result, let myIP = localIPv4() else { return }
                let stale = info.lastUpdateS < 0 || info.lastUpdateS > 60
                guard info.bridge.isEmpty || stale else { return }
                setBridgeHost("\(myIP):\(port)") { error in
                    FileHandle.standardError.write(Data(
                        "[pair] pushed bridge \(myIP):\(port) to \(info.ip): \(error.map { "\($0.localizedDescription)" } ?? "ok")\n".utf8))
                }
            }
        }
    }

    /// LAN IPv4 of this Mac (en0 preferred) — used for one-click "point the
    /// device's bridge at this Mac".
    static func localIPv4() -> String? {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return nil }
        defer { freeifaddrs(addrs) }
        var best: String?
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0,
                  (ifa.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let name = String(cString: ifa.ifa_name)
            let ip = String(cString: host)
            if name == "en0" { return ip }
            if best == nil { best = ip }
        }
        return best
    }
}
