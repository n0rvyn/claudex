import Foundation

public enum DaemonTraceOverrideResolver {
    public enum Resolution: Equatable {
        case noOverride
        case override(URL)
        case invalid(String)
    }

    public static func resolve(envPath: String?) -> Resolution {
        guard let envPath, !envPath.isEmpty else { return .noOverride }
        guard envPath.hasPrefix("/") else {
            return .invalid("must be absolute, got: \(envPath)")
        }
        let systemPrefixes = ["/etc/", "/System/", "/Library/"]
        if systemPrefixes.contains(where: { envPath.hasPrefix($0) }) {
            return .invalid("points to system path: \(envPath)")
        }
        return .override(URL(fileURLWithPath: envPath))
    }

    /// Tries to create the parent directory. Returns nil on success, error message on failure.
    public static func prepareParentDirectory(for url: URL) -> String? {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return nil
        } catch {
            return "failed to prepare parent directory: \(error.localizedDescription)"
        }
    }
}
