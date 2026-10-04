import SwiftUI

// MARK: - Avatar (web2 §3.4): a circle filled with the user's colour showing the first character of the name,
// uppercased, white, weight 650. 32 pt / 14 pt font by default; `lg` 48 pt / 19 pt.

struct Avatar: View {
    let name: String
    let color: String
    let size: CGFloat

    init(name: String, color: String, size: CGFloat = 32) {
        self.name = name
        self.color = color
        self.size = size
    }

    /// 14 pt at 32, 19 pt at 48, proportional elsewhere.
    private var fontSize: CGFloat { size >= 48 ? size * 19 / 48 : size * 14 / 32 }

    var body: some View {
        Circle()
            .fill(Color(hex: color))
            .frame(width: size, height: size)
            .overlay {
                Text(verbatim: name.first.map { String($0).uppercased() } ?? "")
                    .font(.system(size: fontSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

#Preview("Avatar") {
    DSPreviewSchemes {
        HStack(spacing: 12) {
            Avatar(name: "小明", color: "#2f7d5b")
            Avatar(name: "demo", color: "#3b6fb6")
            Avatar(name: "Lily", color: "#b53b72", size: 48)
            Avatar(name: "?", color: "not-a-colour")
        }
    }
}
