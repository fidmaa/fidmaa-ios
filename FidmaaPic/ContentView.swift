import FidmaaCore
import SwiftUI

struct ContentView: View {
    @State private var camera = CameraController()
    @State private var showsDepth = false
    @State private var showsGallery = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if case .failed(let message) = camera.state {
                Text(message)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding()
            } else {
                CameraPreviewView(session: camera.session, onLayerReady: camera.attach(previewLayer:))
                    .ignoresSafeArea()
                if showsDepth {
                    DepthMapView(image: camera.depthImage, rotationAngle: camera.previewRotationAngle,
                                 mirrored: CaptureConfig.depthViewMirrored)
                        .ignoresSafeArea()
                        .transition(.move(edge: .trailing))
                }
                VStack(spacing: 12) {
                    DistanceBanner(status: camera.distance)
                    Spacer()
                    ResultPanel(result: camera.lastResult, error: camera.lastError)
                    controls
                }
                .padding()
            }
        }
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 30).onEnded { value in
            guard abs(value.translation.width) > abs(value.translation.height) else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                if value.translation.width < -50 { showsDepth = true }
                if value.translation.width > 50 { showsDepth = false }
            }
        })
        .onChange(of: showsDepth) { _, depth in camera.isDepthViewActive = depth }
        .sheet(isPresented: $showsGallery) { GalleryView() }
        .onAppear { camera.start() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: camera.start()
            case .background: camera.stop()
            default: break
            }
        }
    }

    private var controls: some View {
        HStack {
            Group {
                if let thumbnail = camera.lastResult?.thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.15)
                }
            }
            .frame(width: 60, height: 80)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onTapGesture { showsGallery = true }
            .accessibilityLabel("Galeria zdjęć")
            .accessibilityAddTraits(.isButton)

            Spacer()

            Button(action: camera.capturePhoto) {
                ZStack {
                    Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                    if camera.isCapturing {
                        ProgressView().tint(.white)
                    } else {
                        Circle().fill(.white).frame(width: 62, height: 62)
                    }
                }
            }
            .disabled(camera.isCapturing || camera.state != .running)
            .accessibilityLabel("Zrób zdjęcie")

            Spacer()
            Color.clear.frame(width: 60, height: 80)
        }
    }
}

private struct DistanceBanner: View {
    let status: DistanceStatus

    var body: some View {
        Text(status.message)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(color, in: Capsule())
    }

    private var color: Color {
        switch status {
        case .ok: .green
        case .tooClose, .tooFar: .orange
        case .noData: .gray
        }
    }
}

private struct ResultPanel: View {
    let result: CaptureResult?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error {
                Text("Błąd: \(error)").foregroundStyle(.red)
            }
            if let result {
                Text("Zapisano: \(result.folder.lastPathComponent)")
                Text("Głębia: \(result.accuracy.rawValue.uppercased())")
                    .foregroundStyle(result.accuracy == .absolute ? .green : .orange)
                if let used = result.framesUsed, let captured = result.framesCaptured {
                    Text("Klatki uśrednione: \(used)/\(captured)")
                }
                ForEach(result.warnings, id: \.self) { warning in
                    Text("⚠︎ \(warning)").foregroundStyle(.yellow)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(error == nil && result == nil ? 0 : 8)
        .background(.black.opacity(error == nil && result == nil ? 0 : 0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
