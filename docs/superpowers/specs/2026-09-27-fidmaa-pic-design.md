# fidmaa-pic — projekt

Data: 2026-09-27

## Cel

Aplikacja na iPhone 17 i nowsze, która przednim aparatem TrueDepth robi zdjęcie
portretowe (selfie) i zapisuje komplet danych jak natywna aplikacja Aparat:
mapę głębi w trybie **absolute** (metry) oraz maski: portretową, włosy, skóra,
zęby, okulary. Dane mają nadawać się do analizy naukowej na komputerze (Python).

### Co powiedział użytkownik
- iPhone 17+, przedni obiektyw, zdjęcie portretowe + wartości z TrueDepth w trybie absolute.
- Chce dane tak jak natywna aplikacja (teeth map, hair map); fallback: JPEG + mapa głębi.
- W UI: widzieć podgląd selfie, ewentualnie komunikat „odsuń się”.
- Zapis: do Zdjęć ORAZ do folderu aplikacji (Pliki/Finder).

### Założenia
- „Absolute” = `AVDepthData.depthDataAccuracy == .absolute`; głębia konwertowana do `kCVPixelFormatType_DepthFloat32` (metry).
- iOS 26, SwiftUI, tylko iPhone, tylko orientacja pionowa.
- Głębia **niefiltrowana** (`isDepthDataFiltered = false`) — surowy pomiar, dziury = NaN/0. Stała w kodzie, łatwa do zmiany.

## Architektura

Projekt Xcode pisany ręcznie (`objectVersion 77`, foldery synchronizowane z dyskiem), bez zewnętrznych zależności.

```
FidmaaPic/
  FidmaaPicApp.swift       – punkt wejścia
  ContentView.swift        – podgląd, komunikat odległości, migawka, miniatura
  CameraPreviewView.swift  – UIViewRepresentable z AVCaptureVideoPreviewLayer
  CameraSession.swift      – AVCaptureSession, wybór formatu, wyjścia, capture
  DistanceEstimator.swift  – mediana głębi w środku kadru → komunikat (czysta logika)
  CaptureExporter.swift    – zapis do Zdjęć i do Documents/<timestamp>/
  CalibrationInfo.swift    – Codable model calibration.json
  DepthImageWriter.swift   – zapis float32 TIFF/raw i masek PNG
FidmaaPicTests/
  DistanceEstimatorTests.swift
  CalibrationInfoTests.swift
```

### CameraSession
- Urządzenie: `AVCaptureDevice.default(.builtInTrueDepthCamera, for: .video, position: .front)`.
- Format: aktywny format z największą rozdzielczością zdjęcia, który ma `supportedDepthDataFormats` zawierające `DepthFloat32`; ustawiony `activeDepthDataFormat` na największy float32.
- Wyjścia:
  - `AVCapturePhotoOutput`: `isDepthDataDeliveryEnabled`, `isPortraitEffectsMatteDeliveryEnabled`, `enabledSemanticSegmentationMatteTypes = availableSemanticSegmentationMatteTypes` (hair, skin, teeth, glasses), `maxPhotoQualityPrioritization = .quality`.
  - `AVCaptureDepthDataOutput` (podgląd odległości, filtrowany dla stabilności komunikatu).
- Ustawienia zdjęcia: HEVC/HEIC, `isDepthDataDeliveryEnabled`, `embedsDepthDataInPhoto`, `isPortraitEffectsMatteDeliveryEnabled`, `embedsPortraitEffectsMatteInPhoto`, `enabledSemanticSegmentationMatteTypes`, `embedsSemanticSegmentationMattesInPhoto`, `isDepthDataFiltered = false`.
- Sesja działa na dedykowanej kolejce; stan publikowany do UI przez `@Observable` na MainActor.

### DistanceEstimator
- Wejście: bufor float32 głębi (metry), szerokość, wysokość.
- Mediana ważnych wartości (skończone, > 0) w środkowym prostokącie 30% × 30%.
- Wynik: `.tooClose` (< 0,25 m), `.tooFar` (> 0,70 m), `.ok`, `.noData`. Progi to stałe.
- Komunikaty: „Odsuń się”, „Przybliż się”, „OK — odległość X cm”, „Brak danych głębi”.

### CaptureExporter
Dla każdego zdjęcia katalog `Documents/YYYYMMDD-HHmmss/`:

| Plik | Zawartość |
|---|---|
| `photo.heic` | `AVCapturePhoto.fileDataRepresentation()` — z osadzoną głębią i maskami |
| `depth.tiff` | 1 kanał float32, metry, orientacja sensora (bez obrotu/lustra) |
| `depth.f32` | te same dane surowo, little-endian, wiersz po wierszu (`np.fromfile(..., '<f4').reshape(h, w)`) |
| `portrait.png`, `hair.png`, `skin.png`, `teeth.png`, `glasses.png` | maski 8-bit grayscale w natywnej rozdzielczości; brakujące pomijane i odnotowane w JSON |
| `calibration.json` | metadane (poniżej) |

Ten sam `photo.heic` trafia do Zdjęć przez `PHPhotoLibrary` (`PHAssetCreationRequest`, `.photo`) — uprawnienie add-only.

### calibration.json
```json
{
  "captureDate": "ISO8601",
  "deviceModel": "iPhone18,1",
  "systemVersion": "26.x",
  "depth": {
    "width": 0, "height": 0,
    "units": "meters",
    "pixelFormat": "DepthFloat32",
    "accuracy": "absolute | relative",
    "quality": "high | low",
    "isFiltered": false,
    "originalPixelFormat": "fourcc",
    "invalidValue": "NaN or 0"
  },
  "image": { "width": 0, "height": 0, "exifOrientation": 0, "mirrored": true },
  "calibration": {
    "intrinsicMatrix": [[fx,0,cx],[0,fy,cy],[0,0,1]],
    "intrinsicMatrixReferenceDimensions": {"width": 0, "height": 0},
    "extrinsicMatrix": [[...4 cols] x3],
    "pixelSize_mm": 0.0,
    "lensDistortionCenter": {"x": 0, "y": 0},
    "lensDistortionLookupTable": [],
    "inverseLensDistortionLookupTable": []
  },
  "mattes": { "portrait": "portrait.png", "hair": "hair.png", "skin": null, "teeth": "teeth.png", "glasses": null },
  "distanceAtCapture_m": 0.42
}
```
Macierze wierszami (row-major). `intrinsicMatrix` odnosi się do `intrinsicMatrixReferenceDimensions` — do skalowania na rozdzielczość głębi.

## Info.plist
`NSCameraUsageDescription`, `NSPhotoLibraryAddUsageDescription`, `UIFileSharingEnabled = YES`, `LSSupportsOpeningDocumentsInPlace = YES`, `UIRequiredDeviceCapabilities` = `front-facing-camera`.

## Obsługa błędów
- Brak TrueDepth / brak formatu z głębią / brak zgody na kamerę → ekran z komunikatem.
- Głębia `.relative` → zapis się wykonuje, ostrzeżenie w UI i `accuracy: "relative"` w JSON.
- Błąd zapisu któregokolwiek pliku lub do Zdjęć → `Logger.error` + komunikat w UI; pozostałe pliki zapisywane dalej.
- Żadnych pustych `catch`.

## Testy
- Jednostkowe: `DistanceEstimator` (mediana, NaN/0, progi), serializacja `CalibrationInfo` (klucze, row-major).
- Build: `xcodebuild build` + `xcodebuild test` na symulatorze.
- Kamera: ręcznie na fizycznym iPhonie (symulator nie ma TrueDepth).

## Poza zakresem
Tylna kamera, wideo, edycja/efekt bokeh w aplikacji, galeria zdjęć, synchronizacja w chmurze.
