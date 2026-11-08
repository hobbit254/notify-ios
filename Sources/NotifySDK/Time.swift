import Foundation

/// created_at as an exact, comparable instant. The server sends RFC 3339 with any offset and up to
/// 9 fraction digits; string order is not time order.
struct TimeKey: Comparable {
    let seconds: Int64
    let nanos: Int
    static func < (a: TimeKey, b: TimeKey) -> Bool { (a.seconds, a.nanos) < (b.seconds, b.nanos) }
}

// ISO8601DateFormatter is thread-safe for parsing (Foundation docs); it is never mutated after creation.
nonisolated(unsafe) private let wholeSeconds: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

func timeKey(_ iso: String) -> TimeKey {
    var s = iso
    var nanos = 0
    if let dot = s.firstIndex(of: ".") {
        let end = s[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) ?? s.endIndex
        let digits = String(s[s.index(after: dot)..<end].prefix(9))
        nanos = Int(digits.padding(toLength: 9, withPad: "0", startingAt: 0)) ?? 0
        s.removeSubrange(dot..<end)
    }
    let secs = wholeSeconds.date(from: s).map { Int64($0.timeIntervalSince1970) } ?? 0
    return TimeKey(seconds: secs, nanos: nanos)
}

/// Newest first: created_at, then id (the server's cursor order, reversed).
func newerFirst(_ a: InboxItem, _ b: InboxItem) -> Bool {
    let (x, y) = (timeKey(a.createdAt), timeKey(b.createdAt))
    return x != y ? x > y : a.id > b.id
}

/// Claims of a JWT (unverified: only for exp and the cache key).
func jwtClaims(_ token: String) -> [String: Any] {
    let parts = token.split(separator: ".")
    guard parts.count >= 2 else { return [:] }
    var b64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
    guard let data = Data(base64Encoded: b64), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
    return obj
}
