import AppKit
import CcinnPsqlKit
import PostgresKit
import SwiftUI

/// Visual language: one accent ("harbor blue"), adaptive syntax palette, consistent metrics, and a distinct icon +
/// colour for every PostgreSQL object kind.
enum Theme {
    static let accent = Color(nsColor: .appAccent)

    enum Metrics {
        static let cornerRadius: CGFloat = 10
        static let smallCornerRadius: CGFloat = 6
        static let cardPadding: CGFloat = 14
    }

    static let monospaced = Font.system(size: 12, design: .monospaced)
    static let monospacedSmall = Font.system(size: 11, design: .monospaced)

    static func color(for profileColor: ProfileColor) -> Color {
        switch profileColor {
        case .none: .secondary
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .teal: .teal
        case .blue: .blue
        case .indigo: .indigo
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }

    // MARK: Object kinds

    static func icon(for kind: RelationKind) -> String {
        switch kind {
        case .table: "tablecells"
        case .partitionedTable: "square.split.2x2"
        case .view: "eye"
        case .materializedView: "square.stack.3d.up.fill"
        case .foreignTable: "externaldrive.connected.to.line.below"
        case .sequence: "number"
        }
    }

    static func color(for kind: RelationKind) -> Color {
        switch kind {
        case .table: Color(nsColor: .kindTable)
        case .partitionedTable: Color(nsColor: .kindPartitioned)
        case .view: Color(nsColor: .kindView)
        case .materializedView: Color(nsColor: .kindMaterialized)
        case .foreignTable: Color(nsColor: .kindForeign)
        case .sequence: Color(nsColor: .kindSequence)
        }
    }

    static func icon(for kind: RoutineKind) -> String {
        switch kind {
        case .function: "function"
        case .procedure: "gearshape.2"
        case .aggregate: "sum"
        case .window: "rectangle.split.3x1"
        }
    }

    static func icon(for kind: TypeKind) -> String {
        switch kind {
        case .enumeration: "list.bullet"
        case .composite: "square.grid.3x1.below.line.grid.1x2"
        case .domain: "checkmark.seal"
        case .range, .multirange: "arrow.left.and.right"
        case .base: "cube"
        }
    }

    static let routineColor = Color(nsColor: .kindRoutine)
    static let typeColor = Color(nsColor: .kindType)

    /// Colour for activity states.
    static func color(forState state: String?) -> Color {
        switch state ?? "" {
        case "active": .green
        case "idle": .secondary
        case "idle in transaction", "idle in transaction (aborted)": .orange
        case "fastpath function call": .blue
        case "disabled": .gray
        default: .secondary
        }
    }

    static func color(forWait type: String?) -> Color {
        switch type ?? "" {
        case "Lock": .red
        case "LWLock": .orange
        case "IO": .blue
        case "IPC", "Timeout": .purple
        case "Client", "Activity": .secondary
        default: .secondary
        }
    }
}

extension NSColor {
    static func adaptive(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        }
    }

    static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    static let appAccent = adaptive(light: .hex(0x1F6FB2), dark: .hex(0x5DADEC))

    static let kindTable = adaptive(light: .hex(0x2563EB), dark: .hex(0x60A5FA))
    static let kindPartitioned = adaptive(light: .hex(0x0E7490), dark: .hex(0x67E8F9))
    static let kindMaterialized = adaptive(light: .hex(0x9333EA), dark: .hex(0xC084FC))
    static let kindView = adaptive(light: .hex(0xD97706), dark: .hex(0xFBBF24))
    static let kindForeign = adaptive(light: .hex(0x64748B), dark: .hex(0x94A3B8))
    static let kindSequence = adaptive(light: .hex(0x0F766E), dark: .hex(0x5EEAD4))
    static let kindRoutine = adaptive(light: .hex(0xBE185D), dark: .hex(0xF9A8D4))
    static let kindType = adaptive(light: .hex(0x4D7C0F), dark: .hex(0xBEF264))

    static let syntaxKeyword = adaptive(light: .hex(0x7C3AED), dark: .hex(0xC4A1FF))
    static let syntaxFunction = adaptive(light: .hex(0x0369A1), dark: .hex(0x7DD3FC))
    static let syntaxString = adaptive(light: .hex(0x15803D), dark: .hex(0x86EFAC))
    static let syntaxNumber = adaptive(light: .hex(0xC2410C), dark: .hex(0xFDBA74))
    static let syntaxComment = adaptive(light: .hex(0x8A8F98), dark: .hex(0x6B7280))
    static let syntaxQuoted = adaptive(light: .hex(0xA16207), dark: .hex(0xFDE68A))
    static let syntaxVariable = adaptive(light: .hex(0xBE185D), dark: .hex(0xF9A8D4))
    static let currentStatement = adaptive(light: NSColor.hex(0x1F6FB2).withAlphaComponent(0.05),
                                           dark: NSColor.hex(0x5DADEC).withAlphaComponent(0.08))
    static let nullValue = NSColor.tertiaryLabelColor
}

enum Format {
    /// Trap-free Double → Int64 (NaN/±inf/out-of-range values are clamped).
    static func int64(_ value: Double) -> Int64 {
        guard value.isFinite else { return 0 }
        if value >= 9.223_372_036_854_775e18 { return .max }
        if value <= -9.223_372_036_854_775e18 { return .min }
        return Int64(value)
    }

    static func bytes(_ value: Int64?) -> String {
        guard let value else { return "—" }
        guard value > 0 else { return "0 B" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .binary)
    }

    static func count(_ value: Int64?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number)
    }

    static func count(_ value: Int) -> String { value.formatted(.number) }

    static func duration(milliseconds: Double) -> String {
        guard milliseconds.isFinite else { return "—" }
        if milliseconds < 1 { return "<1 ms" }
        if milliseconds < 1000 { return "\(Int(milliseconds.rounded())) ms" }
        if milliseconds < 60_000 { return String(format: "%.2f s", milliseconds / 1000) }
        let seconds = int64(milliseconds / 1000)
        if seconds >= 86_400 { return "\(seconds / 86_400)d \(seconds % 86_400 / 3600)h" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    static func duration(seconds: Double?) -> String {
        guard let seconds else { return "—" }
        return duration(milliseconds: seconds * 1000)
    }

    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", value)
    }
}

/// Small rounded label used for versions, models and states.
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
        .overlay(Capsule().strokeBorder(color.opacity(0.25), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Icon for a relation, with markers for hypertables and Citus tables.
struct RelationIcon: View {
    let relation: RelationSummary

    var body: some View {
        Image(systemName: Theme.icon(for: relation.kind))
            .foregroundStyle(Theme.color(for: relation.kind))
            .frame(width: 18)
            .overlay(alignment: .bottomTrailing) {
                if relation.isHypertable || relation.citusPlacement != nil {
                    Circle()
                        .fill(relation.isHypertable ? Color.orange : Color.teal)
                        .frame(width: 6, height: 6)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1))
                        .offset(x: 2, y: 2)
                }
            }
    }
}

/// Inline error presentation with a copy affordance.
struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Pasteboard.copy(message)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy error")
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss")
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius).strokeBorder(Color.red.opacity(0.25)))
    }
}

/// Informational (non-error) notice, e.g. missing privileges.
struct NoticeBanner: View {
    let message: String
    var systemImage = "info.circle"
    var color: Color = .secondary

    var body: some View {
        Label {
            Text(message).font(.callout).textSelection(.enabled)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.Metrics.smallCornerRadius))
    }
}

/// Card container used across the app.
struct Card<Content: View>: View {
    var title: String?
    var systemImage: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Label(title, systemImage: systemImage ?? "square")
                    .labelStyle(TitleOnlyIfNoIcon(hasIcon: systemImage != nil))
                    .font(.headline)
            }
            content
        }
        .padding(Theme.Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.04), radius: 2, y: 1)
    }
}

private struct TitleOnlyIfNoIcon: LabelStyle {
    let hasIcon: Bool

    func makeBody(configuration: Configuration) -> some View {
        if hasIcon {
            HStack(spacing: 6) {
                configuration.icon.foregroundStyle(Theme.accent)
                configuration.title
            }
        } else {
            configuration.title
        }
    }
}

/// Big number with a caption, used in summary rows.
struct StatTile: View {
    let title: String
    let value: String
    var systemImage: String?
    var tint: Color = Theme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(tint) }
                Text(title).foregroundStyle(.secondary)
            }
            .font(.caption)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Theme.Metrics.cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
    }
}

/// Two-column key/value list.
struct KeyValueList: View {
    let items: [(String, String)]
    var monospacedValues = false

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                GridRow {
                    Text(item.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Text(item.1)
                        .font(monospacedValues ? Theme.monospacedSmall : .body)
                        .textSelection(.enabled)
                        .lineLimit(3)
                }
            }
        }
        .font(.callout)
    }
}

enum Pasteboard {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// The app mark, drawn in SwiftUI so it matches the generated app icon: a stack of database disks on a harbor-blue tile.
struct AppLogo: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.55, blue: 0.86), Color(red: 0.06, green: 0.22, blue: 0.45)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            VStack(spacing: size * 0.035) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(index == 0 ? 0.95 : 0.75))
                        .frame(width: size * 0.52, height: size * 0.13)
                }
            }
            .offset(y: -size * 0.02)
            Image(systemName: "chevron.right")
                .font(.system(size: size * 0.16, weight: .heavy))
                .foregroundStyle(Color(red: 0.06, green: 0.22, blue: 0.45))
                .offset(x: -size * 0.14, y: -size * 0.155)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.15), radius: size * 0.08, y: size * 0.04)
    }
}
