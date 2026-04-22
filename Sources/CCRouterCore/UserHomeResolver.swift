import Darwin
import Foundation

public enum UserHomeResolver {
    public static func effectiveHomeDirectoryURL(
        fallbackHomeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let fallbackPath = fallbackHomeDirectoryURL.standardizedFileURL.path
        guard isContainerizedHomeDirectoryPath(fallbackPath),
              let actualHomeDirectoryURL = posixHomeDirectoryURL()
        else {
            return fallbackHomeDirectoryURL
        }

        let actualPath = actualHomeDirectoryURL.standardizedFileURL.path
        guard actualPath != fallbackPath else {
            return fallbackHomeDirectoryURL
        }

        return actualHomeDirectoryURL
    }

    public static func defaultSubscriptionAuthFilePath(
        fallbackHomeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        effectiveHomeDirectoryURL(fallbackHomeDirectoryURL: fallbackHomeDirectoryURL)
            .appendingPathComponent(".codex/auth.json")
            .path
    }

    public static func defaultApplicationSupportDirectoryURL(
        fallbackHomeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        fallbackHomeDirectoryURL
            .appendingPathComponent("Library/Application Support/ModelBridge", isDirectory: true)
    }

    public static func defaultTraceLogFilePath(
        fallbackHomeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        defaultApplicationSupportDirectoryURL(fallbackHomeDirectoryURL: fallbackHomeDirectoryURL)
            .appendingPathComponent("trace.jsonl")
            .path
    }

    static func containerizationWarning(
        fallbackHomeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        let fallbackPath = fallbackHomeDirectoryURL.standardizedFileURL.path
        guard isContainerizedHomeDirectoryPath(fallbackPath) else { return nil }
        return "ModelBridge is running inside App Sandbox. Choose ~/.codex/auth.json in Settings to authorize upstream access."
    }

    static func shouldReplaceContainerizedAuthPath(_ path: String?) -> Bool {
        guard let path, !path.isEmpty else { return true }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return standardizedPath.contains("/Library/Containers/")
            && standardizedPath.hasSuffix("/Data/.codex/auth.json")
    }

    private static func isContainerizedHomeDirectoryPath(_ path: String) -> Bool {
        path.hasPrefix("/Users/")
            && path.contains("/Library/Containers/")
            && path.hasSuffix("/Data")
    }

    private static func posixHomeDirectoryURL() -> URL? {
        guard let entry = getpwuid(getuid()),
              let directory = entry.pointee.pw_dir else {
            return nil
        }

        let path = String(cString: directory)
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
