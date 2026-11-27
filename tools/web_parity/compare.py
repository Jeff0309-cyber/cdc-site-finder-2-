"""Compares the app engine's answers (swift_dump) with the website engine's (js_dump).

usage: python3 compare.py swift.json js.json
Exits with status 1 and lists every difference if they don't match.
"""
import json
import sys


def walk(a, b, path, problems, tolerance=1e-6):
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                problems.append(f"{path}.{key}: only in {'website' if key in b else 'app'}")
            else:
                walk(a[key], b[key], f"{path}.{key}", problems, tolerance)
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            problems.append(f"{path}: {len(a)} items in the app, {len(b)} on the website")
        for index, (x, y) in enumerate(zip(a, b)):
            walk(x, y, f"{path}[{index}]", problems, tolerance)
    elif isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        if abs(a - b) > tolerance * max(1, abs(a)):
            problems.append(f"{path}: app {a}, website {b}")
    elif a != b:
        problems.append(f"{path}: app {a!r}, website {b!r}")


app = json.load(open(sys.argv[1]))
web = json.load(open(sys.argv[2]))
problems = []
walk(app, web, "", problems)
if problems:
    print(f"{len(problems)} differences:")
    for line in problems[:60]:
        print("  " + line)
    sys.exit(1)
print(f"Website engine matches the app: {len(app['spots'])} spots, {len(app['districtBest'])} districts, "
      f"pilot, search ({app['search']['passed']}/{app['search']['total']}), {len(app['seeds'])} seeded reports, "
      f"closure re-score, all equal.")
