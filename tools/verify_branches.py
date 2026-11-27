"""Check every branch-list location against the named malls, estates and buildings in OpenStreetMap.

Usage: python3 -I verify_branches.py <dl_names dir> <osm data dir> [--apply]

For each branch it finds the longest OpenStreetMap name that appears in the branch's address (a mall,
an estate or a building), or else the street number, picks the match closest to the branch's area, and
compares that with where the geocoder put the branch. With --apply it writes the corrections into
weekend_geocoded.json (keeping the old position in "geocoded") and prints what changed.
"""
import json, math, re, sys

names_dir, data_dir = sys.argv[1], sys.argv[2]
APPLY = "--apply" in sys.argv
malls = json.load(open(f"{names_dir}/malls.json"))["elements"]
buildings = json.load(open(f"{names_dir}/buildings.json"))["elements"]

CJK = r"㐀-鿿"
RANK = {"mall": 0, "building": 1, "residential": 2}
STOP = {"商場", "停車場", "地下", "大廈", "中心", "廣場", "花園", "商業中心", "購物中心", "街市", "熟食中心"}


def where(e):
    c = e.get("center") or e
    return c["lat"], c["lon"]


def meters(a, b):
    mid = math.radians((a[0] + b[0]) / 2)
    return math.hypot((b[1] - a[1]) * math.cos(mid) * 111320, (b[0] - a[0]) * 110540)


GENERIC_ZH = re.compile(r"^第?[\d一二三四五六七八九十百A-Za-z]+[座期號樓層區翼]?$|^[\d一二三四五六七八九十]+[座期]")
GENERIC_EN = re.compile(r"^(block|tower|phase|house|wing|zone)\b", re.I)


def generic(n):
    return len(re.findall(rf"[{CJK}]", n)) < 2 or bool(GENERIC_ZH.match(n))


def chinese_names(tags):
    out = set()
    for key in ("name:zh", "name:zh-Hant", "addr:housename:zh", "alt_name:zh", "official_name:zh", "old_name:zh"):
        for v in tags.get(key, "").split(";"):
            if v.strip():
                out.add(v.strip())
    m = re.match(rf"^([{CJK}\d\(\)（）]+)", tags.get("name", ""))
    if m:
        out.add(m.group(1))
    return {re.sub(r"\(.*?\)|（.*?）", "", n) for n in out}


places, by_name, by_number = [], {}, {}
for e in malls + buildings:
    tags = e.get("tags", {})
    kind = "mall" if tags.get("shop") == "mall" else "building" if "building" in tags else \
        "residential" if tags.get("landuse") == "residential" else "place"
    if kind == "place":
        places.append((tags, where(e)))
        continue
    for n in chinese_names(tags):
        if len(n) >= 3 and n not in STOP and not generic(n):
            by_name.setdefault(n, []).append((kind, where(e), tags.get("name", n)))
    en = tags.get("name:en", "")
    if len(en) >= 5 and not GENERIC_EN.match(en) and not re.match(r"^\d", en):
        by_name.setdefault(en.lower(), []).append((kind, where(e), tags.get("name", en)))
    street = tags.get("addr:street:zh") or (re.match(rf"^([{CJK}]+)", tags.get("addr:street", "")) or [None])[0]
    number = tags.get("addr:housenumber", "")
    if street and number:
        for part in re.split(r"[;,]", number):
            r = re.fullmatch(r"\s*(\d+)\s*(?:[-–至]\s*(\d+))?\s*", part)
            if r:
                lo, hi = int(r.group(1)), int(r.group(2) or r.group(1))
                for n in range(lo, min(hi, lo + 40) + 1):
                    by_number.setdefault((street, n), []).append(("building", where(e), tags.get("name", "")))


PLACE_NAMES = {t.get("name:zh") for t, _ in places} | {t.get("name:en", "").lower() for t, _ in places}
for n in list(by_name):
    if n in PLACE_NAMES:
        del by_name[n]


AREA_CACHE = json.load(open(f"{data_dir}/geocode_cache.json"))
LIST_AREAS = {r["area"] for r in json.load(open(f"{data_dir}/weekend_geocoded.json"))}
for n in list(by_name):
    if n in LIST_AREAS:
        del by_name[n]


def anchor_for(area):
    hit = AREA_CACHE.get(f"{area}, 香港")
    for tags, p in places:
        if area in (tags.get("name:zh"), tags.get("name:en"), tags.get("name:zh-Hant")):
            return p
    if hit:
        return float(hit[0]["lat"]), float(hit[0]["lon"])
    return None


def match(address, area, fallback=None):
    text = re.sub(r"\(.*?\)|（.*?）", "", address)
    # "新都城第二期" and "新都城二期" are the same place
    text = text + " " + re.sub(r"第([一二三四五六七八九十\d]+)期", r"\1期", text)
    lower = text.lower()
    anchor = anchor_for(area) or fallback
    if anchor is None:
        return None
    found = [n for n in by_name if n in text or (n.isascii() and n in lower)]
    found.sort(key=lambda n: -len(n))
    options = []
    for n in found[:4]:
        for kind, p, label in by_name[n]:
            d = meters(anchor, p)
            if d < 4000:
                options.append((-len(n), RANK[kind], d, p, f"{label} [{kind}]"))
    for m in re.finditer(rf"([{CJK}]{{1,6}}(?:道|街|路|里|坊|台|徑))(\d+)(?:[-及至、](\d+))?號", text):
        for kind, p, label in by_number.get((m.group(1), int(m.group(2))), []):
            d = meters(anchor, p)
            if d < 4000:
                options.append((-len(m.group(0)), 1, d, p, f"{m.group(1)}{m.group(2)}號 {label} [number]"))
    if not options:
        return None
    options.sort()
    return options[0]


rows = json.load(open(f"{data_dir}/weekend_geocoded.json"))
branches = json.load(open(f"{data_dir}/branches.json"))
moved = 0
# Rows whose only OpenStreetMap match is doubtful; placed by hand in build_dataset.py instead.
MANUAL = {31, 38, 39}
print("Hand-placed branches (should agree):")
for b in branches:
    here = (b["lat"], b["lon"])
    m = match(b["addressZH"], b["area"], here) or match(b["address"], b["area"], here)
    if m:
        d = meters((b["lat"], b["lon"]), m[3])
        flag = "  <-- check" if d > 200 else ""
        print(f"  {d:6.0f} m  {b['id']:12} {b['addressZH'][:26]:28} {m[4][:40]}{flag}")
    else:
        print(f"      --  {b['id']:12} {b['addressZH'][:26]:28} no OSM match")

print("\nBranch list:")
for i, r in enumerate(rows):
    m = match(r["address"], r["area"], (r["lat"], r["lon"]) if "lat" in r else None)
    if not m:
        print(f"      --  #{i:<3} {r['area']:4} {r['address'][:30]:32} no OSM match ({'placed' if 'lat' in r else 'NOT PLACED'})")
        continue
    if "lat" in r:
        d = meters((r["lat"], r["lon"]), m[3])
    else:
        d = float("inf")
    flag = "" if d <= 200 else "  <-- moved" if APPLY else "  <-- differs"
    print(f"  {d:6.0f} m  #{i:<3} {r['area']:4} {r['address'][:30]:32} {m[4][:40]}{flag}")
    if APPLY and d > 200 and i not in MANUAL:
        if "lat" in r:
            r["geocoded"] = [r["lat"], r["lon"], r.get("query")]
        r["lat"], r["lon"], r["query"] = m[3][0], m[3][1], "OpenStreetMap name: " + m[4]
        moved += 1
if APPLY:
    json.dump(rows, open(f"{data_dir}/weekend_geocoded.json", "w"), ensure_ascii=False, indent=0)
    print(f"\nmoved {moved} branches")
