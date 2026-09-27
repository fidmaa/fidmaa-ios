# Live measurements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Live incisor/mouth-opening and mentohyoid (Z) measurement pages with peak hold.
**Architecture:** Pure geometry/detection in FidmaaCore (tested on macOS); app adds synchronized video+depth,
Vision landmarks, a measurement engine and transparent overlay pages over one camera preview.
**Tech Stack:** Swift, AVFoundation, Vision, SwiftUI, Swift Testing.
**Spec:** `docs/superpowers/specs/2026-09-27-fidmaa-pic-design.md` (section „pomiary na żywo”)

## Global Constraints
- Depth grid 640×480, sensor orientation; Vision orientation `.right`; upright→sensor: `xs = yu, ys = 1 − xu`.
- Tooth pixel: luma > 0.55 and saturation < 0.35; run ≥ 3 px; search bands 40% at each end.
- Lips open threshold 8 mm; neck search 20–80 mm below chin; background jump 0.10 m; max 5 holes.
- Peak hold input = median of last 3 values. Analysis ≤ 15 Hz, only on measurement pages.
- No silent error swallowing; export format (docs/export-format.md) unchanged.

## Review Focus
1. Upright↔sensor mapping mistakes (mirroring/rotation) — test with the known IMG_2376 mapping.
2. Profile with no teeth / only upper teeth → must fall back to lips, not a bogus distance.
3. Neck path running into background/clothes → must stop, not report the background.
4. Single-frame spikes must not set the maximum (median of 3).
5. Measurement pages must not slow down photo capture (analysis only when a measurement page is shown).

### Task 1: FidmaaCore measurement primitives (TDD)
Files: `FidmaaCore/Sources/FidmaaCore/LiveMeasurement.swift`, tests `LiveMeasurementTests.swift`.
Produces:
- `struct Intrinsics { fx, fy, cx, cy: Float; static func scaled(fx:fy:cx:cy:reference: Size2D, width:height:) }`
- `enum UprightMapping { static func sensor(fromUpright: (x: Double, y: Double)) -> (x: Double, y: Double) }` (top-left normalized, EXIF 6)
- `enum FaceGeometry { static func lateralDistance(_ a: (u: Float, v: Float), _ b: (u: Float, v: Float), depth: Float, intrinsics: Intrinsics) -> Float }`
- `struct PixelSample { luma, saturation: Float }`; `enum IncisorDetector { static func edges(_ profile: [PixelSample]) -> (upper: Int, lower: Int)? }`
- `enum NeckProfile { static func deepest(offsetsMeters: [Float], depths: [Float], chinDepth: Float) -> Int? }`
- `struct PeakHold { mutating func add(_ v: Float) -> Float?; var maximum: Float?; mutating func reset() }`
Tests: mapping of known point (upright (253,209)/(480,640) → sensor (209/640, 1−253/480)); lateral distance
50 px at 0.42 m, fx 439 → 47.8 mm; incisor profile with teeth at both ends / only upper / none; neck profile
with clear minimum-maximum, background jump stop, holes; peak hold ignores single spike, reset.

### Task 2: Synchronized video + depth in CameraController
Video data output (BGRA, preview-sized, late frames discarded, connection unmirrored, no rotation),
`AVCaptureDataOutputSynchronizer` delegate replaces the depth-only delegate (depth path behavior unchanged:
frame buffer, distance hint, depth view). Frames forwarded to the measurement engine only when
`measurementMode != .none`. If the video output can't be added: log, measurement pages show „niedostępne”.

### Task 3: LiveMeasurementEngine (Vision + measurements)
Throttle 15 Hz; `VNDetectFaceLandmarksRequest` (`.right`); map landmarks to sensor-normalized; mouth: inner-lip
midpoints, profile sampling from BGRA, IncisorDetector, lateral distance at mouth depth, PeakHold per kind;
neck: chin from faceContour, downward path in upright space, NeckProfile, Z difference, PeakHold.
Publishes `MeasurementState { kind, current, maxTeeth, maxLips, maxNeck, points (sensor-normalized), status }` on main.

### Task 4: UI
Single `CameraPreviewView` behind a paged `TabView` of transparent pages `[neck, mouth, camera, depth]`
(camera selected at start). Overlays draw points via the preview layer's `layerPointConverted(fromCaptureDevicePoint:)`;
big MAX, current value, kind, status; tap resets that page. Page → `measurementMode`.

### Task 5: Device check with the user
Build, install, test both pages on the phone; adjust thresholds from what the overlay shows.
