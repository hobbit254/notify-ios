import Combine
import Foundation

public struct HTTPError: Error, Equatable {
    public let status: Int
}

/// A subscriber's realtime inbox (same protocol as @hobbit254/notify-core; docs/SDK.md). Observe `items`,
/// `unread` and `status` from SwiftUI; change state with markRead / archive / markAllRead
/// (optimistic, queued until the server confirms, kept in the cache across launches).
@MainActor
public final class Notify: ObservableObject {
    public struct Options: Sendable {
        /// Where the Notify API and gateway are served, e.g. https://notify.example.com
        public var apiURL: URL
        /// Returns a subscriber JWT from the tenant's backend; called again on 401 and before expiry.
        public var tokenProvider: @Sendable () async throws -> String
        /// Tried in order; one that fails twice without connecting hands over to the next.
        public var transports: [Transport] = [.webSocket, .longPoll]
        /// nil disables caching.
        public var cache: NotifyCache? = SQLiteCache()
        /// Reconnect backoff with full jitter, doubling from base to max (seconds).
        public var reconnectBase: TimeInterval = 1
        public var reconnectMax: TimeInterval = 30
        public var pageSize = 50
        public var session: URLSession = .shared

        public init(apiURL: URL, tokenProvider: @escaping @Sendable () async throws -> String) {
            self.apiURL = apiURL
            self.tokenProvider = tokenProvider
        }
    }

    public enum Event: Sendable {
        case item(InboxItem), unread(Int), status(Status), error(String)
    }

    /// Loaded items, newest first (archived ones too; filter by state).
    @Published public private(set) var items: [InboxItem] = []
    @Published public private(set) var unread = 0
    @Published public private(set) var status: Status = .idle
    @Published public private(set) var transport: Transport?
    /// When the connection last confirmed it was up to date.
    @Published public private(set) var lastSync: Date?

    private let o: Options
    private var byID: [String: InboxItem] = [:]
    private var cursor = ""
    private var newest: InboxItem?
    private var queue: [Pending] = []
    private var token: String?
    private var tokenTask: Task<String, Error>?
    private var cacheKey: String?
    private var conn: (any Connection)?
    private var tIndex = 0, failures = 0, attempt = 0
    private var reconnectAfter: TimeInterval?
    private var reconnectTask: Task<Void, Never>?
    private var flushing: Task<Bool, Never>?
    private var stopped = true
    private var observers: [UUID: (Event) -> Void] = [:]

    public init(_ options: Options) {
        o = options
    }

    /// Typed events (a new item, unread count, status, errors). Keep the returned token alive.
    public func observe(_ handler: @escaping (Event) -> Void) -> AnyCancellable {
        let id = UUID()
        observers[id] = handler
        return AnyCancellable { [weak self] in Task { @MainActor in self?.observers[id] = nil } }
    }

    private func emit(_ e: Event) { observers.values.forEach { $0(e) } }

    /// Loads the cache, fetches the inbox and unread count, then connects.
    public func start() async throws {
        guard stopped else { return }
        stopped = false
        let token = try await getToken()
        if let cache = o.cache {
            let claims = jwtClaims(token)
            cacheKey = "\(claims["app"] ?? ""):\(claims["sub"] ?? "")"
            if let data = cache.load(key: cacheKey!), let snap = try? JSONDecoder().decode(Snapshot.self, from: data) { restore(snap) }
        }
        if cursor.isEmpty {
            let page: Page = try await http("GET", "/v1/inbox?limit=\(o.pageSize)")
            page.items.forEach { add($0, live: false) }
            if !page.nextCursor.isEmpty { cursor = page.nextCursor }
        }
        let count: Count = try await http("GET", "/v1/inbox/unread-count")
        unread = count.count
        changed()
        connect()
    }

    /// Disconnects; queued changes stay cached and are sent after the next start().
    public func stop() {
        stopped = true
        reconnectTask?.cancel()
        conn?.close()
        conn = nil
        setStatus(.idle)
    }

    public func markRead(_ id: String) async { await setState(id, .read) }
    public func archive(_ id: String) async { await setState(id, .archived) }

    public func markAllRead() async {
        for (id, it) in byID where it.state == .unread {
            var copy = it
            copy.state = .read
            byID[id] = copy
        }
        unread = 0
        queue.append(.readAll)
        changed()
        await flush()
    }

    /// Loads archived items (the inbox leaves them out by default).
    public func loadArchived() async throws {
        let page: Page = try await http("GET", "/v1/inbox?state=archived&limit=\(o.pageSize)")
        page.items.forEach { add($0, live: false) }
        changed()
    }

    public func preferences() async throws -> Preferences { try await http("GET", "/v1/preferences") }

    public func setPreferences(_ categories: [String: Bool]) async throws -> Preferences {
        try await http("PUT", "/v1/preferences", body: Preferences(categories: categories)) // push nil: not sent, kept
    }

    /// Turns mobile push on or off for this subscriber; their categories stay as they are.
    public func setPushEnabled(_ enabled: Bool) async throws -> Preferences {
        try await http("PUT", "/v1/preferences", body: ["push": enabled])
    }

    /// Registers this device's FCM registration token (Firebase Messaging's `fcmToken`, not the APNs
    /// device token) so the subscriber gets pushes when the app's push is on. Safe to call on every start.
    public func registerPushToken(_ token: String) async throws {
        let _: Ignored = try await http("POST", "/v1/devices", body: ["token": token, "platform": "ios"])
    }

    /// Stops pushes to this device for this subscriber, e.g. on sign-out (call before `stop()`).
    public func unregisterPushToken(_ token: String) async throws {
        let _: Ignored = try await http("DELETE", "/v1/devices", body: ["token": token])
    }

    // MARK: state

    private func setState(_ id: String, _ state: ItemState) async {
        guard var it = byID[id], it.state != state else { return }
        if it.state == .unread { unread = max(0, unread - 1) }
        it.state = state
        byID[id] = it
        queue.append(.state(id: id, state: state))
        changed()
        await flush()
    }

    /// The state an item should show: the server's, unless a local change is still queued.
    private func pendingState(_ id: String) -> ItemState? {
        var s: ItemState?
        for p in queue {
            switch p {
            case .readAll: if s != .archived { s = .read }
            case let .state(pid, st) where pid == id: s = st
            default: break
            }
        }
        return s
    }

    private func add(_ item: InboxItem, live: Bool) {
        let known = byID[item.id] != nil
        var it = item
        if let p = pendingState(item.id) { it.state = p }
        if !known && live && it.state == .unread { unread += 1 } // replays carry no unread frame
        byID[it.id] = it
        if newest == nil || newerFirst(it, newest!) {
            newest = it
            cursor = it.cursor
        }
        if !known { emit(.item(it)) }
    }

    private func onFrame(_ f: Frame) {
        switch f.type {
        case "item":
            if let it = f.item { add(it, live: true) }
        case "unread":
            // While local changes are queued the local count is newer; a fresh count follows them.
            guard queue.isEmpty, let n = f.count else { return }
            unread = n
            emit(.unread(n))
        case "state":
            guard let st = f.state else { return }
            for (id, it) in byID where (f.all == true ? it.state == .unread : id == f.id) && it.state != st {
                var copy = it
                copy.state = st
                byID[id] = copy
            }
        case "reconnect":
            reconnectAfter = Double(f.afterMS ?? 0) / 1000
            conn?.close()
            return
        default:
            return
        }
        changed()
    }

    private func restore(_ s: Snapshot) {
        queue = s.queue
        s.items.forEach { add($0, live: false) }
        if !s.cursor.isEmpty { cursor = s.cursor }
        unread = s.unread
    }

    private func changed() {
        items = byID.values.sorted(by: newerFirst)
        if let cache = o.cache, let key = cacheKey,
           let data = try? JSONEncoder().encode(Snapshot(items: Array(items.prefix(200)), cursor: cursor, unread: unread, queue: queue)) {
            cache.save(key: key, value: data)
        }
    }

    private func setStatus(_ s: Status) {
        guard s != status else { return }
        status = s
        if s == .online { lastSync = Date() }
        emit(.status(s))
    }

    // MARK: HTTP, with token refresh

    private struct Page: Decodable {
        let items: [InboxItem]
        let nextCursor: String
        enum CodingKeys: String, CodingKey { case items, nextCursor = "next_cursor" }
    }

    private struct Count: Decodable { let count: Int }
    private struct Ignored: Decodable {}

    private func getToken() async throws -> String {
        if let t = token {
            let exp = jwtClaims(t)["exp"] as? Double
            if exp == nil || exp! - Date().timeIntervalSince1970 > 5 * 60 { return t } // docs/SDK.md: 5 min before exp
        }
        if let pending = tokenTask { return try await pending.value }
        let task = Task { try await o.tokenProvider() }
        tokenTask = task
        defer { tokenTask = nil }
        let t = try await task.value
        token = t
        return t
    }

    private func http<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil, retry: Bool = true) async throws -> T {
        let t = try await getToken()
        var req = URLRequest(url: URL(string: o.apiURL.absoluteString + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let enc = JSONEncoder()
            enc.outputFormatting = .sortedKeys
            req.httpBody = try enc.encode(body)
        }
        let (data, res) = try await o.session.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && retry {
            if token == t { token = nil }
            return try await http(method, path, body: body, retry: false)
        }
        guard (200..<300).contains(status) else { throw HTTPError(status: status) }
        if data.isEmpty, let none = Ignored() as? T { return none } // 204
        return try JSONDecoder().decode(T.self, from: data)
    }

    private struct StateBody: Encodable { let state: ItemState }

    /// Sends queued changes in order: network and 5xx errors keep them for the next connection,
    /// other 4xx (e.g. 404, the item is gone) drop them. One drain at a time; a change queued while a
    /// drain was finishing is sent by another one.
    private func flush() async {
        if flushing == nil {
            flushing = Task { await drain() }
        }
        let blocked = await flushing!.value
        flushing = nil
        if !blocked && !queue.isEmpty { await flush() }
    }

    /// True when it stopped on an error that keeps the remaining changes.
    private func drain() async -> Bool {
        while let p = queue.first {
            do {
                switch p {
                case .readAll:
                    let _: Ignored = try await http("POST", "/v1/inbox/read-all")
                case let .state(id, state):
                    let _: Ignored = try await http("PATCH", "/v1/inbox/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)", body: StateBody(state: state))
                }
            } catch let e as HTTPError where e.status < 500 && e.status != 401 {
                // dropped: the server refused this change
            } catch {
                return true
            }
            queue.removeFirst()
            changed()
        }
        return false
    }

    // MARK: transports

    private func connect() {
        guard !stopped else { return }
        let kind = o.transports[tIndex]
        transport = kind
        setStatus(.connecting)
        Task { [weak self] in await self?.open(kind) }
    }

    private func open(_ kind: Transport) async {
        let token: String
        do { token = try await getToken() } catch {
            emit(.error("token: \(error)"))
            return closed(opened: false)
        }
        guard !stopped else { return }
        let since = cursor.isEmpty ? "" : "&since=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor)"
        let tokenQ = token.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? token
        var opened = false
        var done = false
        let onOpen = { [unowned self] in
            opened = true
            attempt = 0
            failures = 0
            setStatus(.online)
            Task { await self.flush() }
        }
        let onClose = { [unowned self] in
            guard !done else { return }
            done = true
            closed(opened: opened)
        }

        switch kind {
        case .webSocket:
            var ws = o.apiURL.absoluteString + "/ws?token=\(tokenQ)\(since)"
            ws = ws.replacingOccurrences(of: "^http", with: "ws", options: .regularExpression)
            let c = WebSocketConnection(url: URL(string: ws)!)
            conn = c
            for await e in c.events {
                switch e {
                case .open: onOpen()
                case let .message(text):
                    if let f = try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)) { onFrame(f) }
                case .close: onClose()
                }
            }
            onClose()
        case .longPoll:
            let c = PollConnection()
            conn = c
            do {
                while !c.cancelled && !stopped {
                    let wait = opened ? "&wait=25" : "" // the first poll answers at once: it proves the connection
                    let path = cursor.isEmpty ? "/v1/inbox?limit=1" : "/v1/inbox?since=\(cursor.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? cursor)\(wait)"
                    let page: Page = try await http("GET", path)
                    if c.cancelled { break }
                    if !opened { onOpen() }
                    page.items.forEach { add($0, live: true) }
                    if cursor.isEmpty, !page.nextCursor.isEmpty { cursor = page.nextCursor }
                    if !page.items.isEmpty { changed() }
                    lastSync = Date()
                }
            } catch {}
            onClose()
        }
    }

    private func closed(opened: Bool) {
        conn = nil
        guard !stopped else { return }
        setStatus(.offline)
        if !opened {
            token = nil // a refused connection may mean an expired token
            failures += 1
            if failures >= 2 && tIndex < o.transports.count - 1 {
                tIndex += 1
                failures = 0
            }
        }
        let delay = reconnectAfter ?? Double.random(in: 0...min(o.reconnectMax, o.reconnectBase * pow(2, Double(attempt))))
        attempt += 1
        reconnectAfter = nil
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            guard !Task.isCancelled else { return }
            self?.connect()
        }
    }
}

// MARK: connections

@MainActor
protocol Connection: AnyObject {
    func close()
}

@MainActor
final class PollConnection: Connection {
    var cancelled = false
    func close() { cancelled = true }
}

/// URLSessionWebSocketTask with its events (open, messages, close) delivered in order on one stream.
@MainActor
final class WebSocketConnection: Connection {
    enum Event { case open, message(String), close }

    let events: AsyncStream<Event>
    private let delegate: Delegate
    private let session: URLSession
    private let task: URLSessionWebSocketTask
    private var ping: Task<Void, Never>?

    init(url: URL) {
        let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
        events = stream
        delegate = Delegate(continuation)
        session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        task = session.webSocketTask(with: url)
        task.resume()
        receive()
        let task = task
        ping = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                task.send(.string(#"{"type":"ping"}"#)) { _ in }
            }
        }
    }

    private func receive() {
        let c = delegate.continuation
        task.receive { [weak self] result in
            switch result {
            case let .success(.string(s)): c.yield(.message(s))
            case let .success(.data(d)): c.yield(.message(String(decoding: d, as: UTF8.self)))
            case .success: break
            case .failure:
                c.yield(.close)
                c.finish()
                return
            }
            Task { @MainActor in self?.receive() }
        }
    }

    func close() {
        ping?.cancel()
        task.cancel(with: .goingAway, reason: nil)
        session.invalidateAndCancel()
        delegate.continuation.yield(.close)
        delegate.continuation.finish()
    }

    final class Delegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
        let continuation: AsyncStream<Event>.Continuation
        init(_ c: AsyncStream<Event>.Continuation) { continuation = c }

        func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol p: String?) {
            continuation.yield(.open)
        }

        func urlSession(_ s: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith code: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            continuation.yield(.close)
            continuation.finish()
        }

        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            continuation.yield(.close)
            continuation.finish()
        }
    }
}
