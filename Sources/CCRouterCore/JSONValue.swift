import Foundation

public struct JSONObject: Codable, Sendable, Equatable {
    public var values: [String: JSONValue]

    public init(_ values: [String: JSONValue] = [:]) {
        self.values = values
    }

    public subscript(key: String) -> JSONValue? {
        get { values[key] }
        set { values[key] = newValue }
    }

    public func string(_ key: String) -> String? {
        values[key]?.stringValue
    }

    public func bool(_ key: String) -> Bool? {
        values[key]?.boolValue
    }

    public func object(_ key: String) -> JSONObject? {
        values[key]?.objectValue
    }

    public func array(_ key: String) -> [JSONValue]? {
        values[key]?.arrayValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        var values: [String: JSONValue] = [:]
        for key in container.allKeys {
            values[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        self.values = values
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in values {
            try container.encode(value, forKey: DynamicCodingKey(stringValue: key)!)
        }
    }
}

public enum JSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object(JSONObject)
    case array([JSONValue])
    case null

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var objectValue: JSONObject? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(value)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .number(Double(value))
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(JSONObject.self) {
            self = .object(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            if value.rounded(.towardZero) == value {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

public extension JSONObject {
    static func from(_ values: [String: JSONValue]) -> JSONObject {
        JSONObject(values)
    }
}

private struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}
