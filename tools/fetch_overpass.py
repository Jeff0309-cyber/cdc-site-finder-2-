"""Fetch an Overpass QL query with exponential backoff across public mirrors."""
import sys, time, json, urllib.request, urllib.parse, urllib.error

MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    "https://overpass.osm.jp/api/interpreter",
]
HEADERS = {"User-Agent": "cdc-site-finder-concept/1.0 (student case project)", "Accept": "application/json"}

def fetch(query, out, attempts=8):
    wait = 5
    for attempt in range(attempts):
        url = MIRRORS[attempt % len(MIRRORS)]
        try:
            data = urllib.parse.urlencode({"data": query}).encode()
            req = urllib.request.Request(url, data=data, headers=HEADERS)
            with urllib.request.urlopen(req, timeout=180) as resp:
                body = resp.read()
            parsed = json.loads(body)
            if "remark" in parsed and not parsed.get("elements"):
                raise RuntimeError(parsed["remark"][:200])
            open(out, "wb").write(body)
            print(f"ok from {url.split('/')[2]}: {len(parsed['elements'])} elements")
            return parsed
        except Exception as error:
            print(f"attempt {attempt + 1} via {url.split('/')[2]} failed: {str(error)[:120]}; waiting {wait}s")
            time.sleep(wait)
            wait = min(wait * 2, 60)
    sys.exit("all attempts failed")

if __name__ == "__main__":
    fetch(open(sys.argv[1]).read(), sys.argv[2])
