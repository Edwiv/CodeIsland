/// Bounds short-lived SSH operations that share the user's jump host.
///
/// Remote setup, health probes, and stale-socket cleanup can all start at once during launch or
/// wake recovery. Opening those connections concurrently overloads some jump proxies and causes
/// false banner timeouts, so they take a single FIFO permit. Long-lived reverse tunnels remain
/// dedicated connections and are not held behind this gate after launch.
actor SSHCommandGate {
    static let shared = SSHCommandGate(limit: 1)

    private let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(1, limit)
        self.available = max(1, limit)
    }

    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            available = min(limit, available + 1)
        } else {
            waiters.removeFirst().resume()
        }
    }
}
