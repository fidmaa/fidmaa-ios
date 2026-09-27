import FidmaaCore
import os
import SwiftUI
import UIKit

/// Grid of captures in Documents; select several and share them (one zip per capture).
struct GalleryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var captures: [URL] = []
    @State private var selection: Set<URL> = []
    @State private var share: ShareBundle?
    @State private var isPreparing = false
    @State private var errorMessage: String?
    @State private var confirmsDeletion = false

    private static let logger = Logger(subsystem: "com.fidmaa.pic", category: "gallery")
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 2)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red).padding()
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(captures, id: \.self) { folder in
                        CaptureTile(folder: folder, isSelected: selection.contains(folder))
                            .onTapGesture { toggle(folder) }
                    }
                }
                if captures.isEmpty && errorMessage == nil {
                    Text("Brak zdjęć").foregroundStyle(.secondary).padding(.top, 40)
                }
            }
            .navigationTitle("Zdjęcia (\(captures.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Zamknij") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(selection.count == captures.count && !captures.isEmpty ? "Odznacz" : "Zaznacz wszystkie") {
                        selection = selection.count == captures.count ? [] : Set(captures)
                    }
                    .disabled(captures.isEmpty)
                }
                ToolbarItem(placement: .bottomBar) {
                    Menu {
                        Button("ZIP — wszystkie dane") { prepareShare(.zip) }
                        Button("HEIC — pojedyncza mapa głębi") { prepareShare(.heicSingle) }
                        Button("HEIC — uśredniona mapa głębi") { prepareShare(.heicAveraged) }
                    } label: {
                        if isPreparing {
                            ProgressView()
                        } else {
                            Label("Udostępnij (\(selection.count))", systemImage: "square.and.arrow.up")
                        }
                    }
                    .disabled(selection.isEmpty || isPreparing)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button(role: .destructive) {
                        confirmsDeletion = true
                    } label: {
                        Label("Usuń (\(selection.count))", systemImage: "trash")
                    }
                    .disabled(selection.isEmpty || isPreparing)
                }
            }
            .task { load() }
            .confirmationDialog("Usunąć \(selection.count) zdjęć z aplikacji?", isPresented: $confirmsDeletion,
                                titleVisibility: .visible) {
                Button("Usuń", role: .destructive) { deleteSelection() }
            } message: {
                Text("Pliki z danymi głębi zostaną trwale usunięte. Kopie w aplikacji Zdjęcia zostają.")
            }
            .sheet(item: $share) { bundle in
                ActivityView(items: bundle.archives) { share = nil }
                .ignoresSafeArea()
            }
        }
    }

    private func load() {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                        appropriateFor: nil, create: true)
            captures = try CaptureLibrary.captureFolders(in: documents)
            selection = selection.intersection(captures)
        } catch {
            Self.logger.error("Listing captures failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = String(localized: "Nie udało się wczytać zdjęć: \(error.localizedDescription)")
        }
    }

    private func toggle(_ folder: URL) {
        if selection.contains(folder) { selection.remove(folder) } else { selection.insert(folder) }
    }

    private enum ShareFormat { case zip, heicSingle, heicAveraged }

    private func deleteSelection() {
        let failures = CaptureLibrary.deleteCaptures(captures.filter(selection.contains))
        for failure in failures {
            Self.logger.error("Deleting \(failure.folder.lastPathComponent, privacy: .public) failed: \(failure.message, privacy: .public)")
        }
        errorMessage = failures.isEmpty ? nil : String(localized: "Nie udało się usunąć \(failures.count) zdjęć: \(failures[0].message)")
        selection = []
        load()
    }

    private func prepareShare(_ format: ShareFormat) {
        let folders = captures.filter(selection.contains)
        isPreparing = true
        errorMessage = nil
        Task.detached(priority: .userInitiated) {
            let result = Result {
                switch format {
                case .zip: try CaptureArchiver.zipCaptures(folders)
                case .heicSingle: try CaptureArchiver.exportPhotos(folders, variant: .single)
                case .heicAveraged: try CaptureArchiver.exportPhotos(folders, variant: .averaged)
                }
            }
            await MainActor.run {
                isPreparing = false
                switch result {
                case .success(let archives):
                    share = ShareBundle(archives: archives)
                case .failure(let error):
                    Self.logger.error("Preparing share failed: \(error.localizedDescription, privacy: .public)")
                    errorMessage = String(localized: "Nie udało się przygotować plików: \(error.localizedDescription)")
                }
            }
        }
    }
}

private struct ShareBundle: Identifiable {
    let id = UUID()
    let archives: [URL]
}

private struct CaptureTile: View {
    let folder: URL
    let isSelected: Bool
    @State private var thumbnail: UIImage?

    var body: some View {
        Color.gray.opacity(0.2)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .overlay {
                if let thumbnail {
                    Image(uiImage: thumbnail).resizable().scaledToFill()
                }
            }
            .clipped()
            .overlay(alignment: .bottomLeading) {
                Text(CaptureLibrary.displayName(forFolder: folder.lastPathComponent))
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.5))
            }
            .overlay(alignment: .topTrailing) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .blue : .white)
                    .background(Circle().fill(isSelected ? .white : .black.opacity(0.3)))
                    .padding(6)
            }
            .overlay {
                if isSelected { Rectangle().stroke(.blue, lineWidth: 3) }
            }
            .task(id: folder) {
                let url = folder.appendingPathComponent("photo.heic")
                thumbnail = await Task.detached(priority: .utility) {
                    ThumbnailLoader.thumbnail(at: url, maxPixelSize: 400)
                }.value
            }
    }
}

/// UIActivityViewController wrapper; the Dropbox app appears there as "Save to Dropbox".
private struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, error in
            if let error {
                Logger(subsystem: "com.fidmaa.pic", category: "gallery")
                    .error("Share failed: \(error.localizedDescription, privacy: .public)")
            }
            onComplete()
        }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
