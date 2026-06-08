# RTM (Roux Tactile Map) — Developer Guide

A practical guide to the **Roux Institute Map** feature in **TactileNav**. Read this before
adding to or changing it. It explains what each file does, how the pieces connect, the current
interaction model, rendering settings, and where to make common changes.

> Everything here is prefixed **`RTM`** (Roux Tactile Map) so it never clashes with the rest of
> the app. The feature is additive: it adds files + one row in `ContentView`; it does not change
> the other TactileNav screens.

---

## 1. What it is (in one paragraph)

A custom **MKMapView** (Apple's map widget with Apple's tiles hidden behind a **system-background
tile overlay**) that shows the Roux Institute neighborhood as thick colored lines (streets),
orange dots (intersections), and red pins (places). It follows the **Nav-Indoor / Indoor_Route**
design: the map **does not move** while you explore — the user's **finger is the cursor**.
Wherever the finger touches/drags, that exact point triggers feedback; as it crosses
streets/intersections/places the phone **buzzes** and **speaks** ("Howie's Pub, on your right").
Off-street touches get a light slow tick. A **ring + arrow indicator** is drawn under the
fingertip while exploring. There is **no** moving location dot. **Page-turn panning** shifts the
camera when you reach a screen edge. Map data comes from bundled `roux_portland.json`, converted
from abstract local metres to real latitude/longitude by `RTMDocumentAdapter`.

---

## 2. Where everything lives

Entry point: **ContentView → Section "Map" → "Roux Institute Map"** opens `RTMRouxMapView()`.

| File | Folder | Role |
|---|---|---|
| `RTMRouxMapView.swift` | `View/` | Screen: loads data, map + floating buttons + Options menu |
| `RTMLiveMapView.swift` | `View/` | MKMapView wrapper + `Coordinator` (gestures, zoom, page-turn, rendering) |
| `RTMMapOverlays.swift` | `View/` | System-background tile + street polylines + per-road-type styling |
| `RTMMapAnnotations.swift` | `View/` | Place pins, intersection dots, fingertip touch indicator |
| `RTMMapFeedbackController.swift` | `Services/` | Hit detection → buzz/speak; page-turn summaries; CSV logging |
| `RTMDocumentAdapter.swift` | `Model/` | JSON `TactileMapDocument` → RTM models; projects metres → lat/lon |
| `RTMFunctionalZoomLevel.swift` | `Model/` | Three zoom levels (distance + visible features + street width scale) |
| `RTMEdgeDirection.swift` | `Model/` | Cardinal directions for page-turn panning |
| `RTMDiscoveredStreet.swift` | `Model/` | Data model for one street (+ `RTMRoadType`) |
| `RTMDiscoveredIntersection.swift` | `Model/` | Data model for one intersection |
| `RTMDiscoveredPOI.swift` | `Model/` | Data model for one place |
| `RTMPOICategory.swift` | `Model/` | Place categories → pin icon + readable label |
| `TactileNavApp.swift` | app root | `AppDelegate` reads `RTMOrientationLock.mask` for portrait lock on map |

Data file: `TactileNav/Model/roux_portland.json`.

Package modules used: **TactileMapCore**, **TactileMapFeedback**, **TactileMapLogging**. RTM does
**not** use the **TactileMapView** module — it has its own `RTMLiveMapView`. There is no
`TactileMapKit` umbrella import; always import sub-modules individually.

---

## 3. Data flow (how a touch becomes a buzz)

```
roux_portland.json  (abstract metres, TactileMapDocument format)
        │  TactileMapDocument.load(...)            ← TactileMapCore
        ▼
RTMDocumentAdapter.convert(document)               ← projects metres → real lat/lon
        │  returns Result(streets, intersections, pois)   [Sendable, off main thread]
        ▼
RTMRouxMapView  (phase = .loaded(...))
        │  passes the 3 lists down
        ▼
RTMLiveMapView (UIViewRepresentable)
        │  builds MKMapView: tile overlay + street polylines + pins/dots
        │  creates RTMMapFeedbackController(streets, intersections, pois)
        ▼
User touches/drags one finger ──► Coordinator.handleExplore (zero-delay long-press)
        │  finger point → coordinate (RAW — no path snapping)
        │  ring+arrow indicator at raw screen point; travel heading from movement
        ▼
RTMMapFeedbackController.update(at: coordinate, heading:)
        │  nearestFeature(): POI > intersection > street (filtered by zoom level)
        │  on ENTER of new feature: haptic + speak (+ CSV row)
        │  off-path: light slow tick pattern
        ▼
TactileMapFeedback engines  (CoreHapticsEngine, AVSpatialAudioEngine / VoiceOver announce)
```

---

## 4. Each file in depth

### `RTMRouxMapView.swift` — the screen

- `Phase` enum: `.loading`, `.loaded(streets,intersections,pois)`, `.failed(message)`.
- `load()` parses on `Task.detached`, sets phase on main actor, posts VoiceOver `.screenChanged`.
- `mapContent` is a `ZStack`: full-screen `RTMLiveMapView` (`.ignoresSafeArea()`), floating
  controls, and `BackSwipeDisabler` background.
- **Transparent navigation bar:** `.toolbarBackground(.hidden, for: .navigationBar)` so the map
  extends behind the title/back button.
- **Controls:** **Zoom in (+)**, **Zoom out (−)**, **Options (…)**. Each uses `sendCommand()` —
  resets `command` to `.none` then sets the new command so repeated taps always fire.
- **Options menu:** Next point of interest (detail zoom only), Go north/south/east/west (page
  turn), Go back, Center map, Fit whole area. **No** "Next intersection" item.
- **`BackSwipeDisabler`:** `UIViewControllerRepresentable` that walks the responder chain in
  `viewDidAppear` to find `UINavigationController` and disable `interactivePopGestureRecognizer`.
  Re-enables on disappear.
- **`RTMOrientationLock`:** locks portrait while the map is visible; `TactileNavApp` `AppDelegate`
  returns `RTMOrientationLock.mask` from `supportedInterfaceOrientationsFor`.

### `RTMLiveMapView.swift` — the map + Coordinator

- **`RTMMapCommand`:** `.none`, `.fitFeatures`, `.centerOnUser`, `.zoomIn`, `.zoomOut`,
  `.moveTo(lat,lon)`, `.pan(direction)`, `.pageTurn(direction)`, `.goBackPage`.
- **`makeUIView`:** builds `RTMMapKitView`, disables all built-in map gestures, sets VoiceOver
  Direct Touch, muted `MKStandardMapConfiguration` (no POIs/traffic), `showsBuildings = false`,
  `backgroundColor = .systemBackground`, adds `RTMWhiteTileOverlay` at `.aboveLabels` with
  `canReplaceMapContent = true`, street polylines, annotations, gesture recognizers.
- **Gestures (no pinch, no two-finger pan):**
  - **Explore:** zero-delay `UILongPressGestureRecognizer` — finger is cursor; map stays fixed.
  - **Triple tap (1 finger):** cycles zoom Overview → Streets → Detail → Overview.
  - **Double tap (1 finger):** page turn when `pendingPageTurn` is set (after edge announcement).
  - **Double tap (2 fingers):** undo last page turn (`viewHistory`).
  - Recognizer priority: `pageTurn.require(toFail: zoomCycle)`, `explore.require(toFail: pageTurn)`,
    `explore.require(toFail: zoomCycle)`.
- **`handleExplore`:** raw finger coordinate (no `snappedToPath`). On lift, keeps `pendingPageTurn`
  for 3 seconds so user can double-tap to page-turn.
- **`performPageTurn`:** shifts camera 80% of viewport in direction; zoom-aware `clampPanCenter`;
  nudges toward features after 0.5s if view is sparse; announces orientation anchor.
- **`applyZoomLevel`:** sets camera distance, clamps center, updates feature visibility,
  `refreshStreetRenderers`, nudges toward features after 0.3s.
- **`clampPanCenter`:** insets pan boundary by viewport size so close zoom cannot show empty views.
- **`nudgeCameraTowardFeaturesIfNeeded`:** if fewer than 2 features on screen, shifts 70% toward
  nearest annotation/street midpoint.
- **`Coordinator`:** street renderers stored in `streetRenderers`; `rescale` / `refreshStreetRenderers`
  update line widths using `streetWidthScale`.
- **`RTMMapKitView`:** fires `onFirstLayout` once for initial camera setup.

### `RTMFunctionalZoomLevel.swift` — three zoom levels

| Level | Distance | Streets visible | Intersections | POIs | `streetWidthScale` |
|---|---|---|---|---|---|
| Overview | 1000 m | primary only | hidden | hidden | 0.65 |
| Streets | 300 m | all | shown | hidden | 0.45 |
| Detail | 120 m | all | shown | shown | 1.0 |

Opens at **Streets (300 m)** centred on data. Zoom via **+ / −** buttons or **triple tap**.

### `RTMMapFeedbackController.swift` — feedback brain

- Priority: **POI > intersection > street** within radii **18 / 20 / 12 m**.
- Only fires on **enter** of a new feature (`activeID` debounce).
- **Off-path:** slow light tick when cursor leaves all features.
- **Places:** speak name + "on your left/right" using precomputed geometric side, flipped for travel
  direction.
- **`announce(_:)`:** VoiceOver ON → `UIAccessibility.post` only; OFF → `audio.speak()` only
  (avoids double speech).
- **Page-turn:** `featuresOffScreen`, `announceEdgeEntry`, `announcePageTurn`, `findOrientationAnchor`.
- **`snappedToPath` / `nearestPointOnPath`:** still used for **POI pin anchoring**, not explore cursor.
- **CSV logging:** `RouxTactileExplorer_<timestamp>` via `CSVTouchLogger`; view in **Data Files**.

### `RTMDocumentAdapter.swift`

- Projects JSON metres around Roux centre (`43.679992`, `-70.2557`); `flipNorthUp = true`.
- Does **not** use package `CoordinateTransform` (stretches vertically).
- Skips `crossing` / `traffic_signal` as POIs.

### `RTMMapOverlays.swift`

- `RTMWhiteTileOverlay`: `canReplaceMapContent`, `minimumZ = 0`, `maximumZ = 30`.
- `RTMWhiteTileRenderer`: fills tiles with `UIColor.systemBackground`.
- `RTMRoadType.renderStyle`: primary **14 m** blue; residential/service **11 m** blue; footway
  11 m green; path/cycleway 7 m dashed; steps 5 m dotted.

### `RTMMapAnnotations.swift`

- Red POI pins (on-path anchor), orange intersection dots (max 20 pt at streets/overview, 34 pt at
  detail).
- `RTMTouchIndicatorView`: yellow ring + white dot + direction arrow at fingertip.

---

## 5. Current interaction model

| Gesture / control | Behavior |
|---|---|
| **One-finger drag** | Explore — map fixed; finger is cursor; raw position (no snapping) |
| **Off street** | Light slow tick haptic |
| **Finger at edge (50 pt)** | Announce off-screen content; enable page-turn double-tap |
| **One-finger double-tap** | Page turn 80% (only if edge was announced; within 3 s of lifting) |
| **Two-finger double-tap** | Go back to previous camera position |
| **Triple tap (1 finger)** | Cycle zoom: Overview → Streets → Detail → Overview |
| **+ / − buttons** | Step zoom one level |
| **Options → Go N/S/E/W** | Page turn in that direction |
| **Options → Go back** | Undo page turn |
| **Options → Next POI** | Jump camera to next place (detail zoom only) |
| **Options → Center / Fit** | Recenter on data centre / fit whole area at overview |
| **VoiceOver three-finger swipe** | Page turn (via `accessibilityScroll`) |

**Removed / not present:** pinch zoom, two-finger pan, map rotation, path snapping during explore,
"Next intersection" menu item, moving location dot.

---

## 6. Rendering characteristics (exact current settings)

All values below match the code in `RTMMapOverlays.swift`, `RTMFunctionalZoomLevel.swift`,
`RTMLiveMapView.swift`, `RTMMapAnnotations.swift`, and `RTMMapFeedbackController.swift`.

### Map base

| Setting | Value | Source |
|---|---|---|
| Backend | Custom `MKMapView` (`RTMLiveMapView`) | — |
| Apple tiles | Hidden via `RTMWhiteTileOverlay` | `RTMMapOverlays.swift` |
| Tile fill | `UIColor.systemBackground` (adapts to light/dark) | `RTMWhiteTileRenderer` |
| Tile overlay | `canReplaceMapContent = true`, `minimumZ = 0`, `maximumZ = 30` | `RTMWhiteTileOverlay.init` |
| Overlay level | `.aboveLabels` | `RTMLiveMapView.makeUIView` |
| Map config | `MKStandardMapConfiguration(emphasisStyle: .muted)`, POIs excluded, traffic off | `makeUIView` |
| Map view extras | `backgroundColor = .systemBackground`, `showsBuildings/Compass/Scale = false` | `makeUIView` |
| Coordinates | Real lat/lon after `RTMDocumentAdapter.convert` | `RTMDocumentAdapter.swift` |

### Functional zoom levels

| Level | Camera distance | Streets visible | Intersections | POIs | `streetWidthScale` |
|---|---|---|---|---|---|
| **Overview** | 1000 m | Primary only | Hidden | Hidden | **0.65** |
| **Streets** | 300 m | All | Shown | Hidden | **0.45** |
| **Detail** | 120 m | All | Shown | Shown | **1.0** |

- Opens at **Streets (300 m)** centred on data centre (`exploreCenter`).
- Camera clamp range: **120 m – 1000 m** (`detail.cameraDistance` … `overview.cameraDistance`).
- Street/intersection/POI visibility toggled in `updateFeatureVisibility` and hit detection respects
  `currentZoomLevel`.

### Streets (`RTMRoadType.renderStyle`)

Screen width formula (in `RTMLiveMapView.Coordinator`):

```
lineWidth = clamp( groundWidthMeters × streetWidthScale × pointsPerMeter , 2.5 , 60 )
```

`pointsPerMeter` = `mapView.bounds.width / visibleMetersAcross`. Line cap/join: **round**.

| Road type | Color | Base ground width | Dash pattern |
|---|---|---|---|
| **primary** | `systemBlue` | **14 m** | solid |
| residential, service | `systemBlue` | 11 m | solid |
| footway | `systemGreen` | 11 m | solid |
| path | `systemGreen` | 7 m | `[10, 8]` |
| cycleway | `systemTeal` | 7 m | `[10, 8]` |
| steps | `brown` | 5 m | `[2, 6]` |

Widths refresh on zoom change via `refreshStreetRenderers` (invalidates paths + `rescale`).

### Intersections (`RTMIntersectionAnnotationView`)

| Setting | Value |
|---|---|
| Fill | `systemOrange` circle |
| Border | **2 pt** white |
| Base frame | **8 mm** (`PhysicalDimensions.mmToPoints(8.0)`) |
| Ground diameter | **12 m** (scales with zoom) |
| Screen clamp | min **8 pt**; max **20 pt** (overview/streets) or **34 pt** (detail) |
| Visibility | Streets + Detail only |

### Places / POIs (`RTMPOIAnnotation`)

| Setting | Value |
|---|---|
| View | `MKMarkerAnnotationView` |
| Tint | `systemRed` |
| Glyph | Category SF Symbol (`RTMPOICategory.symbolName`) |
| `displayPriority` | `.required` (never hidden by MapKit overlap rules) |
| Pin coordinate | On-path anchor via `nearestPointOnPath` (not raw POI location) |
| Visibility | **Detail zoom only** |

### Finger cursor (`RTMTouchIndicatorView`)

Plain `UIView` subview (not an annotation). Shown only during one-finger explore.

| Element | Setting |
|---|---|
| View size | 80 × 80 pt |
| Ring | Radius **20 pt**; fill yellow RGB(1, 0.88, 0) α **0.28**; stroke white α **0.9**, **2.5 pt** |
| Centre dot | Radius **5 pt**, white |
| Arrow | White triangle; whole view rotates to finger heading (radians, 0 = up) |

### Hit detection (feedback — not visual)

Used by `RTMMapFeedbackController.nearestFeature`. Priority: **POI > intersection > street**.

| Feature | Radius |
|---|---|
| POI | **18 m** |
| Intersection | **20 m** |
| Street | **12 m** |

Off-path: light slow tick (`offPathPattern`) when no feature is within range.

### Camera bounds & empty-view prevention

| Setting | Value |
|---|---|
| Pan boundary | Feature bounding rect + **15%** padding per side (`paddedFeaturesRect`) |
| Zoom-aware clamp | `clampPanCenter` insets boundary by ~**40%** of viewport so close zoom cannot show empty tiles |
| Sparse-view nudge | If fewer than **2** features on screen after zoom/page-turn, camera shifts **70%** toward nearest feature |
| Page-turn shift | **80%** of current `region.span` per axis |

### Not rendered

- No location dot (finger is the cursor)
- No Apple street labels, highway shields, or base-map tiles
- No user-location pin (`showsUserLocation = false`)
- Intersections hidden at overview
- POIs hidden until detail zoom

---

## 7. How to make common changes (cookbook)

- **Change zoom distances / visibility:** `RTMFunctionalZoomLevel.swift` (`cameraDistance`,
  `isStreetVisible`, `showIntersections`, `showPOIs`, `streetWidthScale`).
- **Change street colors / widths:** `RTMRoadType.renderStyle` in `RTMMapOverlays.swift`.
- **Change finger-cursor look:** `RTMTouchIndicatorView` in `RTMMapAnnotations.swift`.
- **Tune hit radii:** `poiRadius` / `intersectionRadius` / `streetRadius` in
  `RTMMapFeedbackController`.
- **Change haptic strength per road:** `streetPattern(for:)` in `RTMMapFeedbackController`.
- **Change page-turn shift amount:** `performPageTurn` lat/lon shift (currently 80% of span).
- **Change edge zone size:** `edgeZone` in `RTMLiveMapView.Coordinator` (default 50 pt).
- **Map upside-down:** flip `flipNorthUp` in `RTMDocumentAdapter`.
- **Different data file:** change `"roux_portland"` in `RTMRouxMapView.load()`.
- **CSV logs:** `RTMMapFeedbackController` → **Data Files** screen.

---

## 8. Design direction (status)

- ✅ **Finger is the cursor** — no dot; raw finger position; ring + arrow indicator.
- ✅ **Map locked during explore** — built-in scroll/zoom/rotate off.
- ✅ **Page-turn panning** — edge detection + double-tap + Options menu + VO three-finger swipe.
- ✅ **Functional zoom (3 levels)** — UAHCI-style overview / streets / detail.
- ✅ **VoiceOver Direct Touch** — one-finger explore passes through to map gestures.
- ✅ **Off-path feedback** — tick when not on a feature.
- ✅ **Empty-view prevention** — zoom-aware clamp + nudge toward features.
- ✅ **No Apple Maps leak** — muted config + tile overlay at `.aboveLabels`.

---

## 9. Gotchas

- **Initial camera after layout** — `RTMMapKitView.onFirstLayout`; do not move setup to `updateUIView`.
- **JSON is abstract metres** — only valid after `RTMDocumentAdapter.convert`.
- **`sendCommand` pattern** — menu/button commands must reset `.none` first or SwiftUI may ignore repeats.
- **`BackSwipeDisabler`** — uses a hidden `UIView` + `findHostingViewController()?.navigationController`;
  a separate `UIViewControllerRepresentable` will not find the nav stack.
- **Physical iPhone** — haptics need hardware; Simulator renders map only.

---

## 10. Build & run

Open `TactileNav.xcodeproj`, pick a **real iPhone**, Run → **Map → Roux Institute Map.**

**Touch and drag one finger** to explore. **Triple tap** to cycle zoom. **+ / −** to step zoom.
Drag to a screen edge, lift, **double-tap within 3 seconds** to turn the page. Use **Options (…)** for
page turns, next place, center, or fit. **Two-finger double-tap** to go back.
