import CCRouterCore
import Foundation

@main
struct CCRouterDaemonMain {
    static func main() async {
        let daemon = GatewayDaemon()

        do {
            try await daemon.start()
            let snapshot = await daemon.snapshot()
            print("modelbridge-daemon listening on http://\(snapshot.host):\(snapshot.port)")
            try await Task.sleep(for: .seconds(86_400))
        } catch {
            fputs("Failed to start daemon: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
