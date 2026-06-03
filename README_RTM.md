# Roux Tactile Map (RTM) — what this is

This is **TactileNav's map screen**, called **"Roux Institute Map."**
You reach it from the app's home list: **Map → "Roux Institute Map."**

> **Update:** this is now the app's **single** map (the earlier abstract "OSM" screen was removed). It is the
> original vtsly map: a real MKMapView where you **drag a purple dot** to explore (buzz + speech), with
> two-finger pan, pinch (4 zoom levels), rotate, and follow. **Zoom / Center / Fit** are buttons (the • • •
> Options menu); the left-edge swipe-back is disabled (use the nav button / Z-scrub); a **CSV touch log** is
> written each session. The OSM comparison further down is historical.
>
> Files now live in the normal `View` / `Model` / `Services` folders (the old `RouxTactileMap/` folder was
> dissolved); types still keep the `RTM` prefix.

It shows the Roux Institute neighborhood (Portland, Maine) as a clean, touch‑friendly map and lets you
"walk" around it with a **purple location dot** while the phone **buzzes and speaks** what you're near.
It reuses the map data the app already ships with (`TactileNav/Model/roux_portland.json`) — we did **not**
add any new data file.

> Every file and type in this folder starts with **`RTM`** (Roux Tactile Map) so it's easy to spot and can
> never clash with the rest of TactileNav.

---

## How it's different from "Roux Institute — Portland (OSM)"

There are now two Roux maps in the app, and they feel quite different.

The **OSM** screen ("Roux Institute — Portland (OSM)") is an **abstract drawing on a black screen**. You explore
by sliding one finger around, and there's no "you are here" marker. Its zoom doesn't move a camera — instead it
**shows more or less detail** at three steps (neighborhood → street → intersection).

The new **Tactile Explorer** screen is a **real map**. It's drawn on a **white** background at the real
streets' real positions, and you move a **purple dot** around to explore. It zooms like a normal map (pinch, or
the **+ / − buttons**), you can **drag with two fingers to pan** and **twist to rotate**, and the map **follows
the dot** so you don't run off the edge.

| Thing | Roux — Portland (OSM) | Roux — Tactile Explorer (this folder) |
|---|---|---|
| Background | Black | White |
| Map type | Flat abstract drawing (not a real map) | Real map at true latitude/longitude |
| How you explore | Slide one finger anywhere | Drag a **purple "you are here" dot** |
| Zoom | 3 steps that **add/remove detail** | Real camera zoom — pinch **snaps to 4 levels**, plus **+ / − buttons** |
| Move around | Fixed view | **Two‑finger pan**, **twist to rotate**, **auto‑follow** the dot |
| Buttons | − / + detail | **Zoom in, Zoom out, Center on me** |
| What you hear/feel | Buzz + speech (and switchable spatial/sound modes) | Buzz on streets, pulse on crossings, and **"Name, on your left/right"** at places |

**Honest note — things the OSM screen still does that this one doesn't (yet):**
it offers three switchable feedback styles (plain speech / spatial audio / sound icons),
it declutters by hiding detail when zoomed out, it supports VoiceOver's "direct touch" finger exploration,
and it records a CSV log of touches. The Tactile Explorer focuses on the real‑map + location‑dot experience.

---

## The files — what each one does (and how)

Everything here is working and the app builds clean. In rough "top to bottom" order:

- **`RTMRouxMapView.swift`** — *The screen.* Loads `roux_portland.json`, turns it into our data with the
  adapter, then shows the map plus the floating **+ / − / center** buttons. It also handles the three states:
  a loading spinner, the map, or an error message.

- **`RTMLiveMapView.swift`** — *The actual map.* Wraps a UIKit `MKMapView` so SwiftUI can use it, and its
  inner `Coordinator` does the hands‑on work: dragging the dot (one finger), panning (two fingers), snapping the
  pinch to one of the **four zoom levels** (120 / 300 / 650 / 1000 m), rotating, and **follow mode** (scrolling the
  map to keep the dot in view). It also draws the streets and tells the feedback brain where the dot is.

- **`RTMDocumentAdapter.swift`** — *The translator.* The JSON describes the map in plain meters on a little grid,
  not in real map coordinates. This file converts those meters into real latitude/longitude (anchored at the Roux
  Institute's real center) so it sits correctly on a real map. We do this math ourselves to keep distances true —
  the package's built‑in converter would stretch and misplace it.

- **`RTMMapFeedbackController.swift`** — *The "what should I feel?" brain.* Each time the dot moves, it finds the
  closest thing (place, then intersection, then street) and makes the phone **buzz** and **speak**. It works out
  **"on your left / right"** for places, and has a helper that keeps the dot **glued to the nearest path** so you
  can't wander into blank space.

- **`RTMMapOverlays.swift`** — *The look of the ground + streets.* Paints the whole map **white** (hiding Apple's
  normal map) and defines each street's **color, thickness, and dashes** (blue roads, green footpaths, etc.).

- **`RTMMapAnnotations.swift`** — *The pins and dots.* The red **place pins** (with a little icon each), the orange
  **intersection dots** (which grow/shrink with zoom), and the **purple location dot** with its direction arrow.

- **`RTMDiscoveredStreet.swift` / `RTMDiscoveredIntersection.swift` / `RTMDiscoveredPOI.swift`** — *The simple data
  models.* Plain holders for one street, one intersection, and one place. `RTMDiscoveredStreet` also defines
  `RTMRoadType` (primary, residential, footway, …).

- **`RTMPOICategory.swift`** — *Kinds of place.* The list of place types (restaurant, university, park, …); it
  picks each pin's icon and gives VoiceOver a readable label like "University building."

**Where the rest comes from:** the map data is `TactileNav/Model/roux_portland.json`, and the buzz/speech engines
and the millimeter‑sizing helper come from the shared **TactileMapKit** package (`TactileMapFeedback` and
`TactileMapCore`).

---

## How to open and use it

1. Run TactileNav → on the home list tap **Map → "Roux Institute — Tactile Explorer."**
2. The map opens centered on the **purple dot**.
3. Controls:
   - **One finger** — drag the purple dot to explore (feel streets, hear places).
   - **Two fingers** — pan the map around.
   - **Pinch** — zoom (it snaps to one of 4 levels). Or use the **+ / −** buttons.
   - **Twist** — rotate the map (tap the compass to face north again).
   - **Center button** — jump the map back to the purple dot if you get lost.

> Accessibility tip: with **VoiceOver on**, use the **+ / − / center buttons** to zoom and recenter — they're
> read and tapped normally, which is easier than pinching without sight.
