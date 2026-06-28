import SwiftUI

/// One Muybridge pose: a compound polygon (outer outline + inner holes for the
/// gaps between the legs), scaled to fit and centered in `rect`. Rendered with
/// the even-odd rule so the holes punch through.
private struct GallopShape: Shape {
    let subpaths: [[CGPoint]]
    let box: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard box.width > 0, box.height > 0 else { return path }
        let scale = min(rect.width / box.width, rect.height / box.height)
        let ox = rect.minX + (rect.width - box.width * scale) / 2
        let oy = rect.minY + (rect.height - box.height * scale) / 2
        for poly in subpaths where poly.count > 1 {
            path.move(to: CGPoint(x: ox + poly[0].x * scale, y: oy + poly[0].y * scale))
            for p in poly.dropFirst() {
                path.addLine(to: CGPoint(x: ox + p.x * scale, y: oy + p.y * scale))
            }
            path.closeSubpath()
        }
        return path
    }
}

/// Muybridge "The Horse in Motion" (1878) flip-book animation.
/// Speed drives the cadence — like the running horse on an old taxi meter.
/// Stalled → a very slow walk.
struct MuybridgeHorseView: View {
    let bytesPerSecond: Double
    var tint: Color = .secondary

    @State private var index = 0
    @State private var phase = 0.0
    @State private var lastSeen = -1.0
    @State private var lastChange = Date()
    private let tick = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private static let frames: [[[CGPoint]]] = MuybridgeSilhouettes.paths.map(parse)

    private var fps: Double {
        let mbps = bytesPerSecond / 1_048_576
        if mbps < 0.02 { return 1.0 }          // stalled → very slow walk
        return min(26, 3 + mbps * 2.4)
    }

    var body: some View {
        let frames = Self.frames
        if !frames.isEmpty {
            GallopShape(subpaths: frames[min(index, frames.count - 1)],
                        box: MuybridgeSilhouettes.viewBox)
                .fill(tint, style: FillStyle(eoFill: true))
                .aspectRatio(MuybridgeSilhouettes.viewBox.width / MuybridgeSilhouettes.viewBox.height,
                             contentMode: .fit)
                .onReceive(tick) { _ in
                    if bytesPerSecond != lastSeen {
                        lastSeen = bytesPerSecond
                        lastChange = Date()
                    }
                    let stalled = Date().timeIntervalSince(lastChange) > 2.5
                    let f = stalled ? 1.0 : fps
                    phase += f / 30.0
                    index = Int(phase) % frames.count
                }
                .accessibilityHidden(true)
        }
    }

    /// Parses an SVG-ish path with one or more "M…L…Z" subpaths into polygons.
    private static func parse(_ d: String) -> [[CGPoint]] {
        d.split(separator: "M").compactMap { sub in
            let pts = sub.replacingOccurrences(of: "Z", with: "")
                .split(whereSeparator: { $0 == "L" })
                .compactMap { token -> CGPoint? in
                    let xy = token.split(separator: " ")
                    guard xy.count == 2, let x = Double(xy[0]), let y = Double(xy[1]) else { return nil }
                    return CGPoint(x: x, y: y)
                }
            return pts.count > 1 ? pts : nil
        }
    }
}
