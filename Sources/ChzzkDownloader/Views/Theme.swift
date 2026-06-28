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
    /// An opaque elevated surface for in-window content cards and lists. Apple uses
    /// an opaque grouped background (not a translucent material) for content inside
    /// a window — material is for sidebars/popovers/HUDs. `controlBackgroundColor`
    /// reads bright/white in light mode and a properly elevated grey in dark mode,
    /// so lists no longer look dim over the window background.
    func cardSurface(cornerRadius: CGFloat = 8) -> some View {
        self
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            )
    }

    /// Liquid Glass (macOS 26+) for floating control-layer surfaces — toasts,
    /// bars, pills. Falls back to a translucent material on macOS 14–15. Do NOT
    /// use on content cards/lists; per Apple's guidance those stay opaque
    /// (see cardSurface) for legibility.
    @ViewBuilder
    func liquidGlass(in shape: some InsettableShape) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5))
        }
    }

    func pageContentPadding() -> some View {
        self
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Tabular figures for data that should line up column-to-column.
    func dataFigures() -> some View { self.monospacedDigit() }

    /// A subtle background tint while the pointer is over a list row or card —
    /// the standard macOS hover affordance. Sits behind content (above any card
    /// surface) so labels stay fully legible.
    func hoverHighlight(cornerRadius: CGFloat = 6) -> some View {
        modifier(HoverHighlight(cornerRadius: cornerRadius))
    }
}

/// Encapsulates its own hover state so it can be dropped on rows built inside
/// `@ViewBuilder` functions (which cannot hold `@State`).
struct HoverHighlight: ViewModifier {
    var cornerRadius: CGFloat = 6
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Color.primary.opacity(0.06) : Color.clear,
                        in: RoundedRectangle(cornerRadius: cornerRadius))
            .animation(.easeInOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Fading scroll

/// A vertical `ScrollView` that fades its bottom edge while more content remains
/// below the fold — a quiet cue that the list keeps going. The fade hides when the
/// content fits the viewport or the user has scrolled to the end, so short lists
/// stay flat and there is no fade once you reach the bottom.
struct FadingScrollView<Content: View>: View {
    private let fadeHeight: CGFloat
    private let content: Content

    init(fadeHeight: CGFloat = 28, @ViewBuilder content: () -> Content) {
        self.fadeHeight = fadeHeight
        self.content = content()
    }

    @State private var viewportHeight: CGFloat = 0
    @State private var contentHeight: CGFloat = 0
    @State private var scrolled: CGFloat = 0

    private var moreBelow: Bool {
        contentHeight > viewportHeight + 1 && scrolled < contentHeight - viewportHeight - 1
    }

    var body: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { geo in
                        Color.clear
                            .preference(key: ScrollContentHeightKey.self, value: geo.size.height)
                            .preference(key: ScrollOffsetKey.self,
                                        value: -geo.frame(in: .named("fadingScroll")).minY)
                    })
        }
        .coordinateSpace(name: "fadingScroll")
        .background(
            GeometryReader { geo in
                Color.clear.preference(key: ScrollViewportHeightKey.self, value: geo.size.height)
            })
        .onPreferenceChange(ScrollContentHeightKey.self) { contentHeight = $0 }
        .onPreferenceChange(ScrollViewportHeightKey.self) { viewportHeight = $0 }
        .onPreferenceChange(ScrollOffsetKey.self) { scrolled = $0 }
        // Fade by masking the content to transparent at the bottom (rather than
        // painting a coloured gradient on top). The real background — whatever it
        // is, sidebar edge or rounded window corner included — shows through, so
        // there is never a colour seam.
        .mask(
            VStack(spacing: 0) {
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: moreBelow ? fadeHeight : 0)
            }
            .animation(.easeInOut(duration: 0.2), value: moreBelow)
        )
    }
}

private struct ScrollContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct ScrollViewportHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

struct SectionTitle: View {
    let title: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(AppLocalization.string(title))
                .font(.headline)
            if let detail {
                Spacer()
                Text(AppLocalization.string(detail))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

struct SummaryTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = .brand

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(AppLocalization.string(title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .cardSurface()
    }
}

struct StatusPill: View {
    let text: String
    let systemImage: String
    var tint: Color

    var body: some View {
        Label(AppLocalization.string(text), systemImage: systemImage)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tint.opacity(0.12), in: Capsule())
            .foregroundStyle(tint)
    }
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
                .liquidGlass(in: Capsule())
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
