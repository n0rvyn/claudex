import Foundation
import CryptoKit
import Darwin

public struct SIWCModelCatalogSnapshot: Codable, Sendable {
    public let accountID: String
    public let fetchedAt: Date
    public let models: [SIWCModelSummary]
    public func isFresh(at now: Date = Date(), maxAge: TimeInterval = 3600) -> Bool {
        let age = now.timeIntervalSince(fetchedAt)
        return age >= 0 && age < maxAge
    }
    /// Use the advertised normal window, never the experimental maximum.
    /// All possible saved routes must have verified same-account metadata.
    public func claudeCompactionWindow(for routes: [ModelRoute]) -> Int? {
        guard !routes.isEmpty, models.allSatisfy({ $0.accountID == accountID }) else { return nil }
        let windows = routes.compactMap { route -> Int? in
            guard let model = models.first(where: { $0.id == route.upstreamModel }),
                  let window = model.details["context_window"]?.intValue, window >= 100_000 else { return nil }
            return min(window, 1_000_000)
        }
        guard windows.count == routes.count else { return nil }
        return windows.min()
    }
    public func validationError(for route: ModelRoute) -> String? {
        guard let model = models.first(where: { $0.id == route.upstreamModel }) else {
            return "Model \(route.upstreamModel) is unavailable to the selected account. Choose a model from the refreshed list."
        }
        guard !model.scalarReasoningEfforts.isEmpty else {
            return "Reasoning options for \(route.upstreamModel) were not supplied by the account. Refresh models before saving."
        }
        guard model.scalarReasoningEfforts.contains(route.reasoningEffort) else {
            return "Choose a supported reasoning effort for \(route.upstreamModel)."
        }
        return nil
    }
}

/// Account-specific, one-hour metadata cache. No model is selected and no inference is run.
public actor SIWCModelCatalog {
    public typealias Loader = @Sendable () async throws -> [SIWCModelSummary]
    private let directory: URL
    private let loader: Loader
    private let now: @Sendable () -> Date
    private var inflight: [String: Task<SIWCModelCatalogSnapshot, Error>] = [:]
    public init(directory: URL = SIWCStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("ModelCatalog"),
                loader: @escaping Loader = { try await SIWCAuth.shared.availableModels() },
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.directory = directory; self.loader = loader; self.now = now
    }
    public func load(accountID: String, force: Bool = false) async throws -> SIWCModelCatalogSnapshot {
        if let task = inflight[accountID] { return try await task.value }
        if !force, let cached = try? read(accountID), cached.isFresh(at: now()) { return cached }
        let task = Task { [loader, now] in
            let models = try await loader()
            guard models.allSatisfy({ $0.accountID == accountID && !$0.id.isEmpty }),
                  Set(models.map(\.id)).count == models.count else { throw SIWCError.remote("model_catalog_account_mismatch") }
            return SIWCModelCatalogSnapshot(accountID: accountID, fetchedAt: now(), models: models)
        }
        inflight[accountID] = task
        defer { inflight.removeValue(forKey: accountID) }
        do {
            let snapshot = try await task.value
            try save(snapshot)
            return snapshot
        } catch {
            // Transport failures do not invalidate verified metadata. Explicit
            // authorization/identity failures do; actual model errors still surface.
            if let failure = error as? SIWCError {
                switch failure {
                case .signInRequired, .invalidIdentity, .permissionRequired:
                    try? FileManager.default.removeItem(at: path(accountID))
                case .remote("model_catalog_account_mismatch"), .remote("model_catalog_401"), .remote("model_catalog_403"):
                    try? FileManager.default.removeItem(at: path(accountID))
                default: break
                }
            }
            throw error
        }
    }
    /// Verified account-scoped metadata remains usable while offline; freshness
    /// describes discovery age, not whether the gateway can bind its local socket.
    public nonisolated static func isAuthorizationFailure(_ error: any Error) -> Bool {
        guard let error = error as? SIWCError else { return false }
        switch error {
        case .signInRequired, .invalidIdentity, .permissionRequired, .remote("model_catalog_401"), .remote("model_catalog_403"): return true
        default: return false
        }
    }
    public func cached(accountID: String) throws -> SIWCModelCatalogSnapshot? { try read(accountID) }
    public func runtimeSnapshot(accountID: String) async throws -> SIWCModelCatalogSnapshot {
        if let snapshot = try read(accountID) { return snapshot }
        return try await load(accountID: accountID)
    }
    private func path(_ accountID: String) -> URL {
        let digest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
    private func read(_ accountID: String) throws -> SIWCModelCatalogSnapshot? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        try SIWCStore.validateDirectory(directory)
        let url = path(accountID)
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        guard (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              info.st_size <= 8 * 1024 * 1024 else { throw SIWCError.storage }
        let snapshot = try JSONDecoder().decode(SIWCModelCatalogSnapshot.self, from: Data(contentsOf: url))
        guard snapshot.accountID == accountID, snapshot.models.allSatisfy({ $0.accountID == accountID }),
              Set(snapshot.models.map(\.id)).count == snapshot.models.count else { throw SIWCError.storage }
        return snapshot
    }
    private func save(_ snapshot: SIWCModelCatalogSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try SIWCStore.validateDirectory(directory)
        let temporary = directory.appendingPathComponent(".catalog-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 8 * 1024 * 1024 else { throw SIWCError.storage }
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw SIWCError.storage }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data); try file.synchronize(); try file.close()
        guard rename(temporary.path, path(snapshot.accountID).path) == 0 else { throw SIWCError.storage }
    }
}

public extension SIWCModelSummary {
    var reasoningEfforts: [String] {
        var seen: Set<String> = []
        return (details.array("supported_reasoning_levels") ?? []).compactMap {
            guard let effort = $0.objectValue?.string("effort"), !effort.isEmpty, seen.insert(effort).inserted else { return nil }
            return effort
        }
    }
    var scalarReasoningEfforts: [String] { reasoningEfforts.filter { EffortPolicy.levels.contains($0) } }
    var capabilitySummary: String {
        var entries: [String] = []
        if let parallel = details.bool("supports_parallel_tool_calls") { entries.append("Parallel tool calls: " + (parallel ? "Yes" : "No")) }
        if let verbosity = details.bool("support_verbosity") { entries.append("Verbosity control: " + (verbosity ? "Yes" : "No")) }
        return entries.isEmpty ? "Capability metadata unavailable" : entries.joined(separator: " · ")
    }
}
