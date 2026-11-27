"""Builds the app's Hong Kong dataset from OpenStreetMap downloads.

Inputs (same folder): places.json, homes.json, work.json, branches.json
Outputs: hk_places.json, hk_cells.json  (copied into the app bundle)

Data: (c) OpenStreetMap contributors, ODbL. District populations: 2021 Population Census
(Census and Statistics Department), rounded. Branch list: the team's app concept (published list).
"""
import json, math, re, sys
from collections import defaultdict, Counter
from datetime import datetime, timezone

TODAY = datetime(2026, 11, 27, tzinfo=timezone.utc)

# Territory grid: about 280 m x 280 m blocks.
MIN_LAT, MAX_LAT, MIN_LON, MAX_LON = 22.15, 22.57, 113.82, 114.45
LAT_STEP, LON_STEP = 0.0025, 0.0027
ROWS = math.ceil((MAX_LAT - MIN_LAT) / LAT_STEP - 1e-9)
COLS = math.ceil((MAX_LON - MIN_LON) / LON_STEP - 1e-9)

# 2021 Population Census, district totals (rounded to the nearest hundred).
DISTRICTS = [
    # key, English, Chinese, population
    ("central", "Central and Western", "中西區", 236000),
    ("wanchai", "Wan Chai", "灣仔區", 166700),
    ("eastern", "Eastern", "東區", 529600),
    ("southern", "Southern", "南區", 263300),
    ("ytm", "Yau Tsim Mong", "油尖旺區", 310600),
    ("ssp", "Sham Shui Po", "深水埗區", 431100),
    ("kc", "Kowloon City", "九龍城區", 410600),
    ("wts", "Wong Tai Sin", "黃大仙區", 406800),
    ("kt", "Kwun Tong", "觀塘區", 673200),
    ("kwaitsing", "Kwai Tsing", "葵青區", 495800),
    ("tsuenwan", "Tsuen Wan", "荃灣區", 320100),
    ("tuenmun", "Tuen Mun", "屯門區", 506900),
    ("yuenlong", "Yuen Long", "元朗區", 668100),
    ("north", "North", "北區", 309600),
    ("taipo", "Tai Po", "大埔區", 316500),
    ("shatin", "Sha Tin", "沙田區", 692800),
    ("saikung", "Sai Kung", "西貢區", 489000),
    ("islands", "Islands", "離島區", 185300),
]

def district_key(name_en):
    n = (name_en or "").lower()
    rules = [("central", "central"), ("wan chai", "wanchai"), ("eastern", "eastern"), ("southern", "southern"),
             ("yau tsim", "ytm"), ("sham shui", "ssp"), ("kowloon city", "kc"), ("wong tai", "wts"),
             ("kwun tong", "kt"), ("kwai", "kwaitsing"), ("tsuen wan", "tsuenwan"), ("tuen mun", "tuenmun"),
             ("yuen long", "yuenlong"), ("north", "north"), ("tai po", "taipo"), ("sha tin", "shatin"),
             ("sai kung", "saikung"), ("islands", "islands")]
    for needle, key in rules:
        if needle in n:
            return key
    return None

def cell_id(lat, lon):
    row = math.floor((lat - MIN_LAT) / LAT_STEP)
    col = math.floor((lon - MIN_LON) / LON_STEP)
    if 0 <= row < ROWS and 0 <= col < COLS:
        return row * COLS + col
    return None

def meters(a_lat, a_lon, b_lat, b_lon):
    mid = math.radians((a_lat + b_lat) / 2)
    dx = (b_lon - a_lon) * math.cos(mid) * 111320
    dy = (b_lat - a_lat) * 110540
    return math.hypot(dx, dy)

def coords(e):
    if "lat" in e:
        return e["lat"], e["lon"]
    c = e.get("center")
    return (c["lat"], c["lon"]) if c else (None, None)

def days_since(e):
    tags = e.get("tags", {})
    stamp = tags.get("check_date") or tags.get("survey:date")
    try:
        if stamp:
            when = datetime.fromisoformat(stamp[:10]).replace(tzinfo=timezone.utc)
        else:
            when = datetime.fromisoformat(e["timestamp"].replace("Z", "+00:00"))
        return max(0, (TODAY - when).days)
    except Exception:
        return 3650

CJK = re.compile(r"[　-鿿豈-﫿]")

def split_names(tags):
    """OSM in Hong Kong often writes 'name' as '旺角 Mong Kok'. Returns (english, chinese)."""
    en = tags.get("name:en")
    zh = tags.get("name:zh") or tags.get("name:zh-Hant") or tags.get("name:zh-HK")
    name = tags.get("name", "")
    if not en:
        latin = " ".join(part for part in name.split() if not CJK.search(part)).strip()
        en = latin or None
    if not zh:
        chinese = "".join(part for part in name.split() if CJK.search(part)).strip()
        zh = chinese or None
    return en, zh

def short(x, n=5):
    return round(x, n)

# ---------------------------------------------------------------- places
places_raw = json.load(open("places.json"))["elements"]

stations, universities, schools, rivals, osm_stores = [], [], [], [], []
seen_station_names = set()
for e in places_raw:
    tags = e.get("tags", {})
    lat, lon = coords(e)
    if lat is None:
        continue
    pid = f"osm-{e['type'][0]}{e['id']}"
    en, zh = split_names(tags)
    fresh = days_since(e)
    name_all = tags.get("name", "") + " " + (tags.get("name:en") or "")

    if "大家樂" in name_all or tags.get("brand:wikidata") == "Q16241484":
        if any(word in name_all for word in ["產製", "Processing", "單車", "Bicycle", "大家樂中心", "Café de Coral Centre", "Food Processing"]):
            continue
        if tags.get("amenity") not in ("fast_food", "restaurant", None):
            continue
        street = tags.get("addr:street", "")
        street_en = " ".join(p for p in street.split() if not CJK.search(p)).strip()
        street_zh = "".join(p for p in street.split() if CJK.search(p)).strip()
        number = tags.get("addr:housenumber", "")
        osm_stores.append(dict(id=pid, lat=lat, lon=lon, street_en=street_en, street_zh=street_zh, number=number,
                               branch=tags.get("branch:en") or tags.get("branch"), fresh=fresh))
        continue

    brand = tags.get("brand:en")
    if brand in ("Fairwood", "Maxim's MX", "Tai Hing", "McDonald's"):
        zh_brand = {"Fairwood": "大快活", "Maxim's MX": "美心MX", "Tai Hing": "太興", "McDonald's": "麥當勞"}[brand]
        rivals.append(dict(id=pid, kind="rival", name=brand, nameZH=zh_brand, lat=lat, lon=lon, fresh=fresh))
        continue

    if tags.get("amenity") == "university":
        if en or zh:
            universities.append(dict(id=pid, kind="university", name=en or zh, nameZH=zh or en, lat=lat, lon=lon, fresh=fresh))
        continue

    if tags.get("amenity") == "school":
        if en or zh:
            schools.append(dict(id=pid, kind="school", name=en or zh, nameZH=zh or en, lat=lat, lon=lon, fresh=fresh))
        continue

    if tags.get("railway") == "station":
        network = (tags.get("network", "") + " " + tags.get("operator", "") + " " + tags.get("network:en", "")).lower()
        if tags.get("station") == "light_rail" or "light rail" in network:
            continue
        if "mtr" not in network and "港鐵" not in network and "airport express" not in network:
            continue
        if not en:
            continue
        key = en.lower().replace(" station", "").strip()
        if key in seen_station_names:
            continue
        seen_station_names.add(key)
        base_en = re.sub(r"\s+station$", "", en, flags=re.I)
        base_zh = re.sub(r"站$", "", zh or "")
        stations.append(dict(id=pid, kind="mtr", name=f"{base_en} station", nameZH=f"{base_zh}站" if base_zh else f"{base_en}站",
                             lat=lat, lon=lon, fresh=fresh, aliases=[]))

# Dedupe universities and schools by name (campuses often appear as several elements).
def dedupe_by_name(items):
    seen, out = set(), []
    for item in items:
        key = (item["name"].lower(), round(item["lat"], 2), round(item["lon"], 2))
        if key in seen:
            continue
        seen.add(key)
        out.append(item)
    return out

universities = dedupe_by_name(universities)
schools = dedupe_by_name(schools)

def nearest(items, lat, lon):
    best, best_d = None, float("inf")
    for item in items:
        d = meters(lat, lon, item["lat"], item["lon"])
        if d < best_d:
            best, best_d = item, d
    return best, best_d

# Stores: the published branch list first (better names), then OpenStreetMap entries not already covered.
branches = json.load(open("branches.json"))
stores = []
for b in branches:
    stores.append(dict(id=b["id"], kind="cdcStore", name=f"{b['area']}, {b['address'].split(',')[0]}", nameZH=b["zh"],
                       lat=b["lat"], lon=b["lon"], detail=b["address"], fresh=10, source="branch list"))
# The full May 2023 list (Weekend Weekly), geocoded with Nominatim. Older than OSM's newest edits, so it's
# marked with its real age and shows as "needs a check".
import os
LIST_AGE = (TODAY - datetime(2023, 5, 10, tzinfo=timezone.utc)).days
def fill_missing(w):
    """Branches the geocoder couldn't place: shops inside an MTR station go on the station; the rest go
    on their neighbourhood's centre, flagged approximate. Leaving them out would invent false gaps."""
    m = re.search(r"([\u4e00-\u9fff]{1,6})站", w["address"])
    if m:
        name = m.group(1).replace("機鐵", "").replace("港鐵", "")
        for st in stations:
            if st["nameZH"].startswith(name) or (name == "香港" and st["name"].startswith("Hong Kong station")):
                return dict(w, lat=st["lat"], lon=st["lon"], approximate=False, query="MTR station")
    cache = json.load(open("geocode_cache.json")) if os.path.exists("geocode_cache.json") else {}
    hit = cache.get(f"{w['area']}, 香港")
    if hit:
        return dict(w, lat=float(hit[0]["lat"]), lon=float(hit[0]["lon"]), approximate=True, query="area centre")
    return w

# Branches the geocoder missed or put in the wrong place, fixed by hand from OpenStreetMap buildings and
# street numbers (see verify_branches.py, which fixed the others automatically). Key: part of the address.
HAND_FIXES = {
    "駱克道151號": (22.27841, 114.17339, "OpenStreetMap: 151-155 Lockhart Road"),
    "彌敦道655號": (22.31885, 114.16955, "OpenStreetMap: opposite 654-658 Nathan Road"),
    "豉油街36": (22.31659, 114.17096, "OpenStreetMap: Wingco Mansion, 3-7 Tung Choi Street"),
    "深旺道28號": (22.32697, 114.15381, "OpenStreetMap: V Walk"),
    "櫸樹街88號": (22.32073, 114.16343, "OpenStreetMap: Park Summit, 88 Beech Street"),
    "啟業商場": (22.33020, 114.21060, "OpenStreetMap: Kai Yip Estate"),
    "豐利中心": (22.30954, 114.22408, "OpenStreetMap: Hewlett Centre, 54 Hoi Yuen Road"),
    "保華企業中心": (22.31143, 114.22191, "OpenStreetMap: 51 Hung To Road"),
    "京瑞廣場": (22.38898, 114.20895, "OpenStreetMap: Kings Wing Plaza 2, 1 On Kwan Street"),
    "寶鄉街76號": (22.44800, 114.16655, "OpenStreetMap: 74-78 Po Heung Street"),
    "新豐路140號": (22.50334, 114.12655, "OpenStreetMap: Café de Coral, San Fung Avenue"),
    "Magnet Place": (22.35536, 114.12550, "OpenStreetMap: Magnet Place, 81 Container Port Road"),
    "青山公路118號": (22.44425, 114.02862, "OpenStreetMap: 118 Castle Peak Road (Yuen Long)"),
    "良景商場": (22.40635, 113.96336, "OpenStreetMap: Leung King Plaza"),
    "嘉湖二期": (22.45800, 114.00400, "OpenStreetMap: Kingswood Villas (phase not mapped)"),
    "富東商場": (22.28890, 113.94200, "OpenStreetMap: Fu Tung Plaza"),
}

if os.path.exists("weekend_geocoded.json"):
    for i, w in enumerate(json.load(open("weekend_geocoded.json"))):
        for key, (lat, lon, note) in HAND_FIXES.items():
            if key in w["address"]:
                w = dict(w, lat=lat, lon=lon, query=note, approximate="phase not mapped" in note)
        if "lat" not in w:
            w = fill_missing(w)
        if "lat" not in w:
            continue
        if any(meters(w["lat"], w["lon"], t["lat"], t["lon"]) < 120 for t in stores):
            continue
        station, d = nearest(stations, w["lat"], w["lon"])
        near = station["name"].replace(" station", "") if station and d < 1500 else w["area"]
        stores.append(dict(id=f"list-{i}", kind="cdcStore", name=f"Near {near}", nameZH=f"{w['area']} · {w['address'][:18]}",
                           lat=w["lat"], lon=w["lon"], detail=w["address"], fresh=LIST_AGE,
                           source="Branch list, May 2023" + (" (approximate location)" if w.get("approximate") else "")))

for s in osm_stores:
    if any(meters(s["lat"], s["lon"], t["lat"], t["lon"]) < 150 for t in stores):
        continue
    station, _ = nearest(stations, s["lat"], s["lon"])
    near = station["name"].replace(" station", "") if station else "Hong Kong"
    if s["branch"]:
        name = s["branch"]
    elif s["street_en"]:
        name = f"{near}, {(s['number'] + ' ') if s['number'] else ''}{s['street_en']}"
    else:
        name = f"{near}"
    detail = (f"{s['number']} {s['street_en']}".strip() if s["street_en"] else f"Near {near} station")
    zh = (s["street_zh"] + (s["number"] + "號" if s["number"] else "")) if s["street_zh"] else (station["nameZH"] + "附近" if station else "")
    stores.append(dict(id=s["id"], kind="cdcStore", name=name, nameZH=zh, lat=s["lat"], lon=s["lon"], detail=detail,
                       fresh=s["fresh"], source="OpenStreetMap"))

# Give rivals a location note.
for r in rivals:
    station, d = nearest(stations, r["lat"], r["lon"])
    r["detail"] = f"Near {station['name']}" if station and d < 1500 else "Hong Kong"

# ---------------------------------------------------------------- homes → residents per cell
homes_raw = json.load(open("homes.json"))["elements"]
current = None
building_district = {}
weights = defaultdict(float)
cell_weight = defaultdict(lambda: defaultdict(float))  # district -> cell -> weight
for e in homes_raw:
    if e["type"] == "relation":
        current = district_key(e.get("tags", {}).get("name:en"))
        continue
    if current is None or e["id"] in building_district:
        continue
    lat, lon = coords(e)
    if lat is None:
        continue
    building_district[e["id"]] = current
    tags = e.get("tags", {})
    kind = tags.get("building")
    levels = None
    try:
        levels = float(tags.get("building:levels"))
    except (TypeError, ValueError):
        try:
            levels = float(str(tags.get("height", "")).replace("m", "")) / 3
        except ValueError:
            levels = None
    if not levels or levels <= 0:
        levels = {"apartments": 25, "residential": 12, "dormitory": 8, "house": 2}.get(kind, 6)
    levels = min(levels, 70)
    cid = cell_id(lat, lon)
    if cid is None:
        continue
    weights[current] += levels
    cell_weight[current][cid] += levels

residents = defaultdict(float)
cell_district_votes = defaultdict(Counter)
for key, _, _, population in DISTRICTS:
    total = weights.get(key, 0)
    if total <= 0:
        print("warning: no homes for", key, file=sys.stderr)
        continue
    for cid, w in cell_weight[key].items():
        residents[cid] += population * w / total
        cell_district_votes[cid][key] += w

# ---------------------------------------------------------------- work and shops per cell
work_raw = json.load(open("work.json"))["elements"]
office = defaultdict(float)
shops = defaultdict(float)
for e in work_raw:
    lat, lon = coords(e)
    if lat is None:
        continue
    cid = cell_id(lat, lon)
    if cid is None:
        continue
    tags = e.get("tags", {})
    if e["type"] == "node" and not tags:
        shops[cid] += 1  # "out skel" shop nodes carry no tags
    elif tags.get("building") in ("office", "commercial"):
        try:
            levels = float(tags.get("building:levels"))
        except (TypeError, ValueError):
            levels = 12
        office[cid] += min(levels, 80)
    else:
        office[cid] += 3

# ---------------------------------------------------------------- cells
all_places = stores + rivals + universities + schools + stations
active = set(residents) | set(office) | set(shops)
for p in all_places:
    cid = cell_id(p["lat"], p["lon"])
    if cid is not None:
        active.add(cid)
# Keep a one-block margin around activity so demand can spread into the next street.
margin = set()
for cid in active:
    r, c = divmod(cid, COLS)
    for dr in (-1, 0, 1):
        for dc in (-1, 0, 1):
            if 0 <= r + dr < ROWS and 0 <= c + dc < COLS:
                margin.add((r + dr) * COLS + (c + dc))
active |= margin

district_index = {key: i for i, (key, *_rest) in enumerate(DISTRICTS)}
labelled = {cid: votes.most_common(1)[0][0] for cid, votes in cell_district_votes.items()}

def district_for(cid):
    if cid in labelled:
        return labelled[cid]
    r, c = divmod(cid, COLS)
    for radius in range(1, 40):
        best = None
        for dr in range(-radius, radius + 1):
            for dc in (-radius, radius) if abs(dr) != radius else range(-radius, radius + 1):
                other = (r + dr) * COLS + (c + dc)
                if other in labelled:
                    best = labelled[other]
                    break
            if best:
                break
        if best:
            return best
    return "islands"

cells = []
for cid in sorted(active):
    cells.append([cid, round(residents.get(cid, 0)), round(office.get(cid, 0), 1), int(shops.get(cid, 0)),
                  district_index[district_for(cid)]])

def place_out(p):
    out = dict(id=p["id"], kind=p["kind"], name=p["name"], nameZH=p.get("nameZH") or p["name"],
               lat=short(p["lat"]), lon=short(p["lon"]), detail=p.get("detail", ""), confirmedDaysAgo=p["fresh"])
    if p.get("aliases"):
        out["aliases"] = p["aliases"]
    if p.get("source"):
        out["source"] = p["source"]
    cid = cell_id(p["lat"], p["lon"])
    out["district"] = district_index[district_for(cid)] if cid is not None else district_index["islands"]
    return out

districts_out = [dict(key=k, name=en, nameZH=zh, population=pop) for k, en, zh, pop in DISTRICTS]
json.dump(dict(
    source="OpenStreetMap contributors (ODbL), downloaded 2026-11-27; 2021 Population Census district totals; published CDC branch list",
    districts=districts_out,
    places=[place_out(p) for p in stores + universities + schools + stations + rivals],
), open("hk_places.json", "w"), ensure_ascii=False, separators=(",", ":"))
json.dump(dict(
    grid=dict(minLat=MIN_LAT, minLon=MIN_LON, latStep=LAT_STEP, lonStep=LON_STEP, rows=ROWS, columns=COLS),
    fields=["id", "residents", "office", "shops", "district"],
    cells=cells,
), open("hk_cells.json", "w"), separators=(",", ":"))

print(f"grid {ROWS}x{COLS}; active cells {len(cells)}; residents total {round(sum(residents.values())):,}")
print(f"stores {len(stores)} (branch list {len(branches)}, OSM added {len(stores) - len(branches)}); rivals {len(rivals)}; "
      f"universities {len(universities)}; schools {len(schools)}; stations {len(stations)}")
by_district = Counter(DISTRICTS[place_out(s)['district']][1] for s in stores)
print("mapped stores by district:", dict(by_district))
