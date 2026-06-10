import SwiftUI

// MARK: - Design system
//
// Aesthetic direction: "calm broadcast console".
// A native macOS control panel for capturing Chzzk broadcasts.
//  • One brand accent — Chzzk green — used functionally (primary actions,
//    selection, positive status). Not generic blue, not AI cyan-on-dark.
//  • Broadcast red, reserved for live / recording (on-air convention).
//  • Monospaced digits for all data so figures align and read as instruments.
//  • Semantic system colors throughout → correct in light and dark.

extension Color {
    /// Chzzk brand green, tuned a touch deeper than the logo so white labels
    /// stay legible on filled buttons.
    static let brand = Color(red: 0.0, green: 0.72, blue: 0.49)
    /// On-air red for live / recording indicators.
    static let onAir = Color(red: 0.91, green: 0.19, blue: 0.22)
}

extension View {
    /// A restrained, dark-mode-correct surface for discrete list items.
    /// Uses a hierarchical fill + hairline separator instead of pure-black overlays.
    func cardSurface(cornerRadius: CGFloat = 8) -> some View {
        self
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }

    /// Tabular figures for data that should line up column-to-column.
    func dataFigures() -> some View { self.monospacedDigit() }
}

/// Lightweight optimistic-UI toast — slides up from the bottom on a material pill.
struct ToastView: View {
    let message: String?

    var body: some View {
        Group {
            if let message {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.brand)
                    Text(message).font(.callout)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                .padding(.bottom, 26)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: message)
    }
}

/// A small pulsing dot signalling a live broadcast. Purposeful motion
/// (ease-in-out, no bounce) — it communicates "on air", not decoration.
struct LiveDot: View {
    var size: CGFloat = 8
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(Color.onAir)
            .frame(width: size, height: size)
            .opacity(pulsing ? 1.0 : 0.4)
            .scaleEffect(pulsing ? 1.0 : 0.82)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
            .accessibilityLabel("방송 중")
    }
}
