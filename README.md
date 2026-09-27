# Fidmaa Pic

Aplikacja na iPhone'a z kamerą TrueDepth (iPhone 17 i nowsze, iOS 26), która przednim aparatem
robi zdjęcie portretowe i zapisuje surowe dane głębi w metrach (`AVDepthData`, accuracy `absolute`)
oraz maski: portretową, włosy, skóra, zęby, okulary.

## Uruchomienie

1. Otwórz `FidmaaPic.xcodeproj` w Xcode 26.
2. Target **FidmaaPic** → *Signing & Capabilities* → wybierz swój **Team**
   (w razie konfliktu zmień `Bundle Identifier`, domyślnie `com.fidmaa.pic`).
3. Podłącz iPhone'a, wybierz go jako cel i uruchom (⌘R).
   Na telefonie: Ustawienia → Prywatność i ochrona → Tryb dewelopera musi być włączony.

Na ekranie widać podgląd selfie i komunikat odległości (liczony z mediany głębi w środku kadru):
„Odsuń się” poniżej 25 cm, „Przybliż się” powyżej 70 cm, „OK — odległość X cm” pomiędzy.
Progi: `FidmaaCore/Sources/FidmaaCore/DistanceEstimator.swift`.

## Co jest zapisywane

Każde zdjęcie trafia do **Zdjęć** (HEIC z osadzoną głębią i maskami, jak z aplikacji Aparat) oraz do
folderu aplikacji: *Pliki → Na moim iPhonie → Fidmaa Pic → `YYYYMMDD-HHmmss/`*
(albo Finder → iPhone → Pliki → Fidmaa Pic).

| Plik | Zawartość |
|---|---|
| `photo.heic` | zdjęcie z osadzoną głębią i maskami |
| `depth.tiff` | głębia, 1 kanał float32, metry |
| `depth.f32` | te same dane surowo: little-endian float32, wiersz po wierszu |
| `portrait.png`, `hair.png`, `skin.png`, `teeth.png`, `glasses.png` | maski 8-bit (brak maski → plik nie powstaje, w JSON `null`) |
| `calibration.json` | wymiary, accuracy, parametry kamery (intrinsics, extrinsics, dystorsja), odległość w chwili zdjęcia |

Głębia i maski są w **orientacji sensora** (bez obrotu i lustra), tak jak odnosi się do nich kalibracja.
Orientacja zdjęcia: `image.exifOrientation` / `image.mirrored` w JSON.
Głębia jest **niefiltrowana** — dziury to NaN lub 0 (`CaptureConfig.isDepthDataFiltered`).

## Wczytanie w Pythonie

```python
import json
import numpy as np

meta = json.load(open("calibration.json"))
h, w = meta["depth"]["height"], meta["depth"]["width"]
depth = np.fromfile("depth.f32", dtype="<f4").reshape(h, w)   # metry
valid = np.isfinite(depth) & (depth > 0)

cal = meta["calibration"]
K = np.array(cal["intrinsicMatrix"], dtype=np.float64)
K_depth = K.copy()
K_depth[:2] *= w / cal["intrinsicMatrixReferenceDimensions"]["width"]  # intrinsics w pikselach mapy głębi

ys, xs = np.nonzero(valid)
z = depth[ys, xs]
points = np.column_stack([
    (xs - K_depth[0, 2]) * z / K_depth[0, 0],
    (ys - K_depth[1, 2]) * z / K_depth[1, 1],
    z,
])  # chmura punktów w metrach
```

## Podgląd 3D na Macu

```bash
uv run tools/view3d.py ~/Dropbox/.../20260927-205915.zip --open
```

Tworzy lokalną stronę HTML (`<zdjęcie>-3d.html`) z modelem 3D w zsynchronizowanych panelach:
pojedyncza klatka, filtr bilateralny, mediana z N klatek, mediana + filtr, a dla zdjęć zrobionych
z „Wygładzona Apple” także mapę Apple i fuzję (kształt Apple + skala z surowych klatek).
Tryby: cieniowanie, kolor wg głębi, szum między klatkami, tekstura zdjęcia.
Plik zawiera model 3D twarzy — nie publikuj go.

Panele AI (Apple Depth Pro — głębia liczona z samego zdjęcia RGB, dopasowana do pomiaru):

```bash
# jednorazowo: środowisko z Depth Pro i wagami (~1,9 GB) w dowolnym katalogu roboczym
uv venv --python 3.11 .venv && uv pip install --python .venv/bin/python "git+https://github.com/apple/ml-depth-pro.git" huggingface_hub pillow
.venv/bin/python -c "from huggingface_hub import hf_hub_download; hf_hub_download('apple/DepthPro','depth_pro.pt',local_dir='checkpoints')"
# dla każdego zdjęcia (w katalogu z checkpoints/):
.venv/bin/python <repo>/tools/depth_ai.py <folder zdjęcia> ai.f32
uv run <repo>/tools/view3d.py <folder zdjęcia> --ai-depth ai.f32 --open
```

Szczegóły z AI są wnioskowane z wyglądu, nie zmierzone — podpis panelu podaje różnicę względem pomiaru.

## Testy

Logika (mediana odległości, JSON, zapis float32, nazwy folderów) jest w pakiecie `FidmaaCore`:

```bash
cd FidmaaCore && swift test
```

Kamera wymaga fizycznego urządzenia. Checklista ręczna:
- pierwsze uruchomienie pyta o zgodę na aparat;
- komunikaty „Odsuń się” / „Przybliż się” / „OK” zmieniają się przy zmianie odległości;
- po zdjęciu: miniatura, „Głębia: ABSOLUTE”, folder w Plikach z 9 plikami;
- zdjęcie w Zdjęciach ma tryb Portret (możliwa zmiana głębi ostrości);
- zdjęcie bez twarzy: maski `null` w JSON, reszta plików zapisana.
