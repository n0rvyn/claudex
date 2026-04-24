import Foundation
import CryptoKit

public enum PromptCacheKey {
    /// Derives a stable cache key. When `sessionID` is non-empty and ≤ 512 bytes,
    /// returns the sanitised session ID (lowercased). Otherwise falls back to
    /// `sha256(instructions + firstUserMessageText)` rendered as 64-hex.
    public static func stable(
        sessionID: String?,
        instructions: String,
        firstUserMessageText: String
    ) -> String {
        if let id = sessionID,
           !id.isEmpty,
           id.utf8.count <= 512 {
            return id.lowercased()
        }
        var hasher = SHA256()
        hasher.update(data: Data(instructions.utf8))
        hasher.update(data: Data([0x1F]))  // unit separator, avoids accidental collisions
        hasher.update(data: Data(firstUserMessageText.utf8))
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
