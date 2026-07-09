import Foundation

// Samples this Mac's real up/down throughput once per second by reading the
// kernel's per-interface byte counters (getifaddrs -> AF_LINK if_data), the
// same source nettop/iStat use. Only physical "en*" interfaces are summed so
// VPN/utun traffic isn't double counted. Keeps a ring of the last 3 minutes;
// the popover chart and the ESP8266 (via GET /net on the bridge) both read it.
final class NetSpeedMonitor {
    struct Sample {
        let rx: Double // bytes/sec down
        let tx: Double // bytes/sec up
    }

    /// 4 samples per second: enough temporal resolution that the device's
    /// 250ms-per-step sweep animates smoothly instead of jumping once a second.
    static let sampleInterval = 0.25

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var totalSamples = 0 // monotonically increasing seq for /net consumers
    private var lastRx: UInt64?
    private var lastTx: UInt64?
    private var lastAt: Date?
    private var timer: Timer?

    private let capacity = 720 // 3 minutes at 4Hz

    func start() {
        sampleNow()
        timer = Timer.scheduledTimer(withTimeInterval: Self.sampleInterval, repeats: true) { [weak self] _ in
            self?.sampleNow()
        }
    }

    /// Most recent `count` samples, oldest first (padded semantics up to caller).
    func history(_ count: Int) -> [Sample] {
        lock.lock()
        defer { lock.unlock() }
        return Array(samples.suffix(count))
    }

    /// Latest instantaneous sample (may be spiky at 4Hz).
    var current: Sample {
        lock.lock()
        defer { lock.unlock() }
        return samples.last ?? Sample(rx: 0, tx: 0)
    }

    /// 1-second average — what the DL/UL readout shows (4Hz raw is too jumpy).
    var currentSmoothed: Sample {
        let recent = history(4)
        guard !recent.isEmpty else { return Sample(rx: 0, tx: 0) }
        return Sample(rx: recent.map { $0.rx }.reduce(0, +) / Double(recent.count),
                      tx: recent.map { $0.tx }.reduce(0, +) / Double(recent.count))
    }

    /// JSON for the ESP8266: smoothed current speeds + an incremental tail of
    /// recent samples. `seq` is the total sample count; the device remembers
    /// the last seq it consumed and appends only the new entries, so its sweep
    /// runs at the true 4Hz cadence regardless of how often it polls.
    func jsonData() -> Data {
        lock.lock()
        let seq = totalSamples
        // 28 samples (7s @ 4Hz) so a consumer polling/pushing on a ~5s cadence
        // never drops samples between fetches and keeps the sweep queue fed.
        let tail = Array(samples.suffix(28))
        lock.unlock()
        let smoothed = currentSmoothed
        let dict: [String: Any] = [
            "rx_bps": Int(smoothed.rx),
            "tx_bps": Int(smoothed.tx),
            "seq": seq,
            "interval_ms": Int(Self.sampleInterval * 1000),
            "rx": tail.map { Int($0.rx) },
            "tx": tail.map { Int($0.tx) },
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

    static func formatSpeed(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f MB/s", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0f KB/s", bps / 1_000) }
        return String(format: "%.0f B/s", bps)
    }

    private func sampleNow() {
        let (rx, tx) = Self.counters()
        let now = Date()
        defer {
            lastRx = rx
            lastTx = tx
            lastAt = now
        }
        guard let lr = lastRx, let lt = lastTx, let la = lastAt else { return }
        let dt = now.timeIntervalSince(la)
        guard dt > 0.2 else { return }
        // The totals combine multiple interfaces, so they can decrease when an
        // interface disappears or its kernel counter resets. Rebaseline rather
        // than interpreting that change as a single 32-bit counter wrap.
        guard let dRx = Self.counterDelta(current: rx, previous: lr),
              let dTx = Self.counterDelta(current: tx, previous: lt) else { return }
        let sample = Sample(rx: Double(dRx) / dt, tx: Double(dTx) / dt)
        lock.lock()
        samples.append(sample)
        totalSamples += 1
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
        lock.unlock()
    }

    static func counterDelta(current: UInt64, previous: UInt64) -> UInt64? {
        guard current >= previous else { return nil }
        return current - previous
    }

    private static func counters() -> (UInt64, UInt64) {
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        var rx: UInt64 = 0, tx: UInt64 = 0
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: ifa.ifa_name).hasPrefix("en"),
                  let raw = ifa.ifa_data else { continue }
            let data = raw.assumingMemoryBound(to: if_data.self).pointee
            rx += UInt64(data.ifi_ibytes)
            tx += UInt64(data.ifi_obytes)
        }
        return (rx, tx)
    }
}
