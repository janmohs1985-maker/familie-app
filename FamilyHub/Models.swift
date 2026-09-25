import Foundation

/// Beliebiger JSON-Wert (für die frei geformten `attributes` von Home Assistant).
enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    var string: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }
    var double: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        default: return nil
        }
    }
    var int: Int? { double.map { Int($0) } }
    var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    subscript(key: String) -> JSONValue? { object?[key] }
}

struct HAState: Decodable, Identifiable {
    let entity_id: String
    let state: String
    let attributes: [String: JSONValue]
    let last_changed: String?

    var id: String { entity_id }
    var name: String { attributes["friendly_name"]?.string ?? entity_id }
    var isUnavailable: Bool { state == "unavailable" || state == "unknown" }
    func attr(_ key: String) -> JSONValue? { attributes[key] }
}

struct HACalendar: Decodable, Identifiable, Hashable {
    let entity_id: String
    let name: String
    var id: String { entity_id }
}

struct HAEvent: Identifiable, Hashable {
    let id: String
    let calendarID: String
    let summary: String
    let location: String?
    let description: String?
    let start: Date
    let end: Date
    let allDay: Bool
}

/// Rohformat aus GET /api/calendars/<entity>
struct HAEventRaw: Decodable {
    struct When: Decodable { let dateTime: String?; let date: String? }
    let summary: String?
    let description: String?
    let location: String?
    let uid: String?
    let recurrence_id: String?
    let start: When
    let end: When
}

struct TodoItem: Identifiable, Hashable {
    let uid: String
    let summary: String
    let done: Bool
    let due: String?
    var id: String { uid }
}

enum HADate {
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd"; return f
    }()
    /// Format, das die Services calendar.create_event erwarten (lokale Zeit)
    static let serviceDateTime: DateFormatter = {
        let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        return isoFrac.date(from: s) ?? iso.date(from: s) ?? day.date(from: s)
    }
}
