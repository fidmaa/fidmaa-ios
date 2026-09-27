# Fidmaa Pic — format eksportu (wersja 1)

Umowa dla programów czytających dane z aplikacji (m.in. portrait-analyser / sesja fidmaa-gui).
Nazwy plików i pól są stabilne. Zmiana tego formatu = aktualizacja tego pliku **i** powiadomienie
konsumentów. Nowe pola mogą dochodzić; istniejące nie zmieniają nazwy ani znaczenia.

## Folder zdjęcia / ZIP

Jeden folder na zdjęcie: `YYYYMMDD-HHmmss[-N]/` (ZIP z galerii zawiera ten folder).

| Plik | Zawartość |
|---|---|
| `photo.heic` | zdjęcie z osadzoną głębią i maskami; jak czytać głębię — `depth.heicDepth` |
| `depth.f32` | głębia zdjęcia, **metry**, Float32 LE, W×H wierszami, bez paddingu |
| `depth.tiff` | to samo co `depth.f32`, 1 kanał float32 |
| `depth_stack.f32` | N klatek ze strumienia (N×H×W), metry, Float32 LE, kolejność jak w `frames.json` |
| `depth_median.f32` | mediana per piksel z użytych klatek, metry (NaN gdy brak) |
| `depth_std.f32` | odchylenie standardowe per piksel, metry (NaN gdy brak) |
| `depth_count.u8` | liczba ważnych wartości per piksel, uint8 |
| `portrait.png`, `hair.png`, `skin.png`, `teeth.png`, `glasses.png` | maski 8-bit; brak maski → brak pliku, `null` w JSON |
| `calibration.json` | metadane (niżej) |
| `frames.json` | metadane klatek stosu |

Wszystkie mapy (głębia i maski) są w **orientacji sensora** (poziomo, bez obrotu i lustra), na tej samej
siatce co przechowywane piksele `photo.heic`. Wartości nieważne: NaN lub 0.

## calibration.json

| Pole | Znaczenie |
|---|---|
| `captureDate`, `deviceModel`, `systemVersion` | ISO 8601, np. `iPhone18,1`, `26.3.1` |
| `depth.width`, `depth.height` | wymiary map głębi (640×480) |
| `depth.units` | `"meters"` |
| `depth.accuracy` | `"absolute"` / `"relative"` / `"unknown"` |
| `depth.isFiltered` | `false` — surowa głębia (wygładzanie Apple wyłączone) |
| `depth.originalPixelFormat` | FourCC z AVFoundation, np. `"hdis"` |
| `depth.orientation` | `"sensor"` |
| `depth.interpretation` | `"as-labelled"` / `"inverted-to-match-stream"` / `"unverified"` — jak potraktowano głębię zdjęcia przy zapisie `depth.f32` |
| `depth.photoCenter_m`, `depth.streamCenter_m` | mediany środka użyte do tej decyzji |
| `depth.heicDepth` | `"true-disparity"` — HEIC ma dysparycję 1/m (depth = 1/x); `"ios-original"`, `null` lub brak pola — HEIC ma **metry z etykietą disparity** (depth = x) |
| `image.width`, `image.height`, `image.exifOrientation`, `image.mirrored` | zdjęcie w orientacji zapisu |
| `calibration` | kalibracja z głębi zdjęcia — **układ obrócony o 90°** (ref. 3024×4032) |
| `depthMapCalibration` | kalibracja ze strumienia — **układ map głębi** (ref. 4032×3024); używać do rzutowania 3D |
| `mattes.{portrait,hair,skin,teeth,glasses}` | nazwa pliku albo `null` |
| `distanceAtCapture_m` | mediana środka kadru w chwili zdjęcia |
| `stack.requestedFrames`, `framesCaptured`, `framesUsed` | ustawienie 1×/5×/10× i ile klatek użyto |
| `stack.windowSeconds`, `rotationThresholdDegrees`, `motionAvailable`, `width`, `height` | parametry stosu |
| `stack.stackFile`, `medianFile`, `stdFile`, `countFile`, `framesFile` | nazwy plików stosu |

Macierze: row-major. `intrinsicMatrix` w pikselach `intrinsicMatrixReferenceDimensions`; dla mapy
640×480 przeskalować przez `640 / ref.width`. Wartości niereprezentowalne w JSON (NaN, ±inf) jako
łańcuchy `"NaN"`, `"Infinity"`, `"-Infinity"`.

## frames.json

`referenceFrameIndex`, `frames[]` (`index`, `timestamp`, `rotationFromReference_deg`,
`motionTimeOffset_s`, `used`), `streamCalibration`.

## HEIC bez calibration.json (np. IMG_*.HEIC z aplikacji Zdjęcia)

Oryginały z iOS 26 / iPhone 17 mają metry pod etykietą disparity. Heurystyka: mediana środka mapy;
jeśli jako odległość mieści się w 0,15–1,2 m → metry; jeśli dopiero 1/x → dysparycja
(`tools/view3d.py: depth_from_heic`).
