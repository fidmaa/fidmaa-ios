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
                .padding(.top, 200)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { camera.resetMeasurement() }
        .onLongPressGesture(minimumDuration: 0.6) {
            camera.requestDiagnosticSnapshot()
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
    }

    private var overlay: some View {
        Canvas { context, size in
            let map = { (p: CGPoint) in camera.screenPoint(fromSensor: p, screen: size) }
            for p in state.outline.map(map) {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4)),
                             with: .color(.white.opacity(0.7)))
            }
            for (p, tooth) in zip(state.profile.map(map), state.profileTooth) {
                context.fill(Path(ellipseIn: CGRect(x: p.x - 1.5, y: p.y - 1.5, width: 3, height: 3)),
                             with: .color(tooth ? .cyan : .red.opacity(0.8)))
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
        case .thyroid: .yellow
        case .recess: .orange
        case nil: .white
        }
    }

    private var panel: some View {
        VStack(spacing: 6) {
            Text(mode == .mouth ? LocalizedStringKey("Siekacze / otwarcie ust") : LocalizedStringKey("Thyromental height (TMHT)"))
                .font(.headline)
            if !camera.isMeasurementAvailable {
                Text("Pomiar niedostępny na tym urządzeniu").foregroundStyle(.orange)
            } else if mode == .mouth {
                maxLine("MAKS zęby", state.maxTeeth, .cyan)
                maxLine("MAKS wargi", state.maxLips, .pink)
            } else {
                tmhtLine
                if let pitch = state.pitchDegrees, isActive {
                    Text("pochylenie telefonu \(Int(pitch.rounded()))°").font(.caption)
                }
                Text("Głowa oparta, usta zamknięte, telefon na wprost").font(.caption2).foregroundStyle(.secondary)
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

    /// Steady TMHT; below 50 mm (Etezadi) shown in red. Without a thyroid prominence: the recess fallback.
    @ViewBuilder private var tmhtLine: some View {
        if let value = state.steadyThyroid {
            HStack(alignment: .firstTextBaseline) {
                Text("TMHT").font(.subheadline).foregroundStyle(.yellow)
                Text(millimeters(value))
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(value < 0.050 ? .red : .green)
            }
        } else if let value = state.steadyRecess {
            HStack(alignment: .firstTextBaseline) {
                Text("bródkowo-gnykowy (zastępczo)").font(.subheadline).foregroundStyle(.orange)
                Text(millimeters(value)).font(.system(size: 32, weight: .bold, design: .rounded).monospacedDigit())
            }
            Text("nie znaleziono chrząstki tarczowatej").font(.caption).foregroundStyle(.orange)
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("TMHT").font(.subheadline).foregroundStyle(.yellow)
                Text("—").font(.system(size: 40, weight: .bold, design: .rounded))
            }
        }
    }

    private func maxLine(_ label: LocalizedStringKey, _ value: Float?, _ color: Color) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.subheadline).foregroundStyle(color)
            Text(value.map(millimeters) ?? "—")
                .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
        }
    }

    private var kindLabel: String {
        switch state.kind {
        case .teeth: String(localized: " (zęby)")
        case .lips: String(localized: " (wargi)")
        case .thyroid: String(localized: " (chrząstka)")
        case .recess: String(localized: " (zagłębienie)")
        case nil: ""
        }
    }

    private func millimeters(_ meters: Float) -> String {
        String(format: "%.1f mm", meters * 1000)
    }
}
