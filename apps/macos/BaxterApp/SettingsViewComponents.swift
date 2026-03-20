import SwiftUI

enum SettingsLayout {
    static let labelWidth: CGFloat = 120
    static let rowSpacing: CGFloat = 16
    static let contentWidth: CGFloat = 860
}

struct SettingsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
    }
}

struct SettingRow<Content: View>: View {
    let label: String
    let error: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: SettingsLayout.rowSpacing) {
                Text(label)
                    .foregroundStyle(.secondary)
                    .frame(width: SettingsLayout.labelWidth, alignment: .leading)
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.leading, SettingsLayout.labelWidth + SettingsLayout.rowSpacing)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsAlignedContent<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.rowSpacing) {
            Color.clear
                .frame(width: SettingsLayout.labelWidth, height: 1)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsInsetGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }
}

struct SettingsEditorSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.secondary.opacity(0.06))
            )
    }
}

struct SettingsFieldModifier: ViewModifier {
    let width: CGFloat?
    let monospaced: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(width: width, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.secondary.opacity(0.05))
            )
    }
}

extension View {
    func settingsEditorSurface() -> some View {
        modifier(SettingsEditorSurfaceModifier())
    }

    func settingsField(width: CGFloat? = nil, monospaced: Bool = false) -> some View {
        modifier(SettingsFieldModifier(width: width, monospaced: monospaced))
    }
}
