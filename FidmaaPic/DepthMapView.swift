import FidmaaCore
import SwiftUI

/// Live colored depth, rotated/mirrored to line up with the camera preview, plus a legend.
struct DepthMapView: View {
    let image: CGImage?
    let rotationAngle: CGFloat
    let mirrored: Bool

    var body: some View {
        GeometryReader { geo in
            let sideways = Int(rotationAngle.rounded()) % 180 != 0
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: sideways ? geo.size.height : geo.size.width,
                               height: sideways ? geo.size.width : geo.size.height)
                        .rotationEffect(.degrees(rotationAngle))
                        .scaleEffect(x: mirrored ? -1 : 1, y: 1)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    ProgressView().tint(.white)
                }
            }
        }
        .overlay(alignment: .trailing) { DepthLegend().padding(.trailing, 12) }
    }
}

private struct DepthLegend: View {
    private let steps = 12

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(label(DepthColormap.nearMeters))
            LinearGradient(colors: (0...steps).map { i in
                let depth = DepthColormap.nearMeters
                    + (DepthColormap.farMeters - DepthColormap.nearMeters) * Float(i) / Float(steps)
                let c = DepthColormap.color(depth: depth)
                return Color(red: Double(c.r) / 255, green: Double(c.g) / 255, blue: Double(c.b) / 255)
            }, startPoint: .top, endPoint: .bottom)
            .frame(width: 14, height: 220)
            .clipShape(Capsule())
            Text(label(DepthColormap.farMeters))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(6)
        .background(.black.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func label(_ meters: Float) -> String {
        "\(Int((meters * 100).rounded())) cm"
    }
}
