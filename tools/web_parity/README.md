# Web parity check

The website (`docs/`) scores Hong Kong with `docs/js/engine.js`, a JavaScript translation of the app's Swift engine. This check runs both on the same data and compares the results: the scores, the shortlist with confidence, directions and explanations, district rankings, a pilot round, search results, the seeded reports and a re-score after a rival closes.

From the repository root:

```
M=ios/CDCSiteFinder/Model
xcrun swiftc -O -o /tmp/swift_dump tools/web_parity/main.swift $M/HKData.swift $M/Places.swift $M/SiteEngine.swift $M/Explain.swift $M/Reports.swift $M/SearchIndex.swift $M/Routes.swift
/tmp/swift_dump ios/CDCSiteFinder/Resources > /tmp/app.json
/System/Library/Frameworks/JavaScriptCore.framework/Versions/Current/Helpers/jsc tools/web_parity/js_dump.js -- docs/js/engine.js docs/data > /tmp/web.json
python3 tools/web_parity/compare.py /tmp/app.json /tmp/web.json
```

It prints "Website engine matches the app" or lists every difference.
