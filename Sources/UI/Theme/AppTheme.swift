import SwiftUI

public enum AppTheme {
    public static let accent = Color.teal
    public static let accentSecondary = Color.cyan

    public static let backgroundPrimary = Color(NSColor.controlBackgroundColor)
    public static let backgroundSecondary = Color(NSColor.secondarySystemFill).opacity(0.5)

    public static let textPrimary = Color.primary
    public static let textSecondary = Color.secondary

    public static let success = Color.green
    public static let danger = Color.red

    public static let cornerRadiusSmall: CGFloat = 8
    public static let cornerRadiusMedium: CGFloat = 12
}

public struct AccentButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                LinearGradient(
                    colors: [AppTheme.accent, AppTheme.accentSecondary],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .opacity(configuration.isPressed ? 0.8 : 1.0)
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}
