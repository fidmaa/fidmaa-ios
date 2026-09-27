import AVKit
import FidmaaCore
import SwiftUI

/// Swipe order: neck ← mouth ← camera → depth.
private enum Page: Hashable, CaseIterable {
    case neck
    case mouth
    case camera
    case depth

    var title: LocalizedStringKey {
        switch self {
        case .neck: "Bródkowo-gnykowy"
        case .mouth: "Siekacze / usta"
        case .camera: "Aparat"
        case .depth: "Głębia"
        }
    }
}

/// Dots showing which page is visible, with its name.
private struct PageIndicator: View {
    let page: Page

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                ForEach(Page.allCases, id: \.self) { p in
                    Circle()
                        .fill(p == page ? Color.white : Color.white.opacity(0.35))
                        .frame(width: p == page ? 9 : 7, height: p == page ? 9 : 7)
                }
            }
            Text(page.title).font(.caption2).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.black.opacity(0.3), in: Capsule())
        .allowsHitTesting(false)
    }
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
                // One live preview under transparent pages; the swipe follows the finger.
                CameraPreviewView(session: camera.session, onLayerReady: camera.attach(previewLayer:))
                    .ignoresSafeArea()
                TabView(selection: $page) {
                    MeasurementPage(mode: .neck, camera: camera)
                        .tag(Page.neck)
                    MeasurementPage(mode: .mouth, camera: camera)
                        .tag(Page.mouth)
                    Color.clear
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
                    PageIndicator(page: page)
                    if page == .camera || page == .depth {
                        Picker("Uśrednianie", selection: $averagingFrames) {
                            ForEach(CaptureConfig.averagingOptions, id: \.self) { Text("\($0)×").tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 180)
                        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                    Spacer()
                    if page == .camera {  // other pages only collect data
                        ResultPanel(result: camera.lastResult, error: camera.lastError)
                        controls
                    }
                }
                .padding()
            }
        }
        .onChange(of: page) { _, page in
            camera.isDepthViewActive = page == .depth
            camera.measurementMode = switch page {
            case .mouth: .mouth
            case .neck: .neck
            case .camera, .depth: .none
            }
        }
        // Volume buttons, Camera Control and Bluetooth shutter remotes (which send "volume up") take a photo.
        .onCameraCaptureEvent(isEnabled: !showsGallery && page == .camera) { event in
            if event.phase == .ended { takePhoto() }
        }
        .sheet(isPresented: $showsGallery) { GalleryView() }
        .onAppear {
            camera.start()
            UIApplication.shared.isIdleTimerDisabled = true  // keep the screen on while the app is open
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                camera.start()
                UIApplication.shared.isIdleTimerDisabled = true
            case .background: camera.stop()
            default: break
            }
        }
    }

    private func takePhoto() {
        // Apple-filtered photo depth is hidden: it arrives quantized in ~13 mm steps.
        camera.capturePhoto(averagingFrames: averagingFrames,
                            filteredPhotoDepth: CaptureConfig.defaultPhotoDepthFiltered)
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

            Button(action: takePhoto) {
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
        Text(status.localizedMessage)
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
                Text("Głębia: \(result.accuracy.rawValue.uppercased())\(result.photoDepthFiltered ? " · wygładzona Apple" : "")")
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

extension DistanceStatus {
    /// App-side, localizable version of FidmaaCore's message.
    var localizedMessage: String {
        switch self {
        case .noData: String(localized: "Brak danych głębi")
        case .tooClose: String(localized: "Odsuń się")
        case .tooFar: String(localized: "Przybliż się")
        case .ok(let meters): String(localized: "OK — odległość \(Int((meters * 100).rounded())) cm")
        }
    }
}
