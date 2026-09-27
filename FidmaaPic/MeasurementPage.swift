import SwiftUI

/// Transparent page over the live preview: detected points, the measured segment and the held maximum.
/// Tapping resets this page's maximum.
struct MeasurementPage: View {
    let mode: MeasurementMode
    let camera: CameraController

    private var state: MeasurementState { camera.measurement }
    private var isActive: Bool { camera.measurementMode == mode }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.001)  // makes the whole page tappable
            if isActive {
                overlay
            }
            panel
                .padding(.top, 130)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { camera.resetMeasurement() }
    }

    private var overlay: some View {
        Canvas { context, size in
            let map = { (p: CGPoint) in camera.screenPoint(fromSensor: p, screen: size) }
            for p in state.outline.map(map) {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                             with: .color(.white.opacity(0.7)))
            }
            let a = state.from.map(map)
            let b = state.to.map(map)
            if let a, let b {
                var line = Path()
                line.move(to: a)
                line.addLine(to: b)
                context.stroke(line, with: .color(color), lineWidth: 3)
            }
            for p in [a, b].compactMap({ $0 }) {
                context.stroke(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
                               with: .color(color), lineWidth: 3)
            }
        }
        .allowsHitTesting(false)
    }

    private var color: Color {
        switch state.kind {
        case .teeth: .cyan
        case .lips: .pink
        case .neck: .yellow
        case nil: .white
        }
    }

    private var panel: some View {
        VStack(spacing: 6) {
            Text(mode == .mouth ? "Siekacze / otwarcie ust" : "Bródkowo-gnykowy (oś Z)")
                .font(.headline)
            if !camera.isMeasurementAvailable {
                Text("Pomiar niedostępny na tym urządzeniu").foregroundStyle(.orange)
            } else if mode == .mouth {
                maxLine("MAKS zęby", state.maxTeeth, .cyan)
                maxLine("MAKS wargi", state.maxLips, .pink)
            } else {
                maxLine("MAKS", state.maxNeck, .yellow)
            }
            if isActive, let current = state.current {
                Text("teraz \(millimeters(current))\(kindLabel)")
                    .font(.callout.monospacedDigit())
            }
            if isActive, let status = state.status {
                Text(status).font(.callout).foregroundStyle(.orange)
            }
            Text("stuknij, aby wyzerować").font(.caption2).foregroundStyle(.secondary)
            if isActive, let debug = state.debug {
                Text(debug).font(.system(size: 9).monospaced()).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .padding(12)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .allowsHitTesting(false)
    }

    private func maxLine(_ label: String, _ value: Float?, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(color)
            Text(value.map(millimeters) ?? "—")
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
        }
    }

    private var kindLabel: String {
        switch state.kind {
        case .teeth: " (zęby)"
        case .lips: " (wargi)"
        case .neck, nil: ""
        }
    }

    private func millimeters(_ meters: Float) -> String {
        String(format: "%.1f mm", meters * 1000)
    }
}
