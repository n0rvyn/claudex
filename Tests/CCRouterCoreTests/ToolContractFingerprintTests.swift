import Foundation
@testable import CCRouterCore
import Testing

struct ToolContractFingerprintTests {
    @Test
    func reorderedToolsProduceSameFingerprint() {
        let bash = makeTool(
            name: "Bash",
            description: "Run a bash command",
            parameters: JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "command": .object(JSONObject.from(["type": .string("string")])),
                ])),
                "required": .array([.string("command")]),
            ])
        )
        let read = makeTool(
            name: "Read",
            description: "Read a file",
            parameters: JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "path": .object(JSONObject.from(["type": .string("string")])),
                ])),
                "required": .array([.string("path")]),
            ])
        )

        let first = ToolContractFingerprint.stable([bash, read])
        let second = ToolContractFingerprint.stable([read, bash])

        #expect(first == second)
    }

    @Test
    func requiredAndEnumReorderingStaysEquivalent() {
        let lhs = makeTool(
            name: "Bash",
            description: "Run a bash command",
            parameters: JSONObject.from([
                "type": .string("object"),
                "required": .array([.string("command"), .string("cwd")]),
                "properties": .object(JSONObject.from([
                    "mode": .object(JSONObject.from([
                        "type": .string("string"),
                        "enum": .array([.string("read"), .string("write"), .string("exec")]),
                    ])),
                ])),
            ])
        )
        let rhs = makeTool(
            name: "Bash",
            description: "Run a bash command",
            parameters: JSONObject.from([
                "type": .string("object"),
                "required": .array([.string("cwd"), .string("command")]),
                "properties": .object(JSONObject.from([
                    "mode": .object(JSONObject.from([
                        "type": .string("string"),
                        "enum": .array([.string("exec"), .string("write"), .string("read")]),
                    ])),
                ])),
            ])
        )

        #expect(ToolContractFingerprint.stable([lhs]) == ToolContractFingerprint.stable([rhs]))
    }

    @Test
    func nonSetLikeArrayOrderRemainsSignificant() {
        let lhs = makeTool(
            name: "Bash",
            description: "Run a bash command",
            parameters: JSONObject.from([
                "type": .string("object"),
                "prefixItems": .array([
                    .object(JSONObject.from(["type": .string("string")])),
                    .object(JSONObject.from(["type": .string("number")])),
                ]),
            ])
        )
        let rhs = makeTool(
            name: "Bash",
            description: "Run a bash command",
            parameters: JSONObject.from([
                "type": .string("object"),
                "prefixItems": .array([
                    .object(JSONObject.from(["type": .string("number")])),
                    .object(JSONObject.from(["type": .string("string")])),
                ]),
            ])
        )

        #expect(ToolContractFingerprint.stable([lhs]) != ToolContractFingerprint.stable([rhs]))
    }

    @Test
    func schemaNameAndDescriptionChangesProduceDifferentFingerprints() {
        let baseline = makeTool(
            name: "Bash",
            description: "Run a bash command",
            parameters: JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "command": .object(JSONObject.from(["type": .string("string")])),
                ])),
            ])
        )
        let renamed = makeTool(
            name: "Shell",
            description: "Run a bash command",
            parameters: baseline.object("parameters") ?? JSONObject()
        )
        let redesc = makeTool(
            name: "Bash",
            description: "Run shell code",
            parameters: baseline.object("parameters") ?? JSONObject()
        )
        let reschema = makeTool(
            name: "Bash",
            description: "Run a bash command",
            parameters: JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "command": .object(JSONObject.from(["type": .string("string")])),
                    "cwd": .object(JSONObject.from(["type": .string("string")])),
                ])),
            ])
        )

        let baselineHash = ToolContractFingerprint.stable([baseline])
        #expect(ToolContractFingerprint.stable([renamed]) != baselineHash)
        #expect(ToolContractFingerprint.stable([redesc]) != baselineHash)
        #expect(ToolContractFingerprint.stable([reschema]) != baselineHash)
    }

    @Test
    func nativeToolTypeAndFiltersAffectFingerprint() {
        let baseline = JSONObject.from([
            "type": .string("web_search"),
            "external_web_access": .bool(true),
            "search_content_types": .array([.string("text")]),
            "filters": .object(JSONObject.from([
                "allowed_domains": .array([.string("example.com")]),
            ])),
        ])
        let changed = JSONObject.from([
            "type": .string("web_search"),
            "external_web_access": .bool(true),
            "search_content_types": .array([.string("text")]),
            "filters": .object(JSONObject.from([
                "allowed_domains": .array([.string("example.org")]),
            ])),
        ])

        #expect(ToolContractFingerprint.stable([baseline]) != ToolContractFingerprint.stable([changed]))
    }

    private func makeTool(name: String, description: String, parameters: JSONObject) -> JSONObject {
        JSONObject.from([
            "type": .string("function"),
            "name": .string(name),
            "description": .string(description),
            "strict": .bool(false),
            "parameters": .object(parameters),
        ])
    }
}
