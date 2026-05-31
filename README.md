# TactileNav

## Folder structure

```
TactileNav/
├── TactileNavApp.swift                  ← @main, just shows ContentView
├── ContentView.swift                        ← NavigationStack home screen
├── Model/
│   ├── demo_building.json                   ← the placeholder map (rectangle loop)
│   ├── custom_branch_map.json               ← map for the canvas demo
│   ├── custom_map_draft_1/2.json, _final.json
│   ├── roux_portland.json                   ← real OSM map: Roux Institute area, Portland ME
│   ├── HapticFeedbackSelection.swift        ← enums + defaults for haptic picker
│   └── StudyCondition.swift                 ← the 6 conditions + factory method
├── ViewModel/
│   └── MapViewModel.swift                   ← loads document + policy + logger
├── View/
│   ├── LandmarkStudyView.swift              ← MapKit-backed tactile map
│   ├── FeedbackCustomizationTesterView.swift← per-element haptic picker + map
│   ├── FilesListView.swift                  ← list / share / delete CSV logs
│   ├── GenericMapCanvasView.swift           ← custom SwiftUI Canvas renderer
│   ├── MapCanvasView.swift, MapCanvasViewV2.swift
├── Services/
│   ├── NLFeedbackService.swift              ← condition 1 policy
│   ├── SpatialFeedbackService.swift         ← condition 2 policy
│   └── IconsFeedbackService.swift           ← condition 3 policy
├── Resources/                               ← landmark sound effects (mp3)
└── Assets.xcassets/                         ← app icon, accent color
```

Same folder layout as the original Indoor_Route app, just smaller.

## How it is built

### Dependency

The whole rendering and feedback stack lives in a Swift Package called **TactileMapKit**, **vendored into this repo** at `Packages/TactileMapKit/` and referenced as a **local** Swift Package. This keeps the app self-contained — it builds with no external repo access. The package has 4 modules:

| Module | What we use from it |
|---|---|
| `TactileMapCore` | `TactileMapDocument.load(from:bundle:)`, `MapElement`, `TactileElementType`, `TactileProperties` |
| `TactileMapFeedback` | `FeedbackPolicy` protocol, `CoreHapticsEngine`, `AVSpatialAudioEngine`, `SoundRegistry`, `HapticPattern` presets |
| `TactileMapView` | The `TactileMapView` SwiftUI view (wraps `MKMapView`) |
| `TactileMapLogging` | `CSVTouchLogger` for touch event logging |

**Note:** the package exposes an umbrella library named `TactileMapKit` but it has no module of its own — so in code you import the four sub-modules individually (`import TactileMapCore`, etc.), not `import TactileMapKit`. This caught me out the first time.

### Two render paths

The app actually has **two ways** of drawing the map:

1. **MapKit path** (`TactileMapView` from the package): white background, blue corridors, orange intersections, red landmarks. Backed by `MKMapView`, `MKPolyline`, `MKAnnotationView`, with a blank tile overlay that hides the Apple Maps tiles. Used by the Landmark Study screens and the Feedback Customization Tester's "Open Demo Map".

2. **Custom Canvas path** (`GenericMapCanvasView`): pure SwiftUI `Canvas`, black background with the green/orange palette. I wrote this later because (a) the colors I wanted were closer to a real tactile-map mockup, and (b) at thick line widths MapKit's polyline renderer draws a "star artifact" at corridor junctions. The Canvas path covers that with a filled disc at each junction. Used for the "Branch Road Demo" entry.

## OSM data pipeline

Real-world maps come from OpenStreetMap. `tools/osm_to_tactile.py` is an **offline** converter (not part of the app build) that turns a manual OSM XML export into a `TactileMapDocument` JSON:

```
python3 tools/osm_to_tactile.py input.osm TactileNav/Model/output.json
```

It keeps streets (corridors), junctions (intersections), and traffic signals / crossings / named anchors (landmarks). Long street geometry is simplified (Douglas–Peucker) but tagged nodes are never dropped. `roux_portland.json` was generated this way from a Roux Institute (Portland, ME) export; coordinates are in meters.




