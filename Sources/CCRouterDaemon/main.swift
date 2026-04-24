import CCRouterCore
import Foundation

@main
struct CCRouterDaemonMain {
    static func main() async {
        let envPath = ProcessInfo.processInfo.environment["CC_ROUTER_TRACE_PATH"]

        switch DaemonTraceOverrideResolver.resolve(envPath: envPath) {
        case .noOverride:
            break  // production default path
        case .invalid(let reason):
            fputs("CC_ROUTER_TRACE_PATH \(reason)\n", stderr)
            Foundation.exit(1)
        case .override(let url):
            if let prepErr = DaemonTraceOverrideResolver.prepareParentDirectory(for: url) {
                fputs("CC_ROUTER_TRACE_PATH \(prepErr)\n", stderr)
                Foundation.exit(1)
            }
            await TraceLogger.shared.setFileOverride(url)
        }

        let daemon = GatewayDaemon()
        do {
            try await daemon.start()
            let snapshot = await daemon.snapshot()
            fputs("modelbridge-daemon listening on http://\(snapshot.host):\(snapshot.port)\n", stdout)
            fputs("trace path: \(snapshot.tracePath)\n", stdout)
            try await Task.sleep(for: .seconds(86_400))
        } catch {
            fputs("Failed to start daemon: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
