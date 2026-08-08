#!/usr/bin/env python3
"""Build the Congress Square tactile map from live OpenStreetMap data.

Fetches the downtown Portland, ME street network from the Overpass API and writes
a TactileMapDocument JSON file in local metres, ready to bundle with the app.

    python3 tools/fetch_congress_square.py

Output is deterministic: run it twice on unchanged OSM data and the two files are
byte-identical. Coordinates are metres from the south-west corner of the bounding
box, with y growing *south* (the renderer flips to north-up), so the document is
a plain planar drawing with no projection left to do at runtime.

Data (c) OpenStreetMap contributors, ODbL.
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

# --- Area of interest -------------------------------------------------------
#
# Downtown Portland, ME: I-295 / Marginal Way at the north, the Commercial St
# waterfront at the south, Brighton Ave / St John St west, Franklin / India St
# east. Congress Square sits near the centre.
SOUTH, WEST, NORTH, EAST = 43.6490, -70.2905, 43.6705, -70.2445

# Congress St x High St / Free St — the square the map is named for. Used only to
# choose the opening viewport, and emitted into the document so the app reads it
# from data rather than hardcoding an offset.
CENTER_LAT, CENTER_LON = 43.6537, -70.2635

OVERPASS_ENDPOINTS = (
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
)

METERS_PER_DEGREE_LATITUDE = 111_320.0

# Drivable classes we keep. `highway=service` is excluded on purpose: in this
# bounding box it is overwhelmingly parking-lot aisles and driveways, which read
# as an unnamed thicket under a finger rather than as streets.
ROAD_CLASSES = (
    "motorway",
    "trunk",
    "primary",
    "secondary",
    "tertiary",
    "residential",
    "unclassified",
    "living_street",
    "motorway_link",
    "trunk_link",
    "primary_link",
    "secondary_link",
    "tertiary_link",
)

# Lane count by road class, used when OSM has no `lanes` tag. In this extract the
# tag is present on only a small minority of ways, so this table does most of the
# work — it is a classification, not a measurement, and every element records
# which source produced its value.
LANES_BY_CLASS = {
    "motorway": 4,
    "trunk": 4,
    "primary": 4,
    "secondary": 3,
    "tertiary": 2,
    "residential": 2,
    "unclassified": 2,
    "living_street": 1,
    "motorway_link": 1,
    "trunk_link": 1,
    "primary_link": 1,
    "secondary_link": 1,
    "tertiary_link": 1,
}

# Element types follow the shared vocabulary of the tactile map package:
#   road      -> heavy continuous buzz
#   street    -> softer continuous buzz (what sidewalks get)
#   crosswalk -> sharp repeating tick
TYPE_ROAD = "road"
TYPE_SIDEWALK = "street"
TYPE_CROSSWALK = "crosswalk"
TYPE_INTERSECTION = "intersection"

SIMPLIFY_EPSILON_M = 1.0

# Cut ways that leave the box rather than letting a single vertex outside it
# stretch a line across the whole map.
CLIP_MARGIN_M = 25.0


# --- Overpass ---------------------------------------------------------------

def overpass_query() -> str:
    bbox = f"{SOUTH},{WEST},{NORTH},{EAST}"
    classes = "|".join(ROAD_CLASSES)
    return f"""[out:json][timeout:300];
(
  way["highway"~"^({classes})$"]({bbox});
  way["footway"="sidewalk"]({bbox});
  way["footway"="crossing"]({bbox});
);
out body geom;
"""


def fetch(query: str, retries: int = 4) -> dict:
    body = urllib.parse.urlencode({"data": query}).encode()
    last_error: Exception | None = None
    for attempt in range(retries):
        endpoint = OVERPASS_ENDPOINTS[attempt % len(OVERPASS_ENDPOINTS)]
        try:
            print(f"  querying {urllib.parse.urlparse(endpoint).netloc} ...", file=sys.stderr)
            request = urllib.request.Request(
                endpoint,
                data=body,
                headers={"User-Agent": "TactileNav map builder (contact: UNAR Labs)"},
            )
            with urllib.request.urlopen(request, timeout=420) as response:
                return json.load(response)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as error:
            last_error = error
            wait = 15 * (attempt + 1)
            print(f"  {error} — retrying in {wait}s", file=sys.stderr)
            time.sleep(wait)
    raise SystemExit(f"Overpass failed after {retries} attempts: {last_error}")


# --- Geometry ---------------------------------------------------------------

def meters_per_degree_longitude() -> float:
    mid_lat = (SOUTH + NORTH) / 2.0
    return METERS_PER_DEGREE_LATITUDE * math.cos(math.radians(mid_lat))


def project(lat: float, lon: float) -> tuple[float, float]:
    """Lat/lon -> metres from the SW corner, y growing south."""
    x = (lon - WEST) * meters_per_degree_longitude()
    y = (NORTH - lat) * METERS_PER_DEGREE_LATITUDE
    return x, y


def extent() -> tuple[float, float]:
    width = (EAST - WEST) * meters_per_degree_longitude()
    height = (NORTH - SOUTH) * METERS_PER_DEGREE_LATITUDE
    return width, height


def perpendicular_distance(
    point: tuple[float, float],
    start: tuple[float, float],
    end: tuple[float, float],
) -> float:
    (px, py), (ax, ay), (bx, by) = point, start, end
    dx, dy = bx - ax, by - ay
    length_squared = dx * dx + dy * dy
    if length_squared == 0.0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / length_squared))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def simplify(points: list[tuple[float, float]], epsilon: float) -> list[tuple[float, float]]:
    """Douglas-Peucker, iterative so long ways can't blow the recursion limit."""
    if len(points) < 3:
        return list(points)

    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]

    while stack:
        first, last = stack.pop()
        if last <= first + 1:
            continue
        worst_index, worst_distance = -1, 0.0
        for i in range(first + 1, last):
            distance = perpendicular_distance(points[i], points[first], points[last])
            if distance > worst_distance:
                worst_index, worst_distance = i, distance
        if worst_distance > epsilon:
            keep[worst_index] = True
            stack.append((first, worst_index))
            stack.append((worst_index, last))

    return [point for point, keeper in zip(points, keep) if keeper]


def split_inside_box(
    points: list[tuple[float, float]],
    width: float,
    height: float,
) -> list[list[tuple[float, float]]]:
    """Break a way into the runs of vertices that lie inside the padded box."""

    def inside(point: tuple[float, float]) -> bool:
        x, y = point
        return (
            -CLIP_MARGIN_M <= x <= width + CLIP_MARGIN_M
            and -CLIP_MARGIN_M <= y <= height + CLIP_MARGIN_M
        )

    runs: list[list[tuple[float, float]]] = []
    current: list[tuple[float, float]] = []
    for point in points:
        if inside(point):
            current.append(point)
        elif current:
            runs.append(current)
            current = []
    if current:
        runs.append(current)
    return [run for run in runs if len(run) >= 2]


def drop_repeats(points: list[tuple[float, float]]) -> list[tuple[float, float]]:
    result: list[tuple[float, float]] = []
    for point in points:
        if not result or math.hypot(point[0] - result[-1][0], point[1] - result[-1][1]) > 1e-6:
            result.append(point)
    return result


def polyline_length(points: list[tuple[float, float]]) -> float:
    return sum(
        math.hypot(b[0] - a[0], b[1] - a[1])
        for a, b in zip(points, points[1:])
    )


# --- Element construction ---------------------------------------------------

def road_name(tags: dict) -> str | None:
    name = (tags.get("name") or "").strip()
    if name:
        return name
    # Unnamed ways are dropped, except link roads (ramps): they carry the grade
    # separations that make the network make sense, and are almost never named.
    if tags.get("highway", "").endswith("_link"):
        ref = (tags.get("ref") or "").strip()
        return f"{ref} ramp" if ref else "Ramp"
    return None


def lane_count(tags: dict) -> tuple[int, str]:
    raw = (tags.get("lanes") or "").split(";")[0].strip()
    try:
        lanes = int(float(raw))
        if lanes >= 1:
            return lanes, "osm"
    except ValueError:
        pass
    return LANES_BY_CLASS.get(tags.get("highway", ""), 2), "class"


def crossing_name(tags: dict) -> str:
    name = (tags.get("name") or "").strip()
    return name if name else "Crosswalk"


def build_elements(raw: dict, width: float, height: float) -> list[dict]:
    elements: list[dict] = []
    counts = {TYPE_ROAD: 0, TYPE_SIDEWALK: 0, TYPE_CROSSWALK: 0}
    dropped_unnamed = 0

    for way in raw.get("elements", []):
        if way.get("type") != "way" or "geometry" not in way:
            continue
        tags = way.get("tags", {})
        footway = tags.get("footway")

        if footway == "sidewalk":
            element_type = TYPE_SIDEWALK
            name = (tags.get("name") or "").strip() or "Sidewalk"
            custom = {}
        elif footway == "crossing":
            element_type = TYPE_CROSSWALK
            name = crossing_name(tags)
            custom = {}
            if tags.get("crossing:markings"):
                custom["crossing_markings"] = tags["crossing:markings"]
            if tags.get("crossing"):
                custom["crossing_control"] = tags["crossing"]
        elif tags.get("highway") in ROAD_CLASSES:
            element_type = TYPE_ROAD
            name = road_name(tags)
            if name is None:
                dropped_unnamed += 1
                continue
            lanes, lanes_source = lane_count(tags)
            custom = {
                "lanes": str(lanes),
                "lanes_source": lanes_source,
                "osm_highway": tags["highway"],
            }
            if tags.get("oneway"):
                custom["oneway"] = tags["oneway"]
        else:
            continue

        projected = [project(node["lat"], node["lon"]) for node in way["geometry"]]
        for index, run in enumerate(split_inside_box(projected, width, height)):
            simplified = drop_repeats(simplify(run, SIMPLIFY_EPSILON_M))
            if len(simplified) < 2 or polyline_length(simplified) < 1.0:
                continue
            suffix = f"-{index}" if index else ""
            elements.append(
                {
                    "id": f"{element_type[0]}-{way['id']}{suffix}",
                    "element_type": element_type,
                    "geometry": {
                        "type": "LineString",
                        "coordinates": [
                            [round(x, 2), round(y, 2)] for x, y in simplified
                        ],
                    },
                    "properties": {
                        "name": name,
                        "category": tags.get("highway", element_type),
                        "is_accessible": True,
                        "custom": custom,
                    },
                }
            )
            counts[element_type] += 1

    elements.sort(key=lambda element: element["id"])
    print(
        f"  roads {counts[TYPE_ROAD]}  sidewalks {counts[TYPE_SIDEWALK]}  "
        f"crossings {counts[TYPE_CROSSWALK]}  (dropped {dropped_unnamed} unnamed roads)",
        file=sys.stderr,
    )
    return elements


def compass_bearing(origin: tuple[float, float], toward: tuple[float, float]) -> float:
    """Compass bearing in degrees from `origin` to `toward`: 0 = north, 90 = east.

    Coordinates are projected metres with y growing *south*, so northward is -y.
    """
    dx = toward[0] - origin[0]
    dy = toward[1] - origin[1]
    return math.degrees(math.atan2(dx, -dy)) % 360.0


def build_intersections(raw: dict, width: float, height: float) -> list[dict]:
    """Find every junction in the road network from OSM's own node topology.

    Two ways that genuinely meet *share a node*; two ways that merely cross on a
    bridge do not. So sharing a node is the definition of an intersection, and using
    it means grade separations are excluded for free rather than needing a bridge tag
    (which this extract does not carry). It also catches every shape of junction —
    two-way corners where one street becomes another, T-junctions, four-way crossings
    and the occasional five — without any of them being special-cased.

    A node shared only by ways carrying the *same* name is a street split into pieces,
    not a junction, so at least two distinct street names are required.
    """
    # node id -> list of (way name, way id, position in way, geometry, index)
    node_uses: dict[int, list[dict]] = {}

    for way in raw.get("elements", []):
        if way.get("type") != "way" or "geometry" not in way or "nodes" not in way:
            continue
        tags = way.get("tags", {})
        if tags.get("highway") not in ROAD_CLASSES:
            continue
        name = road_name(tags)
        if name is None:
            continue

        node_ids = way["nodes"]
        geometry = way["geometry"]
        if len(node_ids) != len(geometry):
            continue

        projected = [project(node["lat"], node["lon"]) for node in geometry]
        for index, node_id in enumerate(node_ids):
            node_uses.setdefault(node_id, []).append(
                {
                    "name": name,
                    "way": way["id"],
                    "index": index,
                    "count": len(node_ids),
                    "points": projected,
                }
            )

    intersections: list[dict] = []
    for node_id, uses in node_uses.items():
        names = sorted({use["name"] for use in uses})
        if len(names) < 2:
            continue

        point = uses[0]["points"][uses[0]["index"]]
        x, y = point
        if not (-CLIP_MARGIN_M <= x <= width + CLIP_MARGIN_M):
            continue
        if not (-CLIP_MARGIN_M <= y <= height + CLIP_MARGIN_M):
            continue

        # One leg per direction the roadway continues: a way that ends here
        # contributes one, a way that passes through contributes two.
        legs: list[tuple[float, str]] = []
        for use in uses:
            index, points = use["index"], use["points"]
            if index > 0:
                legs.append((compass_bearing(point, points[index - 1]), use["name"]))
            if index < use["count"] - 1:
                legs.append((compass_bearing(point, points[index + 1]), use["name"]))
        legs.sort()

        intersections.append(
            {
                "id": f"x-{node_id}",
                "element_type": TYPE_INTERSECTION,
                "geometry": {"type": "Point", "coordinates": [round(x, 2), round(y, 2)]},
                "properties": {
                    "name": " and ".join(names),
                    "category": TYPE_INTERSECTION,
                    "is_accessible": True,
                    "custom": {
                        "streets": "|".join(names),
                        "legs": str(len(legs)),
                        "leg_bearings": "|".join(f"{bearing:.1f}" for bearing, _ in legs),
                        "leg_names": "|".join(name for _, name in legs),
                    },
                },
            }
        )

    intersections.sort(key=lambda element: element["id"])
    shapes: dict[int, int] = {}
    for element in intersections:
        legs = int(element["properties"]["custom"]["legs"])
        shapes[legs] = shapes.get(legs, 0) + 1
    summary = "  ".join(f"{legs}-way {count}" for legs, count in sorted(shapes.items()))
    print(f"  intersections {len(intersections)}  ({summary})", file=sys.stderr)
    return intersections


def build_document(elements: list[dict], width: float, height: float) -> dict:
    center_x, center_y = project(CENTER_LAT, CENTER_LON)
    lane_sources = [
        element["properties"]["custom"].get("lanes_source")
        for element in elements
        if element["element_type"] == TYPE_ROAD
    ]
    return {
        "version": "2.0",
        "type": "TactileMapDocument",
        "metadata": {
            "name": "Congress Square - Portland, ME",
            "scale": "1 unit = 1 meter",
            "coordinate_unit": "meters",
            "coordinate_origin": "SW corner; y grows south",
            "source": "OpenStreetMap (ODbL)",
            "bbox": {"south": SOUTH, "west": WEST, "north": NORTH, "east": EAST},
            "initial_center": [round(center_x, 2), round(center_y, 2)],
            "lanes_from_osm_tag": lane_sources.count("osm"),
            "lanes_from_road_class": lane_sources.count("class"),
            "intersections": sum(
                1 for element in elements if element["element_type"] == TYPE_INTERSECTION
            ),
        },
        "bounds": {"width": round(width, 2), "height": round(height, 2)},
        "features": elements,
    }


def validate(document: dict) -> None:
    width = document["bounds"]["width"]
    height = document["bounds"]["height"]
    seen_ids: set[str] = set()

    for element in document["features"]:
        element_id = element["id"]
        if element_id in seen_ids:
            raise SystemExit(f"duplicate element id: {element_id}")
        seen_ids.add(element_id)

        if not element["properties"]["name"]:
            raise SystemExit(f"{element_id}: empty name")

        coordinates = element["geometry"]["coordinates"]
        if element["geometry"]["type"] == "Point":
            coordinates = [coordinates]
        elif len(coordinates) < 2:
            raise SystemExit(f"{element_id}: degenerate geometry")
        for x, y in coordinates:
            if not (math.isfinite(x) and math.isfinite(y)):
                raise SystemExit(f"{element_id}: non-finite coordinate")
            if not (
                -CLIP_MARGIN_M - 1 <= x <= width + CLIP_MARGIN_M + 1
                and -CLIP_MARGIN_M - 1 <= y <= height + CLIP_MARGIN_M + 1
            ):
                raise SystemExit(f"{element_id}: coordinate {x},{y} outside bounds")

    if not document["features"]:
        raise SystemExit("no features produced")
    print(f"  validated {len(document['features'])} elements", file=sys.stderr)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        type=Path,
        default=Path(__file__).resolve().parent.parent
        / "TactileNav"
        / "Model"
        / "congress_square.json",
    )
    parser.add_argument(
        "--cache",
        type=Path,
        help="Reuse a saved Overpass response instead of querying (for reproducible reruns).",
    )
    args = parser.parse_args()

    if args.cache and args.cache.exists():
        print(f"reading cached Overpass response {args.cache}", file=sys.stderr)
        raw = json.loads(args.cache.read_text())
    else:
        print("fetching OpenStreetMap data ...", file=sys.stderr)
        raw = fetch(overpass_query())
        if args.cache:
            args.cache.write_text(json.dumps(raw))
            print(f"cached Overpass response to {args.cache}", file=sys.stderr)

    width, height = extent()
    print(f"building document ({width:.0f} m x {height:.0f} m) ...", file=sys.stderr)
    elements = build_elements(raw, width, height)
    elements += build_intersections(raw, width, height)
    elements.sort(key=lambda element: element["id"])
    document = build_document(elements, width, height)
    validate(document)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(document, indent=1, sort_keys=True, ensure_ascii=False) + "\n"
    )
    size_mb = args.output.stat().st_size / 1_048_576
    print(f"wrote {args.output} ({size_mb:.2f} MB)", file=sys.stderr)


if __name__ == "__main__":
    main()
