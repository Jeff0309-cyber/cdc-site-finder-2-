/* CDC Site Finder, web version.
 * Draws the iPhone app's own results (data/sitefinder.json, made by tools/web_export) on a Leaflet map.
 * Routes: "#" shows the best place, top 10 and districts; "#spot-A" … "#spot-J" show one spot. */
(function () {
  "use strict";

  const HK_BOUNDS = [[22.15, 113.83], [22.56, 114.44]];
  const DEMAND = [[22, "#FCE9B8"], [38, "#F9D27A"], [52, "#F4B63E"], [66, "#EC961C"], [78, "#D96A0E"]];
  // A spot pin with its score label, in screen points. Overlapping pins fold into the best-ranked one.
  const FOOTPRINT = { width: 86, height: 44 };
  // OpenStreetMap's own tiles: free with this credit and no key. CSS tones them down (and darkens them
  // in dark mode) so the demand colours carry the map, as in the app.
  const TILES = "https://tile.openstreetmap.org/{z}/{x}/{y}.png";
  const ATTRIBUTION = '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors';
  const APP_REPO = "https://github.com/Jeff0309-cyber/cdc-site-finder-2-";
  const BRANCH_LIST = "https://www.weekendhk.com/dining/%E5%A4%A7%E5%AE%B6%E6%A8%82-%E6%97%A9%E9%A4%90-%E5%A4%96%E8%B3%A3-%E9%A4%90%E7%89%8C-%E4%B8%8B%E5%8D%88%E8%8C%B6-%E5%84%AA%E6%83%A0-ww02-1494205/";
  const BULB = '<svg viewBox="0 0 24 24" aria-hidden="true"><path fill="#F7B500" stroke="#8F5500" stroke-width="1.4" '
    + 'd="M12 2.5a6.5 6.5 0 0 0-3.8 11.8c.6.5 1 1.2 1 2V17h5.6v-.7c0-.8.4-1.5 1-2A6.5 6.5 0 0 0 12 2.5z"/>'
    + '<path fill="none" stroke="#8F5500" stroke-width="1.6" stroke-linecap="round" d="M9.6 19.6h4.8M10.4 22h3.2"/></svg>';

  const darkQuery = window.matchMedia("(prefers-color-scheme: dark)");
  const motionQuery = window.matchMedia("(prefers-reduced-motion: reduce)");
  const wideQuery = window.matchMedia("(min-width: 900px)");
  const number = new Intl.NumberFormat("en-GB");

  const state = {
    data: null,
    map: null,
    tiles: null,
    demand: null,
    stores: null,
    markers: new Map(),
    layoutKeys: new Map(),
    selected: null,
    ring: null,
  };

  const view = document.getElementById("view");
  const panel = document.getElementById("panel");
  const status = document.getElementById("status");

  // MARK: Helpers

  function esc(value) {
    return String(value).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }

  /** 58,354 → "58,000"; 4,321 → "4,300", as in the app. */
  function rough(n) {
    return number.format(n >= 10000 ? Math.round(n / 1000) * 1000 : Math.round(n / 100) * 100);
  }

  function orders(n) {
    return `~${Math.round(n)}`;
  }

  function percent(share) {
    return `${Math.round(share * 100)}%`;
  }

  function distance(meters) {
    return meters >= 1000 ? `${(meters / 1000).toFixed(1)} km` : `${Math.round(meters / 10) * 10} m`;
  }

  function demandColor(score) {
    let color = null;
    for (const [from, hex] of DEMAND) if (score >= from) color = hex;
    return color;
  }

  /** Store dots: small when zoomed out so they don't hide the demand colours; lighter in dark mode. */
  function storeStyle(zoom) {
    const dark = darkQuery.matches;
    return {
      radius: zoom < 11 ? 2.5 : zoom < 13 ? 3.5 : 5,
      color: dark ? "#1f1915" : "#ffffff",
      weight: zoom < 11 ? 1 : 1.5,
      fillColor: dark ? "#E8A86A" : "#4A2511",
      fillOpacity: 1,
    };
  }

  function announce(text) {
    status.textContent = "";
    window.setTimeout(() => { status.textContent = text; }, 60);
  }

  /** Brings the top of the results into view: the panel scrolls on wide screens, the page on phones. */
  function showResultsTop() {
    if (wideQuery.matches) {
      panel.scrollTop = 0;
    } else {
      const header = document.querySelector(".site-header");
      window.scrollTo({ top: header ? header.offsetHeight : 0, behavior: motionQuery.matches ? "auto" : "smooth" });
    }
  }

  // MARK: Start

  fetch("data/sitefinder.json")
    .then((response) => {
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      return response.json();
    })
    .then(start)
    .catch((error) => {
      view.innerHTML = `<p class="loading">Couldn't load the results (${esc(error.message)}). Please reload the page.</p>`;
    });

  function start(data) {
    state.data = data;
    data.byLetter = new Map(data.spots.map((spot) => [spot.letter, spot]));
    if (window.L) {
      buildMap();
    } else {
      document.querySelector(".map-wrap").hidden = true;
    }
    view.addEventListener("click", onViewClick);
    window.addEventListener("hashchange", () => route(true));
    route(false);
  }

  function route(navigated) {
    const match = /^#spot-([A-Z])$/i.exec(window.location.hash);
    const spot = match ? state.data.byLetter.get(match[1].toUpperCase()) : null;
    if (spot) {
      showSpot(spot, navigated);
    } else {
      showHome(navigated);
    }
  }

  // MARK: Map

  function buildMap() {
    const map = L.map("map", {
      zoomControl: false,
      minZoom: 9,
      maxZoom: 18,
      zoomSnap: 0.25,
      maxBounds: [[21.85, 113.5], [22.85, 114.8]],
      maxBoundsViscosity: 0.7,
    });
    state.map = map;
    L.control.zoom({ position: "bottomright" }).addTo(map);
    map.attributionControl.setPrefix('<a href="https://leafletjs.com">Leaflet</a>');
    state.tiles = L.tileLayer(TILES, { maxZoom: 19, attribution: ATTRIBUTION }).addTo(map);
    map.fitBounds(HK_BOUNDS, { padding: [4, 4] });

    const renderer = L.canvas({ padding: 0.5 });

    // Demand: every street block scoring 22 or more, coloured like the app.
    const grid = state.data.grid;
    state.demand = L.layerGroup(state.data.blocks.map(([id, score]) => {
      const row = Math.floor(id / grid.columns);
      const column = id % grid.columns;
      const south = grid.minLat + row * grid.latStep;
      const west = grid.minLon + column * grid.lonStep;
      return L.rectangle([[south, west], [south + grid.latStep, west + grid.lonStep]], {
        renderer,
        stroke: false,
        fillColor: demandColor(score),
        fillOpacity: 0.5,
        interactive: false,
      });
    })).addTo(map);

    // Café de Coral stores.
    state.stores = L.layerGroup(state.data.stores.map(([lat, lon, name, zh]) =>
      L.circleMarker([lat, lon], { renderer, ...storeStyle(map.getZoom()) }).bindPopup(`<strong>Café de Coral</strong><br>${esc(name)}${zh ? `<br><span lang="zh-HK">${esc(zh)}</span>` : ""}`)
    )).addTo(map);

    // The shortlist.
    for (const spot of state.data.spots) {
      const marker = L.marker([spot.lat, spot.lon], {
        icon: spotIcon(spot, 0, false),
        title: `Spot ${spot.letter}: ${spot.short}`,
        zIndexOffset: 1000 - spot.rank * 10,
      });
      marker.on("click", () => { window.location.hash = `spot-${spot.letter}`; });
      marker.addTo(map);
      state.markers.set(spot.letter, marker);
    }
    const restyleStores = () => {
      const style = storeStyle(map.getZoom());
      state.stores.eachLayer((dot) => { dot.setRadius(style.radius); dot.setStyle(style); });
    };
    map.on("zoomend", () => { layoutSpots(); restyleStores(); });
    darkQuery.addEventListener("change", restyleStores);
    layoutSpots();

    for (const chip of document.querySelectorAll(".chip[data-layer]")) {
      chip.addEventListener("click", () => {
        const on = chip.getAttribute("aria-pressed") !== "true";
        chip.setAttribute("aria-pressed", String(on));
        const layer = chip.dataset.layer === "demand" ? state.demand : state.stores;
        if (on) layer.addTo(map); else layer.remove();
      });
    }
    document.querySelector('[data-action="reset"]').addEventListener("click", () => {
      map.closePopup();
      if (motionQuery.matches) map.fitBounds(HK_BOUNDS, { padding: [4, 4] });
      else map.flyToBounds(HK_BOUNDS, { padding: [4, 4], duration: 0.8 });
    });

    if ("ResizeObserver" in window) {
      new ResizeObserver(() => map.invalidateSize()).observe(document.getElementById("map"));
    }
  }

  function spotIcon(spot, more, selected) {
    const size = selected ? 44 : 36;
    const label = `${spot.score}${more ? ` +${more}` : ""}`;
    const spoken = `Spot ${spot.letter}, score ${spot.score}`
      + (more ? `, and ${more} more spots nearby. Zoom in to see them` : "");
    return L.divIcon({
      className: `spot-icon${selected ? " is-selected" : ""}`,
      html: `<span class="spot-letter" style="width:${size}px;height:${size}px" aria-hidden="true">${esc(spot.letter)}</span>`
        + `<span class="spot-score" aria-hidden="true">${esc(label)}</span><span class="sr-only">${esc(spoken)}</span>`,
      iconSize: null,
      iconAnchor: [size / 2, size / 2],
    });
  }

  /** Same rule as the app: go best first; a pin that would overlap an earlier one folds into it as "+N". */
  function groupSpots(points, keep) {
    const leaders = [];
    const counts = new Map();
    const ordered = points.filter((p) => p.id === keep).concat(points.filter((p) => p.id !== keep));
    for (const point of ordered) {
      const leader = leaders.find((l) => Math.abs(l.x - point.x) < FOOTPRINT.width && Math.abs(l.y - point.y) < FOOTPRINT.height);
      if (leader) {
        counts.set(leader.id, counts.get(leader.id) + 1);
      } else {
        leaders.push(point);
        counts.set(point.id, 0);
      }
    }
    return counts;
  }

  function layoutSpots() {
    const map = state.map;
    if (!map) return;
    const points = state.data.spots.map((spot) => {
      const point = map.latLngToContainerPoint([spot.lat, spot.lon]);
      return { id: spot.letter, x: point.x, y: point.y };
    });
    const groups = groupSpots(points, state.selected ? state.selected.letter : null);
    for (const spot of state.data.spots) {
      const marker = state.markers.get(spot.letter);
      const more = groups.get(spot.letter);
      if (more === undefined) {
        if (map.hasLayer(marker)) marker.remove();
        continue;
      }
      const selected = state.selected === spot;
      const key = `${more}|${selected}`;
      if (state.layoutKeys.get(spot.letter) !== key) {
        marker.setIcon(spotIcon(spot, more, selected));
        marker.setZIndexOffset(selected ? 2000 : 1000 - spot.rank * 10);
        state.layoutKeys.set(spot.letter, key);
      }
      if (!map.hasLayer(marker)) marker.addTo(map);
    }
  }

  function moveTo(latlng, zoom) {
    if (!state.map) return;
    if (motionQuery.matches) state.map.setView(latlng, zoom);
    else state.map.flyTo(latlng, zoom, { duration: 0.8 });
  }

  function drawRing(latlng) {
    if (state.ring) state.ring.remove();
    state.ring = L.circle(latlng, {
      radius: 400,
      color: darkQuery.matches ? "#F7B500" : "#4A2511",
      weight: 1.5,
      fillColor: "#F7B500",
      fillOpacity: 0.12,
      interactive: false,
    }).addTo(state.map);
  }

  function selectOnMap(spot) {
    state.selected = spot;
    if (!state.map) return;
    state.map.closePopup();
    drawRing([spot.lat, spot.lon]);
    moveTo([spot.lat, spot.lon], 15.5);
    layoutSpots();
  }

  function clearSelection() {
    state.selected = null;
    if (state.ring) {
      state.ring.remove();
      state.ring = null;
    }
    layoutSpots();
  }

  // MARK: Home: best place, top 10, districts

  function showHome(navigated) {
    const data = state.data;
    view.innerHTML = bestCard(data.spots[0]) + topList(data.spots) + districtList(data.districts) + about(data);
    if (state.selected) clearSelection();
    if (navigated) showResultsTop();
  }

  function bestCard(spot) {
    return `<article class="card best" aria-labelledby="best-title">
      <p class="eyebrow">Best place to open next</p>
      <div class="head">
        <span class="pin-badge" aria-hidden="true">${esc(spot.letter)}</span>
        <div>
          <h2 id="best-title">${esc(spot.short)}</h2>
          <p class="sub">${esc(spot.district)} · <span lang="zh-HK">${esc(spot.districtZH)}</span> · ${esc(spot.kind)}</p>
        </div>
      </div>
      <dl class="stats">
        <div><dt>score out of 100</dt><dd>${spot.score}</dd></div>
        <div><dt>new orders a day</dt><dd>${orders(spot.netOrders)}</dd></div>
        <div><dt>people within a 5-minute walk</dt><dd>${rough(spot.catchment)}</dd></div>
      </dl>
      <p class="why">${esc(spot.why)}</p>
      <p class="confidence-line">
        <span class="conf">${esc(spot.confidence)} confidence</span>
        <span>First in ${percent(spot.firstShare)} of ${number.format(state.data.robustRuns)} what-if tests</span>
      </p>
      <div class="actions">
        <a class="btn primary" href="#spot-${esc(spot.letter)}">Why here</a>
        <button class="btn" type="button" data-fly="${esc(spot.letter)}">Show on map</button>
      </div>
    </article>`;
  }

  function topList(spots) {
    const rows = spots.map((spot) => `<li><a class="row" href="#spot-${esc(spot.letter)}">
        <span class="pin-badge sm" aria-hidden="true">${esc(spot.letter)}</span>
        <span class="row-main">
          <span class="row-title"><span class="sr-only">Spot ${esc(spot.letter)}: </span>${esc(spot.short)}</span>
          <span class="row-sub">${esc(spot.district)} · ${esc(spot.kind)}</span>
        </span>
        <span class="row-end"><strong>${orders(spot.netOrders)}/day</strong><span>score ${spot.score}</span></span>
      </a></li>`).join("");
    return `<section class="section" aria-labelledby="top-title">
      <h2 id="top-title" class="section-title">Top ${spots.length} spots</h2>
      <p class="section-sub">Ranked by new orders a day. At most two per district, each at least 650 m apart and 320 m from any mapped CDC.</p>
      <ol class="list">${rows}</ol>
    </section>`;
  }

  function districtList(rows) {
    const items = rows.map((row, index) => {
      const coverage = row.expected > 0 ? row.mapped / row.expected : 1;
      const stores = row.mapped >= Math.round(row.expected)
        ? `${row.mapped} CDC stores mapped`
        : `${row.mapped} of ~${Math.round(row.expected)} stores mapped`;
      const thin = coverage < 0.6;
      return `<li><button class="row" type="button" data-district="${index}">
          <span class="rank">${index + 1}</span>
          <span class="row-main">
            <span class="row-title">${esc(row.name)} <span class="zh" lang="zh-HK">${esc(row.zh)}</span>${row.spot ? ` <span class="badge">Spot ${esc(row.spot)}</span>` : ""}</span>
            <span class="row-sub">${number.format(row.population)} people · ${rough(row.underserved)} more than 5 min from a mapped CDC</span>
            <span class="row-note${thin ? " warn" : ""}">${thin ? "Few stores mapped: " : ""}${stores}</span>
          </span>
          <span class="row-end"><strong>${orders(row.netOrders)}/day</strong><span>score ${row.score}</span></span>
        </button></li>`;
    }).join("");
    return `<section class="section" aria-labelledby="districts-title">
      <h2 id="districts-title" class="section-title">All ${rows.length} districts</h2>
      <p class="section-sub">Ranked by their best spot: new orders a day at the best block, after sales taken from existing stores. Tap one to see where it is.</p>
      <ol class="list">${items}</ol>
    </section>`;
  }

  function about(data) {
    return `<details class="card">
      <summary>How it works and where the data comes from</summary>
      <h3>How a spot is scored</h3>
      <p>Hong Kong is split into ${number.format(data.blockCount)} street blocks of about 280 m. Each block is scored from six inputs: homes with no CDC nearby, schools, offices, footfall from MTR stations, rivals nearby and rents. Rivals and rents count against a block. The score becomes new orders a day, minus the sales a new spot would take from the nearest Café de Coral.</p>
      <h3>How sure it is</h3>
      <p>Each spot is re-scored with every input's weight moved 30% up and down, which gives its likely range. Nothing claims high confidence before a real pilot. In ${number.format(data.robustRuns)} what-if tests with random weight changes, Spot ${esc(data.spots[0].letter)} came first ${percent(data.spots[0].firstShare)} of the time.</p>
      <h3>Data</h3>
      <ul>
        <li>Homes, schools, universities, offices, shops, MTR stations and rival chains: © <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors (ODbL).</li>
        <li>District populations: 2021 Population Census, Census and Statistics Department.</li>
        <li>${number.format(data.storesMapped)} Café de Coral locations: the <a href="${BRANCH_LIST}">published branch list (Weekend Weekly, May 2023)</a>, checked against OpenStreetMap buildings, plus OpenStreetMap. Café de Coral has about ${number.format(data.storesEstimated)} stores in Hong Kong.</li>
      </ul>
      <h3>Before deciding</h3>
      <ul>
        <li>The branch list is from 2023. Check the top spots against Café de Coral's own store finder.</li>
        <li>Homes stand in for app orders, and shop density stands in for rent. Real sales and rent data would replace them.</li>
        <li>Orders a day are model estimates, not sales.</li>
      </ul>
      <p>Results from ${esc(data.generated)}, made by the same engine as the iPhone app. The app's Xcode project is in the same <a href="${APP_REPO}">GitHub repository</a> as this page.</p>
    </details>`;
  }

  function onViewClick(event) {
    const fly = event.target.closest("[data-fly]");
    if (fly) {
      const spot = state.data.byLetter.get(fly.dataset.fly);
      if (spot) {
        selectOnMap(spot);
        announce(`Showing spot ${spot.letter} on the map`);
      }
      return;
    }
    const district = event.target.closest("[data-district]");
    if (district) showDistrict(state.data.districts[Number(district.dataset.district)]);
  }

  function showDistrict(row) {
    if (row.spot) {
      window.location.hash = `spot-${row.spot}`;
      return;
    }
    if (!state.map) return;
    clearSelection();
    drawRing([row.lat, row.lon]);
    const popup = L.popup({ autoPan: false })
      .setLatLng([row.lat, row.lon])
      .setContent(`<strong>Best block in ${esc(row.name)}</strong><br>Score ${row.score} · ${orders(row.netOrders)} new orders a day<br>${esc(row.short)}`);
    state.map.once("moveend", () => popup.openOn(state.map));
    moveTo([row.lat, row.lon], 15);
    announce(`Showing the best block in ${row.name}: ${row.short}`);
  }

  // MARK: One spot

  function bar(label, valueText, fraction, against) {
    const width = Math.max(2, Math.min(100, Math.round(fraction * 100)));
    return `<li>
      <span class="bar-label"><span>${esc(label)}${against ? '<span class="tag">counts against</span>' : ""}</span><span>${esc(valueText)}</span></span>
      <span class="bar${against ? " against" : ""}" aria-hidden="true"><i style="width:${width}%"></i></span>
    </li>`;
  }

  function showSpot(spot, navigated) {
    const data = state.data;
    const index = data.spots.indexOf(spot);
    const previous = data.spots[index - 1];
    const next = data.spots[index + 1];

    // Time-of-day split of the new orders (after sales taken from the nearest CDC), so it adds up to the headline.
    const gross = spot.orders.lunch + spot.orders.afterSchool + spot.orders.evening;
    const scale = gross > 0 ? spot.netOrders / gross : 0;
    const times = [["Lunch", spot.orders.lunch], ["After school", spot.orders.afterSchool], ["Evening", spot.orders.evening]]
      .map(([label, value]) => [label, value * scale]);
    const busiest = Math.max(...times.map(([, value]) => value));
    const timeRows = times.map(([label, value]) => bar(label, `~${Math.round(value)} a day`, value / busiest, false)).join("");
    const featureRows = spot.features
      .map((feature) => bar(feature.title, `${Math.round(feature.value * 100)} / 100`, feature.value, feature.penalty))
      .join("");
    const query = `${spot.lat},${spot.lon}`;

    view.innerHTML = `<article class="detail" aria-labelledby="spot-title">
      <a class="back" href="#"><span aria-hidden="true">‹</span> All spots</a>
      <div class="head">
        <span class="pin-badge" aria-hidden="true">${esc(spot.letter)}</span>
        <div>
          <h2 id="spot-title" tabindex="-1">Spot ${esc(spot.letter)} · ${esc(spot.kind)}</h2>
          <p class="sub">Rank ${spot.rank} of ${data.spots.length} · ${esc(spot.district)} · <span lang="zh-HK">${esc(spot.districtZH)}</span></p>
        </div>
      </div>
      <p class="why-box">${BULB}<span>${esc(spot.why)}</span></p>
      <dl class="stat-cards">
        <div class="stat-card"><dt>Demand score</dt><dd><strong>${spot.score}</strong> / 100</dd></div>
        <div class="stat-card"><dt>New orders</dt><dd><strong>${orders(spot.netOrders)}</strong> a day<small>${esc(spot.range)} likely</small></dd></div>
        <div class="stat-card"><dt>Taken from CDC</dt><dd><strong>${spot.takenFromCDC}%</strong><small>${esc(spot.storeName)}, ${distance(spot.storeDistance)}</small></dd></div>
      </dl>
      <section class="card">
        <h3>How to find it</h3>
        <p>${esc(spot.english)}</p>
        <p lang="zh-HK">${esc(spot.chinese)}</p>
        <p class="links">
          <a href="https://www.google.com/maps/search/?api=1&amp;query=${query}" target="_blank" rel="noopener">Open in Google Maps</a>
          <a href="https://www.google.com/maps/@?api=1&amp;map_action=pano&amp;viewpoint=${query}" target="_blank" rel="noopener">Street View</a>
        </p>
      </section>
      <section class="card">
        <h3>New orders through the day</h3>
        <ul class="bars">${timeRows}</ul>
      </section>
      <section class="card">
        <h3>What drives the score</h3>
        <ul class="bars">${featureRows}</ul>
      </section>
      <section class="card">
        <h3>How to start</h3>
        <p><strong>${esc(spot.format)}.</strong> ${esc(spot.formatDetail)}</p>
      </section>
      <section class="card">
        <h3>How sure is this?</h3>
        <p><span class="conf">${esc(spot.confidence)} confidence</span></p>
        <p>${esc(spot.confidenceReason)}</p>
        <p>In ${number.format(data.robustRuns)} what-if tests that moved each weight by up to 30%, this spot came first ${percent(spot.firstShare)} of the time and was in the top 3 ${percent(spot.topThreeShare)} of the time.</p>
      </section>
      <nav class="pager" aria-label="Other spots">
        ${previous ? `<a class="btn" href="#spot-${esc(previous.letter)}">‹ Spot ${esc(previous.letter)}</a>` : "<span></span>"}
        ${next ? `<a class="btn" href="#spot-${esc(next.letter)}">Spot ${esc(next.letter)} ›</a>` : ""}
      </nav>
    </article>`;

    selectOnMap(spot);
    if (navigated) {
      showResultsTop();
      const heading = document.getElementById("spot-title");
      if (heading) heading.focus({ preventScroll: true });
    }
    announce(`Spot ${spot.letter}: ${spot.short}`);
  }
})();
