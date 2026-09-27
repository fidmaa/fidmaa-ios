import FidmaaCore
import SwiftUI

private enum Page: Hashable {
    case camera
    case depth
}

struct ContentView: View {
    @State private var camera = CameraController()
    @State private var page = Page.camera
    @State private var showsGallery = false
    @AppStorage("averagingFrames") private var averagingFrames = CaptureConfig.defaultAveragingFrames
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
                // Paged so the swipe follows the finger: camera ← → colored depth.
                TabView(selection: $page) {
                    CameraPreviewView(session: camera.session, onLayerReady: camera.attach(previewLayer:))
                        .tag(Page.camera)
                    DepthMapView(image: camera.depthImage,
                                 rotationAngle: camera.previewRotationAngle + CaptureConfig.depthViewExtraRotation,
                                 mirrored: CaptureConfig.depthViewMirrored)
                        .tag(Page.depth)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
                VStack(spacing: 12) {
                    DistanceBanner(status: camera.distance)
                    Picker("Uśrednianie", selection: $averagingFrames) {
                        ForEach(CaptureConfig.averagingOptions, id: \.self) { Text("\($0)×").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    Spacer()
                    ResultPanel(result: camera.lastResult, error: camera.lastError)
                    controls
                }
                .padding()
            }
        }
        .onChange(of: page) { _, page in camera.isDepthViewActive = page == .depth }
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

            Button { camera.capturePhoto(averagingFrames: averagingFrames) } label: {
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
