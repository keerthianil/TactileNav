# TactileNav

An iOS accessibility app for blind and low-vision users, built at UNAR Labs / Northeastern University.
Touch-explorable tactile street maps with haptic feedback and spatial audio — designed VoiceOver-first.

## Features

### Congress Square (downtown Portland, ME)

A pannable, street-only tactile map of downtown Portland, drawn at **true physical lane scale**. You
explore it by dragging one finger: each surface under the finger has its own vibration and speaks its
own name. You move around the map by dragging two fingers.

The map covers roughly **3.7 km east–west by 2.4 km north–south** — from the I-295 / Marginal Way edge
down to the Commercial Street waterfront, and from Brighton Ave / St John St across to Franklin Street.
Every street, sidewalk and crossing is real **OpenStreetMap (ODbL)** data: 715 streets, 612 sidewalks
and 681 marked crossings. Nothing is hand-placed.

There are no intersections, traffic, signals or crossing simulation in this view — it is the base street
layout and nothing else.

#### Physical sizing

A tactile map only works if a street is the *same width under a finger* regardless of device. So every
width is a millimetre measurement on the glass, converted using the screen's pixel density.

| Element | Physical width | On a 460 ppi phone |
|---|---|---|
| Road (every road) | 4.0 mm | 24.1 pt |
| Sidewalk | 4.0 mm | 24.1 pt |
| Crosswalk stripe | 2.8 mm | 16.9 pt |

Two different things come off that 4 mm constant, and they are worth keeping apart:

- **Line width.** Every road is drawn 4 mm wide whatever its lane count. 4 mm is a *perceptual*
  constant — roughly the narrowest line a fingertip can reliably follow — not a measurement of asphalt.
  Scaling it by lane count sounds more faithful but is self-defeating: a four-lane road becomes 16 mm,
  wider than a fingertip, so it stops being a line you can trace and turns into a plane whose edges you
  cannot feel. It also buries the sidewalk beside it under the paint.
- **Map scale.** 4 mm on the glass represents one real 3.3 m lane, and that is what converts metres to
  points. So the *spacing* of the network — how far apart two streets run, how wide a junction is, how
  far a crossing reaches — stays true to the ground even though the lines are a constant width.

Crossings are the one thing drawn to the map's line weights rather than to the ground. A crossing way in
the data spans the whole roadway, which on a four-lane street is several times the width of the 4 mm line
that street is drawn as — at true length it sprawls well past the road on both sides and stops looking
like part of the same drawing. Each crossing is a compact zebra mark: white bars on a darker patch, the
way a real one is white paint on asphalt. The patch matters — white bars alone are invisible against the
white background and punch a hole through the road where they cross it.

Lane counts come from OpenStreetMap's `lanes` tag where it exists (205 of 715 streets) and from the
road's OSM class otherwise. They no longer affect the drawn width, but are carried on every road.

Because the scale is physical, the whole map is about **67 screens wide** — which is why it pans.
There is deliberately **no zoom**: a variable scale would make the millimetre measurements untrue.

#### Gestures

Identical with VoiceOver on or off.

| Gesture | Does |
|---|---|
| One finger, press and drag | Explore — vibration and spoken name for whatever is under the finger |
| One finger, single tap | Speak what is under the finger |
| **Two fingers, drag** | Pan the map — continuous, with momentum, like any map |
| Three-finger swipe right, or drag | Go back |
| Back button | Go back |
| VoiceOver Actions rotor (swipe up/down) | Pan north / south / east / west by half a screen, or recenter |
| Recenter button (toolbar) | Jump back to Congress Square |

Panning is on **two** fingers because one finger is the exploration channel and cannot be shared.
Three fingers is not available for continuous panning — VoiceOver reserves it and delivers it as a
discrete scroll — so it stays on "go back", and the Actions rotor gives a step-at-a-time alternative
for anyone who finds a two-finger drag difficult.

**Nothing a single finger can do navigates away.** Back is the three-finger swipe and the Back button,
nothing else. Suppressing the one-finger swipe-back takes two mechanisms, because clearing `isEnabled`
alone does not hold — SwiftUI re-enables the recognizer as the navigation stack updates — so the map
also takes over the recognizer's delegate and refuses to let it begin. The scroll view needs two touches
to pan and accepts at most two, so a three-finger back drag cannot pan at the same time. Exploring hard
against the left edge is safe.

**Exploration runs on raw touches, not a gesture recognizer.** Inside a direct-interaction accessibility
element VoiceOver hands touches straight to the responder chain, and gesture recognizers attached to that
view do not fire dependably. A recognizer-driven explore therefore works with VoiceOver off and goes
completely dead with it on — the worst possible failure for this app. `touchesBegan/Moved/Ended` behave
identically either way.

Because the map is about 67 screens wide it is genuinely possible to pan away and lose your bearings,
so there is a **Recenter** button in the toolbar — the equivalent of the "back to my location" control
on a visual map. It is in the toolbar rather than floating on the map so VoiceOver can always reach it,
and the same action is on the Actions rotor.

#### Haptics and speech

| Surface | Vibration | Spoken |
|---|---|---|
| Road | Heavy continuous buzz (intensity 1.0, sharpness 0.1) | `"Congress Street"` — bare name |
| Sidewalk | Softer, sharper continuous buzz (0.78 / 0.78) | `"North sidewalk, Congress Street"` |
| Crosswalk | Sharp transient tick every 0.17 s | `"Crosswalk across Congress Street"` |
| Empty space | Nothing | Nothing |

A road says only its name — the vibration already tells you it is a roadway. Sidewalks and crossings
lead with the surface type and then name the street they belong to, because there are hundreds of each
and a name alone answers the wrong question.

**Announcements never overlap or get cut off.** Vibration changes the instant the surface changes, but
speech waits for the finger to settle on one surface for 0.2 s, and any newer surface cancels the
pending announcement. So sweeping quickly across six streets lets you *feel* all six while hearing
exactly one complete name — the street you stopped on. On top of that, announcements are posted at high
priority so a new name replaces the previous one cleanly, the screen-entry summary holds exploration
speech until it has finished, and the after-panning orientation cue stays silent while a finger is
exploring.

After a pan settles, the map names the nearest street to the new centre, which is what makes a map this
large navigable rather than disorienting.

### Street Crossing Audio — judging a four-way signal by ear

You stand on the corner of **Congress Street at High Street** — the same junction you can explore by
touch on the map screen — about to cross Congress. Traffic runs on all four legs under a signal cycle,
and the task is the one blind travellers actually perform: work out from sound alone when it is safe
to step off.

The technique being demonstrated is the real one. You do not cross when it goes quiet; you cross with
the **parallel surge** — the moment the traffic beside you, running the way you want to walk, pulls
away from the line. Here that is High Street. Traffic sweeping left to right across your front is
Congress Street and means wait.

**Nothing is narrated.** There is deliberately no spoken commentary on what the traffic is doing —
being told the answer is the opposite of the exercise. A **Reveal the current phase** button shows
which street has the green whenever you want to check yourself, and every control is labelled for
VoiceOver as usual. The bird's-eye diagram's accessibility label is deliberately static: if it
reported the live phase, VoiceOver would hand over the very thing you are meant to work out.

What makes the intersection readable by ear:

- **Real geometry.** The four legs use the true OpenStreetMap bearings of Congress and High (43°, 145°,
  240°, 320°), so the crossing angle is the real one.
- **Vehicles keep right.** One direction of Congress passes about 5 m in front of you and the other is
  a full roadway away at about 11 m. Down a shared centreline everything would sound identical and the
  intersection would carry no information at all.
- **Greens open with a surge.** Two or three vehicles pull away together, because a surge is what a
  listener recognises — one car alone is ambiguous.
- **Turning vehicles.** During the walk phase some vehicles turn across the crosswalk. A turn lingers
  near you instead of sweeping past and away, and that is the movement most likely to hit a pedestrian
  who has already stepped off.
- **Real Doppler.** Pitch is shifted live from each vehicle's modelled position (`f' = f·c/(c−v)`), not
  a cosmetic number. Pan and volume carry direction and distance. Six vehicles can sound at once, each
  with its own pitch shifter.
- **Gas vs. electric.** An all-electric fleet is under 45 dBA at low speed, so the surge you would
  normally step off with is barely there — the technique itself starts to fail. Headphones required.

### Roux Institute Map & Tools

The Roux Institute neighborhood map (real OSM data) and the feedback-tester / CSV-log tools are also
present. Touch exploration on the Congress Square map is logged to CSV as well, and those logs appear in
the Data Files screen.

## Rendering

The map is far larger than a `CALayer` can back (about 81,000 px wide at 3x), so the canvas is not the
size of the map. It stays the size of the screen, sits below a transparent scroll view, and redraws the
window that scrolling exposes. A uniform grid narrows ~2,000 polylines down to the few dozen whose ink
can reach the viewport, and everything drawn — points, widths, colours, text runs — is precomputed once
at load. The same grid backs hit-testing, so finding what is under a finger is arithmetic rather than a
per-vertex coordinate conversion; that headroom is what keeps a fast drag from dropping samples, and a
dropped sample is how a finger skips a 4 mm line without ever feeling it.

The hit radius grows with finger speed, because a fast drag samples further apart and would otherwise
step straight over a line.

**Whichever line the finger is genuinely closest to wins.** Strict priority by type — crossing, then
sidewalk, then road — sounds right, since a crossing is painted on top of the road it spans. But with
681 crossings clustered around the junctions, a crossing's catch radius then claims every road near it,
and a finger tracing a road feels crossing ticks while plainly looking at a road. Type priority now only
settles it when two lines are within a few points of each other, which is exactly the case where the
crossing really is on top of the road. That change alone took wrong-surface feedback on roads from 9%
of the drawn area to 2%.

## Foundation — TactileMapKit

Built on the **TactileMapKit** Swift package, vendored at `Packages/TactileMapKit/`.

| Module | Used for |
|---|---|
| TactileMapCore | `TactileMapDocument.load`, `MapElement` / `TactileGeometry` as the only geometry model, `TactileElementType`, `PhysicalDimensions.mmToPoints` |
| TactileMapFeedback | `CoreHapticsEngine`, `HapticPattern` presets, `OutdoorFeedbackPolicy` (subclassed), `SpatialAudioEngine` |
| TactileMapView | `HitDetectionConfig` tuning constants |
| TactileMapLogging | `CSVTouchLogger` for touch-event logs |

## Data files (`Model/`)

```
congress_square.json    Real OSM (ODbL) street extract — streets, sidewalks, crossings (metres)
roux_portland.json      Real OSM data for the Roux Institute map
```

`congress_square.json` is in local metres from the south-west corner of the bounding box, with y growing
south, so the renderer needs no map projection at runtime. Regenerate it with:

```bash
python3 tools/fetch_congress_square.py
```

The script queries the OpenStreetMap Overpass API for the bounding box, keeps the public street network
(no parking aisles or driveways), simplifies to 1 m tolerance, and writes the document deterministically
— run it twice on unchanged data and you get byte-identical output. The bounding box and the opening
viewport are recorded in the file's metadata, so the app reads them from data rather than hardcoding.

## Logging

Touch exploration is logged to CSV via `CSVTouchLogger` and appears in the Data Files screen as
`CongressSquare_<timestamp>.csv`. Each session records the feature count, the map's content size, and
the device's `pointsPerMeter` and lane width in points — needed to interpret a trace later, since the
same drag covers a different number of streets on devices with different pixel densities. Touch-down,
touch-move (sampled at 100 ms) and touch-up rows carry the street name and surface type under the
finger, or `Background`. Panning is recorded where it settles, with the new viewport centre in metres.

## File structure

```
TactileNav/
  Model/
    StreetMapSizing.swift          Physical mm constants + the lane-anchored map scale
    StreetMapGeometry.swift        Projection, spatial index, hit testing, spoken forms, labels
    PortlandMapLoader.swift        Document load + off-main-thread projection
    IntersectionCrossingModel.swift  Four-way signal cycle, traffic, lane geometry
  View/
    PortlandMapScreen.swift        Screen shell + async load
    PortlandMapView.swift          Scroll view, gestures, VoiceOver, logging
    PortlandStreetCanvasView.swift Viewport renderer
    SpatialAudioSimulationView.swift  Crossing demo screen + bird's-eye diagram
  Services/
    StreetFeedbackPolicy.swift     Per-surface haptics + the single dwell-gated speech channel
    TrafficAudioEngine.swift       Pooled real-Doppler vehicle voices
Packages/
  TactileMapKit/                   Vendored foundation package
tools/
  fetch_congress_square.py         OpenStreetMap → tactile map document
```
