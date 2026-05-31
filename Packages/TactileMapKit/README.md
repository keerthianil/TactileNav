# ProjectMultiNav

A foundational Swift Package to load a JSON map, and get a working tactile map with haptics, spatial audio, and VoiceOver support.

## Quick Start

```swift
import SwiftUI
import TactileMapKit

struct MyMapView: View {
    @Environment(\.dismiss) var dismiss

    var body: some View {
        let doc = try! TactileMapDocument.load(from: "my_building", bundle: .main)

        TactileMapView(
            document: doc,
            feedbackPolicy: DefaultFeedbackPolicy(),
            onBackGesture: { dismiss() }
        )
        .ignoresSafeArea()
    }
}
```

You get: corridors, intersections, landmarks rendered on a map with haptic feedback per element type, spoken names via TTS, VoiceOver direct-interaction, and anchor points on corridors for landmarks.

## Rendering Modes

The package supports two rendering backends:

| Mode | Description | Best for |
|---|---|---|
| **Canvas** (default) | SwiftUI Canvas — direct 2D drawing. Clean junction rendering, touch direction indicator, simpler coordinate pipeline. | New projects, tactile exploration |
| **MapKit** | MKMapView with overlays/annotations. Geographic coordinate system. | Overlaying tactile features on real-world maps |

Canvas mode solves the junction star artifact (ugly gaps where thick corridor lines meet at a point) by drawing filled discs at multi-corridor intersections. It also includes a directional touch indicator showing finger movement direction.

To use MapKit mode instead:

```swift
var config = TactileMapViewConfiguration()
config.renderingMode = .mapKit
TactileMapView(document: doc, configuration: config, feedbackPolicy: DefaultFeedbackPolicy())
```

## Requirements

- iOS 16.0+, Swift 5.9+, Xcode 15+
- Physical iPhone for haptics and spatial audio (Simulator renders the map but no vibrations/HRTF)

## Installation

In Xcode: **File > Add Package Dependencies...** and enter the repo URL. Choose **TactileMapKit** (all 4 modules) or pick individual ones.

## Architecture

```
┌─────────────────────────────────────────┐
│              Your App                    │
└────┬──────────────┬──────────────┬──────┘
     ▼              ▼              ▼
┌──────────┐  ┌──────────┐  ┌──────────┐
│  MapView │  │ Feedback │  │ Logging  │
│(gestures,│  │(haptics, │  │  (CSV,   │
│hit detect│  │  audio)  │  │file mgmt)│
└────┬─────┘  └────┬─────┘  └────┬─────┘
     └──────────────┼─────────────┘
                    ▼
           ┌──────────────┐
           │TactileMapCore│
           │(models, JSON,│
           │ coordinates) │
           └──────────────┘
```

| Module | What it does |
|---|---|
| **TactileMapCore** | Data models, JSON parsing, coordinate transform, physical dimensions, departure zones. No UIKit. |
| **TactileMapFeedback** | Haptic engine (CoreHaptics), spatial audio (AVAudioEngine + HRTF), speech, feedback policy protocol. |
| **TactileMapView** | SwiftUI map view (UIViewRepresentable + MKMapView), gestures, hit detection, VoiceOver, rendering. |
| **TactileMapLogging** | Optional. CSV touch logger, event model, file browser UI. |

**Key design:** Feedback is separated from data. Instead of models calling feedback managers directly, `MapElement` is pure data and you provide a `FeedbackPolicy` that decides what happens on touch.

## JSON Map Format

```json
{
  "version": "1.0",
  "type": "TactileMapDocument",
  "metadata": {
    "name": "Engineering Center - Floor 1",
    "floor": 1,
    "scale": "1 unit = 1 foot",
    "coordinate_unit": "feet"
  },
  "bounds": { "width": 1400, "height": 1400 },
  "features": [
    {
      "id": "c1",
      "type": "corridor",
      "geometry": { "type": "LineString", "coordinates": [[200, 200], [800, 200]] },
      "properties": { "name": "South Corridor", "level": 1, "accessible": true }
    },
    {
      "id": "i1",
      "type": "intersection",
      "geometry": { "type": "Point", "coordinates": [200, 200] },
      "properties": { "name": "SW Corner", "connected_corridors": ["c1", "c4"] }
    },
    {
      "id": "bathroom",
      "type": "landmark",
      "geometry": { "type": "Point", "coordinates": [350, 650] },
      "properties": { "name": "Bathroom", "category": "bathroom", "side": "right" }
    }
  ]
}
```

**Coordinates use real-world units** — set `"coordinate_unit": "feet"` or `"meters"` in metadata. A corridor from `[200, 200]` to `[800, 200]` with unit `feet` is 600 feet long. Use `CoordinateTransform.distance(from:to:)` for distance calculations.

Built-in element types: `corridor` (LineString), `intersection` (Point), `landmark` (Point). Custom types work automatically — just use any string in JSON `"type"` and extend `TactileElementType` in Swift.

Also supports legacy `"type": "FeatureCollection"` format.

### Where to place JSON files in your Xcode project

1. Create a `Maps/` folder in your app target.
2. Drag your `.json` files into it. Check **"Copy items if needed"** and make sure your **app target** is selected.
3. Verify files appear in **Build Phases > Copy Bundle Resources**.

```
YourApp/
  Maps/
    building_floor1.json
  Sounds/              <-- optional custom sound effects
    elevator_ding.mp3
```

## Customization

### Custom feedback

Subclass `DefaultFeedbackPolicy` or implement `FeedbackPolicy` directly:

```swift
@MainActor
class MyPolicy: DefaultFeedbackPolicy {
    override func onEnter(element: any TactileMapElement, touchType: TouchType) {
        if element.elementType == .landmark {
            let side = element.properties.side ?? "center"
            let pos = side == "right" ? AVAudio3DPoint(x: 1, y: 0, z: 0) : AVAudio3DPoint(x: -1, y: 0, z: 0)
            audioEngine.speakSpatially(element.properties.name, at: pos)
            hapticEngine.start(pattern: .landmarkFastPulse)
        } else {
            super.onEnter(element: element, touchType: touchType)
        }
    }
}
```

### Custom haptic patterns

Built-in presets: `.corridorContinuous`, `.intersectionPulse`, `.landmarkFastPulse`, `.singleTap`. Create custom:

```swift
let myPattern = HapticPattern(intensity: 1.0, sharpness: 1.0, mode: .pulsing(onDuration: 0.05, offDuration: 0.05, count: 5))
```

### Custom visual appearance

```swift
let config = TactileMapViewConfiguration(
    corridorColor: .systemGreen,
    corridorLineWidthMM: 6.0,
    intersectionDiameterMM: 10.0,
    landmarkColor: .systemPurple
)
TactileMapView(document: doc, configuration: config, feedbackPolicy: DefaultFeedbackPolicy())
```

All sizes are in **millimeters** — physically the same on every iPhone/iPad via the built-in PPI database (iPhone 8 through 16 Pro Max + iPads).

## Testing

Run unit tests in Xcode: **Product > Test** (Cmd+U). Three test suites: Core, Feedback, View.

Haptics/audio require a physical iPhone — connect via USB, select the device, Cmd+R.

## Troubleshooting

- **No haptics on Simulator** — Expected. Needs a physical iPhone 8+.
- **Spatial audio sounds the same from both sides** — Use headphones/AirPods on a physical device.
- **Map is blank** — Check your JSON file is in Build Phases > Copy Bundle Resources.
- **VoiceOver back gesture not working** — VoiceOver must be on, `onBackGesture` must be set, view must be in a `NavigationStack`.

## Project Structure

```
Package.swift
LICENSE (MIT)
Sources/
  TactileMapCore/        8 files — models, JSON, coordinates, dimensions, departure zones
  TactileMapFeedback/    6 files — haptics, spatial audio, speech, feedback policy
  TactileMapView/       11 files — MapKit view, gestures, hit detection, rendering
  TactileMapLogging/     4 files — CSV logger, events, file browser
Tests/                   3 test suites
DemoApp/                 sample map + usage examples
```

## License

MIT License. See [LICENSE](LICENSE).
