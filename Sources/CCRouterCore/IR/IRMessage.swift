import Foundation

/// A single turn message in the typed IR layer.
///
/// - role: "user" | "assistant" | "system"
/// - content: ordered list of IRBlocks
public struct IRMessage: Sendable, Equatable {
    public let role: String
    public let content: [IRBlock]

    public init(role: String, content: [IRBlock]) {
        self.role = role
        self.content = content
    }
}
