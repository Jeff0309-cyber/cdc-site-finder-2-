"""Parse the Weekend Weekly (May 2023) branch list and geocode it with Nominatim (1 request/second)."""
import json, math, re, time, html as h, urllib.parse, urllib.request, os

page = open("weekend.html", encoding="utf-8", errors="replace").read()
text = re.sub(r"<script.*?</script>|<style.*?</style>", " ", page, flags=re.S)
text = h.unescape(re.sub(r"<[^>]+>", "\n", text))
lines = [l.strip() for l in text.split("\n") if l.strip()]
start = next(k for k, l in enumerate(lines) if "上環德輔道中199號" in l) - 2
rows = []
for k in range(start, len(lines)):
    if re.fullmatch(r"\d{8}", lines[k]):
        rows.append(dict(area=lines[k - 2], address=lines[k - 1], phone=lines[k]))
print("parsed rows:", len(rows))

known = {b["addressZH"] for b in json.load(open("branches.json"))}
todo = [r for r in rows if r["address"] not in known]
print("already placed:", len(rows) - len(todo), " to geocode:", len(todo))

cache_path = "geocode_cache.json"
cache = json.load(open(cache_path)) if os.path.exists(cache_path) else {}
UA = {"User-Agent": "cdc-site-finder-concept/1.0 (student case project; one-off geocoding of a public branch list)"}
last_call = [0.0]

def nominatim(query):
    if query in cache:
        return cache[query]
    wait = 1.1 - (time.time() - last_call[0])
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
    last_call[0] = time.time()
    cache[query] = result
    json.dump(cache, open(cache_path, "w"), ensure_ascii=False)
    return result

def meters(a, b):
    mid = math.radians((a[0] + b[0]) / 2)
    return math.hypot((b[1] - a[1]) * math.cos(mid) * 111320, (b[0] - a[0]) * 110540)

BUILDING = re.compile(r"([一-鿿A-Za-z0-9]{2,14}?(?:中心|廣場|商場|大廈|大樓|花園|城|坊|苑|邨|站|閣|匯|天地|薈|置|街市|商業大廈|樓))")
STREET = re.compile(r"([一-鿿]{2,8}(?:道|街|路|里|徑))(\d+[A-Z]?(?:-\d+[A-Z]?)?)號")

area_cache = {}
results = []
for row in todo:
    area = row["area"]
    if area not in area_cache:
        hit = nominatim(f"{area}, 香港")
        area_cache[area] = (float(hit[0]["lat"]), float(hit[0]["lon"])) if hit else None
    anchor = area_cache[area]

    queries = []
    addr = re.sub(r"\(.*?\)|（.*?）", "", row["address"])
    building = None
    for m in BUILDING.finditer(addr):
        candidate = re.sub(r"^.*?\d+號", "", m.group(1))  # drop leading street number
        candidate = re.sub(r"^(地下|一樓|二樓|三樓|高層|低層)", "", candidate)
        if len(candidate) >= 3:
            building = candidate
            break
    street = STREET.search(addr)
    if building:
        queries.append(f"{building}, {area}")
        queries.append(f"{building}, 香港")
    if street:
        queries.append(f"{street.group(2)} {street.group(1)}, 香港")
        queries.append(f"{street.group(1)}{street.group(2)}號")

    found = None
    for q in queries:
        hit = nominatim(q)
        if not hit:
            continue
        point = (float(hit[0]["lat"]), float(hit[0]["lon"]))
        if anchor and meters(point, anchor) > 3000:
            continue
        found = dict(lat=point[0], lon=point[1], query=q, match=hit[0].get("display_name", "")[:80])
        break
    results.append(dict(row, **(found or {})))
    status = f"{found['lat']:.5f},{found['lon']:.5f} via {found['query']}" if found else "NOT FOUND"
    print(f"{area:6} {row['address'][:28]:30} -> {status}", flush=True)

json.dump(results, open("weekend_geocoded.json", "w"), ensure_ascii=False, indent=0)
ok = sum(1 for r in results if "lat" in r)
print(f"geocoded {ok} of {len(results)}")
