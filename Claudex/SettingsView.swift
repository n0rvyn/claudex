import AppKit
import CCRouterCore
import ServiceManagement
import SwiftUI

// MARK: - Settings window (native tabs)

struct DoctorSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SettingsTab = .general

    var body: some View {
        ZStack {
            MBColor.paper.ignoresSafeArea()

            TabView(selection: $selection) {
                GeneralSettingsTab(model: model)
                    .tag(SettingsTab.general)
                    .tabItem { Label("General", systemImage: "gearshape") }

                GatewaySettingsTab(model: model)
                    .tag(SettingsTab.gateway)
                    .tabItem { Label("Gateway", systemImage: "dot.radiowaves.left.and.right") }

                ClaudeCodeSettingsTab(model: model)
                    .tag(SettingsTab.claudeCode)
                    .tabItem { Label("Claude Code", systemImage: "terminal") }

                UpstreamSettingsTab(model: model)
                    .tag(SettingsTab.upstream)
                    .tabItem { Label("Upstream", systemImage: "arrow.triangle.branch") }

                DiagnosticsSettingsTab(model: model)
                    .tag(SettingsTab.diagnostics)
                    .tabItem { Label("Diagnostics", systemImage: "waveform.and.magnifyingglass") }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SettingsFooter(model: model)
            }
        }
    }
}

// MARK: - Settings footer

private struct SettingsFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            MBDot(state: model.headerDotState, size: 6)
            Text(statusLine)
                .font(.system(size: 11))
                .foregroundStyle(MBColor.inkDim)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text(model.appVersion)
                .font(MBFont.monoSmall)
                .foregroundStyle(MBColor.inkFaint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(MBColor.paperDim)
        .overlay(
            Rectangle()
                .fill(MBColor.ruleSoft)
                .frame(height: 0.5),
            alignment: .top
        )
    }

    private var statusLine: String {
        if model.requiresAuthAttention { return model.authActionTitle }
        if !model.daemonIsRunning { return "Gateway paused" }
        return "Gateway running · \(model.upstreamDisplayName)"
    }
}

private enum SettingsTab: Hashable {
    case general, gateway, claudeCode, upstream, diagnostics
}

// MARK: - Shared tab chrome

private struct SettingsShell<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .background(MBColor.paper)
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @ObservedObject var model: AppModel
    @AppStorage("claudex.appearance") private var appearanceRaw: Int = 0

    var body: some View {
        SettingsShell {
            AppInfoCard(model: model)
                .padding(.bottom, 14)

            MBSection(title: "Appearance") {
                MBField(
                    label: "Theme",
                    help: "Menu bar popover and settings window adapt to this."
                ) {
                    MBSeg(
                        value: $appearanceRaw,
                        options: [(0, "Auto"), (1, "Light"), (2, "Dark")]
                    )
                }
            }

            MBSection(title: "Startup") {
                MBField(
                    label: "Launch at login",
                    help: "Start Claudex and bind the local gateway when you log in."
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { _ in model.toggleLaunchAtLogin() }
                    ))
                    .toggleStyle(MBToggleStyle())
                    .labelsHidden()
                }
                launchAtLoginStatusView
            }

            MBSection(title: "Storage") {
                MBField(
                    label: "Config file",
                    help: "Edited by the app as you change settings.",
                    stacked: true,
                    chipText: "Plaintext",
                    chipTone: .warn
                ) {
                    HStack(spacing: 6) {
                        MBReadOnlyField(value: model.configurationPath, truncateMiddle: true)
                        Button(action: { model.openConfigurationLocation() }) {
                            Label("Reveal", systemImage: "folder")
                        }
                        Button(action: { copyConfigPath() }) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }

                MBField(
                    label: "App data folder",
                    help: "Trace logs and auxiliary state.",
                    stacked: true
                ) {
                    Button(action: { model.openApplicationSupportDirectory() }) {
                        Label("Reveal in Finder", systemImage: "folder.badge.gearshape")
                    }
                }
            }

            AboutSection(model: model)
        }
    }

    @ViewBuilder
    private var launchAtLoginStatusView: some View {
        switch model.launchAtLoginStatus {
        case .notFound:
            MBBanner(
                tone: .warn,
                title: "Launch at login needs the packaged app bundle.",
                message: "Run \"bash scripts/build_app_bundle.sh\" in the Claudex repo to produce dist/Claudex.app, then move it into /Applications."
            ) {
                Button(action: { revealApplicationsFolder() }) {
                    Label("Open /Applications", systemImage: "app.gift")
                }
            }
            .padding(.top, 4)

        case .requiresApproval:
            MBBanner(
                tone: .warn,
                title: "Login Items needs your approval.",
                message: "macOS hasn't authorized Claudex to start at login yet."
            ) {
                Button(action: { openLoginItemsSettings() }) {
                    Label("Open Login Items", systemImage: "gear")
                }
            }
            .padding(.top, 4)

        case .enabled:
            HStack(spacing: 6) {
                MBDot(state: .live, size: 8)
                Text("Will start automatically at login.")
                    .font(.system(size: 12))
                    .foregroundStyle(MBColor.inkMid)
            }
            .padding(.top, 6)

        case .notRegistered:
            EmptyView()

        @unknown default:
            EmptyView()
        }
    }

    private func copyConfigPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.configurationPath, forType: .string)
    }

    private func revealApplicationsFolder() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications", isDirectory: true))
    }

    private func openLoginItemsSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

private struct AppInfoCard: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            MBBridgeBadge(size: 40, cornerRadius: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claudex")
                    .font(MBFont.labelB)
                    .foregroundStyle(MBColor.ink)
                Text("Local Anthropic ↔ Codex bridge · \(model.appVersion)")
                    .font(.system(size: 11))
                    .foregroundStyle(MBColor.inkDim)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(MBColor.paperDim)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(MBColor.ruleSoft, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - About section

private struct AboutSection: View {
    @ObservedObject var model: AppModel

    private let privacyURL   = URL(string: "https://prickly-pentagon-3b6.notion.site/Privacy-Policy-34dd945c7a9b814e87b6ea016d49a747")
    private let termsURL     = URL(string: "https://prickly-pentagon-3b6.notion.site/Terms-of-Use-34dd945c7a9b81acb4b7e1cae6deb37d")
    private let supportURL   = URL(string: "https://prickly-pentagon-3b6.notion.site/Support-34dd945c7a9b810ba78cc1bce08a6a8e")
    private let marketingURL = URL(string: "https://prickly-pentagon-3b6.notion.site/Market-Claudex-34dd945c7a9b8193a7bbe8d5b4a439bf")

    var body: some View {
        MBSection(title: "About") {
            MBField(label: "Version") {
                HStack(spacing: 6) {
                    Text(model.appVersion)
                        .font(MBFont.mono)
                        .foregroundStyle(MBColor.inkMid)
                        .textSelection(.enabled)
                    Button(action: { copyVersion() }) {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                }
            }
            MBField(label: "Public pages", help: "Linked from the App Store Connect submission.") {
                HStack(spacing: 12) {
                    linkButton(title: "Privacy Policy", url: privacyURL)
                    linkButton(title: "Terms of Use",   url: termsURL)
                    linkButton(title: "Support",        url: supportURL)
                    linkButton(title: "Marketing",      url: marketingURL)
                }
            }
            MBField(label: "Quit") {
                Button(role: .destructive, action: { NSApplication.shared.terminate(nil) }) {
                    Label("Quit Claudex", systemImage: "power")
                }
            }
        }
    }

    @ViewBuilder
    private func linkButton(title: String, url: URL?) -> some View {
        if let url {
            Button(action: { NSWorkspace.shared.open(url) }) {
                Label(title, systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.link)
        } else {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(MBColor.inkFaint)
                .help("URL not configured")
        }
    }

    private func copyVersion() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(model.appVersion, forType: .string)
    }
}

// MARK: - Gateway tab

private struct GatewaySettingsTab: View {
    @ObservedObject var model: AppModel
    @State private var revealToken = false

    var body: some View {
        SettingsShell {
            MBSection(title: "Local gateway") {
                MBField(
                    label: "Listener host",
                    help: "Where the local gateway binds. 127.0.0.1 keeps it loopback-only."
                ) {
                    TextField("127.0.0.1", text: $model.gatewayHostDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(MBFont.mono)
                        .frame(maxWidth: 220)
                }
                MBField(
                    label: "Listener port",
                    help: "Choose any free local port."
                ) {
                    TextField("4317", text: $model.gatewayPortDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(MBFont.mono)
                        .frame(maxWidth: 120)
                }
                MBField(label: "Current endpoint") {
                    HStack(spacing: 6) {
                        MBReadOnlyField(value: model.endpoint)
                        Button(action: { model.copyEndpoint() }) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            }

            MBSection(title: "Ingress token") {
                MBField(
                    label: "x-api-key",
                    help: "Used to gate requests reaching the local gateway. Regenerate to invalidate old copies.",
                    stacked: true
                ) {
                    HStack(spacing: 6) {
                        MBReadOnlyField(value: revealToken
                            ? model.currentConfiguration.gatewayAuthToken
                            : mask(model.currentConfiguration.gatewayAuthToken))
                        Button(action: { revealToken.toggle() }) {
                            Image(systemName: revealToken ? "eye.slash" : "eye")
                        }
                        Button(action: { model.copyGatewayToken() }) {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        Button(action: { model.regenerateGatewayToken() }) {
                            Label("Regenerate", systemImage: "arrow.clockwise")
                        }
                    }
                }
                MBField(label: "State") {
                    Text(model.gatewayTokenText)
                        .font(.system(size: 12))
                        .foregroundStyle(MBColor.inkMid)
                        .textSelection(.enabled)
                }
            }

            HStack {
                Spacer(minLength: 0)
                Button(action: { model.saveGatewaySettings() }) {
                    Label("Save gateway", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
    }

    private func mask(_ value: String) -> String {
        guard value.count > 8 else { return String(repeating: "•", count: max(6, value.count)) }
        let head = value.prefix(4)
        let tail = value.suffix(4)
        return "\(head)••••••••\(tail)"
    }
}

// MARK: - Claude Code tab

private struct ClaudeCodeSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsShell {
            MBSection(title: "Environment") {
                MBField(
                    label: "CLI snippet",
                    help: "Paste these two exports into the shell that runs Claude Code.",
                    stacked: true
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        envSnippetBlock
                        HStack(spacing: 6) {
                            Button(action: { model.copyEnvSnippet() }) {
                                Label("Copy both", systemImage: "doc.on.doc")
                            }
                            .buttonStyle(.borderedProminent)
                            Button(action: { model.copyEndpoint() }) {
                                Label("Copy base URL", systemImage: "link")
                            }
                            Button(action: { model.copyGatewayToken() }) {
                                Label("Copy token", systemImage: "key")
                            }
                        }
                    }
                }
            }

            MBSection(title: "Quick start") {
                MBField(
                    label: "Verified command",
                    help: "Confirms Claude Code can reach the gateway end-to-end.",
                    stacked: true
                ) {
                    MBReadOnlyField(value: """
                    ANTHROPIC_BASE_URL=\(model.endpoint)
                    ANTHROPIC_AUTH_TOKEN=<gateway-token>
                    claude --bare -p --output-format json 'Reply exactly SMOKEOK.'
                    """)
                }
            }
        }
    }

    private var envSnippetBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("$").foregroundStyle(MBColor.live)
                Text("export ").foregroundStyle(MBColor.inkDim)
                + Text("ANTHROPIC_BASE_URL").foregroundStyle(MBColor.ink)
                + Text("=").foregroundStyle(MBColor.inkDim)
                + Text(model.endpoint).foregroundStyle(MBColor.warnInk)
            }
            HStack(spacing: 8) {
                Text("$").foregroundStyle(MBColor.live)
                Text("export ").foregroundStyle(MBColor.inkDim)
                + Text("ANTHROPIC_AUTH_TOKEN").foregroundStyle(MBColor.ink)
                + Text("=").foregroundStyle(MBColor.inkDim)
                + Text("<gateway-token>").foregroundStyle(MBColor.warnInk)
            }
        }
        .font(MBFont.mono)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MBColor.term)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Upstream tab

private struct UpstreamSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsShell {
            MBSection(title: "Route") {
                MBField(
                    label: "Destination",
                    help: "Claudex currently routes Anthropic Messages to the subscription-backed responses endpoint.",
                    stacked: true
                ) {
                    routeVisualization
                }
            }

            MBSection(title: "Upstream") {
                MBField(
                    label: "Responses URL",
                    help: "The subscription-backed HTTP endpoint to forward to."
                ) {
                    TextField("", text: $model.responsesURLDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(MBFont.mono)
                }
            }

            MBSection(title: "Routing policy") {
                RoutingPolicyEditor(model: model)
            }

            MBSection(title: "Subscription auth") {
                MBField(
                    label: "Auth file",
                    help: "Click Choose, then select ~/.codex/auth.json from your home folder.",
                    stacked: true
                ) {
                    HStack(spacing: 6) {
                        TextField("", text: Binding(
                            get: { model.subscriptionAuthFilePathDraft },
                            set: { model.updateSubscriptionAuthFilePathDraft($0) }
                        ))
                            .textFieldStyle(.roundedBorder)
                            .font(MBFont.mono)
                        Button(action: { model.chooseSubscriptionAuthFile() }) {
                            Label("Choose", systemImage: "key.horizontal")
                        }
                        Button(action: { model.openSubscriptionAuthLocation() }) {
                            Label("Reveal", systemImage: "folder")
                        }
                    }
                }
                MBField(label: "Auth state") {
                    HStack(spacing: 6) {
                        MBDot(state: model.isUpstreamReady ? .live : .warn, size: 8)
                        Text(model.authText)
                            .font(.system(size: 12))
                            .foregroundStyle(MBColor.inkMid)
                            .textSelection(.enabled)
                    }
                }
                if model.requiresAuthAttention {
                    MBField(label: "Next step") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(model.authInstructionText)
                                .font(.system(size: 11))
                                .foregroundStyle(MBColor.inkDim)
                            Button(action: { model.chooseSubscriptionAuthFile() }) {
                                Label(model.authResolutionLabel, systemImage: model.authResolutionSystemImage)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            MBSection(title: "Token status") {
                MBField(label: "Access token") {
                    Text(model.doctorSnapshot?.accessTokenPreview ?? "—")
                        .font(MBFont.mono)
                        .foregroundStyle(MBColor.inkMid)
                        .textSelection(.enabled)
                }
                MBField(label: "Last refresh") {
                    Text(relativeRefreshText(model.doctorSnapshot?.lastRefresh))
                        .font(.system(size: 12))
                        .foregroundStyle(MBColor.inkMid)
                }
                MBField(label: "State") {
                    HStack(spacing: 6) {
                        MBDot(state: tokenDotState, size: 8)
                        Text(tokenStateText)
                            .font(.system(size: 12))
                            .foregroundStyle(MBColor.inkMid)
                    }
                }
                MBField(label: "Refresh") {
                    HStack(spacing: 8) {
                        Button(action: { Task { await model.refreshTokenNow() } }) {
                            Label("Refresh now", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.isRefreshingToken)
                        if model.isRefreshingToken {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                if let error = model.tokenRefreshError {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(MBColor.faultInk)
                        Button(action: { model.chooseSubscriptionAuthFile() }) {
                            Label("Re-authorize auth file", systemImage: "key.horizontal")
                        }
                        .controlSize(.small)
                    }
                }
            }

            HStack(spacing: 8) {
                Button(action: { model.reloadPersistedConfiguration() }) {
                    Label("Reload config", systemImage: "arrow.clockwise.circle")
                }
                Spacer(minLength: 0)
                Button(action: { Task { await model.saveRoutingAndApply() } }) {
                    Label("Save routing + upstream", systemImage: "tray.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .task {
            await model.startTokenStatusPolling()
        }
    }

    private var routeVisualization: some View {
        MBCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Source")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(MBColor.inkDim)
                    Text("Claude Code — POST \(model.currentConfiguration.messagesPath)")
                        .font(MBFont.mono)
                        .foregroundStyle(MBColor.ink)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.down")
                    Text("Routed to")
                }
                .font(.system(size: 11))
                .foregroundStyle(MBColor.inkFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.upstreamDisplayName)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(MBColor.liveInk)
                    Text(model.upstreamHostLabel)
                        .font(MBFont.mono)
                        .foregroundStyle(MBColor.ink)
                    Text("Executor · \(model.currentConfiguration.executorModel)")
                        .font(MBFont.monoSmall)
                        .foregroundStyle(MBColor.inkDim)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(MBColor.liveSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MBColor.live.opacity(0.3), lineWidth: 0.5)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private var tokenDotState: MBDot.State {
        if model.isRefreshingToken { return .warn }
        if model.doctorSnapshot?.hasRefreshToken == true && model.isUpstreamReady { return .live }
        return model.isUpstreamReady ? .warn : .fault
    }

    private var tokenStateText: String {
        if model.isRefreshingToken { return "refreshing…" }
        if model.doctorSnapshot?.hasRefreshToken == true { return "ready" }
        if model.isUpstreamReady { return "requires re-auth" }
        return "auth unavailable"
    }

    private func relativeRefreshText(_ date: Date?) -> String {
        guard let date else { return "never" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

private struct RoutingRuleDraftRow: View {
    @Binding var draft: RoutingRuleDraft
    let index: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        MBCard(padding: 12, cornerRadius: 9, background: MBColor.paperDim) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("RULE \(index + 1)")
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(MBColor.inkDim)
                    MBPill(text: "\(draft.keyword.isEmpty ? "match" : draft.keyword) → \(draft.upstreamModel)", tone: .brand, mono: true)
                    Spacer(minLength: 0)
                    Button(action: onMoveUp) {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canMoveUp ? MBColor.inkMid : MBColor.inkFaint)
                    .disabled(!canMoveUp)
                    .help("Move rule up")
                    .accessibilityLabel("Move routing rule up")
                    Button(action: onMoveDown) {
                        Image(systemName: "arrow.down")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canMoveDown ? MBColor.inkMid : MBColor.inkFaint)
                    .disabled(!canMoveDown)
                    .help("Move rule down")
                    .accessibilityLabel("Move routing rule down")
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MBColor.faultInk)
                    .help("Delete rule")
                    .accessibilityLabel("Delete this routing rule")
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Match keyword")
                        .font(MBFont.captionB)
                        .foregroundStyle(MBColor.inkMid)
                    TextField("opus", text: $draft.keyword)
                        .textFieldStyle(.roundedBorder)
                        .font(MBFont.mono)
                        .frame(maxWidth: 320)
                }

                RouteDraftPickers(draft: Binding(
                    get: {
                        RouteDraft(
                            upstreamModel: draft.upstreamModel,
                            effort: draft.effort,
                            verbosity: draft.verbosity
                        )
                    },
                    set: { route in
                        draft.upstreamModel = route.upstreamModel
                        draft.effort = route.effort
                        draft.verbosity = route.verbosity
                    }
                ))
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct RoutingPolicyEditor: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = model.routingSaveError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(MBColor.faultInk)
            }

            MBCard(padding: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Match rules")
                                .font(MBFont.labelB)
                                .foregroundStyle(MBColor.ink)
                            Text("Rules are checked from top to bottom. The first keyword contained in the Claude model name wins.")
                                .font(.system(size: 11))
                                .foregroundStyle(MBColor.inkDim)
                        }
                        Spacer(minLength: 0)
                        Button(action: { model.addRoutingRule() }) {
                            Label("Add rule", systemImage: "plus")
                        }
                    }

                    if model.routingRulesDraft.isEmpty {
                        VStack(spacing: 6) {
                            Text("No routing rules yet")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(MBColor.inkMid)
                            Text("Default route will handle every Claude request until a match rule is added.")
                                .font(.system(size: 11))
                                .foregroundStyle(MBColor.inkDim)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, minHeight: 110)
                        .padding(.horizontal, 16)
                        .background(MBColor.paperDim)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.routingRulesDraft.indices, id: \.self) { index in
                                RoutingRuleDraftRow(
                                    draft: $model.routingRulesDraft[index],
                                    index: index,
                                    canMoveUp: index > 0,
                                    canMoveDown: index < model.routingRulesDraft.count - 1,
                                    onMoveUp: {
                                        model.moveRoutingRule(from: IndexSet(integer: index), to: index - 1)
                                    },
                                    onMoveDown: {
                                        model.moveRoutingRule(from: IndexSet(integer: index), to: index + 2)
                                    },
                                    onDelete: {
                                        model.removeRoutingRule(id: model.routingRulesDraft[index].id)
                                    }
                                )
                            }
                        }
                    }

                    routeDivider

                    RoutePolicyBlock(
                        title: "Default route",
                        badge: "FALLBACK",
                        help: "Used when no match rule catches the Claude model.",
                        draft: $model.fallbackRouteDraft
                    )

                    routeDivider

                    RoutePolicyBlock(
                        title: "Advisor route",
                        badge: "ADVISOR",
                        help: "Used only for advisor sub-calls.",
                        draft: $model.advisorRouteDraft
                    )
                }
            }
        }
    }

    private var routeDivider: some View {
        Rectangle()
            .fill(MBColor.ruleSoft)
            .frame(height: 0.5)
    }
}

private struct RoutePolicyBlock: View {
    let title: String
    let badge: String
    let help: String
    @Binding var draft: RouteDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(MBFont.labelB)
                    .foregroundStyle(MBColor.ink)
                MBPill(text: badge, tone: .neutral)
                Spacer(minLength: 0)
            }
            Text(help)
                .font(.system(size: 11))
                .foregroundStyle(MBColor.inkDim)
            RouteDraftPickers(draft: $draft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RouteDraftPickers: View {
    @Binding var draft: RouteDraft

    var body: some View {
        HStack(spacing: 8) {
            RoutePickerColumn(title: "Model") {
                Picker("Model", selection: $draft.upstreamModel) {
                    ForEach(RoutingOptions.upstreamModels, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                .labelsHidden()
            }
            .frame(maxWidth: 250)

            RoutePickerColumn(title: "Reasoning") {
                Picker("Reasoning", selection: $draft.effort) {
                    ForEach(RoutingOptions.efforts, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                .labelsHidden()
            }
            .frame(maxWidth: 130)

            RoutePickerColumn(title: "Verbosity") {
                Picker("Verbosity", selection: $draft.verbosity) {
                    ForEach(RoutingOptions.verbosities, id: \.self) { value in
                        Text(value).tag(value)
                    }
                }
                .labelsHidden()
            }
            .frame(maxWidth: 130)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RoutePickerColumn<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(MBFont.captionB)
                .foregroundStyle(MBColor.inkMid)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Diagnostics tab

private struct DiagnosticsSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsShell {
            MBSection(title: "Traffic health") {
                kpiGrid
                    .padding(.top, 6)
            }

            MBSection(title: "Runtime") {
                MBField(label: "Last request") {
                    valueText(model.lastRequestOutcome)
                }
                MBField(label: "Recent stages") {
                    valueText(formatStagePairs(model.traceStageCounts), mono: true)
                }
                MBField(label: "Function calls") {
                    valueText(joinedOrFallback(model.recentFunctionCallNames), mono: true)
                }
                MBField(label: "Connectors") {
                    valueText(joinedOrFallback(model.recentConnectorNames), mono: true)
                }
                MBField(label: "Rejected paths") {
                    valueText(joinedOrFallback(model.recentRejectedPaths), mono: true)
                }
                MBField(label: "Recent errors") {
                    valueText(joinedOrFallback(model.recentErrorReasons))
                }
            }

            MBSection(title: "Trace") {
                MBField(
                    label: "Log file",
                    help: "Claudex appends one JSON object per line as requests flow through.",
                    stacked: true
                ) {
                    HStack(spacing: 6) {
                        MBReadOnlyField(value: model.tracePath)
                        Button(action: { model.openTraceLocation() }) {
                            Label("Reveal", systemImage: "folder")
                        }
                        Button(action: { model.copyDiagnosticsSummary() }) {
                            Label("Copy summary", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                }
                MBField(label: "Recent lines", stacked: true) {
                    recentLogsPanel
                }
            }
        }
    }

    private var kpiGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())],
            spacing: 10
        ) {
            kpiCard(label: "Requests", value: "\(model.recentRequestCount)",
                    detail: "\(model.formattedRequestsPerMinute) / min")
            kpiCard(label: "Success", value: model.recentRequestCount == 0 ? "—" : percentString(model.successRate),
                    detail: "\(model.recentSuccessCount) ok · \(model.recentFailureCount) err",
                    tone: model.recentFailureCount > 0 ? .warn : .live)
            kpiCard(label: "Last latency", value: model.lastLatencyMilliseconds.map { "\($0) ms" } ?? "—",
                    detail: "p50/p95 \(model.latencySummary)")
        }
    }

    private func kpiCard(label: String, value: String, detail: String, tone: MBPill.Tone = .neutral) -> some View {
        MBCard(padding: 12) {
            MBKpi(label: label, value: value, detail: detail, tone: tone)
        }
    }

    private var recentLogsPanel: some View {
        MBTerminalPanel {
            if model.recentTraceLines.isEmpty {
                Text(MBCopy.trafficEmptyLong)
                    .font(MBFont.mono)
                    .foregroundStyle(MBColor.termDim)
            } else {
                ForEach(Array(model.recentTraceLines.enumerated()), id: \.offset) { _, line in
                    let summary = TraceLineFormatter.summary(line)
                    MBTerminalLogLine(
                        timestamp: summary.timestamp,
                        level: summary.level,
                        message: summary.message
                    )
                }
            }
        }
        .frame(minHeight: 180, maxHeight: 320)
    }

    // MARK: Helpers

    private func percentString(_ value: Double) -> String {
        let bounded = max(0, min(1, value))
        return String(format: "%.0f%%", bounded * 100)
    }
}

// MARK: - Value text helper

@ViewBuilder
private func valueText(_ value: String, mono: Bool = false) -> some View {
    Text(value)
        .font(mono ? MBFont.mono : .system(size: 12))
        .foregroundStyle(MBColor.inkMid)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: - Helpers shared across tabs

private func formatStagePairs(_ values: [String: Int]) -> String {
    guard !values.isEmpty else { return "No recent stages" }
    return values.keys.sorted().map { "\($0)=\(values[$0] ?? 0)" }.joined(separator: ", ")
}

private func joinedOrFallback(_ values: [String]) -> String {
    values.isEmpty ? "—" : values.joined(separator: ", ")
}
