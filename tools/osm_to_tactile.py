#!/usr/bin/env python3
"""
osm_to_tactile.py — OFFLINE build tool (NOT shipped in the app).

Converts a manually-exported OpenStreetMap XML file (.osm) into a
TactileMapDocument JSON file that the TactileMapDemo / TactileMapKit
Canvas renderer can load.

Mapping:
  OSM highway way        -> corridor   (LineString)
  shared junction node   -> intersection (Point)
  traffic_signals / crossing / named POI / Roux anchor -> landmark (Point)

Coordinates are projected from lat/lon into a local METERS grid using a
simple equirectangular projection centered on the data. Screen-y is
flipped so north is at the top. Geometry of long ways is simplified with
Douglas-Peucker, but nodes carrying semantic tags are never removed.

Usage:
  python3 osm_to_tactile.py INPUT.osm OUTPUT.json [--name "Map name"]
"""

import sys
import math
import json
import argparse
import xml.etree.ElementTree as ET

# Highway values kept as corridors. Foot-prohibited ones are marked
# is_accessible=false but still drawn for spatial context.
WALKABLE = {
    "footway", "path", "pedestrian", "steps", "cycleway", "track",
    "residential", "living_street", "service", "unclassified",
    "tertiary", "tertiary_link", "secondary", "secondary_link",
    "primary", "primary_link",
}
VEHICLE_ONLY = {
    "motorway", "motorway_link", "trunk", "trunk_link", "motorway_junction",
}
CORRIDOR_HIGHWAYS = WALKABLE | VEHICLE_ONLY


def perpendicular_distance(pt, a, b):
    (px, py), (ax, ay), (bx, by) = pt, a, b
    dx, dy = bx - ax, by - ay
    if dx == 0 and dy == 0:
        return math.hypot(px - ax, py - ay)
    t = ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)
    t = max(0.0, min(1.0, t))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def douglas_peucker(points, epsilon, keep_flags):
    """Simplify a polyline but never drop a point flagged keep=True."""
    if len(points) < 3:
        return points
    dmax, idx = 0.0, 0
    for i in range(1, len(points) - 1):
        d = perpendicular_distance(points[i], points[0], points[-1])
        if d > dmax:
            dmax, idx = d, i
    must_keep_inside = any(keep_flags[1:-1])
    if dmax > epsilon or must_keep_inside:
        left = douglas_peucker(points[:idx + 1], epsilon, keep_flags[:idx + 1])
        right = douglas_peucker(points[idx:], epsilon, keep_flags[idx:])
        return left[:-1] + right
    return [points[0], points[-1]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("input")
    ap.add_argument("output")
    ap.add_argument("--name", default="Roux Institute Area - Portland, ME")
    ap.add_argument("--epsilon", type=float, default=1.5,
                    help="Douglas-Peucker tolerance in meters")
    args = ap.parse_args()

    tree = ET.parse(args.input)
    root = tree.getroot()

    # ---- Pass 1: read all nodes ----
    nodes = {}        # id -> (lat, lon, tags)
    for n in root.findall("node"):
        nid = n.get("id")
        tags = {t.get("k"): t.get("v") for t in n.findall("tag")}
        nodes[nid] = (float(n.get("lat")), float(n.get("lon")), tags)

    # ---- Pass 2: read ways, keep only highway corridors ----
    ways = []         # (way_id, [node_ids], tags)
    node_use_count = {}
    for w in root.findall("way"):
        tags = {t.get("k"): t.get("v") for t in w.findall("tag")}
        hw = tags.get("highway")
        if hw not in CORRIDOR_HIGHWAYS:
            continue
        refs = [nd.get("ref") for nd in w.findall("nd")]
        refs = [r for r in refs if r in nodes]
        if len(refs) < 2:
            continue
        ways.append((w.get("id"), refs, tags))
        for r in refs:
            node_use_count[r] = node_use_count.get(r, 0) + 1

    # ---- Identify landmark nodes (traffic signals, crossings, named POIs, Roux) ----
    def is_landmark(tags):
        if tags.get("highway") == "traffic_signals":
            return ("traffic_signal", tags.get("name", "Traffic signal"))
        if tags.get("highway") == "crossing" or "crossing" in tags:
            return ("crossing", tags.get("name", "Crossing"))
        if tags.get("amenity") and tags.get("name"):
            return (tags["amenity"], tags["name"])
        if tags.get("shop") and tags.get("name"):
            return ("shop", tags["name"])
        if tags.get("name") and ("building" in tags or "tourism" in tags):
            return ("building", tags["name"])
        return None

    # Roux anchor: find any node/way named like the Roux Institute
    roux_name_match = lambda v: v and "roux" in v.lower()

    # ---- Projection extent: use only nodes referenced by kept geometry + landmarks
    used = set()
    for _, refs, _ in ways:
        used.update(refs)
    landmark_node_ids = set()
    for nid, (lat, lon, tags) in nodes.items():
        if is_landmark(tags):
            landmark_node_ids.add(nid)
            used.add(nid)

    lats = [nodes[n][0] for n in used]
    lons = [nodes[n][1] for n in used]
    minlat, maxlat = min(lats), max(lats)
    minlon, maxlon = min(lons), max(lons)
    lat0 = (minlat + maxlat) / 2.0
    m_per_deg_lat = 111320.0
    m_per_deg_lon = 111320.0 * math.cos(math.radians(lat0))

    def project(nid):
        lat, lon, _ = nodes[nid]
        x = (lon - minlon) * m_per_deg_lon
        y = (maxlat - lat) * m_per_deg_lat   # flip: north -> top
        return (round(x, 2), round(y, 2))

    width = round((maxlon - minlon) * m_per_deg_lon, 2)
    height = round((maxlat - minlat) * m_per_deg_lat, 2)

    features = []

    # ---- Corridors ----
    for wid, refs, tags in ways:
        hw = tags["highway"]
        pts = [project(r) for r in refs]
        keep = [node_use_count.get(r, 0) >= 2 or r in landmark_node_ids
                for r in refs]
        pts = douglas_peucker(pts, args.epsilon, keep)
        features.append({
            "id": f"c-{wid}",
            "element_type": "corridor",
            "geometry": {"type": "LineString",
                         "coordinates": [[p[0], p[1]] for p in pts]},
            "properties": {
                "name": tags.get("name", hw.replace("_", " ").title()),
                "category": hw,
                "is_accessible": hw not in VEHICLE_ONLY,
            },
        })

    # ---- Intersections (shared nodes that aren't landmarks) ----
    for nid, count in node_use_count.items():
        if count >= 2 and nid not in landmark_node_ids:
            x, y = project(nid)
            connected = [f"c-{wid}" for wid, refs, _ in ways if nid in refs]
            features.append({
                "id": f"i-{nid}",
                "element_type": "intersection",
                "geometry": {"type": "Point", "coordinates": [x, y]},
                "properties": {
                    "name": "Intersection",
                    "connected_corridors": connected,
                },
            })

    # ---- Landmarks (point nodes) ----
    for nid in landmark_node_ids:
        lat, lon, tags = nodes[nid]
        cat, name = is_landmark(tags)
        x, y = project(nid)
        features.append({
            "id": f"l-{nid}",
            "element_type": "landmark",
            "geometry": {"type": "Point", "coordinates": [x, y]},
            "properties": {"name": name, "category": cat, "side": "right"},
        })

    # ---- Roux anchor (from named node OR way centroid) ----
    roux_added = any(roux_name_match(nodes[n][2].get("name")) for n in landmark_node_ids)
    if not roux_added:
        # search a way named Roux and use its centroid
        for w in root.findall("way"):
            tags = {t.get("k"): t.get("v") for t in w.findall("tag")}
            if roux_name_match(tags.get("name")):
                refs = [nd.get("ref") for nd in w.findall("nd") if nd.get("ref") in nodes]
                if refs:
                    xs = [project(r)[0] for r in refs]
                    ys = [project(r)[1] for r in refs]
                    features.append({
                        "id": "l-roux-anchor",
                        "element_type": "landmark",
                        "geometry": {"type": "Point",
                                     "coordinates": [round(sum(xs) / len(xs), 2),
                                                     round(sum(ys) / len(ys), 2)]},
                        "properties": {"name": tags["name"],
                                       "category": "anchor", "side": "right"},
                    })
                    roux_added = True
                break

    doc = {
        "version": "1.0",
        "type": "TactileMapDocument",
        "metadata": {
            "name": args.name,
            "scale": "1 unit = 1 meter",
            "coordinate_unit": "meters",
            "source": "OpenStreetMap (ODbL) — manual export",
            "center_lat": round(lat0, 6),
        },
        "bounds": {"width": width, "height": height},
        "features": features,
    }

    with open(args.output, "w") as f:
        json.dump(doc, f, indent=2)

    # ---- Report ----
    corr = sum(1 for f in features if f["element_type"] == "corridor")
    inter = sum(1 for f in features if f["element_type"] == "intersection")
    land = sum(1 for f in features if f["element_type"] == "landmark")
    print(f"Wrote {args.output}")
    print(f"  bounds: {width} x {height} meters")
    print(f"  corridors:     {corr}")
    print(f"  intersections: {inter}")
    print(f"  landmarks:     {land}")
    print(f"  Roux anchor present: {roux_added}")


if __name__ == "__main__":
    main()
