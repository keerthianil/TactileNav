# TactileNav

An iOS accessibility app for blind and low-vision users, built at UNAR Labs / Northeastern University.
Touch-explorable tactile maps with haptic feedback and spatial audio, designed VoiceOver-first.

Two screens:

| Screen | What it is |
|---|---|
| **Congress Square** | A pannable tactile street map of downtown Portland, Maine. Real OpenStreetMap data, roads only. |
| **Street Crossing Audio** | One four-way junction: a tactile diagram of the intersection, plus simulated traffic to judge a signal by ear. |

## Congress Square

Drag **one finger** to explore — a street under the finger buzzes and says its name. Drag **two
fingers** to pan. There is no zoom: every width is a physical millimetre measurement, and a variable
scale would make that untrue.

The extract covers roughly 3.7 × 2.4 km of downtown Portland, from Marginal Way to the Commercial
Street waterfront. It is **roads and nothing else**. The data also carries sidewalks and crossings and
they are deliberately dropped: at city scale they crowd every junction with lines a few millimetres
apart, which reads as noise under a finger rather than as a street network. Sidewalks and crossings
belong to the intersection view, where there is room to tell them apart.

### Sizing

Line width and map scale are two independent numbers, and keeping them independent is the whole trick.

| | Value | On a 460 ppi phone |
|---|---|---|
| Road line width | 4.0 mm | 24.1 pt |
| Block spacing (the map's scale) | 40 mm per 120 m | ≈ 2.0 pt/m |

**Line width** is a perceptual constant — roughly the narrowest line a fingertip can reliably follow —
not a measurement of asphalt. It does not scale with lane count: a four-lane road at 16 mm is wider than
a fingertip, so it stops being a line you can trace and becomes a plane whose edges you cannot feel.

**Map scale** comes from block spacing, *not* from the lane width. Deriving it from the lane width
("4 mm is one 3.3 m lane") sounds principled but makes the drawing life-size: about 55 m of street fits
on a phone, the whole extract becomes 67 screens across, and the viewport holds two streets and a
junction with no grid to orient by. 40 mm per block is a little under a hand span, so a block can be
crossed in one movement and neighbouring junctions are on screen together.

Both numbers are physical millimetres, so both are the same size on every device — only the point count
changes with pixel density.

### Feedback

| Under the finger | Haptic | Speech |
|---|---|---|
| Street | Continuous buzz, intensity 1.0, sharpness 0.10 | Street name |
| Between streets | Nothing | Nothing |

Silence off the streets is the point: it is how a blank block reads as blank.

Haptics change the instant the street changes; speech waits for a 0.2 s dwell and any newer request
cancels the pending one. Sweep across six streets and you feel all six but hear only the one you stop
on — announcing each would produce `"Congr—" "Hi—" "Fre—"`.

### Rendering

The map is far larger than a `CALayer` can back, so the canvas is not the size of the map. It stays the
size of the screen, sits below a transparent scroll view, and redraws the window that scrolling exposes.
A uniform grid narrows the network down to the few polylines whose ink can reach the viewport, and
everything drawn is precomputed at load. The same grid backs hit-testing, so finding what is under a
finger is arithmetic rather than a per-vertex conversion — that headroom is what keeps a fast drag from
dropping samples, and a dropped sample is how a finger skips a 4 mm line without ever feeling it.

The hit radius grows with finger speed, because a fast drag samples further apart and would otherwise
step straight over a line.

## Street Crossing Audio

A tactile diagram of Congress Street at High Street, with simulated traffic on all four legs under a
signal cycle. The exercise is the one blind travellers actually perform: work out from sound alone when
the parallel street gets its green, because that surge is the cue to step off. Nothing is narrated —
being told the answer defeats it — and the diagram stops speaking while traffic is playing. The current
phase is available on demand behind a button. **Headphones needed.**

An all-electric fleet is under 45 dBA at low speed, so the surge you would normally step off with is
barely there and the technique itself starts to fail. That is what the fleet picker is for.

The diagram is a schematic plus rather than a projection of the real bearings: a finger tracing a leg
wants a straight line, and the four legs have to be the same length or the shorter ones read as less
important. The junction it names is real, and the audio runs on the real bearings.

| Element | Width | Haptic |
|---|---|---|
| Roadway | 12 mm | Continuous buzz, 1.0 / 0.10 |
| Sidewalk | 4 mm | Continuous buzz, 0.78 / 0.78 |
| Crossing | 2.8 mm | Sharp transient ticks, 1.0 / 1.00 |
| Between them | — | Nothing |

Roadway versus sidewalk is the distinction that matters, and it is carried by **sharpness** rather than
intensity — a low-sharpness rumble and a high-sharpness vibration feel like different materials, where
loud and quiet just feels like the same thing further away.

The sidewalks sit one kerb back from the roadway — 11.8 mm from the centre, derived as half the roadway
plus the crossing plus the kerb plus half the sidewalk — and form a square around the junction. The four
crossings are the sides of that square, each bridging two corners and spanning the roadway between them.
Crossing bars are painted only where the crossing lies over the roadway, which is both true on the
ground and what keeps white paint off a white background.

## Gestures

Identical with VoiceOver on or off.

| Gesture | Action |
|---|---|
| One finger, drag | Explore |
| One finger, tap | Say what is under the finger |
| Two fingers, drag | Pan the map |
| Three fingers, swipe right | Back |
| VoiceOver Actions rotor | Pan half a screen, or recentre |

**One finger never navigates.** A navigation controller has two pop gestures — the familiar left-edge
swipe and, since iOS 18, one that pops from a swipe anywhere on the view — and both are switched off
while a tactile screen is open. The second is the one that matters: an explore drag *is* a full-screen
swipe. Back is the Back button and the three-finger swipe, and nothing else.

## VoiceOver

Exploration runs on raw `touchesBegan`/`Moved`/`Ended`, not a gesture recognizer. Inside a
direct-interaction accessibility element VoiceOver hands touches to the responder chain, and recognizers
on that view do not fire dependably — a recognizer-based explore works with VoiceOver off and goes
completely dead with it on.

Each map is a single accessibility element with `.allowsDirectInteraction` and, on iOS 17+,
`.silentOnTouch`, re-applied whenever VoiceOver is toggled. Speech goes out as a high-priority
`.announcement` under VoiceOver and through `AVSpeechSynthesizer` otherwise.

Arriving on the street map, VoiceOver focus is moved onto the map itself and reads the map's own label,
which leads with the name — "Congress Square, downtown Portland…". A detached string posted as a
screen-change announcement is unreliable here: it competes with the push transition and the navigation
title, and is routinely dropped, which is how the map came to open without saying which map it was.

### Testing

**Both states need testing, and a pass in one proves nothing about the other.** Exploration runs on raw
touches specifically so the two paths are the same code, but that is the claim under test, not a
guarantee — a gesture-recognizer version works with VoiceOver off and is completely dead with it on.

- **VoiceOver off** — drag one finger across each map and confirm it buzzes continuously, that surfaces
  are distinguishable, and that speech names what is under the finger.
- **VoiceOver on** — the same, plus: the map announces its name on arrival, the Actions rotor offers
  pan and recentre, and a three-finger swipe right goes back.
- **Both** — a one-finger swipe from anywhere, including the left edge, must never navigate back.

Haptics need a physical device either way; the simulator has nothing to vibrate.

## Foundation

Built on **TactileMapKit**, the shared tactile-mapping Swift package vendored at
`Packages/TactileMapKit/`. The app supplies its own rendering, sizing and feedback policies on top.

| Module | Used for |
|---|---|
| TactileMapCore | `TactileMapDocument.load`, `MapElement` / `TactileGeometry`, `TactileElementType`, `PhysicalDimensions.mmToPoints` |
| TactileMapFeedback | `CoreHapticsEngine`, `HapticPattern` presets, `OutdoorFeedbackPolicy` (subclassed), `SpatialAudioEngine` |
| TactileMapView | `HitDetectionConfig` tuning constants |
| TactileMapLogging | `CSVTouchLogger` |

## Data

`Model/congress_square.json` — an OpenStreetMap extract in local metres, generated by `tools/`.
OpenStreetMap data is © OpenStreetMap contributors, licensed **ODbL**.

## Logging

Every session on the map writes a CSV via `CSVTouchLogger`, readable in the app under **Tools → Data
Files** and through the Files app.

Session metadata records the map, the street count, both sizing numbers (`laneWidthMM` and
`blockSpacingMM`), the resolved `pointsPerMeter`, the content size, and whether VoiceOver was on. Both
sizing numbers are needed: one converts a logged position back to ground distance, the other is the
physical width of the line the finger was following, and they are independent.

Each event carries the timestamp, elapsed session time, event type, the street under the finger (or
`Background`), an `onStreet` flag, and the position in **content points and in metres from the map's
north-west corner**. Content coordinates, not screen coordinates — the map is far larger than the
screen, so a screen point means nothing once the map has been panned.

## Build

Open `TactileNav.xcodeproj` and run. iOS 16+.

Haptics need a physical device — the simulator has nothing to vibrate. So does any real check of
VoiceOver behaviour. See **VoiceOver → Testing** above for what to exercise in each state.

```bash
xcodebuild test -project TactileNav.xcodeproj -scheme TactileNav -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## Layout

```
TactileNav/
  Model/    StreetMapGeometry, StreetMapSizing, IntersectionLayout,
            IntersectionCrossingModel, PortlandMapLoader, congress_square.json
  View/     PortlandMapScreen, PortlandMapView, PortlandStreetCanvasView,
            IntersectionTactileView, SpatialAudioSimulationView,
            SwipeBackSuppression, FeedbackCustomizationTesterView, FilesListView
  Services/ StreetFeedbackPolicy, TrafficAudioEngine
Packages/TactileMapKit/    vendored foundation package
tools/                     map extraction and asset scripts
```
