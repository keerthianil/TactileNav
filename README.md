# TactileNav

An iOS accessibility app for blind and low-vision users, built at UNAR Labs / Northeastern University.
Touch-explorable tactile maps with haptic feedback and spatial audio, designed VoiceOver-first.

Two screens:

| Screen | What it is |
|---|---|
| **Congress Square** | A pannable tactile street map of downtown Portland, Maine, from real OpenStreetMap data. Double tap a junction to open it. |
| **Street Crossing Audio** | Simulated traffic at one real junction, for practising when to step off by ear. |

## Congress Square

Drag **one finger** to explore — a street under the finger buzzes and says its name. Drag **two
fingers** to pan. There is no zoom: every width is a physical millimetre measurement, and a variable
scale would make that untrue.

The extract covers roughly 3.7 × 2.4 km of downtown Portland, from Marginal Way to the Commercial
Street waterfront. It is **roads plus the junctions where they cross** (see Intersections below). The
data also carries sidewalks and crossings, and those are deliberately dropped: at city scale they crowd
every junction with lines a few millimetres apart, which reads as noise under a finger rather than as a
street network. Sidewalks and crossings belong to the intersection view, where there is room to tell
them apart.

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

### Intersections

A **red square** marks every junction. They come from **OpenStreetMap's own node topology**, computed
when the extract is built: two ways that genuinely meet share a node, and two ways that merely cross on
a bridge do not. That is both the real definition of a junction and what keeps grade separations —
I-295 over a downtown street — from being reported as intersections. Ways sharing a node but carrying
the same name are one street split into pieces and are ignored.

Every shape the network contains is included, not just the four-way ones:

| Shape | Count |
|---|---|
| Two-way (a corner where one street becomes another) | 12 |
| Three-way (a T) | 414 |
| Four-way | 209 |
| Five-way | 7 |
| Six-way | 1 |

Each junction carries its arms — a true compass bearing and the street each one carries — which is what
the close-up is drawn from and what the entry announcement reads out.

A junction outranks the road it sits on: land on one and you feel the junction, not the street.
**Double tap** one to open it.

### The intersection close-up

Double-tapping a junction opens it full screen, drawn from the real geometry around that junction — the
arms at their true bearings, and the sidewalks and crossings OpenStreetMap records at that corner.
Nothing is schematic: a junction that meets at 43° is drawn at 43°.

| Element | Width | Haptic |
|---|---|---|
| Roadway | true width for its lane count, 8–16 mm | Continuous buzz, 1.0 / 0.10 |
| Sidewalk | 4 mm | Continuous buzz, 0.78 / 0.78 |
| Crossing | 2.8 mm | Sharp transient ticks, 1.0 / 1.00 |
| Between them | — | Nothing |

The roadway is drawn at its *real* width here rather than a fixed one, because the sidewalks and
crossings around it are at their real positions — a fixed width pushes the road's edge across the
sidewalk beside it and the kerb, the most important line at a junction, stops existing.

Back is the Back button, a three-finger swipe right, a double tap anywhere, or VoiceOver's escape.

### Feedback

| Under the finger | Haptic | Sound | Speech |
|---|---|---|---|
| Street | Continuous buzz, 1.0 / 0.10 | — | Street name |
| Intersection | Pulsing, 1.0 / 0.5, 0.15 s on / 0.10 s off | 1120 Hz ding every 0.4 s | "Intersection of A and B" |
| Between them | Nothing | Nothing | Nothing |

Silence off the streets is the point: it is how a blank block reads as blank. The intersection's three
cues — a pulse clearly unlike the road's steady rumble, a repeating ding, and the streets named once —
match the reference app one for one.

Haptics change the instant the thing under the finger changes; speech waits for a 0.2 s dwell and any
newer request cancels the pending one. Sweep across six streets and you feel all six but hear only the
one you stop on — announcing each would produce `"Congr—" "Hi—" "Fre—"`. Junction speech runs through
the same dwell-gated channel, so panning past a row of junctions never stacks or cuts off an
announcement.

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

Simulated traffic on all four legs of Congress Street at High Street, under a signal cycle. The
exercise is the one blind travellers actually perform: work out from sound alone when the parallel
street gets its green, because that surge is the cue to step off. Nothing is narrated — being told the
answer defeats it. **Headphones needed.**

To feel the shape of this junction rather than hear it, open it from the map: it is the one the opening
viewport is centred on.

**Where you are is stated in as many words**, because "sound is coming from the left" means nothing
until you know what is on your left. The screen says which corner you are standing on, which way you
are facing, which street is in front of you and which runs beside you — and offers the whole thing to
VoiceOver as one sentence. The corner and facing are derived from the same listener position the audio
is computed from, so they cannot drift out of step with what you hear.

Two controls shape the exercise:

- **Traffic** — gas, electric or mixed. An all-electric fleet is under 45 dBA at low speed, so the
  surge you would normally step off with is barely there and the technique itself starts to fail.
- **Speed** — slow, normal or fast. Slow stretches each pass out so the rise and fall in pitch is easy
  to follow while you are learning to hear it.

The sound is engine harmonics plus filtered noise, because what you mostly hear from a passing vehicle
is tyre roar — a stack of sine harmonics alone sounds like an organ, not a car. Distance is carried by
three things at once, as it is in the real world: level, pitch shift, and brightness, with a per-voice
low-pass that closes down as a vehicle recedes. An EV keeps the tyre noise and loses almost all of the
engine, which is exactly why it is so hard to hear coming.

## Gestures

Identical with VoiceOver on or off.

| Gesture | Action |
|---|---|
| One finger, drag | Explore |
| One finger, tap | Say what is under the finger |
| One finger, double tap | Open the intersection under the finger |
| Two fingers, drag | Pan the map |
| Three fingers, swipe right | Back |
| VoiceOver Actions rotor | Pan half a screen, or recentre |

**Panning is one-to-one with your fingers.** There is no momentum and no rubber-banding: the map moves
exactly as far as the fingers move and stops when they stop. A sighted user throws a map and watches
where it lands, but someone reading by touch has a finger holding a place on the grid, and a map that
keeps gliding slides that place away with no way to tell how far it went.

The double tap is synthesised from the same raw touches as everything else, so it behaves identically
with VoiceOver on and off — a second gesture-recognizer implementation for VoiceOver is exactly the
split that leaves one of the two states broken.

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
