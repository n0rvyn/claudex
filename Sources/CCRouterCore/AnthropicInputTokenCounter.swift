import Foundation

public protocol AnthropicInputTokenCounting: Sendable {
    func countInputTokens(for responsesPayload: JSONObject) async throws -> Int
}

public struct AnthropicInputTokenCounter: AnthropicInputTokenCounting, Sendable {
    public init() {}

    public func countInputTokens(for responsesPayload: JSONObject) async throws -> Int {
        let encoder = try CL100KEncoder.shared()
        let countableStrings = try Self.collectCountableStrings(from: responsesPayload)
        let total = try countableStrings.reduce(into: 0) { partial, string in
            partial += try encoder.encode(string).count
        }
        return max(1, total)
    }

    private static func collectCountableStrings(from payload: JSONObject) throws -> [String] {
        var strings: [String] = []

        if let instructions = payload.string("instructions"), !instructions.isEmpty {
            strings.append(instructions)
        }

        for item in payload.array("input")?.compactMap(\.objectValue) ?? [] {
            strings.append(contentsOf: try stringsForInputItem(item))
        }

        for tool in payload.array("tools")?.compactMap(\.objectValue) ?? [] {
            if let name = tool.string("name"), !name.isEmpty {
                strings.append(name)
            }
            if let description = tool.string("description"), !description.isEmpty {
                strings.append(description)
            }
            if let parameters = tool.object("parameters") {
                strings.append(try canonicalJSONString(for: .object(parameters)))
            }
        }

        return strings
    }

    private static func stringsForInputItem(_ item: JSONObject) throws -> [String] {
        var strings: [String] = []

        switch item.string("type") {
        case "message":
            for content in item.array("content")?.compactMap(\.objectValue) ?? [] {
                if let text = content.string("text"), !text.isEmpty {
                    strings.append(text)
                }
            }
        case "function_call":
            if let arguments = item.string("arguments"), !arguments.isEmpty {
                strings.append(arguments)
            }
        case "function_call_output":
            if let output = item.string("output"), !output.isEmpty {
                strings.append(output)
            }
        case "reasoning":
            if let summary = flattenReasoningSummary(item["summary"]), !summary.isEmpty {
                strings.append(summary)
            }
        default:
            strings.append(try canonicalJSONString(for: .object(item)))
        }

        return strings
    }

    private static func flattenReasoningSummary(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text):
            return text
        case .array(let items):
            let parts = items.compactMap { value -> String? in
                guard let object = value.objectValue else { return nil }
                guard object.string("type") == "summary_text" else { return nil }
                return object.string("text")
            }
            guard !parts.isEmpty else { return nil }
            return parts.joined(separator: "\n\n")
        default:
            return nil
        }
    }

    private static func canonicalJSONString(for value: JSONValue) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }
}

enum CL100KEncoderStorage {
    static let sharedResult: Result<CL100KEncoder, Error> = Result {
        try CL100KEncoder.loadFromBundle()
    }
}

struct CL100KEncoder: Sendable {
    static let resourceFileName = "cl100k_base"
    static let resourceExtension = "tiktoken"
    static let patStr = #"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}{1,3}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"#
    static let specialTokens: [String: Int] = [
        "<|endoftext|>": 100257,
        "<|fim_prefix|>": 100258,
        "<|fim_middle|>": 100259,
        "<|fim_suffix|>": 100260,
        "<|endofprompt|>": 100276,
    ]

    private let mergeableRanks: [Data: Int]
    private let regex: NSRegularExpression

    static func shared() throws -> CL100KEncoder {
        try CL100KEncoderStorage.sharedResult.get()
    }

    static func bundledResourceData() throws -> Data {
        guard let url = Bundle.module.url(forResource: resourceFileName, withExtension: resourceExtension) else {
            throw AnthropicInputTokenCounterError.missingTokenizerResource
        }
        return try Data(contentsOf: url)
    }

    static func loadFromBundle() throws -> CL100KEncoder {
        try CL100KEncoder(resourceData: bundledResourceData())
    }

    init(resourceData: Data) throws {
        guard let contents = String(data: resourceData, encoding: .utf8) else {
            throw AnthropicInputTokenCounterError.invalidTokenizerEncoding
        }

        var ranks: [Data: Int] = [:]
        for line in contents.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else {
                throw AnthropicInputTokenCounterError.invalidTokenizerLine(String(line))
            }
            guard let tokenBytes = Data(base64Encoded: String(parts[0])),
                  let rank = Int(parts[1])
            else {
                throw AnthropicInputTokenCounterError.invalidTokenizerLine(String(line))
            }
            ranks[tokenBytes] = rank
        }

        self.mergeableRanks = ranks
        self.regex = try NSRegularExpression(pattern: Self.patStr)
    }

    func encode(_ text: String) throws -> [Int] {
        guard !text.isEmpty else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var tokenIDs: [Int] = []
        tokenIDs.reserveCapacity(text.count)
        for match in matches {
            let piece = nsText.substring(with: match.range)
            tokenIDs.append(contentsOf: try encodePiece(Data(piece.utf8)))
        }
        return tokenIDs
    }

    private func encodePiece(_ piece: Data) throws -> [Int] {
        guard !piece.isEmpty else { return [] }
        if let rank = mergeableRanks[piece] {
            return [rank]
        }

        var parts = piece.map { Data([$0]) }
        while parts.count > 1 {
            var bestIndex: Int?
            var bestRank = Int.max

            for index in 0..<(parts.count - 1) {
                let pair = parts[index] + parts[index + 1]
                guard let rank = mergeableRanks[pair] else { continue }
                if rank < bestRank {
                    bestRank = rank
                    bestIndex = index
                }
            }

            guard let mergeIndex = bestIndex else { break }
            parts[mergeIndex] = parts[mergeIndex] + parts[mergeIndex + 1]
            parts.remove(at: mergeIndex + 1)
        }

        return try parts.map { token in
            guard let rank = mergeableRanks[token] else {
                throw AnthropicInputTokenCounterError.unknownTokenPiece(token)
            }
            return rank
        }
    }
}

enum AnthropicInputTokenCounterError: Error {
    case missingTokenizerResource
    case invalidTokenizerEncoding
    case invalidTokenizerLine(String)
    case unknownTokenPiece(Data)
}
