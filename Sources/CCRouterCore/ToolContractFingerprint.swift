import CryptoKit
import Foundation

enum ToolContractFingerprint {
    private static let unorderedSchemaArrayKeys: Set<String> = [
        "required",
        "enum",
        "type",
        "allOf",
        "anyOf",
        "oneOf",
    ]

    static func stable(_ tools: [JSONObject]) -> String {
        let normalizedTools = tools.map(normalizeTool).sorted { lhs, rhs in
            let lhsName = lhs.string("name") ?? ""
            let rhsName = rhs.string("name") ?? ""
            if lhsName != rhsName {
                return lhsName < rhsName
            }
            return canonicalJSONString(for: .object(lhs)) < canonicalJSONString(for: .object(rhs))
        }

        let canonical = canonicalJSONString(for: .array(normalizedTools.map(JSONValue.object)))
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func normalizeTool(_ tool: JSONObject) -> JSONObject {
        let type = tool.string("type") ?? "function"
        if type == "function" {
            return JSONObject.from([
                "type": .string(type),
                "name": .string(tool.string("name") ?? ""),
                "description": .string(tool.string("description") ?? ""),
                "strict": tool["strict"] ?? .bool(false),
                "parameters": .object(normalizeObject(tool.object("parameters") ?? JSONObject(), parentKey: "parameters")),
            ])
        }

        var fields: [String: JSONValue] = ["type": .string(type)]
        for key in ["external_web_access", "search_content_types", "filters", "user_location"] {
            if let value = tool.values[key] {
                fields[key] = normalizeValue(value, parentKey: key)
            }
        }
        return JSONObject.from(fields)
    }

    private static func normalizeValue(_ value: JSONValue, parentKey: String?) -> JSONValue {
        switch value {
        case .object(let object):
            return .object(normalizeObject(object, parentKey: parentKey))
        case .array(let array):
            let normalized = array.map { normalizeValue($0, parentKey: nil) }
            guard shouldSortArray(for: parentKey, values: array) else {
                return .array(normalized)
            }
            return .array(normalized.sorted {
                canonicalJSONString(for: $0) < canonicalJSONString(for: $1)
            })
        case .string, .number, .bool, .null:
            return value
        }
    }

    private static func normalizeObject(_ object: JSONObject, parentKey: String?) -> JSONObject {
        var normalized: [String: JSONValue] = [:]
        for key in object.values.keys.sorted() {
            guard let value = object.values[key] else { continue }
            normalized[key] = normalizeValue(value, parentKey: key)
        }
        return JSONObject(normalized)
    }

    private static func shouldSortArray(for parentKey: String?, values: [JSONValue]) -> Bool {
        guard let parentKey, unorderedSchemaArrayKeys.contains(parentKey) else {
            return false
        }
        if parentKey == "type" {
            return values.count > 1
        }
        return true
    }

    private static func canonicalJSONString(for value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try! encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}
