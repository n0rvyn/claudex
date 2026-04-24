import Foundation
@testable import CCRouterCore
import Testing

struct AnthropicInputTokenCounterTests {
    private let counter = AnthropicInputTokenCounter()

    @Test
    func identicalPayloadsCountTheSame() async throws {
        let payload = makePayload(
            instructions: "System instructions",
            inputText: "hello",
            toolDescription: "Run a bash command",
            toolParameters: JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "command": .object(JSONObject.from(["type": .string("string")])),
                ])),
            ])
        )

        let first = try await counter.countInputTokens(for: payload)
        let second = try await counter.countInputTokens(for: payload)

        #expect(first == second)
    }

    @Test
    func addingPromptBearingTextOrToolSchemaIncreasesTheCount() async throws {
        let baseline = makePayload(
            instructions: "System instructions",
            inputText: "hello",
            toolDescription: "Run a bash command",
            toolParameters: JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "command": .object(JSONObject.from(["type": .string("string")])),
                ])),
            ])
        )
        let morePromptText = makePayload(
            instructions: "System instructions",
            inputText: "hello with more text",
            toolDescription: "Run a bash command",
            toolParameters: JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "command": .object(JSONObject.from(["type": .string("string")])),
                ])),
            ])
        )
        let biggerSchema = makePayload(
            instructions: "System instructions",
            inputText: "hello with more text",
            toolDescription: "Run a bash command",
            toolParameters: JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "command": .object(JSONObject.from(["type": .string("string")])),
                    "cwd": .object(JSONObject.from(["type": .string("string")])),
                ])),
                "required": .array([.string("command"), .string("cwd")]),
            ])
        )

        let baselineCount = try await counter.countInputTokens(for: baseline)
        let textCount = try await counter.countInputTokens(for: morePromptText)
        let schemaCount = try await counter.countInputTokens(for: biggerSchema)

        #expect(textCount > baselineCount)
        #expect(schemaCount > textCount)
    }

    @Test
    func denylistedFieldsDoNotChangeTheResult() async throws {
        let baseline = makePayload(
            instructions: "System instructions",
            inputText: "hello",
            toolDescription: "Run a bash command",
            toolParameters: JSONObject.from([
                "type": .string("object"),
                "properties": .object(JSONObject.from([
                    "command": .object(JSONObject.from(["type": .string("string")])),
                ])),
            ])
        )
        var mutated = baseline
        mutated["model"] = .string("different-model")
        mutated["tool_choice"] = .string("none")
        mutated["parallel_tool_calls"] = .bool(false)
        mutated["reasoning"] = .object(JSONObject.from(["effort": .string("xhigh"), "summary": .string("auto")]))
        mutated["store"] = .bool(true)
        mutated["stream"] = .bool(false)
        mutated["include"] = .array([.string("different.include")])
        mutated["service_tier"] = .string("default")
        mutated["prompt_cache_key"] = .string("another-cache-key")
        mutated["text"] = .object(JSONObject.from(["verbosity": .string("high")]))
        mutated["client_metadata"] = .object(JSONObject.from(["source": .string("other")]))

        let baselineCount = try await counter.countInputTokens(for: baseline)
        let mutatedCount = try await counter.countInputTokens(for: mutated)

        #expect(mutatedCount == baselineCount)
    }

    @Test
    func countNeverDropsBelowOne() async throws {
        let payload = JSONObject.from([
            "instructions": .string(""),
            "input": .array([]),
            "tools": .array([]),
        ])

        let count = try await counter.countInputTokens(for: payload)

        #expect(count == 1)
    }

    private func makePayload(
        instructions: String,
        inputText: String,
        toolDescription: String,
        toolParameters: JSONObject
    ) -> JSONObject {
        JSONObject.from([
            "model": .string("executor-upstream"),
            "instructions": .string(instructions),
            "input": .array([
                .object(JSONObject.from([
                    "type": .string("message"),
                    "role": .string("user"),
                    "content": .array([
                        .object(JSONObject.from([
                            "type": .string("input_text"),
                            "text": .string(inputText),
                        ])),
                    ]),
                ])),
            ]),
            "tools": .array([
                .object(JSONObject.from([
                    "type": .string("function"),
                    "name": .string("Bash"),
                    "description": .string(toolDescription),
                    "strict": .bool(false),
                    "parameters": .object(toolParameters),
                ])),
            ]),
            "tool_choice": .string("auto"),
            "parallel_tool_calls": .bool(true),
            "reasoning": .object(JSONObject.from(["effort": .string("high"), "summary": .string("auto")])),
            "store": .bool(false),
            "stream": .bool(true),
            "include": .array([.string("reasoning.encrypted_content")]),
            "service_tier": .string("priority"),
            "prompt_cache_key": .string("cache-key"),
            "text": .object(JSONObject.from(["verbosity": .string("low")])),
            "client_metadata": .object(JSONObject.from(["x-codex-installation-id": .string("install-id")])),
        ])
    }
}
