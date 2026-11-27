/* CDC Site Finder: the screens, translated from the app's SwiftUI views (ContentView, SheetViews,
 * BestPlaceViews, CompareView, ControlCenterView, ReportSheet). Same wording, same order, same rules. */
(function (root) {
  "use strict";
  const SF = root.SF;
  const SiteModel = root.SiteModel;
  const icon = root.icon;
  const { netOrders, round, formatted } = SF;
  const percent = SiteModel.percent;

  function esc(value) {
    return String(value).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }

  const $ = (id) => document.getElementById(id);
  const wideQuery = root.matchMedia("(min-width: 900px)");
  const relative = new Intl.RelativeTimeFormat("en", { numeric: "auto" });

  function ago(iso) {
    const seconds = (new Date(iso).getTime() - Date.now()) / 1000;
    const units = [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60]];
    for (const [unit, size] of units) if (Math.abs(seconds) >= size) return relative.format(Math.round(seconds / size), unit);
    return "just now";
  }

  function dateTime(iso) {
    return new Date(iso).toLocaleString("en-GB", { dateStyle: "medium", timeStyle: "short" });
  }

  function routeAttrs(route) {
    return `data-action="open" data-type="${route.type}" data-id="${esc(route.id === undefined ? "" : route.id)}"`;
  }

  // MARK: Small views shared by several screens

  const View = {
    spotPin(letter, size = "") {
      return `<span class="spot-badge ${size}" aria-hidden="true">${esc(letter)}</span>`;
    },

    placePin(kind, scale = 1) {
      const k = SF.KIND[kind];
      const d = Math.round(k.diameter * scale);
      return `<span class="place-badge" style="width:${d}px;height:${d}px;background:${k.color}" aria-hidden="true">${icon(k.icon, { size: Math.round(d * 0.5) })}</span>`;
    },

    confidenceChip(level, { compact = false, showsIcon = true } = {}) {
      const symbol = level === "high" ? "circle-check" : level === "medium" ? "contrast" : "circle-alert";
      const title = SF.LEVEL[level].title;
      return `<span class="chip-conf ${level}" aria-label="${title} confidence">${showsIcon ? icon(symbol, { size: 12 }) : ""}${compact ? title : `${title} confidence`}</span>`;
    },

    miniStat(value, label) {
      return `<div class="mini-stat"><strong>${esc(value)}</strong><span>${esc(label)}</span></div>`;
    },

    statTile(value, unit, label, note = null) {
      return `<div class="stat-tile card">
        <span class="label">${esc(label)}</span>
        <span class="value">${esc(value)}${unit ? `<span class="unit">${esc(unit)}</span>` : ""}</span>
        ${note ? `<span class="note">${esc(note)}</span>` : ""}
      </div>`;
    },

    why(text) {
      return `<div class="callout">${icon("lightbulb", { size: 18 })}<span>${esc(text)}</span></div>`;
    },

    directions(d) {
      return `<div class="directions card">${icon("footprints", { size: 18 })}
        <div class="row-text">
          <span class="caption mute"><b>How to find it</b></span>
          <span>${esc(d.english)}</span>
          <span class="mute" lang="zh-HK">${esc(d.chinese)}</span>
        </div>
      </div>`;
    },

    sectionTitle(text) {
      return `<h3 class="section-title">${esc(text)}</h3>`;
    },

    confidenceCard(c) {
      return `<div class="card pad stack" style="gap:8px">
        <div class="hstack">${View.confidenceChip(c.level)}<span class="spacer"></span><strong class="footnote" style="font-size:15px">${SF.rangeText(c)} new orders a day</strong></div>
        <p class="footnote">${esc(SF.confidenceReason(c))}</p>
        <p class="caption mute">Checked by re-scoring with each weight 30% higher and lower. Only a pilot can raise confidence to High.</p>
      </div>`;
    },

    /** The six inputs as signed bars: what each one adds to (or takes off) this block's score. */
    inputBars(block, weights) {
      const contributions = SF.FEATURES.map((f) => [f, SF.contribution(block, f, weights)]);
      const largest = Math.max(Math.max(...contributions.map(([, v]) => Math.abs(v))), 0.01);
      const rows = contributions.map(([f, value]) => {
        const info = SF.FEATURE[f];
        const level = SF.Explain.level(block.features[f] || 0);
        const width = Math.max(0, Math.min(100, Math.abs(value) / largest * 100));
        return `<div class="input-row" role="img" aria-label="${esc(info.title)}: ${level}, ${value >= 0 ? "raises" : "lowers"} the score">
          ${icon(info.icon, { size: 17 })}
          <div class="input-main">
            <div class="input-head"><strong>${esc(info.title)}</strong><span>${level}</span></div>
            <div class="bar-track"><div class="bar-fill${value >= 0 ? "" : " down"}" style="width:${width}%"></div></div>
          </div>
        </div>`;
      }).join("");
      return `<div class="card bars">${rows}<p class="caption mute">Yellow raises the score, red lowers it. Bar length is the input times its learned weight.</p></div>`;
    },

    ordersChart(orders) {
      const rows = [["Lunch", orders.lunch], ["After school", orders.afterSchool], ["Evening", orders.evening]];
      const top = Math.max(...rows.map(([, v]) => v), 0.01);
      return `<div class="card orders-chart" role="img" aria-label="${rows.map(([l, v]) => `${l} ${round(v)}`).join(", ")}">
        ${rows.map(([label, value]) => `<span class="label">${label}</span>
          <span class="bar-line"><i style="width:${Math.max(1, value / top * 82)}%"></i><b>${round(value)}</b></span>`).join("")}
      </div>`;
    },

    externalLinks(c) {
      const q = `${c.lat},${c.lon}`;
      return `<div class="btn-row">
        <a class="btn wide" href="https://www.google.com/maps/search/?api=1&amp;query=${q}" target="_blank" rel="noopener">${icon("map", { size: 16 })}Open in Google Maps</a>
        <a class="btn wide" href="https://www.google.com/maps/@?api=1&amp;map_action=pano&amp;viewpoint=${q}" target="_blank" rel="noopener">${icon("binoculars", { size: 16 })}Street View</a>
      </div>`;
    },

    reportButton() {
      return `<button class="btn grey full" type="button" data-action="report">${icon("message-square-warning", { size: 16 })}Report a problem</button>`;
    },
  };

  // MARK: The app

  class App {
    constructor(model) {
      this.model = model;
      this.searchText = "";
      this.searchFocused = false;
      this.renderedRouteKey = null;
      this.controlsTab = "model";
      this.reportContext = null;
      this.confirmActions = [];
      this.draggingWeights = false;

      this.sheet = $("sheet");
      this.sheetBody = $("sheet-body");
      this.controls = $("controls");
      this.reportDialog = $("report");
      this.confirmDialog = $("confirm");

      this.setUpStaticParts();
      this.applySheetHeight();
      this.renderChips();
      this.map = new root.SiteMap(model, $("map"), this);
      model.subscribe((kinds) => this.update(kinds));
      this.update(new Set(["state"]));
    }

    // MARK: Layout

    /** Map space covered by the search bar and chips (top) and by the sheet (bottom, or left on wide screens). */
    insets() {
      if (wideQuery.matches) return { top: 60, right: 60, bottom: 16, left: 432 };
      const chips = $("chips").getBoundingClientRect();
      return { top: Math.max(chips.bottom, 100) + 8, right: 0, bottom: this.sheetHeight(this.model.detent) + 8, left: 0 };
    }

    sheetHeight(detent) {
      const h = root.innerHeight;
      if (detent === "large") return Math.round(h - Math.max(52, h * 0.08));
      if (detent === "medium") return Math.round(h * 0.5);
      return 168;
    }

    applySheetHeight(px) {
      const height = px === undefined ? this.sheetHeight(this.model.detent) : px;
      this.sheet.style.setProperty("--sheet-height", `${height}px`);
      this.sheet.dataset.detent = this.model.detent;
      document.documentElement.style.setProperty("--map-bottom", wideQuery.matches ? "0px" : `${height}px`);
    }

    setUpStaticParts() {
      $("search-icon").innerHTML = icon("search", { size: 18 });
      $("search-clear").innerHTML = icon("circle-x", { size: 20 });
      $("sheet-back").innerHTML = icon("chevron-left", { size: 22 });

      // Search
      const input = $("search");
      input.addEventListener("input", () => {
        this.searchText = input.value;
        this.renderSearch();
      });
      input.addEventListener("focus", () => {
        this.searchFocused = true;
        this.renderSearch();
      });
      input.addEventListener("blur", () => {
        this.searchFocused = false;
        root.setTimeout(() => this.renderSearch(), 0);
      });
      input.addEventListener("keydown", (event) => {
        if (event.key === "Escape") this.endSearch();
        if (event.key === "Enter") {
          const first = this.searchText.trim() ? this.model.search(this.searchText)[0] : null;
          if (first) this.finishSearch(first);
        }
      });
      $("search-clear").addEventListener("click", () => this.endSearch());
      const panel = $("search-panel");
      panel.addEventListener("pointerdown", (event) => event.preventDefault());
      panel.addEventListener("click", (event) => {
        const row = event.target.closest("[data-result]");
        if (row) {
          const list = row.dataset.recent ? this.model.recentSearches : this.model.search(this.searchText);
          const result = list.find((r) => r.id === row.dataset.result);
          if (result) this.finishSearch(result);
        }
        if (event.target.closest("[data-action=clear-recent]")) this.model.clearRecentSearches();
      });

      // Chips and map buttons
      $("chips").addEventListener("click", (event) => {
        const chip = event.target.closest("[data-layer]");
        if (chip) this.model.toggle(chip.dataset.layer);
      });
      $("map-buttons").addEventListener("click", (event) => {
        const button = event.target.closest("[data-action]");
        if (!button) return;
        if (button.dataset.action === "recenter") this.model.recenter();
        if (button.dataset.action === "locate") this.model.locateMe();
        if (button.dataset.action === "controls") this.openControls(this.model.pendingReports.length ? "reviews" : "model");
      });

      // Sheet
      $("sheet-back").addEventListener("click", () => this.model.back());
      this.sheetBody.addEventListener("click", (event) => this.handleAction(event));
      this.setUpSheetDrag();
      root.addEventListener("resize", () => {
        this.applySheetHeight();
        this.map && this.map.scheduleRedraw();
      });
      wideQuery.addEventListener("change", () => this.applySheetHeight());

      // Dialogs
      this.controls.addEventListener("click", (event) => this.handleControlsClick(event));
      this.controls.addEventListener("input", (event) => this.handleWeightInput(event));
      this.controls.addEventListener("change", (event) => this.handleWeightCommit(event));
      this.controls.addEventListener("close", () => {
        this.model.controlTab = null;
        this.update(new Set(["controls"]));
      });
      this.reportDialog.addEventListener("click", (event) => this.handleReportClick(event));
      this.confirmDialog.addEventListener("click", (event) => {
        const button = event.target.closest("[data-confirm]");
        if (button) {
          const index = Number(button.dataset.confirm);
          this.confirmDialog.close();
          if (index >= 0 && this.confirmActions[index]) this.confirmActions[index].run();
        } else if (event.target === this.confirmDialog) {
          this.confirmDialog.close();
        }
      });
    }

    setUpSheetDrag() {
      const handle = $("sheet-handle");
      const order = ["peek", "medium", "large"];
      let start = null;
      handle.addEventListener("pointerdown", (event) => {
        if (wideQuery.matches) return;
        start = { y: event.clientY, height: this.sheet.getBoundingClientRect().height, moved: false, time: Date.now() };
        handle.setPointerCapture(event.pointerId);
        this.sheet.classList.add("is-dragging");
      });
      handle.addEventListener("pointermove", (event) => {
        if (!start) return;
        const dy = start.y - event.clientY;
        if (Math.abs(dy) > 4) start.moved = true;
        const height = Math.max(110, Math.min(this.sheetHeight("large"), start.height + dy));
        this.applySheetHeight(height);
      });
      const finish = (event) => {
        if (!start) return;
        this.sheet.classList.remove("is-dragging");
        const current = this.sheet.getBoundingClientRect().height;
        let detent;
        if (!start.moved) {
          detent = order[(order.indexOf(this.model.detent) + 1) % order.length];
        } else {
          const velocity = (start.y - event.clientY) / Math.max(1, Date.now() - start.time);
          detent = order.reduce((best, d) => (Math.abs(this.sheetHeight(d) - current) < Math.abs(this.sheetHeight(best) - current) ? d : best), "peek");
          if (velocity > 0.6) detent = order[Math.min(2, order.indexOf(this.model.detent) + 1)];
          if (velocity < -0.6) detent = order[Math.max(0, order.indexOf(this.model.detent) - 1)];
        }
        start = null;
        this.model.setDetent(detent);
        this.applySheetHeight();
      };
      handle.addEventListener("pointerup", finish);
      handle.addEventListener("pointercancel", finish);
      handle.addEventListener("keydown", (event) => {
        if (event.key !== "Enter" && event.key !== " ") return;
        event.preventDefault();
        this.model.setDetent(order[(order.indexOf(this.model.detent) + 1) % order.length]);
      });
    }

    // MARK: Updates

    update(kinds) {
      const all = kinds.has("state");
      if (all || kinds.has("detent") || kinds.has("route")) this.applySheetHeight();
      this.renderChips();
      this.renderMapButtons();
      this.renderHiddenPins();
      if (all || kinds.has("toast")) this.renderToast();
      if (all || kinds.has("search") || kinds.has("scores")) this.renderSearch();
      if (all || kinds.has("route") || kinds.has("scores") || kinds.has("reports")) this.renderSheet();
      if (this.controls.open && (all || kinds.has("scores") || kinds.has("reports") || kinds.has("controls"))) this.renderControls();
    }

    renderChips() {
      $("chips").innerHTML = SF.LAYERS.map((layer) => {
        const info = SF.LAYER[layer];
        return `<button class="chip" type="button" data-layer="${layer}" aria-pressed="${this.model.layers.has(layer)}">${icon(info.icon, { size: 15 })}${esc(info.title)}</button>`;
      }).join("");
      $("legend").hidden = !this.model.layers.has("demand");
    }

    renderMapButtons() {
      const pending = this.model.pendingReports.length;
      const label = pending ? `Model, data and quality. ${pending} reports waiting for review` : "Model, data and quality";
      $("map-buttons").innerHTML = `
        <button class="map-button" type="button" data-action="recenter" aria-label="Show the whole area">${icon("crosshair", { size: 20 })}</button>
        <button class="map-button" type="button" data-action="locate" aria-label="Show where I am">${icon("navigation", { size: 19 })}</button>
        <button class="map-button" type="button" data-action="controls" aria-label="${label}">${icon("sliders-horizontal", { size: 20 })}${pending ? `<span class="count-badge" aria-hidden="true">${pending}</span>` : ""}</button>`;
    }

    renderHiddenPins() {
      const count = this.model.hiddenPinCount;
      const el = $("hidden-pins");
      el.hidden = count === 0;
      el.innerHTML = count ? `${icon("search", { size: 12 })}${count} pins hidden · zoom in` : "";
      el.setAttribute("aria-label", `${count} pins hidden to avoid overlap. Zoom in to see them.`);
    }

    renderToast() {
      const toast = this.model.toast;
      const el = $("toast");
      el.hidden = !toast;
      el.innerHTML = toast ? `${icon(toast.icon, { size: 16 })}<span>${esc(toast.message)}</span>` : "";
    }

    // MARK: Search

    renderSearch() {
      const panel = $("search-panel");
      const input = $("search");
      const active = this.searchFocused || this.searchText.length > 0;
      $("search-clear").hidden = !active;
      panel.hidden = !active;
      input.setAttribute("aria-expanded", String(active));
      $("chips").hidden = active;
      document.querySelector(".overlay-row").hidden = active;
      if (!active) return;
      if (!this.searchText.trim()) {
        const recent = this.model.recentSearches;
        panel.innerHTML = recent.length
          ? `<div class="recent-head"><span>Recent</span><button type="button" data-action="clear-recent">Clear</button></div>`
            + recent.map((r) => this.searchRow(r, true)).join("")
          : `<p class="search-hint">Search by name, abbreviation (CityU, MK), address (Nathan Road) or Chinese (旺角). Typos are fine.</p>`;
        return;
      }
      const results = this.model.search(this.searchText);
      panel.innerHTML = results.length
        ? results.map((r) => this.searchRow(r, false)).join("")
        : `<p class="search-hint">Try a district (Mong Kok), a school (CityU), an MTR station or 旺角</p>`;
    }

    searchRow(result, recent) {
      const spot = result.icon === "star" && !recent;
      return `<button class="search-row" type="button" data-result="${esc(result.id)}" ${recent ? 'data-recent="1"' : ""}>
        <span class="badge-icon${spot ? " is-spot" : ""}">${icon(recent ? "history" : result.icon, { size: 15 })}</span>
        <span class="row-text"><span class="row-title">${esc(result.title)}</span><span class="row-sub">${esc(result.subtitle)}</span></span>
      </button>`;
    }

    finishSearch(result) {
      this.model.choose(result);
      this.endSearch();
    }

    endSearch() {
      const input = $("search");
      input.value = "";
      this.searchText = "";
      input.blur();
      this.searchFocused = false;
      this.renderSearch();
    }

    // MARK: Sheet

    renderSheet() {
      const model = this.model;
      const route = model.path[0] || null;
      const key = route ? `${route.type}:${route.id}` : "home";
      const sameRoute = key === this.renderedRouteKey;
      const scroll = this.sheetBody.scrollTop;
      let title = "";
      let html;
      if (!route) {
        html = this.homeView();
      } else if (route.type === "spot" || route.type === "block") {
        const spot = route.type === "spot" ? model.spotForBlock(route.id) : null;
        const block = model.block(route.id);
        if (spot) {
          title = `Spot ${spot.letter}`;
          html = this.spotView(spot);
        } else if (block) {
          title = "Street block";
          html = this.blockView(block);
        } else {
          title = "Street block";
          html = `<p class="empty">This block is no longer on the map.</p>`;
        }
      } else if (route.type === "place") {
        const place = model.place(route.id);
        title = place ? SF.KIND[place.kind].title : "Removed";
        html = place ? this.placeView(place)
          : `<div class="empty">${icon("map-pin-off", { size: 34 })}<h2 class="headline">Removed from the map</h2><p class="footnote">An approved report removed this place.</p></div>`;
      } else if (route.type === "compare") {
        title = "Compare spots";
        html = this.compareView();
      } else {
        title = "Districts";
        html = this.districtsView();
      }
      $("sheet-nav").hidden = !route;
      $("sheet-title").textContent = title;
      this.sheetBody.innerHTML = html;
      this.sheetBody.scrollTop = sameRoute ? scroll : 0;
      this.renderedRouteKey = key;
    }

    homeView() {
      const model = this.model;
      const best = model.bestSpot;
      const pending = model.pendingReports.length;
      const rows = model.spots.map((spot) => {
        const confidence = model.confidence(spot.block);
        const d = model.directions(spot.block.center);
        const approved = model.isApproved(spot.id);
        return `<button class="list-row" type="button" ${routeAttrs({ type: "spot", id: spot.id })}>
          ${View.spotPin(spot.letter)}
          <span class="row-text">
            <span class="hstack gap8"><span class="row-title">${esc(SF.SPOT_KIND[spot.kind])}</span>${approved ? `<span style="color:var(--green)">${icon("badge-check", { size: 14, label: "Approved for a pilot" })}</span>` : ""}</span>
            <span class="row-sub" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">${esc(d.short)} · ${esc(model.area.districts[spot.block.district].name)}</span>
          </span>
          <span class="row-end">
            <span class="score-text">Score ${spot.block.score}</span>
            <span class="row-sub">~${round(netOrders(spot.block))}/day · ${SF.FORMAT[spot.format].title}</span>
            ${View.confidenceChip(confidence.level, { compact: true })}
          </span>
          <span class="chevron">${icon("chevron-right", { size: 14 })}</span>
        </button>`;
      }).join("");
      return `<div class="stack">
        ${best ? this.bestPlaceCard(best) : ""}
        <div class="hstack">
          <div class="row-text">
            <h2 class="title3">Top ${model.spots.length} across ${esc(model.area.name)}</h2>
            <p class="footnote mute">${formatted(model.blocks.length)} street blocks scored · at most two spots per district</p>
          </div>
          ${model.spots.length >= 2 ? `<button class="btn" type="button" ${routeAttrs({ type: "compare" })}>${icon("columns-2", { size: 15 })}Compare</button>` : ""}
        </div>
        <div class="card list">${rows}</div>
        ${pending ? `<button class="card list-row" type="button" data-action="controls" data-tab="reviews">
            <span style="color:var(--red)">${icon("inbox", { size: 18 })}</span>
            <span class="row-title" style="flex:1">${pending} reports waiting for review</span>
            <span class="chevron">${icon("chevron-right", { size: 14 })}</span>
          </button>` : ""}
        ${this.pilotCard()}
        <div class="caption mute stack" style="gap:6px">
          <span>${icon("map", { size: 13 })} Web version of the iPhone app. The map is OpenStreetMap; anything you change here (approvals, reports, pilots) is saved in this browser only.</span>
          <span>Places and homes: © OpenStreetMap contributors (ODbL), with 2021 Census district totals and the published CDC branch list. Orders, reports and pilot results are modelled, not measured.</span>
          <span>Student concept by Team 26210. Not affiliated with Café de Coral Holdings Limited.</span>
        </div>
      </div>`;
    }

    bestPlaceCard(spot) {
      const model = this.model;
      const block = spot.block;
      const confidence = model.confidence(block);
      const district = model.area.districts[block.district];
      const d = model.directions(block.center);
      return `<div class="cream pad stack" style="gap:10px">
        <p class="eyebrow">Best place to open next</p>
        <div class="hstack top">${View.spotPin(spot.letter, "big")}
          <div class="row-text">
            <h2 class="title3">${esc(d.short)}</h2>
            <span class="footnote mute">${esc(district.title)} · <span lang="zh-HK">${esc(district.nameZH)}</span> · ${esc(SF.SPOT_KIND[spot.kind])}</span>
          </div>
        </div>
        <div class="mini-stats">
          ${View.miniStat(String(block.score), "score / 100")}
          ${View.miniStat(`~${round(netOrders(block))}`, "new orders a day")}
          ${View.miniStat(SF.Geo.roughCount(block.catchment), "people in 5 min walk")}
        </div>
        <p class="footnote">${esc(model.why(block))}</p>
        <div class="hstack gap8">${View.confidenceChip(confidence.level)}
          ${confidence.coverageNote ? `<span class="warn-label">${icon("triangle-alert", { size: 12 })}Check for a nearby branch first</span>` : ""}
        </div>
        <div class="btn-row">
          <button class="btn prominent wide" type="button" ${routeAttrs({ type: "spot", id: spot.id })}>${icon("lightbulb", { size: 16 })}Why here</button>
          <button class="btn wide" type="button" ${routeAttrs({ type: "districts" })}>${icon("list-ordered", { size: 16 })}All 18 districts</button>
        </div>
      </div>`;
    }

    pilotCard() {
      const model = this.model;
      const last = model.pilotRounds[model.pilotRounds.length - 1];
      return `<div class="cream pad stack" style="gap:10px">
        <h3 class="headline" style="color:var(--brown);font-size:15px">${icon("refresh-cw", { size: 16 })} It learns</h3>
        <p class="footnote">Put lockers at three spots for 4 weeks (approved spots go first). Real orders update the model, so each new pick is better than the last.</p>
        ${last ? `<div class="mini-stats">${View.miniStat(String(model.pilotRounds.length), "pilot rounds")}${View.miniStat(percent(last.errorBefore), "error before")}${View.miniStat(percent(last.errorAfter), "error after")}</div>` : ""}
        <button class="btn prominent tall full" type="button" data-action="run-pilot" ${model.spots.length ? "" : "disabled"}>${icon("play", { size: 16 })}${model.pilotRounds.length ? "Run the next pilot round" : "Run a 4-week locker pilot"}</button>
      </div>`;
    }

    spotView(spot) {
      const model = this.model;
      const block = spot.block;
      const confidence = model.confidence(block);
      const d = model.directions(block.center);
      const approved = model.isApproved(spot.id);
      const net = netOrders(block);
      const scaled = { lunch: block.orders.lunch * (1 - block.cannibalisation), afterSchool: block.orders.afterSchool * (1 - block.cannibalisation), evening: block.orders.evening * (1 - block.cannibalisation) };
      const format = SF.FORMAT[spot.format];
      return `<div class="stack stack-16">
        <div class="hstack">${View.spotPin(spot.letter, "big")}
          <div class="row-text" style="gap:4px">
            <h2 class="title3">${esc(spot.title)}</h2>
            <span class="hstack gap8"><span class="footnote mute">Rank ${spot.rank} of ${model.spots.length}</span>${View.confidenceChip(confidence.level)}</span>
          </div>
        </div>
        ${View.why(model.why(block))}
        <div class="stat-tiles">
          ${View.statTile(String(block.score), "/ 100", "Demand score")}
          ${View.statTile(`~${round(net)}`, "a day", "New orders", `${SF.rangeText(confidence)} likely`)}
          ${View.statTile(SF.Explain.percentText(block.cannibalisation), "", "Taken from CDC", `${block.nearestStore.name}, ${SF.Geo.formatDistance(block.storeDistance)}`)}
        </div>
        ${View.directions(d)}
        <div class="card pad stack" style="gap:10px">
          ${approved
            ? `<div class="approved-line">${icon("badge-check", { size: 18 })}<span style="flex:1">Approved for the next locker pilot</span><button class="link-button" type="button" data-action="undo-decision" data-id="${spot.id}">Undo</button></div>`
            : `<p class="caption mute">Your call: approve it for the next locker pilot, or skip it with a reason.</p>
               <div class="btn-row">
                 <button class="btn prominent wide" type="button" data-action="approve" data-id="${spot.id}">${icon("check", { size: 16 })}Approve</button>
                 <button class="btn wide" type="button" data-action="skip" data-id="${spot.id}">${icon("undo-2", { size: 16 })}Skip</button>
               </div>`}
        </div>
        <div class="cream pad format-card">
          <span class="format-icon">${icon(format.icon, { size: 22 })}</span>
          <div class="row-text" style="gap:3px"><h3 class="headline">Start with a ${esc(format.title.toLowerCase())}</h3><p class="footnote">${esc(format.detail)}</p></div>
        </div>
        ${View.sectionTitle("How sure is this?")}
        ${View.confidenceCard(confidence)}
        ${View.sectionTitle("Why the AI picked it")}
        ${View.inputBars(block, model.weights)}
        ${View.sectionTitle("Expected orders by time of day")}
        ${View.ordersChart(scaled)}
        ${View.externalLinks(block.center)}
        ${View.reportButton()}
      </div>`;
    }

    blockView(block) {
      const model = this.model;
      const excluded = model.excludedBlocks;
      const decision = model.decision(block.id);
      const skipped = !!decision && decision.type === "skipped";
      return `<div class="stack stack-16">
        <div class="row-text"><h2 class="title3">Street block</h2><span class="footnote mute">${excluded.has(block.id) ? "Taken off the shortlist" : "Not shortlisted"}</span></div>
        ${View.why(model.why(block))}
        <div class="stat-tiles">
          ${View.statTile(String(block.score), "/ 100", "Demand score")}
          ${View.statTile(`~${round(netOrders(block))}`, "a day", "New orders")}
          ${View.statTile(SF.Explain.percentText(block.cannibalisation), "", "Taken from CDC", `${block.nearestStore.name}, ${SF.Geo.formatDistance(block.storeDistance)}`)}
        </div>
        ${View.directions(model.directions(block.center))}
        <div class="info-box">
          <div class="info-line">${icon("info", { size: 15 })}<span>${esc(model.engine.exclusionReason(block, model.spots, excluded))}</span></div>
          ${skipped ? `<button class="link-button" type="button" style="font-size:13px;text-align:left" data-action="undo-decision" data-id="${block.id}">Put it back on the shortlist</button>` : ""}
        </div>
        ${View.sectionTitle("What drives this score")}
        ${View.inputBars(block, model.weights)}
        ${View.externalLinks(block.center)}
        ${View.reportButton()}
      </div>`;
    }

    placeView(place) {
      const model = this.model;
      const stale = SF.isStale(place);
      const title = place.kind === "cdcStore" ? `Café de Coral · ${place.name}` : place.name;
      let extra;
      if (place.kind === "cdcStore") {
        const served = model.blocks.filter((b) => b.nearestStore.id === place.id && b.storeDistance < SF.MINIMUM_STORE_GAP).length;
        const nearby = model.spots.filter((s) => s.block.nearestStore.id === place.id);
        extra = `<div class="stat-tiles">${View.statTile(String(served), "blocks", "Already covers", `within ${SF.MINIMUM_STORE_GAP} m`)}${View.statTile(String(nearby.length), "", "Shortlisted spots nearby")}</div>
          ${nearby.length ? `${View.sectionTitle("Spots that would take sales from this store")}
            <div class="card list">${nearby.map((s) => `<button class="list-row" type="button" ${routeAttrs({ type: "spot", id: s.id })}>${View.spotPin(s.letter)}<span class="row-title" style="flex:1">${esc(SF.SPOT_KIND[s.kind])}</span><span class="row-sub">${SF.Explain.percentText(s.block.cannibalisation)} of its orders</span></button>`).join("")}</div>` : ""}`;
      } else {
        const role = {
          school: 'Feeds the "Schools and campuses" input. Universities count about twice as much as a secondary school.',
          university: 'Feeds the "Schools and campuses" input. Universities count about twice as much as a secondary school.',
          office: 'Feeds the "Offices and young workers" input, which mostly drives lunch orders.',
          mtr: 'Feeds the "Footfall and MTR exits" input.',
          rival: 'Feeds the "Rivals nearby" input, which lowers nearby scores. Shown as a category, not a real outlet.',
        }[place.kind];
        extra = `<p class="footnote mute">${esc(role)}</p>`;
      }
      return `<div class="stack stack-16">
        <div class="hstack">${View.placePin(place.kind)}
          <div class="row-text"><h2 class="title3">${esc(title)}</h2><span class="footnote mute"><span lang="zh-HK">${esc(place.nameZH)}</span> · ${esc(SF.KIND[place.kind].title)}</span></div>
        </div>
        ${place.detail ? `<p style="margin:0">${esc(place.detail)}</p>` : ""}
        <div class="freshness card">
          <span class="${stale ? "stale" : "ok"}">${icon(stale ? "triangle-alert" : "badge-check", { size: 18 })}</span>
          <div class="row-text">
            <strong>${stale ? "Needs a check" : `Confirmed open ${esc(SF.Freshness.describe(place.confirmedDaysAgo))}`}</strong>
            ${stale ? `<span class="caption mute">Nobody has confirmed it for ${esc(SF.Freshness.duration(place.confirmedDaysAgo))}.</span>` : ""}
          </div>
          ${place.confirmedDaysAgo > 0 ? `<button class="btn" type="button" data-action="confirm-open" data-id="${esc(place.id)}">Confirm open</button>` : ""}
        </div>
        ${extra}
        ${place.aliases.length ? `<p class="caption mute">Also found by searching: ${esc(place.aliases.join(", "))}</p>` : ""}
        ${View.externalLinks(place.coordinate)}
        ${View.reportButton()}
      </div>`;
    }

    compareView() {
      const model = this.model;
      const spots = model.spots.slice(0, 3);
      const rows = [
        ["Demand score", spots.map((s) => s.block.score), (v) => String(v), true],
        ["New orders a day", spots.map((s) => netOrders(s.block)), (v) => `~${round(v)}`, true],
        ["Taken from CDC", spots.map((s) => s.block.cannibalisation), (v) => SF.Explain.percentText(v), false],
        ["Walk from MTR", spots.map((s) => model.directions(s.block.center).walkMinutes || 99), (v) => `${v} min`, false],
        ["Rent pressure", spots.map((s) => s.block.features.rent || 0), (v) => SF.Explain.level(v), false],
        ["Rivals nearby", spots.map((s) => s.block.features.rivals || 0), (v) => SF.Explain.level(v), false],
      ];
      const body = rows.map(([title, values, fmt, higher]) => {
        const best = higher ? Math.max(...values) : Math.min(...values);
        return `<tr><th scope="row">${title}</th>${values.map((v) => `<td class="${v === best ? "best" : ""}">${esc(fmt(v))}</td>`).join("")}</tr>`;
      }).join("");
      const top = spots[0];
      const tradeOffs = top ? spots.slice(1).map((spot) => `<div class="card pad stack" style="gap:6px">
          <div class="hstack gap8">${View.spotPin(spot.letter, "small")}<h3 class="section-title" style="margin:0">${spot.letter} compared with ${top.letter}</h3></div>
          ${SF.Explain.tradeOffs(spot, top).map((line) => `<div class="tradeoff">${icon("arrow-left-right", { size: 12 })}<span>${esc(line)}</span></div>`).join("")}
        </div>`).join("") : "";
      return `<div class="stack stack-16">
        <div class="row-text"><h2 class="title3">Compare the top ${spots.length}</h2><span class="footnote mute">Best value in each row is in bold.</span></div>
        <div class="card"><table class="compare-table">
          <thead><tr><td></td>${spots.map((s) => `<th scope="col">${View.spotPin(s.letter, "small")}<span class="sr-only">Spot ${s.letter}</span></th>`).join("")}</tr></thead>
          <tbody>${body}
            <tr><th scope="row">Confidence</th>${spots.map((s) => `<td>${View.confidenceChip(model.confidence(s.block).level, { compact: true, showsIcon: false })}</td>`).join("")}</tr>
            <tr><th scope="row">Start with</th>${spots.map((s) => `<td>${SF.FORMAT[s.format].title}</td>`).join("")}</tr>
          </tbody>
        </table></div>
        ${tradeOffs}
        <p class="caption mute">Ranks come from expected new orders after sales taken from existing stores. Confidence shows how much a rank could move if the model's weights are wrong.</p>
      </div>`;
    }

    districtsView() {
      const model = this.model;
      const rows = model.districtRows.map((row, index) => {
        const coverage = row.expectedStores > 0 ? row.mappedStores / row.expectedStores : 1;
        const thin = coverage < 0.6;
        const stores = row.mappedStores >= round(row.expectedStores)
          ? `${row.mappedStores} CDC stores mapped`
          : `${row.mappedStores} of ~${round(row.expectedStores)} stores mapped`;
        const target = row.best ? (row.bestSpot ? { type: "spot", id: row.best.id } : { type: "block", id: row.best.id }) : null;
        return `<button class="list-row" type="button" ${target ? routeAttrs(target) : "disabled"}>
          <span class="rank-num">${index + 1}</span>
          <span class="row-text" style="gap:3px">
            <span class="hstack gap8" style="flex-wrap:wrap"><span class="row-title">${esc(row.district.name)}</span><span class="caption mute" lang="zh-HK">${esc(row.district.nameZH)}</span>${row.bestSpot ? `<span class="spot-tag">Spot ${row.bestSpot.letter}</span>` : ""}</span>
            <span class="row-sub">${formatted(row.district.population)} people · ${SF.Geo.roughCount(row.underserved)} more than 5 min from a mapped CDC</span>
            <span class="coverage${thin ? " thin" : " mute"}">${thin ? icon("triangle-alert", { size: 11 }) : ""}${stores}</span>
          </span>
          ${row.best ? `<span class="row-end"><span class="score-text">~${round(netOrders(row.best))}/day</span><span class="row-sub">score ${row.best.score}</span></span>` : ""}
        </button>`;
      }).join("");
      return `<div class="stack">
        <div class="row-text"><h2 class="title3">Districts ranked by their best spot</h2><span class="footnote mute">New orders a day at the best block in each district, after sales taken from existing stores.</span></div>
        <div class="card list">${rows}</div>
        <p class="caption mute">Stores mapped: ${model.data.stores.length} locations from the published branch list (May 2023), the team's 30 checked branches and OpenStreetMap, against about ${SF.ESTIMATED_STORE_TOTAL} Café de Coral stores today. Districts marked with a warning have fewer than 60% of their likely stores mapped, so their gaps may be data gaps.</p>
      </div>`;
    }

    // MARK: Actions in the sheet

    currentReportTarget() {
      const route = this.model.path[0];
      if (!route) return null;
      if (route.type === "spot" || route.type === "block") {
        const block = this.model.block(route.id);
        if (!block) return null;
        const spot = this.model.spotForBlock(route.id);
        return { target: { type: "block", id: route.id }, title: spot ? spot.title : `Street block: ${this.model.directions(block.center).short}` };
      }
      if (route.type === "place") {
        const place = this.model.place(route.id);
        if (!place) return null;
        return { target: { type: "place", id: place.id }, title: place.kind === "cdcStore" ? `Café de Coral · ${place.name}` : place.name };
      }
      return null;
    }

    handleAction(event) {
      const el = event.target.closest("[data-action]");
      if (!el || el.disabled) return;
      const model = this.model;
      const id = el.dataset.id;
      switch (el.dataset.action) {
        case "open": {
          const type = el.dataset.type;
          const route = { type };
          if (type === "spot" || type === "block") route.id = Number(id);
          if (type === "place") route.id = id;
          model.open(route);
          break;
        }
        case "run-pilot":
          model.runPilot();
          break;
        case "approve":
          model.approveSpot(Number(id));
          break;
        case "skip": {
          const spot = model.spotForBlock(Number(id));
          this.confirm({
            title: `Why skip Spot ${spot ? spot.letter : ""}?`,
            message: "The next best block takes its place. Skips are tracked, so the team can see what the model keeps getting wrong.",
            actions: SiteModel.SKIP_REASONS.map((reason) => ({ label: reason, run: () => model.skipSpot(Number(id), reason) })),
          });
          break;
        }
        case "undo-decision":
          model.clearDecision(Number(id));
          break;
        case "confirm-open":
          model.confirmOpen(id);
          break;
        case "report": {
          const context = this.currentReportTarget();
          if (context) this.openReport(context.target, context.title);
          break;
        }
        case "controls":
          this.openControls(el.dataset.tab || "model");
          break;
        default:
          break;
      }
    }

    // MARK: Confirmation dialog

    confirm({ title, message, actions }) {
      this.confirmActions = actions;
      this.confirmDialog.innerHTML = `
        <div class="confirm-box">
          <div class="confirm-text"><h2 id="confirm-title">${esc(title)}</h2>${message ? `<p>${esc(message)}</p>` : ""}</div>
          ${actions.map((a, i) => `<button class="confirm-action${a.destructive ? " destructive-action" : ""}" type="button" data-confirm="${i}">${esc(a.label)}</button>`).join("")}
        </div>
        <div class="confirm-box confirm-cancel"><button class="confirm-action" type="button" data-confirm="-1" style="font-weight:600">Cancel</button></div>`;
      this.confirmDialog.showModal();
    }

    // MARK: Report a problem

    openReport(target, title) {
      const options = SF.ReportChecks.options(target);
      this.reportContext = { target, title };
      this.reportDialog.innerHTML = `<form class="dialog-inner" method="dialog">
        <div class="dialog-head">
          <button class="text-button left" type="button" data-report="cancel">Cancel</button>
          <h2 id="report-title">Report a problem</h2>
          <button class="text-button strong right" type="button" data-report="send">Send</button>
        </div>
        <div class="dialog-body">
          <div class="group"><p class="group-head">Reporting</p><div class="group-box"><div class="group-row"><strong>${esc(title)}</strong></div></div></div>
          <fieldset class="group" style="border:0;padding:0;margin-left:0;margin-right:0"><legend class="group-head" style="padding:0">What's wrong?</legend><div class="group-box">
            ${options.map((kind, i) => `<label class="choice"><input type="radio" name="kind" value="${kind}" ${i === 0 ? "checked" : ""}>
              <span style="color:var(--brown)">${icon(SF.REPORT_KIND[kind].icon, { size: 18 })}</span><span>${esc(SF.REPORT_KIND[kind].title)}</span><span class="tick">${icon("check", { size: 18 })}</span></label>`).join("")}
          </div></fieldset>
          <fieldset class="group" style="border:0;padding:0;margin-left:0;margin-right:0"><legend class="group-head" style="padding:0">Who's reporting?</legend><div class="group-box">
            ${SF.ROLES.map((role, i) => `<label class="choice"><input type="radio" name="role" value="${role}" ${i === 0 ? "checked" : ""}>
              <span class="row-text"><span>${esc(SF.ROLE[role].title)}</span><span class="caption mute">${esc(SF.ROLE[role].trust)}</span></span><span class="tick">${icon("check", { size: 18 })}</span></label>`).join("")}
          </div>
          <p class="group-foot">Reports from people on site are reviewed first. Nobody's report changes the map until a reviewer approves it.</p></fieldset>
          <div class="group"><p class="group-head"><label for="report-note">Note (optional)</label></p><div class="group-box"><textarea id="report-note" class="note-input" rows="3" placeholder="What did you see?"></textarea></div></div>
        </div>
      </form>`;
      this.reportDialog.showModal();
    }

    handleReportClick(event) {
      const button = event.target.closest("[data-report]");
      if (!button) return;
      if (button.dataset.report === "send" && this.reportContext) {
        const form = this.reportDialog.querySelector("form");
        const kind = form.querySelector("input[name=kind]:checked").value;
        const role = form.querySelector("input[name=role]:checked").value;
        const note = form.querySelector("#report-note").value;
        this.model.submitReport(this.reportContext.target, kind, role, note);
      }
      this.reportDialog.close();
    }

    // MARK: Control centre (model, data, reviews, quality)

    openControls(tab) {
      this.controlsTab = tab;
      this.model.openControls(tab);
      if (!this.controls.open) this.controls.showModal();
      this.renderControls(true);
    }

    renderControls(reset = false) {
      if (this.draggingWeights) {
        this.updateWeightLabels();
        return;
      }
      const model = this.model;
      const tab = this.controlsTab;
      const pending = model.pendingReports.length;
      const titles = { model: "How the AI scores", data: "Data and freshness", reviews: "Review reports", quality: "Quality checks" };
      const tabs = [["model", "Model"], ["data", "Data"], ["reviews", pending ? `Reviews (${pending})` : "Reviews"], ["quality", "Quality"]];
      const previous = this.controls.querySelector(".dialog-body");
      const scroll = previous && !reset ? previous.scrollTop : 0;
      const body = tab === "model" ? this.modelTab() : tab === "data" ? this.dataTab() : tab === "reviews" ? this.reviewsTab() : this.qualityTab();
      this.controls.innerHTML = `<div class="dialog-inner">
        <div class="dialog-head"><span></span><h2 id="controls-title">${titles[tab]}</h2><button class="text-button strong right" type="button" data-controls="done">Done</button></div>
        <div class="segmented" role="tablist" aria-label="Section">${tabs.map(([id, label]) => `<button type="button" role="tab" aria-selected="${tab === id}" data-tab="${id}">${esc(label)}</button>`).join("")}</div>
        <div class="dialog-body" role="tabpanel">${body}</div>
      </div>`;
      this.controls.querySelector(".dialog-body").scrollTop = scroll;
    }

    group(head, rows, foot = "") {
      return `<section class="group">${head ? `<h3 class="group-head">${esc(head)}</h3>` : ""}<div class="group-box">${rows}</div>${foot ? `<p class="group-foot">${esc(foot)}</p>` : ""}</section>`;
    }

    modelTab() {
      const model = this.model;
      const steps = [
        ["What the AI looks at", "Six inputs for every street block in the area"],
        ["What it predicts", "Demand score (0–100), expected orders at lunch, after school and in the evening, and sales taken from the nearest CDC"],
        ["Result", "A ranked shortlist, each spot with a confidence level and the cheapest format to start with"],
        ["People decide", "The team approves or skips each pick, and reviews reports before the map changes"],
        ["It learns", "Real locker orders update the weights below"],
      ].map(([title, detail], i) => `<div class="group-row top"><span class="flow-num">${i + 1}</span><div class="row-text"><strong style="font-size:15px">${title}</strong><span class="caption mute">${detail}</span></div></div>`).join("");

      const total = SF.Weights.total(model.weights);
      const weights = SF.FEATURES.map((f) => {
        const info = SF.FEATURE[f];
        const value = model.weights[f];
        return `<div class="group-row column">
          <div class="hstack top" style="gap:10px"><span style="color:var(--brown)">${icon(info.icon, { size: 18 })}</span>
            <div class="row-text"><strong style="font-size:15px">${esc(info.title)}</strong><span class="caption mute">${esc(info.source)}</span></div>
            <span class="weight-value${info.penalty ? " down" : ""}" data-weight-value="${f}">${info.penalty ? "−" : ""}${round(value / Math.max(total, 0.01) * 100)}%</span>
          </div>
          <input type="range" min="0.02" max="0.6" step="0.005" value="${value}" data-weight="${f}" aria-label="${esc(info.title)} weight">
        </div>`;
      }).join("");

      let pilots;
      if (!model.pilotRounds.length) {
        pilots = `<div class="group-row"><span class="footnote mute">No pilots yet. Run one from the shortlist to see the model learn.</span></div>`;
      } else {
        pilots = `<div class="group-row column">${this.pilotChart(model.pilotRounds)}</div>`
          + model.pilotRounds.slice().reverse().map((r) => `<div class="group-row column" style="gap:4px">
            <strong style="font-size:15px">Round ${r.id}: error ${percent(r.errorBefore)} → ${percent(r.errorAfter)}</strong>
            <span class="caption mute">${r.results.map((x) => `${x.letter} ${round(x.predicted)} predicted, ${round(x.actual)} actual`).join(" · ")}</span></div>`).join("");
      }
      return this.group("How a spot gets picked", steps)
        + this.group("Inputs and learned weights", weights, "Drag a slider to see the shortlist re-rank on the map. Rivals and rent lower a score; the rest raise it.")
        + this.group("Pilot history", pilots, "Error is how far predicted orders were from actual locker orders, before the model learned from that round.")
        + this.group("", `<button class="destructive" type="button" data-controls="reset-model">Reset the model</button>`, "Resets the weights and clears pilot rounds. Reports, data changes and team decisions stay.");
    }

    pilotChart(rounds) {
      const w = 320, h = 150, left = 44, bottom = 26, top = 8, right = 10;
      const values = rounds.map((r) => r.errorBefore * 100);
      const maxY = Math.max(5, Math.ceil(Math.max(...values) / 5) * 5);
      const x = (i) => rounds.length === 1 ? left + (w - left - right) / 2 : left + i * (w - left - right) / (rounds.length - 1);
      const y = (v) => top + (h - top - bottom) * (1 - v / maxY);
      const ticks = [0, maxY / 2, maxY];
      const points = values.map((v, i) => `${x(i)},${y(v)}`).join(" ");
      return `<svg class="chart-svg" viewBox="0 0 ${w} ${h}" role="img" aria-label="Prediction error by pilot round: ${values.map((v, i) => `round ${rounds[i].id} ${Math.round(v)}%`).join(", ")}">
        ${ticks.map((t) => `<line x1="${left}" x2="${w - right}" y1="${y(t)}" y2="${y(t)}" stroke="var(--line)"/><text x="${left - 6}" y="${y(t) + 4}" text-anchor="end" font-size="10" fill="var(--mute)">${Math.round(t)}</text>`).join("")}
        <polyline points="${points}" fill="none" stroke="var(--brown)" stroke-width="2"/>
        ${values.map((v, i) => `<circle cx="${x(i)}" cy="${y(v)}" r="4" fill="var(--brown)"/><text x="${x(i)}" y="${h - 10}" text-anchor="middle" font-size="10" fill="var(--mute)">${rounds[i].id}</text>`).join("")}
        <text x="${(w + left) / 2}" y="${h}" text-anchor="middle" font-size="10" fill="var(--mute)">Pilot round</text>
        <text x="${-(top + (h - top - bottom) / 2)}" y="10" font-size="10" fill="var(--mute)" text-anchor="middle" transform="rotate(-90)">Prediction error, %</text>
      </svg>`;
    }

    dataTab() {
      const model = this.model;
      const inputs = SF.FEATURES.map((f) => {
        const info = SF.FEATURE[f];
        return `<div class="group-row top"><span style="color:var(--brown)">${icon(info.icon, { size: 18 })}</span><div class="row-text">
          <strong style="font-size:15px">${esc(info.title)}</strong><span class="caption mute">${esc(info.source)}.</span><span class="caption mute"><b>${esc(info.updated)}</b></span></div></div>`;
      }).join("");

      const coverage = model.districtRows.slice().sort((a, b) => a.district.index - b.district.index).map((row) => {
        const share = row.expectedStores > 0 ? row.mappedStores / row.expectedStores : 1;
        const thin = share < 0.6;
        return `<div class="group-row"><span style="flex:1">${esc(row.district.name)}</span>${thin ? `<span style="color:var(--amber)">${icon("triangle-alert", { size: 14 })}</span>` : ""}
          <span class="weight-value" style="font-weight:400;color:${thin ? "var(--amber)" : "var(--mute)"}">${row.mappedStores} of ~${round(row.expectedStores)}</span></div>`;
      }).join("");

      const stale = model.stalePlaces;
      const staleRows = stale.length === 0
        ? `<div class="group-row" style="color:var(--green)">${icon("badge-check", { size: 16 })}<span class="footnote">Every place was confirmed in the last ${SF.Freshness.staleAfterDays} days.</span></div>`
        : stale.slice(0, 15).map((p) => `<div class="group-row">${View.placePin(p.kind, 0.8)}<div class="row-text"><strong style="font-size:15px">${esc(p.name)}</strong>
            <span class="caption mute">${esc(p.detail)} · not confirmed for ${esc(SF.Freshness.duration(p.confirmedDaysAgo))}</span></div>
            <button class="btn" type="button" data-controls="confirm-place" data-id="${esc(p.id)}">Confirm</button></div>`).join("")
          + (stale.length > 15 ? `<div class="group-row"><span class="footnote mute">and ${stale.length - 15} more</span></div>` : "");

      const edits = model.appliedEdits.length === 0
        ? `<div class="group-row"><span class="footnote mute">No changes yet. Approved reports and confirmations appear here.</span></div>`
        : model.appliedEdits.slice().reverse().map((a) => `<div class="group-row"><div class="row-text"><span>${esc(a.summary)}</span><span class="caption mute">${esc(dateTime(a.date))}</span></div>
            <button class="link-button" type="button" style="font-size:13px" data-controls="undo-edit" data-id="${esc(a.id)}">Undo</button></div>`).join("");

      const skipped = Array.from(model.decisions).filter(([, d]) => d.type === "skipped").sort((a, b) => a[0] - b[0]);
      const skippedRows = skipped.length === 0
        ? `<div class="group-row"><span class="footnote mute">No spots skipped.</span></div>`
        : skipped.map(([id, d]) => {
          const block = model.block(id);
          return `<div class="group-row"><div class="row-text"><span>${esc(block ? model.directions(block.center).short : "Street block")}</span><span class="caption mute">${esc(d.reason)}</span></div>
            <button class="link-button" type="button" style="font-size:13px" data-controls="restore" data-id="${id}">Restore</button></div>`;
        }).join("");

      const privacy = [
        ["grid-3x3", "Homes are counted per 280 m street block from public building data, never per person."],
        ["users", "With real Club 100 orders, blocks with fewer than 20 orders a week would be merged with neighbours."],
        ["lock", "Pilots use locker totals only. Nobody's order history leaves the Club 100 system."],
        ["navigation", "Your location is used only on this device to find the block you're in. It isn't stored."],
      ].map(([i, text]) => `<div class="group-row top footnote"><span style="color:var(--brown)">${icon(i, { size: 16 })}</span><span>${text}</span></div>`).join("");

      return this.group("Inputs and when they were last updated", inputs)
        + this.group("CDC stores mapped, by district", coverage, `Expected counts share ${SF.ESTIMATED_STORE_TOTAL} stores by population. Where coverage is thin, "no CDC nearby" may be a data gap, so those spots get lower confidence. CDC's own store list would close this.`)
        + this.group(`Stores and rivals that need a check (${stale.length})`, staleRows, "Not checked on OpenStreetMap, or listed only in the May 2023 branch list, for over two years. Out-of-date places cause the worst map mistakes.")
        + this.group("Changes applied to the map", edits)
        + this.group("Spots the team skipped", skippedRows)
        + this.group("Privacy", privacy, "Collect only what the model needs, as the maps report recommends. Sample rules for the concept.")
        + this.group("", `<button class="destructive" type="button" data-controls="reset-all">Reset the whole demo</button>`, "Restores the starting weights, data and report queue, and clears decisions and recent searches.");
    }

    reportRow(report) {
      const model = this.model;
      const role = SF.ROLE[report.role];
      const verdictIcon = { agrees: "shield-check", disagrees: "shield-alert", unsure: "circle-help" }[report.check.verdict];
      let status;
      if (report.status === "pending") {
        status = `<div class="btn-row">
          <button class="btn prominent wide" type="button" data-controls="approve-report" data-id="${esc(report.id)}">${icon("check", { size: 15 })}Approve</button>
          <button class="btn danger wide" type="button" data-controls="reject-report" data-id="${esc(report.id)}">${icon("x", { size: 15 })}Reject</button>
        </div>`;
      } else if (report.status === "approved") {
        status = `<span class="status-line ok">${icon("circle-check", { size: 14 })}Approved · map updated</span>`;
      } else {
        status = `<span class="status-line no">${icon("circle-x", { size: 14 })}Rejected · map unchanged</span>`;
      }
      return `<div class="group-row column" style="gap:8px">
        <div class="hstack top" style="gap:10px"><span style="color:var(--brown)">${icon(SF.REPORT_KIND[report.kind].icon, { size: 18 })}</span>
          <div class="row-text" style="gap:2px"><strong style="font-size:15px">${esc(SF.REPORT_KIND[report.kind].title)}</strong>
            <span class="footnote">${esc(model.titleFor(report.target))}</span>
            <span class="caption mute">${esc(role.title)} · ${esc(role.trust)} · ${esc(ago(report.created))}</span></div></div>
        ${report.note ? `<p class="footnote" style="margin:0;font-style:italic">“${esc(report.note)}”</p>` : ""}
        <div class="check-badge ${report.check.verdict}"><span class="verdict">${icon(verdictIcon, { size: 13 })}${SF.VERDICT[report.check.verdict]}</span><span class="caption">${esc(report.check.detail)}</span></div>
        ${status}
      </div>`;
    }

    reviewsTab() {
      const pending = this.model.pendingReports;
      const reviewed = this.model.reviewedReports;
      const pendingRows = pending.length === 0
        ? `<div class="group-row footnote mute">${icon("inbox", { size: 16 })}<span>Nothing waiting. New reports appear here before they change the map.</span></div>`
        : pending.map((r) => this.reportRow(r)).join("");
      return this.group("Waiting for review", pendingRows, "Tiered trust, like Waze's map editors: anyone can report, on-site reports come first, and only a reviewer changes the map. The automated check flags reports that clash with listings or sales data.")
        + (reviewed.length ? this.group("Reviewed", reviewed.map((r) => this.reportRow(r)).join("")) : "");
    }

    qualityTab() {
      const model = this.model;
      const metrics = model.qualityMetrics.map((m) => {
        const cls = m.passes === true ? "pass" : m.passes === false ? "fail" : "none";
        const sym = m.passes === true ? "circle-check" : m.passes === false ? "triangle-alert" : "circle-dashed";
        return `<div class="group-row top"><span class="metric-icon ${cls}">${icon(sym, { size: 18 })}</span><div class="row-text" style="gap:3px">
          <span class="hstack"><strong style="font-size:15px;flex:1">${esc(m.title)}</strong><strong class="weight-value">${esc(m.value)}</strong></span>
          <span class="caption mute">${esc(m.detail)}</span><span class="caption mute"><b>Target: ${esc(m.target)}</b></span></div></div>`;
      }).join("");
      const bench = model.searchBenchmark;
      const cases = bench.rows.filter((row) => row.testCase.note !== "shortlist letter").map((row) => `<div class="group-row top">
          <span style="color:${row.passed ? "var(--green)" : "var(--red)"}">${icon(row.passed ? "circle-check" : "circle-x", { size: 17 })}</span>
          <div class="row-text"><strong class="footnote">“${esc(row.testCase.query)}”</strong><span class="caption mute">${esc(row.testCase.note)} → ${esc(row.first ? row.first.title : "no result")}</span></div></div>`).join("");
      return this.group("Metrics worth tracking", metrics, "From the maps report: ETA error becomes prediction error, route acceptance becomes how often the team accepts a pick.")
        + this.group(`Search test set: ${bench.passed} of ${bench.total} right first`, cases, "Real queries the team types, kept as a regression test. The same set runs in the app's unit tests.");
    }

    handleControlsClick(event) {
      if (event.target === this.controls) {
        this.controls.close();
        return;
      }
      const tab = event.target.closest("[data-tab]");
      if (tab && this.controls.contains(tab) && tab.closest(".segmented")) {
        this.controlsTab = tab.dataset.tab;
        this.model.controlTab = this.controlsTab;
        this.renderControls(true);
        return;
      }
      const button = event.target.closest("[data-controls]");
      if (!button) return;
      const model = this.model;
      const id = button.dataset.id;
      switch (button.dataset.controls) {
        case "done":
          this.controls.close();
          break;
        case "reset-model":
          this.confirm({ title: "Reset the weights and clear all pilot rounds?", message: "", actions: [{ label: "Reset", destructive: true, run: () => model.resetModel() }] });
          break;
        case "reset-all":
          this.confirm({ title: "Reset everything to the starting demo?", message: "", actions: [{ label: "Reset everything", destructive: true, run: () => model.resetEverything() }] });
          break;
        case "confirm-place":
          model.confirmOpen(id);
          break;
        case "undo-edit": {
          const applied = model.appliedEdits.find((a) => a.id === id);
          if (applied) model.undo(applied);
          break;
        }
        case "restore":
          model.clearDecision(Number(id));
          break;
        case "approve-report": {
          const report = model.reports.find((r) => r.id === id);
          if (report) model.approve(report);
          break;
        }
        case "reject-report": {
          const report = model.reports.find((r) => r.id === id);
          if (report) model.reject(report);
          break;
        }
        default:
          break;
      }
    }

    handleWeightInput(event) {
      const slider = event.target.closest("[data-weight]");
      if (!slider) return;
      this.draggingWeights = true;
      this.pendingWeight = [slider.dataset.weight, Number(slider.value)];
      if (this.weightFrame) return;
      this.weightFrame = root.requestAnimationFrame(() => {
        this.weightFrame = null;
        const [feature, value] = this.pendingWeight;
        this.model.setWeight(feature, value);
      });
    }

    handleWeightCommit(event) {
      if (!event.target.closest("[data-weight]")) return;
      this.draggingWeights = false;
      this.model.commitWeights();
      root.setTimeout(() => this.renderControls(), 0);
    }

    updateWeightLabels() {
      const total = SF.Weights.total(this.model.weights);
      for (const label of this.controls.querySelectorAll("[data-weight-value]")) {
        const f = label.dataset.weightValue;
        label.textContent = `${SF.FEATURE[f].penalty ? "−" : ""}${round(this.model.weights[f] / Math.max(total, 0.01) * 100)}%`;
      }
    }
  }

  // MARK: Start

  function start() {
    const body = $("sheet-body");
    Promise.all(["data/hk_places.json", "data/hk_cells.json"].map((path) => fetch(path).then((response) => {
      if (!response.ok) throw new Error(`${path}: HTTP ${response.status}`);
      return response.json();
    })))
      .then(([places, cells]) => {
        const area = SF.loadArea(places, cells);
        const model = new SiteModel(area);
        root.siteFinder = new App(model);
      })
      .catch((error) => {
        body.innerHTML = `<p class="loading">Couldn't load the map data (${esc(error.message)}). Please reload the page.</p>`;
        console.error(error);
      });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", start);
  else start();
})(typeof globalThis !== "undefined" ? globalThis : this);
