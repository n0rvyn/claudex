import AppKit
import CCRouterCore
import ServiceManagement
import SwiftUI

// MARK: - Settings window (native tabs)

struct DoctorSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var selection: SettingsTab = .upstream
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Claudex", systemImage: "terminal.fill").font(MBFont.title).padding(.bottom, 20)
                    navigation("Account & model", icon: "person.crop.circle", tab: .upstream)
                    navigation("Claude Code", icon: "terminal", tab: .claudeCode)
                    navigation("Gateway", icon: "network", tab: .gateway)
                    navigation("Activity", icon: "waveform.path", tab: .diagnostics)
                    navigation("General", icon: "gearshape", tab: .general)
                    Spacer()
                }
                .padding(14).frame(width: 178).frame(maxHeight: .infinity).background(MBColor.paperDim)
                Divider()
                Group {
                    switch selection {
                    case .general: GeneralSettingsTab(model: model)
                    case .gateway: GatewaySettingsTab(model: model)
                    case .claudeCode: ClaudeCodeSettingsTab(model: model)
                    case .upstream: UpstreamSettingsTab(model: model)
                    case .diagnostics: DiagnosticsSettingsTab(model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            SettingsFooter(model: model)
        }.font(MBFont.label).tint(MBColor.brand).accentColor(MBColor.brand).background(MBColor.paper).tint(MBColor.brand)
        .background(SettingsWindowSizing())
        .disclosureGroupStyle(WholeRowDisclosureStyle())
        .onAppear {
            #if DEBUG
            switch ProcessInfo.processInfo.environment["CLAUDEX_UI_PANE"] {
            case "general": selection = .general
            case "gateway": selection = .gateway
            case "claudeCode": selection = .claudeCode
            case "diagnostics": selection = .diagnostics
            default: break
            }
            #endif
        }
    }
    private func navigation(_ title: String, icon: String, tab: SettingsTab) -> some View {
        Button { selection = tab } label: {
            Label(title, systemImage: icon).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 9).padding(.vertical, 8)
                .foregroundStyle(selection == tab ? MBColor.ink : MBColor.inkDim)
                .background(selection == tab ? MBColor.brandSoft : .clear, in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityLabel(title)
    }
}

// MARK: - Settings footer

private struct SettingsFooter: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 8) {
            MBDot(state: model.headerDotState, size: 6)
            Text(statusLine)
                .font(.system(size: 12))
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
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(MBColor.paper)
    }
}

// MARK: - General tab

private struct GeneralSettingsTab: View {
    @ObservedObject var model: AppModel
    @AppStorage("claudex.appearance") private var appearanceRaw: Int = 0

    var body: some View {
        SettingsShell {
            Text("General").font(MBFont.title).padding(.bottom, 20)
            MBSection(title: "Appearance") {
                MBField(
                    label: "Theme",
                    help: "Use system appearance or choose a theme."
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
                    help: "Open Claudex when you sign in."
                ) {
                    Toggle("", isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { _ in model.toggleLaunchAtLogin() }
                    ))
                    .toggleStyle(.switch)
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
                message: "Install Claudex in Applications to enable launch at login."
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
                    .font(.system(size: 12))
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
            Text("Gateway").font(MBFont.title).padding(.bottom, 20)
            HStack {
                Label(model.daemonIsRunning ? "Gateway running" : "Gateway paused", systemImage: model.daemonIsRunning ? "circle.fill" : "pause.circle")
                    .foregroundStyle(MBColor.inkDim)
                Spacer()
                Button(model.daemonIsRunning ? "Pause" : "Start") { model.toggleDaemon() }
                    .buttonStyle(.borderedProminent).disabled(!model.daemonIsRunning && !model.canStartDaemon)
            }.padding(.bottom, 20)
            MBSection(title: "Local listener") {
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
        "••••••••••••••••"
    }
}

// MARK: - Claude Code tab

private struct ClaudeCodeSettingsTab: View {
    @ObservedObject var model: AppModel

    var body: some View {
        SettingsShell {
            Text("Connect Claude Code").font(MBFont.title).padding(.bottom, 6)
            Text("Copy the exports into your terminal, then launch Claude Code.").foregroundStyle(MBColor.inkDim).padding(.bottom, 20)
            MBSection(title: "Connection exports") {
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

            DisclosureGroup("Optional connection check") {
                MBField(
                    label: "Optional manual check",
                    help: "Running this command consumes plan usage. Full Claude Code sessions have not yet been validated.",
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
                Text("export ").foregroundStyle(MBColor.termDim)
                + Text("ANTHROPIC_BASE_URL").foregroundStyle(MBColor.termInk)
                + Text("=").foregroundStyle(MBColor.termDim)
                + Text(model.endpoint).foregroundStyle(MBColor.termInk)
            }
            HStack(spacing: 8) {
                Text("$").foregroundStyle(MBColor.live)
                Text("export ").foregroundStyle(MBColor.termDim)
                + Text("ANTHROPIC_AUTH_TOKEN").foregroundStyle(MBColor.termInk)
                + Text("=").foregroundStyle(MBColor.termDim)
                + Text("<gateway-token>").foregroundStyle(MBColor.termInk)
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
    @State private var optionsExpanded = false
    private var draftError: String? {
        let route = ModelRoute(upstreamModel: model.fallbackRouteDraft.upstreamModel, reasoningEffort: model.fallbackRouteDraft.effort, textVerbosity: model.fallbackRouteDraft.verbosity)
        if !model.useAdvancedRouting, model.modelCatalogUsable {
            guard let selected = model.availableChatGPTModels.first(where: { $0.id == route.upstreamModel }) else {
                return "Saved model \(route.upstreamModel) is unavailable. Choose an account model; saved settings stay intact until you apply changes."
            }
            if !selected.scalarReasoningEfforts.contains(route.reasoningEffort) {
                return "Saved effort \(route.reasoningEffort.isEmpty ? "(none)" : route.reasoningEffort) is unavailable. Choose a supported reasoning effort."
            }
        }
        return model.routingCatalogError((model.useAdvancedRouting ? model.routingRulesDraft.map { ModelRoute(upstreamModel: $0.upstreamModel, reasoningEffort: $0.effort, textVerbosity: $0.verbosity) } : []) + [route])
    }
    var body: some View {
        ScrollViewReader { proxy in
        SettingsShell {
            Text("Account & model").font(MBFont.title).padding(.bottom, 6)
            Text("Connect ChatGPT, map Claude models, then start the gateway.")
                .foregroundStyle(MBColor.inkDim).padding(.bottom, 22)
            MBSection(title: "1. Connect ChatGPT") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.chatGPTAccounts) { account in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "person.crop.circle").foregroundStyle(MBColor.inkDim)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(account.label).textSelection(.enabled)
                                Text(account.active && account.authorized ? "Connected · selected account" : account.authorized ? "Connected" : "Authorization needed")
                                    .font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            if !account.active && account.authorized { Button("Use") { model.selectChatGPTAccount(account.id) } }
                            if account.authorized { Button("Sign out") { model.signOutChatGPT(account.id) } }
                        }
                    }
                    if model.isSigningIn {
                        HStack { ProgressView().controlSize(.small); Text("Finish connecting in your browser"); Button("Cancel") { model.cancelChatGPTSignIn() } }
                        Text("You can cancel and try again without changing your routing.").font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                    } else {
                        Button(model.chatGPTAccounts.contains(where: { $0.authorized }) ? "Connect another account" : "Connect ChatGPT") { model.beginChatGPTSignIn() }
                            .buttonStyle(.bordered)
                    }
                    if let error = model.signInError { Text(error).foregroundStyle(MBColor.faultInk).textSelection(.enabled) }
                }.padding(.vertical, 12)
            }
            MBSection(title: "2. Model mapping") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top) {
                        if model.isLoadingModelCatalog { ProgressView().controlSize(.small) }
                        Text(model.modelCatalogStatus).font(MBFont.caption).foregroundStyle(MBColor.inkDim).frame(maxWidth: .infinity, alignment: .leading)
                        Button("Refresh") { Task { await model.loadChatGPTModelCatalog() } }
                            .disabled(model.isLoadingModelCatalog || !model.chatGPTAccounts.contains(where: { $0.active && $0.authorized }))
                    }
                    Toggle("Use the same model for all", isOn: Binding(
                        get: { !model.useAdvancedRouting },
                        set: { same in
                            model.useAdvancedRouting = !same
                            if !same { model.prepareClaudeModelRows() }
                        }
                    ))
                    Toggle("Allow Claude to adjust", isOn: $model.allowClaudeAdjustment)
                    Text(model.allowClaudeAdjustment ? "Chosen effort is the default and maximum. Claude may request a lower supported effort. Thinking budgets cannot be translated." : "Chosen model and effort are fixed. Claude’s effort and thinking settings are overridden.")
                        .font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                    MappingColumnHeader(adjustable: model.allowClaudeAdjustment)
                    if !model.useAdvancedRouting {
                        MappingRouteRow(title: "All roles", draft: $model.fallbackRouteDraft, onFocus: { proxy.scrollTo("fallback", anchor: .center) }).environmentObject(model).id("fallback")
                    } else {
                        ForEach(["opus", "sonnet", "haiku"], id: \.self) { keyword in
                            ClaudeModelRouteRow(model: model, keyword: keyword, onFocus: { proxy.scrollTo(keyword, anchor: .center) }).id(keyword)
                        }
                        Divider().padding(.vertical, 4)
                        MappingRouteRow(title: "Other", draft: $model.fallbackRouteDraft, onFocus: { proxy.scrollTo("fallback", anchor: .center) }).environmentObject(model).id("fallback")
                        Text("Fallback for Claude model names that have no matching rule.").font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                    }
                    if model.modelCatalogUsable, model.routingSaveError == nil, let error = draftError { Text(error).font(MBFont.caption).foregroundStyle(MBColor.faultInk).textSelection(.enabled) }
                    Text(model.mappingSaveStatus).font(MBFont.caption).foregroundStyle(model.routingSaveError == nil ? MBColor.inkDim : MBColor.faultInk)
                    if let error = model.routingSaveError {
                        Text(error).font(MBFont.caption).foregroundStyle(MBColor.faultInk).textSelection(.enabled)
                        HStack {
                            Button("Retry saving") { model.scheduleMappingSave() }
                            Button("Restore saved mapping") { model.reloadPersistedConfiguration() }
                        }
                    }
                }.padding(.vertical, 12)
            }
            if model.statusText.hasPrefix("Failed") { Text(model.statusText).foregroundStyle(MBColor.faultInk).padding(.bottom, 12) }
            if model.showConnectionInstructions && model.daemonIsRunning {
                Text("Paste the connection exports into your terminal, then launch Claude Code. Requests use your ChatGPT plan.").font(MBFont.caption)
                HStack { Button("Copy connection exports") { model.copyEnvSnippet() }; Button("Done") { model.showConnectionInstructions = false } }.padding(.vertical, 10)
            }
            SelectedModelHints(model: model)
            DisclosureGroup("Advanced routing") {
                Text("Custom source names and ordered matching rules. Existing mappings are preserved.").font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                RoutingPolicyEditor(model: model).environmentObject(model)
            }.padding(.top, 14)
            DisclosureGroup("Answer detail", isExpanded: $optionsExpanded) {
                Text(model.useAdvancedRouting ? "Applies only to the Other fallback. Role mappings retain their own saved answer detail." : "Applies to all roles using the shared model.")
                    .font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                Text("Controls response length and detail, separately from reasoning effort.").font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                Picker("Answer detail", selection: $model.fallbackRouteDraft.verbosity) {
                    ForEach(RoutingOptions.verbosities, id: \.self) { Text($0).tag($0) }
                }.padding(.top, 6)
            }.padding(.top, 8)
        }
        .onAppear { model.enableMappingAutosave() }
        .task { await model.loadChatGPTAccounts(); await model.startTokenStatusPolling() }
        }
    }
}

private struct ClaudeModelRouteRow: View {
    @ObservedObject var model: AppModel
    let keyword: String
    var onFocus: () -> Void = {}
    private var route: Binding<RouteDraft> {
        Binding(get: {
            guard let row = model.routingRulesDraft.first(where: { $0.keyword.lowercased() == keyword }) else { return model.fallbackRouteDraft }
            return RouteDraft(upstreamModel: row.upstreamModel, effort: row.effort, verbosity: row.verbosity)
        }, set: { value in
            model.prepareClaudeModelRows()
            guard let index = model.routingRulesDraft.firstIndex(where: { $0.keyword.lowercased() == keyword }) else { return }
            model.routingRulesDraft[index].upstreamModel = value.upstreamModel
            model.routingRulesDraft[index].effort = value.effort
            model.routingRulesDraft[index].verbosity = value.verbosity
        })
    }
    var body: some View {
        MappingRouteRow(title: keyword.capitalized, draft: route, onFocus: onFocus).environmentObject(model)
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
                        .font(.system(size: 12, weight: .semibold))
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
                                .font(.system(size: 12))
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
                                .font(.system(size: 12))
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
                .font(.system(size: 12))
                .foregroundStyle(MBColor.inkDim)
            RouteDraftPickers(draft: $draft)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RouteDraftPickers: View {
    @Binding var draft: RouteDraft
    var showVerbosity = true
    var onFocus: () -> Void = {}
    private enum Field: Hashable { case model, effort, verbosity }
    @FocusState private var focusedField: Field?
    @EnvironmentObject private var model: AppModel
    private var selected: SIWCModelSummary? { model.availableChatGPTModels.first { $0.id == draft.upstreamModel } }
    private var efforts: [String] { selected?.scalarReasoningEfforts ?? [] }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                RoutePickerColumn(title: "Model") {
                    Picker("Model", selection: $draft.upstreamModel) {
                        if selected == nil { Text("Unavailable: " + draft.upstreamModel).tag(draft.upstreamModel).disabled(true) }
                        ForEach(model.availableChatGPTModels) { item in Text(item.label).tag(item.id) }
                    }
                    .labelsHidden().focused($focusedField, equals: .model)
                    .disabled(!model.modelCatalogUsable)
                    .onChange(of: draft.upstreamModel) { _, _ in
                        if !efforts.contains(draft.effort) { draft.effort = "" }
                    }
                }.frame(maxWidth: 350)
                RoutePickerColumn(title: model.allowClaudeAdjustment ? "Default / maximum" : "Fixed effort") {
                    Picker(model.allowClaudeAdjustment ? "Default / maximum effort" : "Fixed effort", selection: $draft.effort) {
                        if !efforts.contains(draft.effort) { Text(draft.effort.isEmpty ? "Choose effort" : "Unavailable").tag(draft.effort).disabled(true) }
                        ForEach(efforts, id: \.self) { value in Text(value).tag(value) }
                    }.labelsHidden().focused($focusedField, equals: .effort).disabled(!model.modelCatalogUsable || efforts.isEmpty)
                }.frame(maxWidth: 150)
                if showVerbosity { RoutePickerColumn(title: "Response detail") {
                    Picker("Verbosity", selection: $draft.verbosity) {
                        ForEach(RoutingOptions.verbosities, id: \.self) { value in Text(value).tag(value) }
                    }.labelsHidden().focused($focusedField, equals: .verbosity)
                }.frame(maxWidth: 130) }
            }
            if let selected {
                if showVerbosity { Text(selected.capabilitySummary).font(MBFont.caption).foregroundStyle(MBColor.inkDim) }
                if efforts.isEmpty && showVerbosity { Text("Reasoning metadata unavailable; refresh before saving.").font(MBFont.caption).foregroundStyle(MBColor.faultInk) }
            } else if showVerbosity { Text("Choose an available account model; the saved value has not been replaced automatically.").font(MBFont.caption).foregroundStyle(MBColor.faultInk) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: focusedField) { _, field in if field != nil { onFocus() } }
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
            Text("Activity").font(MBFont.title).padding(.bottom, 20)
            MBSection(title: "Recent traffic") {
                kpiGrid
                    .padding(.top, 6)
            }

            MBSection(title: "Last request") {
                valueText(model.lastRequestOutcome).padding(.vertical, 12)
                if !model.recentErrorReasons.isEmpty { valueText(joinedOrFallback(model.recentErrorReasons)) }
            }
            DisclosureGroup {
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
            } label: {
                Text("Request details").font(.system(size: 14, weight: .semibold)).foregroundStyle(MBColor.ink)
            }.padding(.vertical, 8)

            DisclosureGroup {
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
            } label: {
                Text("Trace log").font(.system(size: 14, weight: .semibold)).foregroundStyle(MBColor.ink)
            }.padding(.vertical, 8)
            DisclosureGroup("Model catalog diagnostics") {
                Text("Raw account model metadata for troubleshooting. Changing these disclosures does not change routing.").font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                Text(model.modelCatalogStatus).font(MBFont.caption).foregroundStyle(MBColor.inkDim)
                ForEach(model.availableChatGPTModels) { item in
                    DisclosureGroup(item.label + " · Raw metadata") {
                        Text(item.detailsText).font(MBFont.mono).textSelection(.enabled)
                    }
                }
            }.padding(.vertical, 8)

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

/// SwiftUI Settings windows otherwise inherit a fixed content fitting size on macOS 15.
private struct SettingsWindowSizing: NSViewRepresentable {
    final class WindowView: NSView {
        #if DEBUG
        private var fixtureSizeApplied = false
        #endif
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(configureWindow), name: NSWindow.didBecomeKeyNotification, object: window)
            }
            DispatchQueue.main.async { [weak self] in self?.configureWindow() }
        }
        @objc private func configureWindow() {
            guard let window else { return }
            window.styleMask.insert(.resizable)
            window.contentMinSize = NSSize(width: 680, height: 520)
            // Settings scenes may retain an initial content-sized maximum after attachment.
            window.contentMaxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if !fixtureSizeApplied, environment["CLAUDEX_UI_FIXTURE"] != nil,
               let raw = environment["CLAUDEX_UI_WINDOW_SIZE"] {
                let parts = raw.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2, parts[0].isFinite, parts[1].isFinite, parts[0] >= 680, parts[1] >= 520 {
                    fixtureSizeApplied = true
                    window.setContentSize(NSSize(width: parts[0], height: parts[1]))
                    let evidence = "Offline fixture resize: " + String(describing: window.frame) + "; resizable=" + String(window.styleMask.contains(.resizable)) + "\n"
                    try? FileHandle.standardError.write(contentsOf: Data(evidence.utf8))
                }
            }
            #endif
        }
    }
    func makeNSView(context: Context) -> WindowView { WindowView() }
    func updateNSView(_ nsView: WindowView, context: Context) {}
}

private struct MappingColumnHeader: View {
    let adjustable: Bool
    var body: some View {
        HStack(spacing: 10) {
            Text("Claude Code").frame(width: 76, alignment: .leading)
            Color.clear.frame(width: 12, height: 1)
            Text("OpenAI model").frame(maxWidth: .infinity, alignment: .leading)
            Text(adjustable ? "Effort limit" : "Fixed effort").frame(width: 100, alignment: .leading)
        }.font(MBFont.captionB).foregroundStyle(MBColor.inkDim).padding(.top, 10)
    }
}

private struct MappingRouteRow: View {
    let title: String
    @Binding var draft: RouteDraft
    var onFocus: () -> Void = {}
    @EnvironmentObject private var model: AppModel
    private enum Field: Hashable { case model, effort }
    @FocusState private var focus: Field?
    private var selected: SIWCModelSummary? { model.availableChatGPTModels.first { $0.id == draft.upstreamModel } }
    private var efforts: [String] { selected?.scalarReasoningEfforts ?? [] }
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).frame(width: 76, alignment: .leading)
            Image(systemName: "arrow.right").font(.system(size: 11)).foregroundStyle(MBColor.inkFaint).frame(width: 12).accessibilityHidden(true)
            Picker(title + " OpenAI model", selection: $draft.upstreamModel) {
                if selected == nil { Text("Unavailable: " + draft.upstreamModel).tag(draft.upstreamModel).disabled(true) }
                ForEach(model.availableChatGPTModels) { item in Text(item.label).tag(item.id) }
            }.labelsHidden().frame(maxWidth: .infinity).focused($focus, equals: .model).disabled(!model.modelCatalogUsable)
                .onChange(of: draft.upstreamModel) { _, _ in if !efforts.contains(draft.effort) { draft.effort = "" } }
            Picker(title + (model.allowClaudeAdjustment ? " effort limit" : " fixed effort"), selection: $draft.effort) {
                if !efforts.contains(draft.effort) { Text(draft.effort.isEmpty ? "Choose" : "Unavailable").tag(draft.effort).disabled(true) }
                ForEach(efforts, id: \.self) { Text($0).tag($0) }
            }.labelsHidden().frame(width: 100).focused($focus, equals: .effort).disabled(!model.modelCatalogUsable || efforts.isEmpty)
        }.padding(.vertical, 4).onChange(of: focus) { _, value in if value != nil { onFocus() } }
    }
}

private struct SelectedModelHints: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let ids = Set((model.useAdvancedRouting ? model.routingRulesDraft.map(\.upstreamModel) : []) + [model.fallbackRouteDraft.upstreamModel])
        VStack(alignment: .leading, spacing: 7) {
            ForEach(model.availableChatGPTModels.filter { ids.contains($0.id) }) { item in
                Text(item.label + " · supported effort: " + item.scalarReasoningEfforts.joined(separator: ", "))
                Text(item.capabilitySummary).foregroundStyle(MBColor.inkDim)
            }
            Text("Source: selected account’s model catalog. " + model.modelCatalogStatus).foregroundStyle(MBColor.inkDim)
        }.font(MBFont.caption).padding(.vertical, 10)
    }
}

/// Only the header is a button; independent controls inside the content remain independent.
private struct WholeRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        WholeRowDisclosure(configuration: configuration)
    }
}

private struct WholeRowDisclosure: View {
    let configuration: DisclosureGroupStyleConfiguration
    @FocusState private var focused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { configuration.isExpanded.toggle() } label: {
                HStack(spacing: 9) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 12, weight: .semibold)).frame(width: 14).accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9).padding(.horizontal, 5)
                    .contentShape(Rectangle())
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? MBColor.brand : .clear, lineWidth: 2))
            }.buttonStyle(.plain).focused($focused)
                .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
                .onKeyPress(.return) { configuration.isExpanded.toggle(); return .handled }
                .onKeyPress(.space) { configuration.isExpanded.toggle(); return .handled }
            if configuration.isExpanded { configuration.content.disclosureGroupStyle(WholeRowDisclosureStyle()) }
        }
    }
}
