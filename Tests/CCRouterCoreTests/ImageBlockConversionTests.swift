import Foundation
@testable import CCRouterCore
import Testing

// MARK: - ImageBlockConversionTests

/// Tests for image block encoding/decoding in the IR codec layer.
///
/// Covers:
/// - decodeRequestBlocks: image base64 → IRImage
/// - decodeRequestBlocks: invalid base64 → nil
/// - decodeRequestBlocks: missing mediaType → nil
/// - encodeInputItems: IRImage → input_image data URL
/// - encodeInputItems: unsupported media type → nil
/// - encodeFullHistory: user message with text + image → single message with both parts
/// - encodeFullHistory: tool_result with image → function_call_output + synthetic user message
/// - encodeFullHistory: tool_result with text only → single function_call_output
struct ImageBlockConversionTests {

    // MARK: decodeRequestBlocks

    @Test func decodeRequestBlocks_imageBlock_returnsIRImage() {
        // Valid PNG base64 data
        let rawBytes = Data([0x89, 0x50, 0x4e, 0x47])
        let b64 = rawBytes.base64EncodedString()
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from([
                "type": .string("image"),
                "source": .object(JSONObject.from([
                    "type": .string("base64"),
                    "media_type": .string("image/png"),
                    "data": .string(b64),
                ])),
            ])
        ])
        #expect(blocks.count == 1)
        if case .image(let decodedData, let mediaType) = blocks[0] {
            #expect(decodedData == rawBytes)
            #expect(mediaType == "image/png")
        } else {
            Issue.record("Expected .image block")
        }
    }

    @Test func decodeRequestBlocks_imageBlock_invalidBase64_returnsNil() {
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from([
                "type": .string("image"),
                "source": .object(JSONObject.from([
                    "type": .string("base64"),
                    "media_type": .string("image/png"),
                    "data": .string("not-valid-base64!!!"),
                ])),
            ])
        ])
        #expect(blocks.isEmpty)
    }

    @Test func decodeRequestBlocks_imageBlock_missingMediaType_returnsNil() {
        let blocks = IRAnthropicCodec.decodeRequestBlocks([
            JSONObject.from([
                "type": .string("image"),
                "source": .object(JSONObject.from([
                    "type": .string("base64"),
                    "data": .string("AQID"),
                ])),
            ])
        ])
        #expect(blocks.isEmpty)
    }

    // MARK: encodeInputItems

    @Test func encodeInputItems_imageWithPngMediaType_producesDataUrl() {
        let rawBytes = Data([0x89, 0x50, 0x4e, 0x47])
        let message = IRMessage(role: "user", content: [.image(data: rawBytes, mediaType: "image/png")])
        let items = IRResponsesCodec.encodeInputItems([message])
        #expect(items.count == 1)
        guard let obj = items[0].objectValue else {
            Issue.record("Expected .objectValue")
            return
        }
        #expect(obj.string("type") == "message")
        #expect(obj.string("role") == "user")
        let content = obj.array("content")
        #expect(content?.count == 1)
        guard let imagePart = content?[0].objectValue else {
            Issue.record("Expected content[0] to be an object")
            return
        }
        #expect(imagePart.string("type") == "input_image")
        let imageUrl = imagePart.string("image_url") ?? ""
        #expect(imageUrl.hasPrefix("data:image/png;base64,"))
        #expect(imageUrl.hasSuffix(rawBytes.base64EncodedString()))
    }

    @Test func encodeInputItems_imageWithUnsupportedMediaType_returnsNil() {
        let rawBytes = Data([0x01, 0x02])
        let message = IRMessage(role: "user", content: [.image(data: rawBytes, mediaType: "image/tiff")])
        let items = IRResponsesCodec.encodeInputItems([message])
        // image/tiff is not in the whitelist; the whole message item is dropped
        #expect(items.isEmpty)
    }

    @Test func encodeInputItems_imageWithWebpMediaType_producesDataUrl() {
        let rawBytes = Data([0x52, 0x49, 0x46, 0x46])
        let message = IRMessage(role: "user", content: [.image(data: rawBytes, mediaType: "image/webp")])
        let items = IRResponsesCodec.encodeInputItems([message])
        #expect(items.count == 1)
        guard let obj = items[0].objectValue else {
            Issue.record("Expected .objectValue")
            return
        }
        let content = obj.array("content")
        guard let imagePart = content?[0].objectValue else {
            Issue.record("Expected image content part")
            return
        }
        #expect(imagePart.string("type") == "input_image")
        let imageUrl = imagePart.string("image_url") ?? ""
        #expect(imageUrl.hasPrefix("data:image/webp;base64,"))
    }

    @Test func encodeInputItems_imageWithJpegMediaType_producesDataUrl() {
        let rawBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let message = IRMessage(role: "user", content: [.image(data: rawBytes, mediaType: "image/jpeg")])
        let items = IRResponsesCodec.encodeInputItems([message])
        #expect(items.count == 1)
        guard let obj = items[0].objectValue else {
            Issue.record("Expected .objectValue")
            return
        }
        let content = obj.array("content")
        guard let imagePart = content?[0].objectValue else {
            Issue.record("Expected image content part")
            return
        }
        #expect(imagePart.string("type") == "input_image")
        let imageUrl = imagePart.string("image_url") ?? ""
        #expect(imageUrl.hasPrefix("data:image/jpeg;base64,"))
    }

    @Test func encodeInputItems_imageWithGifMediaType_producesDataUrl() {
        let rawBytes = Data([0x47, 0x49, 0x46, 0x38])
        let message = IRMessage(role: "user", content: [.image(data: rawBytes, mediaType: "image/gif")])
        let items = IRResponsesCodec.encodeInputItems([message])
        #expect(items.count == 1)
        guard let obj = items[0].objectValue else {
            Issue.record("Expected .objectValue")
            return
        }
        let content = obj.array("content")
        guard let imagePart = content?[0].objectValue else {
            Issue.record("Expected image content part")
            return
        }
        #expect(imagePart.string("type") == "input_image")
        let imageUrl = imagePart.string("image_url") ?? ""
        #expect(imageUrl.hasPrefix("data:image/gif;base64,"))
    }

    // MARK: encodeFullHistory

    @Test func encodeFullHistory_userMessageWithTextAndImage_producesSingleMessageWithBothParts() {
        let imageBytes = Data([0x89, 0x50, 0x4e, 0x47])
        let messages: [IRMessage] = [
            IRMessage(role: "user", content: [
                .text("Hello"),
                .image(data: imageBytes, mediaType: "image/png"),
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 1)
        guard let msg = items[0].objectValue else {
            Issue.record("Expected message item")
            return
        }
        #expect(msg.string("type") == "message")
        #expect(msg.string("role") == "user")
        let content = msg.array("content")
        #expect(content?.count == 2)
        #expect(content?[0].objectValue?.string("type") == "input_text")
        #expect(content?[0].objectValue?.string("text") == "Hello")
        #expect(content?[1].objectValue?.string("type") == "input_image")
        #expect(content?[1].objectValue?.string("image_url")?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func encodeFullHistory_toolResultWithImageContent_producesFunctionCallOutputAndUserMessage() {
        let imageBytes = Data([0x89, 0x50, 0x4e, 0x47])
        let messages: [IRMessage] = [
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "call_abc", content: [
                    .text("Screenshot captured"),
                    .image(data: imageBytes, mediaType: "image/png"),
                ])
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 2)

        // First item: function_call_output with placeholder text
        guard let fco = items[0].objectValue else {
            Issue.record("Expected function_call_output")
            return
        }
        #expect(fco.string("type") == "function_call_output")
        #expect(fco.string("call_id") == "call_abc")
        let outputText = fco.string("output") ?? ""
        #expect(outputText.contains("Screenshot captured"))
        #expect(outputText.contains("[image content follows in next user message]"))

        // Second item: synthetic user message with input_image
        guard let userMsg = items[1].objectValue else {
            Issue.record("Expected user message")
            return
        }
        #expect(userMsg.string("type") == "message")
        #expect(userMsg.string("role") == "user")
        let imgContent = userMsg.array("content")
        #expect(imgContent?.count == 1)
        #expect(imgContent?[0].objectValue?.string("type") == "input_image")
        #expect(imgContent?[0].objectValue?.string("image_url")?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func encodeFullHistory_toolResultWithTextOnly_producesSingleFunctionCallOutput() {
        let messages: [IRMessage] = [
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "call_xyz", content: [
                    .text("Tool succeeded"),
                ])
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 1)
        guard let fco = items[0].objectValue else {
            Issue.record("Expected function_call_output")
            return
        }
        #expect(fco.string("type") == "function_call_output")
        #expect(fco.string("call_id") == "call_xyz")
        #expect(fco.string("output") == "Tool succeeded")
    }

    @Test func encodeFullHistory_assistantMessageWithImage_producesMessageItem() {
        let imageBytes = Data([0x47, 0x49, 0x46, 0x38])
        let messages: [IRMessage] = [
            IRMessage(role: "assistant", content: [
                .image(data: imageBytes, mediaType: "image/gif"),
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 1)
        guard let msg = items[0].objectValue else {
            Issue.record("Expected message item")
            return
        }
        #expect(msg.string("type") == "message")
        #expect(msg.string("role") == "assistant")
        let content = msg.array("content")
        #expect(content?.count == 1)
        #expect(content?[0].objectValue?.string("type") == "input_image")
        #expect(content?[0].objectValue?.string("image_url")?.hasPrefix("data:image/gif;base64,") == true)
    }

    @Test func encodeFullHistory_toolResultWithImageOnly_producesFunctionCallOutputAndUserMessage() {
        let imageBytes = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let messages: [IRMessage] = [
            IRMessage(role: "user", content: [
                .toolResult(toolUseID: "call_img", content: [
                    .image(data: imageBytes, mediaType: "image/jpeg"),
                ])
            ])
        ]
        let items = IRResponsesCodec.encodeFullHistory(messages)
        #expect(items.count == 2)

        // function_call_output with no preceding text
        guard let fco = items[0].objectValue else {
            Issue.record("Expected function_call_output")
            return
        }
        #expect(fco.string("type") == "function_call_output")
        #expect(fco.string("call_id") == "call_img")
        let outputText = fco.string("output") ?? ""
        #expect(outputText == "[image content follows in next user message]")

        // synthetic user message with the image
        guard let userMsg = items[1].objectValue else {
            Issue.record("Expected user message")
            return
        }
        #expect(userMsg.string("type") == "message")
        #expect(userMsg.string("role") == "user")
        let imgContent = userMsg.array("content")
        #expect(imgContent?.count == 1)
        #expect(imgContent?[0].objectValue?.string("type") == "input_image")
        #expect(imgContent?[0].objectValue?.string("image_url")?.hasPrefix("data:image/jpeg;base64,") == true)
    }
}
