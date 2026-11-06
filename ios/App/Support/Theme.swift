import SwiftUI

/// Design tokens. Components use these, never raw values.
enum Theme {
    enum Colors {
        static let background = Color(red: 0.04, green: 0.04, blue: 0.06)
        static let surface = Color(red: 0.11, green: 0.11, blue: 0.14)
        static let surfaceRaised = Color(red: 0.16, green: 0.16, blue: 0.20)
        static let textPrimary = Color.white
        static let textSecondary = Color(white: 0.68)
        static let accent = Color(red: 0.96, green: 0.71, blue: 0.27)
        static let progressTrack = Color.white.opacity(0.25)
        static let danger = Color(red: 0.94, green: 0.36, blue: 0.36)
        static let scrim = Color.black.opacity(0.55)
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 10
        static let button: CGFloat = 12
    }

    enum Size {
        static let landscapeCardWidth: CGFloat = 260
        static let posterWidth: CGFloat = 118
        static let gridPosterMin: CGFloat = 104
        static let heroHeight: CGFloat = 440
        static let castPhoto: CGFloat = 72
        static let progressHeight: CGFloat = 4
        static let playerButton: CGFloat = 44
        static let playerMainButton: CGFloat = 64
        static let fieldMaxWidth: CGFloat = 420
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Theme.Space.m)
            .background(Theme.Colors.accent.opacity(configuration.isPressed ? 0.7 : 1))
            .foregroundStyle(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
    }
}

struct FieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.Space.m)
            .background(Theme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.button))
            .foregroundStyle(Theme.Colors.textPrimary)
    }
}

extension View {
    func fieldStyle() -> some View { modifier(FieldStyle()) }
}
