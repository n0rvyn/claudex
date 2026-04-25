import SwiftUI

// MARK: - Palette

enum MBColor {
    // Surfaces — warm cream paper tones (light) with dark graphite equivalents.
    static let paper      = dynamic(light: rgb(0xFCFAF6), dark: rgb(0x1C1B18))
    static let paperDim   = dynamic(light: rgb(0xF5F2ED), dark: rgb(0x242320))
    static let paperDeep  = dynamic(light: rgb(0xEDEAE4), dark: rgb(0x2B2A26))
    static let paperAlt   = dynamic(light: rgb(0xFEFDFB), dark: rgb(0x212020))

    // Borders / dividers
    static let rule       = dynamic(light: rgb(0xE2DED6), dark: rgb(0x39372F))
    static let ruleSoft   = dynamic(light: rgb(0xEAE6DE), dark: rgb(0x2E2D28))

    // Text
    static let ink        = dynamic(light: rgb(0x2B2821), dark: rgb(0xEFECE3))
    static let inkMid     = dynamic(light: rgb(0x625D52), dark: rgb(0xB6B1A4))
    static let inkDim     = dynamic(light: rgb(0x908C82), dark: rgb(0x8E8A80))
    static let inkFaint   = dynamic(light: rgb(0xBBB7AD), dark: rgb(0x6A665E))

    // Accents — consistent lightness across light/dark where possible.
    static let live       = Color(red: 0.32, green: 0.70, blue: 0.56)   // teal green
    static let liveSoft   = dynamic(light: rgb(0xDFF0E7), dark: rgb(0x1F3A30))
    static let liveInk    = dynamic(light: rgb(0x2E6453), dark: rgb(0x9CD4BC))

    static let warn       = Color(red: 0.87, green: 0.65, blue: 0.32)   // amber
    static let warnSoft   = dynamic(light: rgb(0xF5ECDB), dark: rgb(0x3A301D))
    static let warnInk    = dynamic(light: rgb(0x835B23), dark: rgb(0xE6C691))

    static let fault      = Color(red: 0.83, green: 0.36, blue: 0.30)   // clay red
    static let faultSoft  = dynamic(light: rgb(0xF3E7E4), dark: rgb(0x3B241F))
    static let faultInk   = dynamic(light: rgb(0x823228), dark: rgb(0xE4A297))

    // Brand — slate blue-teal used sparingly (selected tab, links).
    static let brand      = Color(red: 0.20, green: 0.47, blue: 0.68)
    static let brandSoft  = dynamic(light: rgb(0xDFE8F0), dark: rgb(0x1E2E3E))

    // Terminal log surface (shared light/dark — stays dark).
    static let term       = rgb(0x25231E)
    static let termInk    = rgb(0xE0DCD1)
    static let termDim    = rgb(0x84817A)

    private static func rgb(_ hex: UInt32) -> Color {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        return Color(red: r, green: g, blue: b)
    }

    private static func dynamic(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

// MARK: - Typography

enum MBFont {
    static let ui        = Font.system(.body)
    static let caption   = Font.system(size: 11, weight: .medium)
    static let captionB  = Font.system(size: 11, weight: .semibold)
    static let label     = Font.system(size: 13, weight: .medium)
    static let labelB    = Font.system(size: 13, weight: .semibold)
    static let title     = Font.system(size: 14, weight: .semibold)
    static let section   = Font.system(size: 11, weight: .semibold)
    static let kpiNumber = Font.system(size: 20, weight: .semibold, design: .monospaced)
    static let mono      = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 10, design: .monospaced)
}

// MARK: - Dot

struct MBDot: View {
    enum State { case live, warn, fault, idle }

    let state: State
    var size: CGFloat = 8

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(
                Circle()
                    .stroke(state == .live ? MBColor.live.opacity(0.25) : .clear, lineWidth: 2)
                    .scaleEffect(1.6)
            )
    }

    private var color: Color {
        switch state {
        case .live:  return MBColor.live
        case .warn:  return MBColor.warn
        case .fault: return MBColor.fault
        case .idle:  return MBColor.inkFaint
        }
    }
}

// MARK: - Pill

struct MBPill: View {
    enum Tone { case neutral, live, warn, fault, brand }

    let text: String
    var tone: Tone = .neutral
    var mono: Bool = false

    var body: some View {
        Text(text)
            .font(mono ? MBFont.monoSmall : MBFont.caption)
            .foregroundStyle(foreground)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(background))
            .overlay(Capsule().stroke(border, lineWidth: 0.5))
            .fixedSize()
    }

    private var background: Color {
        switch tone {
        case .neutral: return MBColor.paperDim
        case .live:    return MBColor.liveSoft
        case .warn:    return MBColor.warnSoft
        case .fault:   return MBColor.faultSoft
        case .brand:   return MBColor.brandSoft
        }
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return MBColor.inkMid
        case .live:    return MBColor.liveInk
        case .warn:    return MBColor.warnInk
        case .fault:   return MBColor.faultInk
        case .brand:   return MBColor.brand
        }
    }

    private var border: Color {
        switch tone {
        case .neutral: return MBColor.rule
        case .live:    return MBColor.live.opacity(0.35)
        case .warn:    return MBColor.warn.opacity(0.35)
        case .fault:   return MBColor.fault.opacity(0.35)
        case .brand:   return MBColor.brand.opacity(0.35)
        }
    }
}

// MARK: - Card

struct MBCard<Content: View>: View {
    var padding: CGFloat = 14
    var cornerRadius: CGFloat = 10
    var background: Color = MBColor.paperAlt
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(MBColor.rule, lineWidth: 0.5)
            )
    }
}

// MARK: - Banner

struct MBBanner<Actions: View>: View {
    enum Tone { case warn, info, success }

    let tone: Tone
    let title: String
    var message: String? = nil
    @ViewBuilder var actions: Actions

    init(
        tone: Tone,
        title: String,
        message: String? = nil,
        @ViewBuilder actions: () -> Actions = { EmptyView() }
    ) {
        self.tone = tone
        self.title = title
        self.message = message
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(accentForeground)
                .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MBColor.ink)
                if let message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(MBColor.inkMid)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                actions
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(background)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(border, lineWidth: 0.5)
        )
    }

    private var iconName: String {
        switch tone {
        case .warn:    return "exclamationmark.triangle.fill"
        case .info:    return "info.circle.fill"
        case .success: return "checkmark.seal.fill"
        }
    }

    private var background: Color {
        switch tone {
        case .warn:    return MBColor.warnSoft
        case .info:    return MBColor.brandSoft
        case .success: return MBColor.liveSoft
        }
    }

    private var border: Color {
        switch tone {
        case .warn:    return MBColor.warn.opacity(0.35)
        case .info:    return MBColor.brand.opacity(0.35)
        case .success: return MBColor.live.opacity(0.35)
        }
    }

    private var accentForeground: Color {
        switch tone {
        case .warn:    return MBColor.warnInk
        case .info:    return MBColor.brand
        case .success: return MBColor.liveInk
        }
    }
}

// MARK: - Section header

struct MBSectionHeader: View {
    let title: String
    var trailing: AnyView? = nil

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(MBFont.section)
                .tracking(0.6)
                .foregroundStyle(MBColor.inkDim)
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
    }
}

// MARK: - Bridge badge icon

struct MBBridgeBadge: View {
    var size: CGFloat = 30
    var cornerRadius: CGFloat = 8

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [MBColor.live, MBColor.brand.opacity(0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: size * 0.5, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 0.5)
                .blendMode(.overlay)
        )
        .shadow(color: MBColor.brand.opacity(0.25), radius: 3, x: 0, y: 1)
    }
}

// MARK: - KPI cell

struct MBKpi: View {
    let label: String
    let value: String
    var detail: String? = nil
    var tone: MBPill.Tone = .neutral

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(MBColor.inkDim)
            Text(value)
                .font(MBFont.kpiNumber)
                .foregroundStyle(MBColor.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(toneForeground)
                    .lineLimit(1)
            }
        }
    }

    private var toneForeground: Color {
        switch tone {
        case .live:  return MBColor.liveInk
        case .warn:  return MBColor.warnInk
        case .fault: return MBColor.faultInk
        default:     return MBColor.inkDim
        }
    }
}

// MARK: - Field row (label column + control column)

struct MBField<Content: View>: View {
    let label: String
    var help: String? = nil
    var stacked: Bool = false
    var chipText: String? = nil
    var chipTone: MBPill.Tone = .neutral
    @ViewBuilder let content: Content

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 6) {
                labelRow(font: MBFont.labelB)
                content
                if let help {
                    Text(help)
                        .font(.system(size: 11))
                        .foregroundStyle(MBColor.inkDim)
                }
            }
            .padding(.vertical, 8)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    labelRow(font: MBFont.label)
                    if let help {
                        Text(help)
                            .font(.system(size: 11))
                            .foregroundStyle(MBColor.inkDim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 200, alignment: .leading)

                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 10)
            .overlay(
                Rectangle()
                    .fill(MBColor.ruleSoft)
                    .frame(height: 0.5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            )
        }
    }

    @ViewBuilder
    private func labelRow(font: Font) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(font)
                .foregroundStyle(MBColor.ink)
            if let chipText {
                MBPill(text: chipText, tone: chipTone)
            }
        }
    }
}

// MARK: - Section (header + rows)

struct MBSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(MBColor.inkDim)
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .overlay(
                Rectangle()
                    .fill(MBColor.ruleSoft)
                    .frame(height: 0.5)
                    .frame(maxHeight: .infinity, alignment: .top)
            )
        }
        .padding(.bottom, 18)
    }
}

// MARK: - Read-only mono text field (for paths, env snippets)

struct MBReadOnlyField: View {
    let value: String
    var mono: Bool = true
    var truncateMiddle: Bool = false

    var body: some View {
        Group {
            if truncateMiddle {
                Text(value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(value)
            } else {
                Text(value)
            }
        }
        .font(mono ? MBFont.mono : MBFont.ui)
        .foregroundStyle(MBColor.ink)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(MBColor.paperAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(MBColor.rule, lineWidth: 0.5)
        )
    }
}

// MARK: - Terminal log line

struct MBTerminalLogLine: View {
    let timestamp: String?
    let level: String?
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let timestamp {
                Text(timestamp)
                    .font(MBFont.monoSmall)
                    .foregroundStyle(MBColor.termDim)
                    .frame(minWidth: 86, alignment: .leading)
            }
            if let level {
                Text(level.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(levelColor(level))
                    .frame(width: 44, alignment: .leading)
            }
            Text(message)
                .font(MBFont.mono)
                .foregroundStyle(MBColor.termInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level.lowercased() {
        case "debug": return Color(red: 0.58, green: 0.62, blue: 0.74)
        case "info":  return Color(red: 0.52, green: 0.80, blue: 0.68)
        case "warn":  return Color(red: 0.92, green: 0.74, blue: 0.40)
        case "error": return Color(red: 0.90, green: 0.50, blue: 0.45)
        default:      return MBColor.termDim
        }
    }
}

// MARK: - Terminal panel

struct MBTerminalPanel<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                content
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(MBColor.term)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.25), lineWidth: 0.5)
        )
    }
}

// MARK: - Flow line (animated dot moving along rail)

struct MBFlowLine: View {
    let running: Bool
    var color: Color = MBColor.live

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: running
                                ? [color.opacity(0.55), color.opacity(0)]
                                : [MBColor.rule, MBColor.rule],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 1.5)

                if running {
                    TimelineView(.animation(minimumInterval: 1 / 60, paused: false)) { ctx in
                        let t = ctx.date.timeIntervalSinceReferenceDate
                        let phase = CGFloat(t.truncatingRemainder(dividingBy: 2)) / 2
                        Circle()
                            .fill(color)
                            .frame(width: 5, height: 5)
                            .shadow(color: color, radius: 3)
                            .opacity(edgeFadeOpacity(phase))
                            .offset(x: max(0, phase * geo.size.width - 2.5))
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 12)
    }

    private func edgeFadeOpacity(_ phase: CGFloat) -> Double {
        if phase < 0.05 { return Double(phase / 0.05) }
        if phase > 0.95 { return Double((1 - phase) / 0.05) }
        return 1
    }
}

// MARK: - Segmented control

struct MBSeg<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: String
        var id: Value { value }
    }

    @Binding var value: Value
    let options: [Option]
    var dense: Bool = false

    init(value: Binding<Value>, options: [(Value, String)], dense: Bool = false) {
        self._value = value
        self.options = options.map { Option(value: $0.0, label: $0.1) }
        self.dense = dense
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let selected = option.value == value
                Button { value = option.value } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? MBColor.ink : MBColor.inkMid)
                        .padding(.horizontal, dense ? 10 : 12)
                        .padding(.vertical, dense ? 3 : 5)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(selected ? MBColor.paperAlt : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(selected ? MBColor.rule : Color.clear, lineWidth: 0.5)
                        )
                        .shadow(color: selected ? Color.black.opacity(0.06) : .clear, radius: 1, y: 0.5)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(MBColor.paperDeep)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(MBColor.rule, lineWidth: 0.5)
        )
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Shared copy

enum MBCopy {
    static let trafficEmptyLong = "No traffic yet. Start the daemon and run a Claude Code request."
    static let trafficEmptyShort = "No traffic yet"
}

// MARK: - Trace line formatting

enum TraceLineFormatter {
    static func summary(_ line: String) -> TraceSummary {
        guard let dict = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return TraceSummary(timestamp: nil, stage: nil, level: nil, message: line, statusCode: nil)
        }
        let stage = dict["stage"] as? String
        let statusCode = dict["status_code"] as? Int
        let level: String? = {
            if let statusCode, statusCode >= 400 { return "error" }
            switch stage {
            case "anthropic_in", "anthropic_out": return "info"
            case "local_auth_reject":             return "warn"
            case .some: return "debug"
            case .none: return nil
            }
        }()
        let timestamp: String? = {
            guard let ms = dict["logged_at_unix_ms"] as? Double else { return nil }
            return timeFormatter.string(from: Date(timeIntervalSince1970: ms / 1000))
        }()
        var parts: [String] = []
        if let stage { parts.append(stage) }
        if let statusCode { parts.append("\(statusCode)") }
        if let duration = dict["duration_ms"] as? Int { parts.append("\(duration)ms") }
        if let result = dict["result"] as? String { parts.append(result) }
        if let path = dict["path"] as? String { parts.append(path) }
        if let message = dict["error_message"] as? String { parts.append(message) }
        return TraceSummary(
            timestamp: timestamp,
            stage: stage,
            level: level,
            message: parts.isEmpty ? line : parts.joined(separator: " · "),
            statusCode: statusCode
        )
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

struct TraceSummary {
    let timestamp: String?
    let stage: String?
    let level: String?
    let message: String
    let statusCode: Int?

    var toneForStatus: MBDot.State {
        if let statusCode, statusCode >= 400 { return .fault }
        if level == "warn" { return .warn }
        if level == "info" { return .live }
        return .idle
    }
}

// MARK: - Master switch styled toggle

struct MBToggleStyle: ToggleStyle {
    var tint: Color = MBColor.live

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? tint : MBColor.rule)
                    .frame(width: 30, height: 18)
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 1)
                    .frame(width: 14, height: 14)
                    .padding(2)
            }
            .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
            .onTapGesture { configuration.isOn.toggle() }
        }
        .fixedSize()
    }
}
