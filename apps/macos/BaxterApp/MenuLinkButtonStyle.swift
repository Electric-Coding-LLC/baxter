import SwiftUI

struct MenuLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuLinkButtonBody(configuration: configuration)
    }
}

private struct MenuLinkButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(backgroundColor)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .onHover { hovering in
                isHovered = isEnabled ? hovering : false
            }
            .foregroundStyle(foregroundColor)
            .animation(.easeOut(duration: 0.10), value: isHovered)
    }

    private var isActive: Bool {
        guard isEnabled else { return false }
        return configuration.isPressed || isHovered
    }

    private var backgroundColor: Color {
        isActive ? Color.accentColor : .clear
    }

    private var foregroundColor: Color {
        if !isEnabled {
            return .secondary
        }
        return isActive ? .white : .primary
    }
}
