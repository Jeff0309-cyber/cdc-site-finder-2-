# Rebuilding the Hong Kong dataset

The app reads `ios/CDCSiteFinder/Resources/hk_places.json` and `hk_cells.json`. These scripts rebuild them.

1. **Download OpenStreetMap data.** The script is polite: it retries with backoff across the public Overpass mirrors.
   ```
   python3 fetch_overpass.py queries/cdc.overpassql r_cdc.json        # and rivals, unis, stations, schools, work
   python3 fetch_overpass.py queries/homes.overpassql homes.json
   ```
   Merge the five place downloads into `places.json` (a JSON object with one `elements` array) and rename `r_work.json` to `work.json`.
2. **Geocode the published branch list** (Weekend Weekly, 10 May 2023) with Nominatim. The scripts send one request per second and cache the results.
   ```
   python3 geocode_branches.py
   python3 geocode_pass2.py          # retries the misses with mall, English and estate names
   ```
3. **Check every branch against OpenStreetMap's named malls, estates and buildings.** The geocoder alone gets many wrong: it put two Hong Kong branches in Shenzhen.
   ```
   python3 fetch_overpass.py queries/named_malls_estates.overpassql dl_names/malls.json
   python3 fetch_overpass.py queries/named_buildings.overpassql dl_names/buildings.json
   python3 verify_branches.py dl_names .            # report only
   python3 verify_branches.py dl_names . --apply    # move branches more than 200 m from their building
   ```
   The check looks for the longest mall, estate or building name in each address (or its street number), near the branch's area. When the geocoder disagrees by more than 200 m, the check moves the branch to the building and keeps the old position in `geocoded`. In the 2023 list it moved 37 branches. Branches with no usable match are placed by hand in `HAND_FIXES` in `build_dataset.py`, using `queries/branch_lookups.overpassql`.
4. **Build:** run `python3 build_dataset.py`, then copy `hk_places.json` and `hk_cells.json` into `ios/CDCSiteFinder/Resources/`.
5. **Web version:** refresh `data/sitefinder.json` in the separate `cdc-site-finder-web` repository with `web_export` (see "Web version" in the main README).

`data/branches.json` is the 30 branches from the team's app concept, placed by hand. `data/weekend_geocoded.json` is the branch list after steps 2 and 3, so a rebuild can copy both into the working folder and skip straight to step 4.

Sources: © OpenStreetMap contributors (ODbL 1.0), 2021 Population Census district totals (Census and Statistics Department), Weekend Weekly's branch list and the team's app concept. Keep the OpenStreetMap credit wherever the data is shown.
