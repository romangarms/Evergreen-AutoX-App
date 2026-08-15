import SwiftUI

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }

    static let egBg = Color(light: 0xF3F2F2, dark: 0x171514)
    static let egInk = Color(light: 0x201E1D, dark: 0xEDEBEA)
    static let egRed = Color(light: 0xEC3013, dark: 0xFF4A2C)
    static let egDarkRed = Color(light: 0xAE1800, dark: 0xE0523C)
    static let egGray = Color(light: 0x7D7979, dark: 0x969191)
    static let egGrayDark = Color(light: 0x605D5D, dark: 0xB0ACAB)
    static let egGrayLight = Color(light: 0xBAB6B6, dark: 0x555151)
    static let egHairline = Color(light: 0xD7D3D3, dark: 0x383534)
    static let egPinnedBg = Color(light: 0xFFF2EF, dark: 0x2B1D19)
    static let egMeBg = Color(light: 0xEAE7E7, dark: 0x282625)
    static let egCard = Color(light: 0xF8F4F4, dark: 0x201E1D)
    static let egTabBg = Color(light: 0xEAE9E9, dark: 0x232121)

    // Deliberately non-adaptive: sits on egRed, which stays red in both modes.
    static let egOnRed = Color(hex: 0xF8F5F4)

    static let egDivider = Color.egInk.opacity(0.4)
}

struct EGTag: View {
    let text: String
    var background = Color.egRed
    var foreground = Color.egOnRed
    var size: CGFloat = 11

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .heavy))
            .kerning(1.1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background)
    }
}

struct EGOutlineTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .heavy))
            .kerning(0.8)
            .foregroundStyle(Color.egInk)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .overlay(Rectangle().strokeBorder(Color.egDivider, lineWidth: 1.5))
    }
}

struct EGColumnLabel: View {
    let text: String
    var size: CGFloat = 9.5

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .heavy))
            .kerning(0.9)
            .foregroundStyle(Color.egGray)
    }
}

struct EGButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary }
    var kind: Kind = .secondary

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .heavy))
            .kerning(0.8)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(kind == .primary ? Color.egOnRed : Color.egInk)
            .background(kind == .primary ? Color.egRed : Color.clear)
            .overlay {
                if kind == .secondary {
                    Rectangle().strokeBorder(Color.egDivider, lineWidth: 2)
                }
            }
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}

struct EGBackButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .heavy))
                Text(label)
                    .font(.system(size: 11, weight: .heavy))
                    .kerning(0.9)
            }
            .foregroundStyle(Color.egRed)
            .contentShape(Rectangle().inset(by: -15))
        }
        .buttonStyle(.plain)
    }
}
