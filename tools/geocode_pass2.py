"""Second pass for branches the first pass missed: try mall names, English names and estates, alone and with the area."""
import json, math, re, time, urllib.parse, urllib.request

rows = json.load(open("weekend_geocoded.json"))
cache = json.load(open("geocode_cache.json"))
UA = {"User-Agent": "cdc-site-finder-concept/1.0 (student case project; one-off geocoding of a public branch list)"}
last = [0.0]

def nominatim(query):
    if query in cache:
        return cache[query]
    wait = 1.1 - (time.time() - last[0])
    if wait > 0:
        time.sleep(wait)
    url = "https://nominatim.openstreetmap.org/search?" + urllib.parse.urlencode(
        {"q": query, "format": "jsonv2", "countrycodes": "cn", "viewbox": "113.82,22.57,114.45,22.15", "bounded": 1,
         "limit": 1, "accept-language": "zh-HK"})
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as resp:
            result = json.loads(resp.read())
    except Exception as error:
        print("  error", error)
        result = []
    last[0] = time.time()
    cache[query] = result
    json.dump(cache, open("geocode_cache.json", "w"), ensure_ascii=False)
    return result

def meters(a, b):
    mid = math.radians((a[0] + b[0]) / 2)
    return math.hypot((b[1] - a[1]) * math.cos(mid) * 111320, (b[0] - a[0]) * 110540)

MALL = re.compile(r"([一-鿿]{1,8}(?:商場|廣場|中心|城|坊|匯|天地|半島))")
ESTATE = re.compile(r"([一-鿿]{1,6}(?:邨|苑|村|花園|大廈|大樓|居))")
ENGLISH = re.compile(r"[A-Za-z][A-Za-z ]*[A-Za-z]")
PHASE = re.compile(r"(第?[一二三四五六七八九十\d]+期)")

def clean(name, area):
    name = PHASE.sub("", name)
    for prefix in ("香港", "九龍", "新界", area):
        if name.startswith(prefix) and len(name) - len(prefix) >= 2:
            name = name[len(prefix):]
    return name

improved = 0
for row in rows:
    if "lat" in row:
        continue
    area, addr = row["area"], re.sub(r"\(.*?\)|（.*?）", "", row["address"])
    anchor_hit = cache.get(f"{area}, 香港") or []
    anchor = (float(anchor_hit[0]["lat"]), float(anchor_hit[0]["lon"])) if anchor_hit else None
    candidates = []
    for pattern in (MALL, ENGLISH, ESTATE):
        for m in pattern.findall(addr):
            name = clean(m.strip(), area)
            if len(name) >= 2 and name not in candidates and not re.fullmatch(r"[A-Z]?\d*", name):
                candidates.append(name)
    found = None
    for name in candidates[:3]:
        for query in (name, f"{name}, {area}"):
            hit = nominatim(query)
            if not hit:
                continue
            point = (float(hit[0]["lat"]), float(hit[0]["lon"]))
            if anchor and meters(point, anchor) > 3000:
                continue
            found = dict(lat=point[0], lon=point[1], query=query, match=hit[0].get("display_name", "")[:80])
            break
        if found:
            break
    if found:
        row.update(found)
        improved += 1
    print(f"{area:6} {addr[:26]:28} candidates={candidates[:3]} -> {'%.5f,%.5f' % (found['lat'], found['lon']) if found else 'still missing'}", flush=True)

json.dump(rows, open("weekend_geocoded.json", "w"), ensure_ascii=False, indent=0)
print(f"second pass placed {improved} more; total placed {sum(1 for r in rows if 'lat' in r)} of {len(rows)}")
