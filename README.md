# TactileNav

An iOS accessibility app for blind and low-vision users, built at UNAR Labs / Northeastern University.
Features touch-explorable tactile maps with haptic feedback, spatial audio, and full VoiceOver support.

## Features

### Portland Old Port Map
Tactile map of Portland, Maine's Old Port district covering the grid of Exchange Street, Market Street,
Congress Street, Middle Street, and Fore Street. Five streets, six intersections, two landmarks.

- **Two zoom levels**: Level 1 shows the full area. Double-tap an intersection to zoom into Level 2,
  which shows road legs at 12mm width, sidewalks, and crosswalks.
- **Drag to explore**: Touch and drag across the map. A yellow touch indicator follows your finger.
  Each feature type has a distinct haptic pattern (roads buzz, intersections pulse, crosswalks tick).
- **Traffic data**: Time-of-day selector (AM, Mid, PM, Eve, Night) changes the traffic density
  announced when touching a road. Includes lane count and traffic level.
- **APS signals**: Three intersections have simulated Accessible Pedestrian Signals. Announced
  when touching those intersections.
- **Back navigation**: Double-tap anywhere in Level 2, use the back button, three-finger swipe right,
  or VoiceOver escape gesture to return to Level 1.

### Street Crossing Simulation
Spatial audio simulation of vehicles passing at a street crossing. Uses AVAudioEngine with
AVAudioEnvironmentNode and HRTF-HQ rendering. The listener stands at the curb while a vehicle
sound source moves left to right.

- Vehicle types: Car (200-1200 Hz), Bus (100-350 Hz), Truck (80-500 Hz), EV (2000-4000 Hz)
- Speed slider: 15-50 mph
- Doppler effect applied automatically by AVAudioEnvironmentNode
- Use headphones for the best spatial audio experience

### Roux Institute Map
Touch-explorable map of the Roux Institute neighborhood (Portland, ME) with real OSM street data.
Drag to explore with haptic feedback. Built on the TactileMapKit package.

### Tools
- **Feedback Customization Tester** - Per-element haptic tuning tool
- **Data Files** - List, share, and delete CSV touch logs

## Haptic Patterns

| Feature    | Pattern                  | Intensity | Sharpness |
|------------|--------------------------|-----------|-----------|
| Road       | Continuous buzz          | 1.0       | 0.1       |
| Intersection | Pulse (0.25s interval) | 1.0       | 0.5       |
| Landmark   | Fast pulse (0.12s)       | 1.0       | 0.7       |
| Sidewalk   | Continuous (softer)      | 0.78      | 0.78      |
| Crosswalk  | Transient ticks (0.17s)  | 1.0       | 1.0       |

## Dependency - TactileMapKit

Built on **TactileMapKit**, vendored at `Packages/TactileMapKit/` from the ProjectMultiNav repository.

| Module             | Used For |
|--------------------|----------|
| TactileMapCore     | PhysicalDimensions, TactileMapDocument, MapElement |
| TactileMapFeedback | HapticPattern presets, CoreHapticsEngine, FeedbackPolicy |
| TactileMapView     | SwiftUI map view (Roux map and Feedback Tester) |
| TactileMapLogging  | CSVTouchLogger for touch-event CSV logs |

## File Structure

```
TactileNav/
  TactileNavApp.swift
  ContentView.swift
  Model/
    PortlandMapData.swift                - Feature models and haptic patterns
    PortlandMapLoader.swift              - JSON loader with coordinate transforms
    portland_congress_square.json         - Level 1 map (5 streets, 6 intersections, 2 landmarks)
    intersection_i_{1-6}_detail.json     - Level 2 details per intersection
    portland_aps_data.json               - Simulated APS locations
    portland_traffic_data.json           - Simulated traffic profiles
    roux_portland.json                   - OSM data (Roux Institute area)
    RTMDocumentAdapter.swift             - JSON to lat/lon models for Roux map
    RTMDiscovered*.swift                 - Roux map data models
  View/
    PortlandMapScreen.swift              - Level 1 map + time-of-day picker
    PortlandMapView.swift                - UIViewRepresentable with touch indicator and hit testing
    PortlandIntersectionDetailView.swift - Level 2 detail with back button
    SpatialAudioSimulationView.swift     - Street crossing audio sandbox
    RTMRouxMapView.swift                 - Roux Institute map screen
    RTMLiveMapView.swift                 - MKMapView wrapper for Roux map
    RTMMapAnnotations.swift              - Roux map annotations
    RTMMapOverlays.swift                 - Roux map overlays
    FeedbackCustomizationTesterView.swift
    FilesListView.swift
  Services/
    PortlandFeedbackManager.swift        - CHHapticEngine + audio feedback hub
    RTMMapFeedbackController.swift       - Roux map feedback controller
Packages/
  TactileMapKit/                         - Vendored from ProjectMultiNav
```
