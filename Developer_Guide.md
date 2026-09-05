# TactileNav — Developer Guide

This is the deep-dive companion to `CLAUDE.md` and `README.md`. Where those explain *what* the app is
and *why* its physical constants are what they are, this document explains *how the code actually
works* — file by file, function by function, with the real data flow through both screens — and lists
every concrete inconsistency found while reading the source, so you know what's solid ground and what
to be careful copying as a pattern.

Read `README.md` first for the product rationale. Read this for the mechanics.

---

## 1. Project wiring

`TactileNav.xcodeproj` depends on `Packages/TactileMapKit` as a **local path package**
(`XCLocalSwiftPackageReference`, `project.pbxproj:600-604`, `relativePath = Packages/TactileMapKit`) —
not a remote git dependency. Only the umbrella product `TactileMapKit` is linked into the app target's
Frameworks phase (`project.pbxproj:607-611`), but the app never writes `import TactileMapKit` anywhere;
every file imports the specific sub-module it needs (`import TactileMapCore`, `import TactileMapFeedback`,
etc.). This works because the umbrella product transitively re-exposes the four underlying targets — the
umbrella import is link-only plumbing.

`Packages/TactileMapKit/Package.swift`: `swift-tools-version 5.9`, `.iOS(.v16)` only. Four library
targets, each independently importable:

```
TactileMapCore        (no target deps)
TactileMapFeedback  → TactileMapCore
TactileMapView      → TactileMapCore, TactileMapFeedback
TactileMapLogging   → TactileMapCore
```

Three test targets: `TactileMapCoreTests`, `TactileMapFeedbackTests`, `TactileMapViewTests`.

**Important nuance:** `TactileMapCore`'s comment claims "zero UIKit dependency," but
`PhysicalDimensions.swift` does `#if canImport(UIKit) import UIKit` and calls `UIScreen.main.scale`,
`UIScreen.main.nativeBounds`, `UIDevice.current.userInterfaceIdiom`. The `#if` guard keeps it
cross-platform-compilable, but at runtime on iOS this target absolutely touches UIKit. Don't take the
comment at face value if you're evaluating whether this module is portable.

---

## 2. Navigation root

`TactileNavApp.swift` — `AppDelegate` (an `NSObject, UIApplicationDelegate`) forces `.portrait` only,
because panning is calibrated to physical millimetres and rotation would disorient someone exploring by
touch. `@main TactileNavApp` hosts a single `ContentView()`.

`ContentView.swift` is the only navigation root: a `NavigationStack` → `List` with two sections —

- **Maps**: `PortlandMapScreen()` (Congress Square), `SpatialAudioSimulationView()` (Street Crossing Audio)
- **Tools**: `FeedbackCustomizationTesterView()`, `FilesListView()` — dev/debug screens, not part of the
  user-facing product

---

## 3. Data model layer (`Model/`)

### `StreetMapSizing.swift` — the physical-mm constants for the street map

`StreetMapSizing` is an enum namespace holding every size constant for Congress Square:

- `laneWidthMM = 4.0` — the perceptual line-width constant (not derived from real lane width)
- `blockSpacingMM = 40.0`, with real-world references `laneWidthMeters = 3.3`, `blockLengthMeters = 120.0`
  used only to *derive* `pointsPerMeter` — never to size the drawn line
- `roadHitRadius = 22`, `intersectionBoxMM = 6.0`, `intersectionBorderMM = 0.5`,
  `intersectionClusterMeters = 25`
- Colors: `roadColor` (#023E8A), `intersectionColor` (#c1121f), `labelColor`, `labelFontSize = 13`
- `Metrics: Sendable` — a snapshot struct (`pointsPerMeter`, `roadWidthPoints`, etc.) built via
  `@MainActor currentMetrics()` so it can cross into a background `Task`

### `StreetMapGeometry.swift` (741 lines — the largest app file)

This is where the map's data model, hit-testing, and junction-computation logic live.

- **`StreetFeature`** — one road polyline plus precomputed hit/draw bounds.
- **`Intersection`** — a computed junction (never present in the source data).
- **`MapProbe`** — `.road` / `.intersection`, carries an `id` for change-detection dedup.
- **`StreetLabel`** — a CoreText `CTLine` placement for a street name.
- **`StreetMap`** — the assembled map: `features`, `labels`, `intersections`, plus three
  `UniformGrid` spatial indices (feature grid cell=128pt, label grid=512pt, intersection grid=256pt).

**Loading (`StreetMap.build(document:extras:metrics:hitConfig:labelFont:)`, lines 213-323):**
1. Filters `document.features` to `element.elementType == .road` only — **sidewalks and crosswalks
   from the OSM extract are dropped right here**, not upstream.
2. Projects every coordinate from metres to points via `metrics.pointsPerMeter`.
3. Computes the overall content bounding box (this becomes `StreetMap.contentSize`, which is why the
   map is larger than any `CALayer` and has to be panned rather than zoomed).
4. Builds the three `UniformGrid` spatial indices.
5. Calls `computeIntersections(roads:metrics:)`.

**Junction computation (lines 339-460)** — this is the algorithm behind the README's "computed from the
road geometry" claim:
1. Bucket every road segment into a 256pt grid cell.
2. Only test segment pairs that share a cell (`segmentCrossing`) — this is what keeps the algorithm
   fast across ~500+ roads instead of being O(n²) over the whole network.
3. Skip crossings between two segments that carry the *same* street name (line 376) — a street split
   into multiple OSM ways is not a junction with itself.
4. `clusterCrossings` (393-460) unions nearby crossing points within `metrics.intersectionClusterPoints`
   (derived from `intersectionClusterMeters = 25`) using a flood-fill/union-find approach, then drops any
   cluster that only names one street (line 440's `names.count >= 2` guard) — this is the invariant the
   unit test `aStreetDoesNotIntersectItself` locks in.

**Hit-testing entry points** (used directly by the touch pipeline in §5):

```swift
StreetMap.probe(at: CGPoint, velocity: CGFloat) -> MapProbe?   // lines 156-171
StreetMap.feature(at: CGPoint, velocity: CGFloat) -> StreetFeature?  // lines 134-148
```

`probe(at:velocity:)` checks the intersection grid first (`intersectionIndex.candidates(near:radius:)`),
falls back to `feature(at:velocity:)` if nothing's within range — this is the mechanism behind
"a junction outranks the road beneath it." Both compute a velocity-adaptive catch radius:
`bonus = min(velocity / hitConfig.velocityDivisor, hitConfig.velocityBonusMax)` — a fast drag samples
farther apart between touch events, so the radius has to grow or a fast finger steps clean over a 4mm
line without ever registering it.

**Free functions at file scope** (not namespaced, `nonisolated`, reused by `IntersectionLayout` too):
`boundingBox`, `distanceToSegment`, `distanceToPolyline`, `closestPointOnPolyline`, `polylineMidpoint`,
`segmentsIntersect`, `segmentCrossing`, `pointAlongPolyline`, `polylineLength`.

**`UniformGrid`** (lines 573-628) — a flat spatial hash grid with `candidates(near:radius:)` and
`candidates(intersecting:)`. This is the thing that makes hit-testing "arithmetic rather than a
per-vertex conversion," per the README.

### `PortlandMapLoader.swift`

- `StreetMapExtras: Decodable` — a second decode pass over `congress_square.json` for metadata the
  shared `TactileMapMetadata` type doesn't carry (`initial_center`, `bbox`, `source`).
- `LoadContext: @unchecked Sendable` (lines 74-86) — a `@MainActor`-built snapshot of
  `StreetMapSizing.Metrics` + a `CTFont`. This exists specifically so `loadStreetMap(context:)` can run
  off the main actor inside `Task.detached` (see `PortlandMapScreen.load()`), because parsing hundreds
  of features and computing ~490 junctions is real work you don't want blocking the main thread on
  first launch.
- `loadStreetMap(context:)` calls `TactileMapDocument.load(from: "congress_square", bundle:)` (from
  TactileMapCore) then `StreetMap.build(document:extras:metrics:labelFont:)`.

### `IntersectionLayout.swift` — the schematic junction geometry (Street Crossing screen)

- `IntersectionSurface` enum: `.road` / `.sidewalk` / `.crossing`, each mapping to a
  `TactileElementType` (`.road`, `.street`, `.crosswalk`) and a `.priority` (crossing=2 > sidewalk=1 >
  road=0) used to break ties when a finger lands where surfaces would otherwise overlap.
- Constants: `roadWidthMM=12`, `sidewalkWidthMM=4`, `crossingWidthMM=2.8`, `crossingBarLengthMM=1.4`,
  `crossingBarCount=3`, `kerbGapMM=1.0`, and a *computed* `sidewalkOffsetMM` (11.8mm — derived from half
  the roadway + crossing + kerb + half the sidewalk, not picked by hand; see the README section on this).
- `build(size:alongName:acrossName:)` (lines 124-209) constructs 2 road bands + 8 sidewalk bands
  (2 per roadway, broken at the junction so corners read as corners) + 4 crossing bands, forming a
  schematic axis-aligned plus-shape — **not** a projection of the real street bearings. That distinction
  matters for §5.2 below.
- `hit(_:)` (217-235) does nearest-segment lookup via `distanceToSegment` — imported from
  `StreetMapGeometry.swift`, a cross-file dependency worth knowing about if you ever split these files
  apart — with an 8pt tie-break applied via `.priority`.

### `IntersectionCrossingModel.swift` (442 lines) — traffic + signal simulation

- `DemoIntersection` — an enum namespace of static geometry constants for the *real* Congress/High
  intersection: bearings (43°/240°/320°/145°), `listenerPositionM`, `crosswalkCenterM`. This is the
  "real bearings" the README refers to — a completely separate geometric model from `IntersectionLayout`'s
  schematic drawing.
- `IntersectionLeg` — 4 cases, each with `.bearing`, `.street`, `.phase`, `.opposite`.
- `SignalPhase` — `Kind` enum (`.green(Movement)` / `.allRed`); static `cycle` array
  (18s green / 4s all-red / 18s green / 4s all-red = 44s total); `phase(at:)` static lookup;
  `isWalkPhase` (walk only ever coincides with the parallel-street green).
- `SimulatedVehicle` — a value struct; `position(legLength:)` / `worldPosition(legLength:)` do the
  actual lane-curve math (walk the entry lane → quadratic Bézier turn or straight-through at the
  junction centre → exit lane, all rotated into the listener's frame using `DemoIntersection`'s bearings).
- `IntersectionCrossingModel` (`@MainActor final class`) — owns `vehicles`, `elapsed`, `fleet`;
  `advance(by:)` spawns/ages/retires vehicles per tick and returns departed vehicles so their audio
  voices can be freed.

### `HapticFeedbackSelection.swift` — dead-end taxonomy (flagged in §7)

`MapElementType` (corridor/intersection/landmark) and `HapticPatternType` (5 presets) exist **only** to
back the "Feedback Customization Tester" dev tool. They are not the vocabulary the real screens use
(which is road/street/crosswalk, from `TactileElementType`), and selections made here are never read by
either real feedback controller. Don't mistake this for the real haptic taxonomy.

---

## 4. TactileMapKit — what's actually used vs. what's vendored but unused

The package ships a full outdoor+indoor tactile mapping toolkit. TactileNav uses a narrow slice of it.
Knowing the boundary matters because most of the package's own `TactileMapView` machinery is present in
the repo but **dead code from the app's point of view**.

| Module | Consumed API | Not used by the app |
|---|---|---|
| **TactileMapCore** | `TactileMapDocument.load(from:bundle:)`, `MapElement`/`TactileGeometry`, `TactileElementType`, `PhysicalDimensions.mmToPoints`, `TactileMapDiagnostics` | `CoordinateTransform`, `DepartureZone` — no call sites anywhere in the app |
| **TactileMapFeedback** | `CoreHapticsEngine`, `HapticPattern` (only `.heavyBuzzContinuous`, `.streetContinuous`, `.intersectionPulse`, `.singleTap` actually used), `OutdoorFeedbackPolicy` (subclassed once), `SpatialAudioEngine` protocol (conformed to, not used via the shipped `AVSpatialAudioEngine` implementation) | `.crosswalkTick`, `.routePulse`, `.corridorContinuous`, `.landmarkFastPulse` presets exist but aren't wired to anything; `AVSpatialAudioEngine` itself is never instantiated |
| **TactileMapView** | Only `HitDetectionConfig` (the tuning-constant struct: `corridorBaseRadiusPts=20`, `velocityBonusMax=30`, `velocityDivisor=30`, `updateThreshold=0.1`) | `TactileMapView` itself, `CanvasMapView`, `CanvasHitDetector`, `MapCoordinator`, `AccessibleMapView`, `DefaultElementRenderer`, `AnchorAnnotation`, `FeatureAnnotation`, `BlankTileOverlay`, `ElementStyle`, `TactileMapViewConfiguration`, `AccessibleCanvasHost`, `HitDetector`, `NavigationHelper` — none imported anywhere in the app |
| **TactileMapLogging** | `CSVTouchLogger`, `TouchEvent`, `TouchEventType` | `FileManagerView` — the package's ready-made logs UI; the app reimplements its own instead (see §7.2) |

**The headline fact for onboarding:** the app only imports `TactileMapView` for one tuning-constant
struct. Both real screens render themselves with a hand-rolled `UIScrollView` + `Canvas`/`UIView` stack
(`PortlandMapView.swift`, `PortlandStreetCanvasView.swift`, `IntersectionTactileView.swift`) because both
need continuous two-finger panning with momentum over content far larger than a `CALayer` can back —
something the package's `TactileMapView` doesn't provide. Don't go looking for the map's rendering logic
inside the package; it's entirely in the app.

---

## 5. Full data-flow traces

### 5.1 Congress Square: one touch, start to finish

```
finger down
  → PortlandStreetScrollView.touchesBegan  (PortlandMapView.swift:115-130)
      guards: exactly 1 active touch, not mid-pan/decelerating
      records exploreTouch/exploreStartedAt/exploreStartPoint
      calls onExploreBegan?(point)
  → Coordinator.exploreBegan(at:)  (PortlandMapView.swift:706-720)
      startLoggingIfNeeded()
      feedback.beginExploring()          // drops the screen-entry speech hold
      updateExploration(at: point, velocity: 0)
      logTouch(.touchDown, at: point, probe: currentProbe)
      shows the yellow follow-dot
  → Coordinator.updateExploration(at:velocity:)  (793-809)
      → StreetMap.probe(at:velocity:)  (StreetMapGeometry.swift:156-171)
          checks intersectionIndex.candidates(near:radius:) first
          falls back to feature(at:velocity:) against the road UniformGrid
      → if the resolved id changed since currentProbeID:
          .intersection → feedback.enterIntersection(identifier:announcement:)
          .road         → feedback.enter(identifier:announcement:)
          nil           → feedback.leaveAll()
        (feedback == StreetFeedbackController.shared)

HAPTICS  (StreetFeedbackController.enter, StreetFeedbackPolicy.swift:250-261)
  guards on identifier change → haptics.stopAll() → policy.onEnter(StreetSurfaceElement, .direct)
  → StreetFeedbackPolicy.onEnter (lines 56-64)
      hapticEngine.start(pattern: .heavyBuzzContinuous)   // CoreHapticsEngine → advanced continuous player
      audioEngine.speak(element.properties.name)

SPEECH  (TactileSpeechChannel.speak, StreetFeedbackPolicy.swift:131-142)
  cancels any pending utterance → checks suppression
  schedules a DispatchWorkItem after dwell = 0.2s
  → utter(_:) (181-193): UIAccessibility.post(.announcement) if VoiceOver is on,
    else a fresh AVSpeechUtterance via AVSpeechSynthesizer

finger moves
  → touchesMoved → onExploreMoved → Coordinator.exploreMoved(to:)  (722-735)
      hit-test throttled to hitConfig.updateThreshold (0.1s)
      repeats the probe/dispatch/haptic/speech steps above on element change
      logTouch(.touchMove, ...)   // further throttled inside CSVTouchLogger by samplingInterval=0.1s
      follow-dot moves every frame regardless of hit-test throttling

CSV LOGGING  (Coordinator.logTouch, PortlandMapView.swift:512-549)
  builds a TouchEvent(timestamp, sessionElapsed, eventType, elementName, elementType, touchPoint, custom)
  → logger.logEvent(_:)  (CSVTouchLogger.swift:108-153)
      always writes touchDown/touchUp; throttles touchMove
      appends a line: Time Stamp, Trial Time, Touch Event, Object Type, Touch X, Touch Y, + custom keys

finger up
  → touchesEnded → onExploreEnded → Coordinator.exploreEnded()  (737-747)
      logs .touchUp, isExploring = false
      feedback.stopAll()   // cancels haptics + tone + pending speech
      clears probe state, hides the dot
```

The **intersection path** differs only in the haptic/speech step: `enterIntersection` plays
`.intersectionPulse` (1.0/0.5 intensity/sharpness, 0.15s-on/0.10s-off pulsing) and starts a repeating
1120 Hz tone via `ToneGenerator.playRepeatingTone`, alongside the same dwell-gated speech call.

### 5.2 Street Crossing Audio: traffic + signal simulation

```
SpatialAudioSimulationView.start()  (lines 138-147)
  audio.activate()          // TrafficAudioEngine: AVAudioSession .playback/.mixWithOthers,
                            // builds 6 player→pitch→mixer voice chains, engine.start()
  model.reset(); model.fleet = fleet
  starts a 60 Hz Timer → tick()

tick()  (157-214), each frame:
  delta = min(now - lastTick, 0.1)
  model.advance(by: delta)   // IntersectionCrossingModel.advance, lines 288-320
    advances elapsed
    detects a signal-phase change via SignalPhase.phase(at: elapsed)
    on green transition: spawns 2-3 vehicles at once for whichever Movement just turned green
    continues a slower trickle spawn through the green
    returns vehicles that travelled > legLengthM*2, for voice release

  for each live vehicle  (model.updateEachVehicle, 169-199):
    lazily audio.acquireVoice(type:) — claims a Voice, schedules a looping synthesized tone
    position = vehicle.position(legLength:)   // walks entry lane → Bézier turn/through → exit lane,
                                              // in the listener's frame using DemoIntersection bearings
    Doppler cents = one-frame finite-difference of radial distance, via 1200*log2(343/(343-closing)),
                    clamped ±400
    pan  = position.x / distance
    volume = 6.0 / distance, scaled by vehicle.type.loudness
    audio.updateVoice(voice, pan:volume:cents:)   // sets player.pan/.volume, pitch.pitch (±2400 clamp)

  nearestCents republished to @State at most every 0.25s (avoids 60Hz SwiftUI/VoiceOver churn)
  isWalkPhase only written on actual change, same reason

IN PARALLEL — tactile diagram (completely separate code path):
  IntersectionTactileView(alongName:, acrossName:, speaks: !running)
    IntersectionTouchView.rebuild() → IntersectionLayout.build(...)   // the SCHEMATIC axis-aligned plus
    touches → IntersectionFeedbackController.enter(id:surface:name:speaking:)
      road → .heavyBuzzContinuous, sidewalk → .streetContinuous, crossing → a LOCAL inline crossingTick
      pattern (see §7.3 — this differs from the package's HapticPattern.crosswalkTick)
    speech only fires when speaks == true, i.e. only while traffic is stopped — so the diagram and the
    traffic audio never talk over each other

stop()  (149-155): invalidates the ticker, audio.releaseAllVoices(), model.reset()
.onDisappear { stop() } — so the engine doesn't keep looping tones after navigating away
```

**Key thing to internalize:** `IntersectionLayout` (the drawn/touched geometry) and
`IntersectionCrossingModel`/`DemoIntersection` (the vehicle physics) are two independent geometric
models of the same intersection — one schematic and axis-aligned for a fingertip, one using the real
43°/240°/320°/145° OSM bearings for spatial audio. `IntersectionLayout.swift`'s file header documents
this divergence as intentional. Don't try to unify them; a finger tracing a leg wants a straight line
and all four legs equal length, which the real bearings would not give you.

---

## 6. View layer map

| File | Role |
|---|---|
| `PortlandMapScreen.swift` | SwiftUI host: async-loads the `StreetMap` off-main via `Task.detached`, shows loading/ready/failed states, calls `StreetFeedbackController.shared.stopAll()` on disappear |
| `PortlandMapView.swift` (812 lines) | The real controller: `PortlandStreetScrollView` (raw-touch exploration + 2-finger pan), `PortlandStreetMapContainerView` (canvas below a transparent scroll view over an empty sized `spacer`), `Coordinator` (hit-testing dispatch, feedback, CSV logging, recentring, back-gesture handling) |
| `PortlandStreetCanvasView.swift` | Pure drawing: redraws only the viewport window (`bounds` inset by 64pt), order is roads → intersections → labels |
| `SpatialAudioSimulationView.swift` | SwiftUI host for the crossing screen: owns the `IntersectionCrossingModel`, the 60Hz ticker, the fleet/phase UI, wraps `IntersectionTactileView` |
| `IntersectionTactileView.swift` | `IntersectionCanvasView` (drawing), `IntersectionFeedbackController` (its own haptics+speech, separate from the map screen's), `IntersectionTouchView` (raw touch handlers) |
| `SwipeBackSuppression.swift` | `SwipeBackBlocker` (delegate that refuses both iOS pop gestures, including the iOS 18+ full-screen one via a private-selector reflection call), `SwipeBackSuppression` (apply/restore lifecycle) |
| `FeedbackCustomizationTesterView.swift` | Dev tool — haptic pattern preview, disconnected from the real feedback pipeline (see §7.4) |
| `FilesListView.swift` | Dev tool — CSV log browser, duplicates package functionality (see §7.2) |

---

## 7. Concrete inconsistencies and code smells

These were found by reading, not inferred — use this list to know what *not* to copy as a pattern, and
where a bug could be hiding if related behavior ever changes.

### 7.1 "Zero UIKit dependency" claim doesn't hold
`Package.swift` comments `TactileMapCore` as Foundation/CoreLocation/CoreGraphics-only, but
`PhysicalDimensions.swift` conditionally imports UIKit and CoreHaptics and uses `UIScreen`/`UIDevice` at
runtime on iOS. Harmless in practice (the app only runs on iOS), but don't assume this target is
UIKit-free if you ever try to reuse it somewhere that isn't.

### 7.2 `FilesListView` duplicates the package's `FileManagerView`
`TactileMapLogging` ships a ready-made `FileManagerView` (file list, share, delete). The app's
`FilesListView.swift` reimplements the same thing independently rather than using it. Functionally fine
(both read/write the same Documents-directory CSVs), but it's a maintenance duplication — a fix made in
one won't propagate to the other.

### 7.3 Two different "crossing tick" haptic patterns for the same concept
`IntersectionFeedbackController` (in `IntersectionTactileView.swift`) defines its own inline
`crossingTick` pattern (`.burst(pulseCount: 1, onDuration: 0.05, offDuration: 0.12)`) instead of reusing
`HapticPattern.crosswalkTick` from TactileMapFeedback (`.pulsing(onDuration: 0.05, offDuration: 0.12,
count: 50)`). These are similar-looking but structurally different haptic modes with different cadence.
There isn't a shared "crossing/crosswalk" haptic signature across the two screens despite both
nominally representing the same painted-marking concept.

More broadly: `IntersectionFeedbackController` hand-rolls its own road/sidewalk/crossing → pattern
dispatch instead of subclassing `OutdoorFeedbackPolicy` the way `StreetFeedbackPolicy` does for the map
screen — same mapping shape, implemented twice, independently.

### 7.4 `FeedbackCustomizationTesterView` is fully disconnected from the real pipeline
Its `HapticPreviewer` owns a raw `CHHapticEngine` and hand-builds `CHHapticPattern`s per
`HapticPatternType` case, rather than using `HapticPattern` + `CoreHapticsEngine`. The
`HapticFeedbackSelection`/`MapElementType`/`HapticPatternType` model (`Model/HapticFeedbackSelection.swift`)
that backs this tool's picker is never read by `StreetFeedbackPolicy` or `IntersectionFeedbackController`
— selecting a pattern here previews something that only approximately resembles what the real screens
play, and changing a selection has zero effect on the actual app. Treat this screen purely as a haptics
sandbox, not as a control surface.

### 7.5 `TactileSpeechChannel` has silent no-op protocol methods
`StreetFeedbackPolicy.swift`: `speak(_:configuration:)` and `speakSpatially(_:at:)` both just call the
plain dwell-gated `speak(_:)`, discarding the `configuration`/`position` argument entirely.
`playSpatialSound`/`playClickSound`/`registerSound` are empty-bodied no-ops. This satisfies the
`SpatialAudioEngine` protocol's shape but not its contract. Not currently exercised (the app never calls
those overloads), but if you add a call site expecting spatial positioning or a custom speech
configuration to work through this conformer, it silently won't.

### 7.6 Force-unwraps in audio buffer construction
`TrafficAudioEngine.swift` (`AVAudioFormat(...)!`, `AVAudioPCMBuffer(...)!`, `buf.floatChannelData![0]`)
and `ToneGenerator.swift` force-unwrap audio buffer allocations. These are on hardcoded, always-valid
parameters (fixed sample rate/channel count) so failure is practically unreachable, but they are
unguarded and would crash under extreme memory pressure.

### 7.7 Dead parameter
`PortlandStreetScrollView.endExplore(cancelled:)` accepts `cancelled` but never reads it in the body;
both call sites pass a value that has no effect beyond the unconditional `onExploreEnded?()` call.

### 7.8 Private API touchpoint
`SwipeBackSuppression.swift` calls `navigation.perform(NSSelectorFromString("interactiveContentPopGestureRecognizer"))`
to grab iOS 18's private full-screen pop gesture. Guarded by `responds(to:)` so it degrades gracefully
on OS versions without it, but it's a string-selector call to an undocumented API — Apple could rename
or remove it with no compile-time warning. Worth a comment or a regression test tied to new iOS betas.

### 7.9 CSV filename convention isn't enforced by the shared logger
`FilesListView.FileRowView`'s filename parser assumes exactly the `<MapName>_<yyyyMMdd>_<HHmmss>`
shape (3 underscore-tokens) that the map screen's custom `fileNameGenerator` produces. The package's own
default generator (`Session_{yyyyMMdd}_{HHmmss}_v{N}`) produces 4 tokens, which this parser was not
written to handle correctly — a latent bug that hasn't manifested only because just one logger
configuration is currently exercised.

### 7.10 Two independent `CSVTouchLogger` instances
`PortlandMapView.Coordinator` and `FilesListView` each construct their own `CSVTouchLogger`. They
happen to agree because both resolve to the same Documents directory, but there's no single owning
instance — a sign that the package's `CSVTouchLogger` conflates "session recorder" and "file manager"
responsibilities into one class, forcing the app to spin up a second instance purely to call
file-management methods (`getAllLogFiles`, `deleteFile`, `getFileSize`, `shareFile`).

### 7.11 Duplicated color constant
`IntersectionPalette.road` (`IntersectionTactileView.swift`) and `StreetMapSizing.roadColor` both
hardcode the same `#023E8A` independently. A future recolor would need updating both, with no compiler
link between them.

---

## 8. Where to make common changes

- **Change the map's line width or scale** → `StreetMapSizing.swift` (`laneWidthMM`, `blockSpacingMM`).
  Never derive one from the other — see the README's "Sizing" section and the unit test
  `mapScaleComesFromBlockSpacingNotLaneWidth`.
- **Change junction detection** → `computeIntersections`/`clusterCrossings` in `StreetMapGeometry.swift`.
  The 25m cluster radius and the "different name" guard are both load-bearing invariants with dedicated
  tests (`aStreetDoesNotIntersectItself`, `realIntersectionsAreFoundInTheRoadNetwork`).
- **Change street-map haptics/speech** → `StreetFeedbackPolicy.swift`. Remember `TactileSpeechChannel`
  is the sole speech gateway for that screen and has the dwell-gating logic; don't bypass it with a
  direct `AVSpeechSynthesizer` call or you'll reintroduce the stutter-on-sweep problem it exists to fix.
- **Change the crossing junction's schematic layout** → `IntersectionLayout.swift`. Remember this is
  deliberately *not* the same geometry as the traffic simulation (§5.2) — don't try to derive one from
  the other.
- **Change traffic/signal behavior** → `IntersectionCrossingModel.swift` (`SignalPhase.cycle`,
  `advance(by:)`) and `TrafficAudioEngine.swift` (voice pool, Doppler math).
- **Add a new screen with a tactile touch surface** → follow the pattern in
  `PortlandStreetScrollView`/`IntersectionTouchView`: raw `touchesBegan/Moved/Ended`, never a gesture
  recognizer for exploration, because VoiceOver's direct-interaction mode hands touches to the
  responder chain and recognizers on that view don't fire dependably. Test both VoiceOver states.

---

## 9. Testing

`TactileNavTests/TactileNavTests.swift` is Swift Testing (not XCTest) and is organized into four
`@MainActor struct`s worth knowing about when adding coverage:

- `CongressSquareMapTests` — data integrity, physical sizing, hit-testing, intersections, rendering
  (pixel-tallies a rendered frame to assert only road-blue and background-white appear, no leftover grey
  from sidewalks), panning, back-navigation, VoiceOver setup, exploration touch pipeline.
- `IntersectionCrossingTests` — the traffic simulation: stereo pan sweep for cross vs. parallel traffic,
  turning-vehicle dwell time, near/far lane distance separation, Doppler approach/recede curve, signal
  cycle timing, voice-pool ceiling, EV fleet loudness.
- `IntersectionLayoutTests` — the schematic junction geometry: band counts, physical widths, kerb-gap
  derivation, crossing bridging, hit-testing coverage, canvas pixel classification.

Run a single test:

```bash
xcodebuild test -project TactileNav.xcodeproj -scheme TactileNav \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -only-testing:TactileNavTests/CongressSquareMapTests/aFingerOnARoadFeelsTheRoad
```

Haptics and true VoiceOver behavior need a physical device; the simulator can run every test above but
proves nothing about actual vibration or spoken-word timing.
