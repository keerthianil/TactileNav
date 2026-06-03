# TactileNav

An iOS accessibility app that turns the **Roux Institute** neighborhood (Portland, Maine) into a
touch-explorable map for blind and low-vision users. The app has **one map screen**, "Roux Institute Map."

## The map

A real map (MKMapView) on a white background at true street positions. You explore by dragging a purple
**"you are here" dot**: streets **buzz**, intersections **pulse**, and places **speak** their name and side
("Howie's Pub, on your right"). It's built on the vendored **TactileMapKit** package (haptics / spatial audio /
logging) and the bundled map data `TactileNav/Model/roux_portland.json`.

### How you interact (Nav_Indoor model)

- **One finger** — drag to move the dot and explore (streets buzz, places speak); the map auto-follows. This
  works **with VoiceOver on** because the map is a **Direct Touch** area (enable Direct Touch once in the rotor).
- **Zoom** — the **+ / −** buttons. The map's own pan / zoom / rotate gestures are **disabled**, so a stray
  gesture (e.g. a rotor twist) can't drift or spin it.
- **• • • Options** — jump to a **Point of interest** or **Intersection** (the dot jumps there and announces it
  — the VoiceOver-friendly way to move without dragging), plus **Center on me** and **Fit whole area**.
- **Back** — nav-bar button or VoiceOver Z-scrub. The left-edge swipe-back is disabled so moving the map can't
  pop the screen.
- Every session writes a **CSV touch log** (open **Data Files** to share / delete).

## Folder structure

```
TactileNav/
├── TactileNavApp.swift                  ← @main, shows ContentView
├── ContentView.swift                    ← home list: Roux Institute Map + Tools
├── Model/
│   ├── roux_portland.json               ← OSM-derived map data (Roux area; coords in meters)
│   ├── RTMDocumentAdapter.swift          ← JSON → real latitude/longitude models
│   ├── RTMDiscoveredStreet/Intersection/POI.swift  ← simple data models
│   ├── RTMPOICategory.swift              ← place categories + pin icons
│   └── HapticFeedbackSelection.swift     ← haptic picker config (Feedback Tester)
├── View/
│   ├── RTMRouxMapView.swift              ← the map screen + zoom / Options buttons
│   ├── RTMLiveMapView.swift              ← MKMapView wrapper (Direct Touch, dot drag, follow)
│   ├── RTMMapAnnotations.swift           ← purple dot / place pins / intersection dots
│   ├── RTMMapOverlays.swift              ← white background + street styling
│   ├── FeedbackCustomizationTesterView.swift  ← per-element haptic tuning tool
│   └── FilesListView.swift               ← list / share / delete CSV logs
├── Services/
│   └── RTMMapFeedbackController.swift     ← decides feedback under the dot; haptics + speech + CSV log
├── Resources/                            ← landmark sound effects (mp3)
└── Assets.xcassets/
```

> Map types are prefixed `RTM` (Roux Tactile Map). See `README_RTM.md` (repo root) for a deeper per-file tour.

## Dependency — TactileMapKit

The rendering/feedback foundation is the **TactileMapKit** Swift package, **vendored** at
`Packages/TactileMapKit/` and referenced locally (the app builds with no external repo access). Four modules:

| Module | What the app uses |
|---|---|
| `TactileMapCore` | `TactileMapDocument.load`, `MapElement`, `TactileElementType`, `TactileProperties` |
| `TactileMapFeedback` | `FeedbackPolicy`, `CoreHapticsEngine`, `AVSpatialAudioEngine`, `HapticPattern` presets |
| `TactileMapView` | The package's MapKit SwiftUI view — used only by the Feedback Customization Tester |
| `TactileMapLogging` | `CSVTouchLogger` for the touch-event log |

Import the sub-modules individually (`import TactileMapCore`, …), not an umbrella `TactileMapKit`.

## OSM data pipeline

Map data comes from OpenStreetMap. `tools/osm_to_tactile.py` is an **offline** converter (not part of the app
build) that turns a manual OSM XML export into a `TactileMapDocument` JSON:

```
python3 tools/osm_to_tactile.py input.osm TactileNav/Model/roux_portland.json --pedestrian
```

It keeps walkable streets (corridors), real intersections, and traffic signals / crossings / named anchors
(landmarks); `--pedestrian` drops motorways so the interstate interchange is excluded. Long geometry is
simplified (Douglas–Peucker) but tagged nodes are never dropped. `roux_portland.json` was generated this way
from a Roux Institute (Portland, ME) export; coordinates are in meters.
