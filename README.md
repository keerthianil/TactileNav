# TactileNav

An iOS accessibility app for blind and low-vision users, built at UNAR Labs / Northeastern University.
Touch-explorable tactile street maps with haptic feedback, spatial audio, time-of-day traffic, and
accessible-pedestrian-signal simulation — designed VoiceOver-first.

## Features

### Congress Square Map (downtown Portland, ME)
A tactile map of the real Congress Street corridor around Congress Square. Street geometry is a real
**OpenStreetMap (ODbL)** extract — Congress, High, Free, Oak, Casco, Brown, Center, Preble, Spring and
Park Streets, their intersections, and two real landmarks (the **Portland Museum of Art** and
**Congress Square Park**). The APS and traffic data layered on top are simulated but structured to match
their real sources, so a future real data drop is a file swap.

- **Drag to explore.** Touch and drag; a yellow indicator follows your finger. Each feature has a distinct
  haptic pattern (roads buzz, intersections pulse, landmarks fast-pulse, sidewalks softer, crosswalks tick)
  and is spoken as you reach it.
- **Traffic you can feel and hear.** A peak / normal / light selector changes each road's congestion.
  Blind/low-vision users perceive it through **haptic intensity** (heavier traffic = stronger, deeper
  vibration) and an **audio rumble** whose density tracks the level — colour is only a secondary cue.
  Volumes come from HPMS-class AADT × FHWA urban hourly profiles.
- **Intersection crossing detail.** Double-tap an intersection to open a zoomed, direction-faithful
  crossing built from the real street bearings. It runs a live signal cycle you perceive by ear + touch:
  a slow **APS locator tone** during DON'T WALK, a rapid tick or spoken "Walk sign is on" plus a
  **vibrotactile-arrow** pulse during WALK, and accelerating **countdown** beeps during clearance.
  A car passes through with real Doppler on a cadence set by the traffic level; during WALK a car may
  turn across your crosswalk — the highest-risk moment for a blind pedestrian.
- **Back navigation everywhere.** Three-finger swipe right, three-finger drag, VoiceOver 3-finger scroll,
  VoiceOver two-finger Z-scrub, or the Back button.

### Street Crossing Audio (spatial-audio sandbox)
A single-lane bird's-eye sandbox for the audio engine and the two hardest crossing judgments:

- **Straight vs. turning** — a turning vehicle stays closer, longer (needs ~11 dB more to judge than
  mere presence).
- **Car vs. EV** — the electric vehicle is near-silent (under 45 dBA under 20 mph), demonstrating the
  detection-gap hazard.
- **Real Doppler.** Pitch is shifted live from the vehicle's modelled position (`f' = f·c/(c−v)`), not a
  cosmetic number; a 25 mph pass yields ≈1.1 semitones of total shift. Pan + volume convey direction and
  distance. Headphones recommended.

### Roux Institute Map & Tools
The Roux Institute neighborhood map (real OSM data) and the feedback-tester / CSV-log tools are unchanged.

## Interaction model (VoiceOver-first)

Exploration works identically with VoiceOver on or off. UIKit gesture recognizers stay active in both
modes; with VoiceOver on, the map view carries `.allowsDirectInteraction` (and `.silentOnTouch` on
iOS 17+) so raw touches pass straight through to the recognizers — there is no separate manual touch path
to race with VoiceOver. Long-press-drag explores, single tap speaks, double tap drills in / goes back, and
`shouldRecognizeSimultaneouslyWith` + `require(toFail:)` keep the gestures from fighting each other.

## Haptic patterns

| Feature      | Pattern                          | Intensity        | Sharpness |
|--------------|----------------------------------|------------------|-----------|
| Road         | Continuous buzz                  | scales w/ traffic| 0.1       |
| Intersection | Pulse                            | 1.0              | 0.5       |
| Landmark     | Fast pulse                       | 1.0              | 0.7       |
| Sidewalk     | Continuous (softer)              | 0.78             | 0.78      |
| Crosswalk    | Transient ticks (0.17s)          | 1.0              | 1.0       |

## Foundation — TactileMapKit

Built on the **TactileMapKit** Swift package, vendored at `Packages/TactileMapKit/`. The Congress Square
map is parsed by the package (`TactileMapDocument.load`), haptics run on its `CoreHapticsEngine`
(`HapticPattern`), and the Roux map/tools use its view, feedback, and logging modules.

| Module             | Used for |
|--------------------|----------|
| TactileMapCore     | `TactileMapDocument` / `MapElement`, `PhysicalDimensions` |
| TactileMapFeedback | `CoreHapticsEngine`, `HapticPattern` |
| TactileMapView     | SwiftUI map view (Roux map, Feedback Tester) |
| TactileMapLogging  | `CSVTouchLogger` for touch-event logs |

## Data files (`Model/`)

```
congress_square.json    Real OSM (ODbL) base map — streets, intersections, landmarks (metres)
portland_aps.json       Simulated APS, structured to mirror the NYC Open Data APS schema
portland_traffic.json   Simulated traffic — HPMS-class AADT × FHWA urban hourly profiles
roux_portland.json      Real OSM data for the Roux Institute map
```

Regenerating the base map: the raw OSM export is converted to `congress_square.json` (local metres,
north-up). If the extract's bounding box changes, update the SW-corner anchor constants in
`CongressSquareAdapter`.

## File structure

```
TactileNav/
  Model/
    PortlandMapData.swift          Feature + traffic + APS models, TrafficLevel/TrafficState
    CongressSquareAdapter.swift    TactileMapDocument → projected render models
    PortlandMapLoader.swift        Package load + overlay decode + procedural Level-2 detail
  View/
    PortlandMapScreen.swift        Level-1 map + peak/normal/light selector
    PortlandMapView.swift          MKMapView + drag-to-explore gesture model + rendering
    PortlandIntersectionDetailView.swift  Level-2 signal/APS/vehicle simulation
    SpatialAudioSimulationView.swift      Lane sandbox: straight/turning × car/EV, real Doppler
  Services/
    PortlandFeedbackManager.swift  Haptics (CoreHapticsEngine) + speech orchestration
    TrafficAudioEngine.swift       One AVAudioEngine: real-Doppler vehicle + rumble + APS earcons
Packages/
  TactileMapKit/                   Vendored foundation package
```
