import Foundation

public enum ItemState: String, Codable, Sendable {
    case unread, read, archived
}

public enum Status: String, Sendable {
    case idle, connecting, online, offline
}

public enum Transport: String, Sendable {
    case webSocket, longPoll
}

/// Any JSON value (the tenant-defined `payload.data`).
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .object(let o): try c.encode(o)
        case .array(let a): try c.encode(a)
        case .null: try c.encodeNil()
        }
    }
}

/// The tenant's payload; title, body, url and category are what NotificationCenterView shows.
public struct Payload: Codable, Equatable, Sendable {
    public var title: String?
    public var body: String?
    public var url: String?
    public var category: String?
    public var data: JSONValue?
}

/// An inbox item, as GET /v1/inbox and item frames carry it (docs/API.md).
public struct InboxItem: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let notificationID: String
    public internal(set) var state: ItemState
    public let template: String?
    public let payload: Payload
    public let createdAt: String
    public let cursor: String

    enum CodingKeys: String, CodingKey {
        case id, state, template, payload, cursor
        case notificationID = "notification_id"
        case createdAt = "created_at"
    }

    /// created_at as a Date (millisecond precision is plenty for display).
    public var date: Date { Date(timeIntervalSince1970: Double(timeKey(createdAt).seconds) + Double(timeKey(createdAt).nanos) / 1e9) }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var categories: [String: Bool]
    /// Whether this subscriber gets mobile pushes (ADR 0023); the inbox gets everything either way.
    /// Left nil in a request, the server keeps the subscriber's choice.
    public var push: Bool?

    public init(categories: [String: Bool], push: Bool? = nil) {
        self.categories = categories
        self.push = push
    }
}

/// A read/archive change waiting to reach the server.
enum Pending: Codable, Equatable, Sendable {
    case state(id: String, state: ItemState)
    case readAll
}

/// What the cache keeps between launches.
struct Snapshot: Codable, Sendable {
    var items: [InboxItem]
    var cursor: String
    var unread: Int
    var queue: [Pending]
}

/// Frames from /ws (docs/API.md § Realtime).
struct Frame: Decodable {
    let type: String
    let item: InboxItem?
    let count: Int?
    let id: String?
    let all: Bool?
    let state: ItemState?
    let afterMS: Int?

    enum CodingKeys: String, CodingKey {
        case type, item, count, id, all, state
        case afterMS = "after_ms"
    }
}
