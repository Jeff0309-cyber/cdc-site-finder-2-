/* CDC Site Finder: app state, translated from the iPhone app's SiteModel.swift.
 * Holds the weights, team decisions, reports, pilots and map edits, saves them in this browser,
 * and tells the screen to redraw when anything changes. */
(function (root) {
  "use strict";
  const SF = root.SF;
  const { netOrders, round } = SF;

  const STORAGE_KEY = "siteFinder.state.v2";
  const SKIP_REASONS = ["No space for a locker", "Landlord said no", "Too close to a rival", "Something else"];
  const DETAIL_ZOOM = 13;
  const HONG_KONG = { minLat: 22.15, maxLat: 22.57, minLon: 113.82, maxLon: 114.45 };

  function newID() {
    if (root.crypto && typeof root.crypto.randomUUID === "function") return root.crypto.randomUUID();
    return "id-" + Date.now().toString(36) + "-" + Math.random().toString(36).slice(2, 10);
  }

  function percent(value) {
    return `${round(value * 100)}%`;
  }

  function sameRoute(a, b) {
    return !!a && !!b && a.type === b.type && a.id === b.id;
  }

  function regionContains(region, c) {
    return c.lat >= region.minLat && c.lat <= region.maxLat && c.lon >= region.minLon && c.lon <= region.maxLon;
  }

  class SiteModel {
    constructor(area, { persists = true } = {}) {
      this.area = area;
      this.persists = persists;
      this.listeners = new Set();
      this.weights = SF.Weights.copy(SF.Weights.starting);
      this.pilotRounds = [];
      this.appliedEdits = [];
      this.reports = [];
      this.decisions = new Map();
      this.recentSearches = [];
      this.layers = new Set(["demand", "stores"]);
      this.path = [];
      this.selection = null;
      this.detent = "peek";
      this.camera = { id: 0, fit: true };
      this.controlTab = null;
      this.toast = null;
      this.hiddenPinCount = 0;
      this.scoreVersion = 0;
      this.dataVersion = 0;
      this.userLocation = null;

      const restored = persists && this.restore();
      this.rebuild();
      if (!restored) {
        this.reports = SF.ReportChecks.seeds(area, this.data, (id) => this.block(id), this.spots, new Date(), newID);
        this.save();
      }
    }

    // MARK: Change notifications

    subscribe(listener) {
      this.listeners.add(listener);
      return () => this.listeners.delete(listener);
    }

    changed(what = "state") {
      if (this.pendingChange) {
        this.pendingChange.add(what);
        return;
      }
      this.pendingChange = new Set([what]);
      queueMicrotask(() => {
        const kinds = this.pendingChange;
        this.pendingChange = null;
        for (const listener of this.listeners) listener(kinds);
      });
    }

    // MARK: Lookups

    block(id) {
      const index = this.blockIndex.get(id);
      return index === undefined ? null : this.blocks[index];
    }

    get bestSpot() {
      return this.spots[0] || null;
    }

    spotForBlock(id) {
      return this.spots.find((s) => s.block.id === id) || null;
    }

    place(id) {
      return SF.allPlaces(this.data).find((p) => p.id === id) || null;
    }

    drawCells(region, zoom) {
      const area = region || HONG_KONG;
      if (zoom < DETAIL_ZOOM) {
        return this.coarseCells.filter((cell) => regionContains(area, cell.corners[0]) || regionContains(area, cell.corners[2]));
      }
      const out = [];
      for (const block of this.blocks) {
        if (block.score < SF.MINIMUM_DRAWN_SCORE || !regionContains(area, block.center)) continue;
        out.push({ id: `b${block.id}`, blockID: block.id, corners: this.area.Grid.corners(block.id), score: block.score });
      }
      return out;
    }

    get pendingReports() {
      return this.reports.filter((r) => r.status === "pending").sort((a, b) => {
        const trust = SF.ROLE[b.role].trustRank - SF.ROLE[a.role].trustRank;
        return trust !== 0 ? trust : (a.created < b.created ? 1 : a.created > b.created ? -1 : 0);
      });
    }

    get reviewedReports() {
      return this.reports.filter((r) => r.status !== "pending")
        .sort((a, b) => ((b.reviewed || "") > (a.reviewed || "") ? 1 : (b.reviewed || "") < (a.reviewed || "") ? -1 : 0));
    }

    /** Blocks the shortlist must skip, with the reason shown to the team. */
    get excludedBlocks() {
      const result = new Map();
      for (const [id, decision] of this.decisions) {
        if (decision.type === "skipped") result.set(id, `skipped by the team (${decision.reason.toLowerCase()})`);
      }
      for (const applied of this.appliedEdits) {
        if (applied.edit.type === "excludeBlock") result.set(applied.edit.id, applied.edit.reason);
      }
      return result;
    }

    get stalePlaces() {
      return SF.allPlaces(this.data).filter(SF.isStale).sort((a, b) => b.confirmedDaysAgo - a.confirmedDaysAgo);
    }

    confidence(block) {
      return this.confidences.get(block.id) || this.engine.confidence(block, this.weights, this.evidence(block.id));
    }

    evidence(blockID) {
      for (let i = this.pilotRounds.length - 1; i >= 0; i--) {
        const result = this.pilotRounds[i].results.find((r) => r.blockID === blockID);
        if (result) return { round: this.pilotRounds[i].id, result };
      }
      return null;
    }

    directions(coordinate) {
      return SF.Wayfinding.describe(coordinate, this.data);
    }

    why(block) {
      const spot = this.spotForBlock(block.id);
      return SF.Explain.why(block, this.weights, this.data, spot ? spot.rank : null);
    }

    decision(blockID) {
      return this.decisions.get(blockID) || null;
    }

    isApproved(blockID) {
      const d = this.decisions.get(blockID);
      return !!d && d.type === "approved";
    }

    titleFor(target) {
      if (target.type === "place") {
        const place = this.place(target.id) || SF.allPlaces(this.area.base).find((p) => p.id === target.id);
        if (!place) return "A removed place";
        return place.kind === "cdcStore" ? `Café de Coral · ${place.name}` : place.name;
      }
      const block = this.block(target.id);
      if (!block) return "A street block";
      const spot = this.spotForBlock(target.id);
      if (spot) return spot.title;
      return `Street block: ${this.directions(block.center).short}`;
    }

    // MARK: Selection and camera

    open(route, moveCamera = true) {
      this.selection = route;
      this.path = [route];
      if (this.detent === "peek") this.detent = "medium";
      if (moveCamera) {
        if (route.type === "spot" || route.type === "block") {
          const block = this.block(route.id);
          if (block) this.focus(block.center, 15.6);
        } else if (route.type === "place") {
          const place = this.place(route.id);
          if (place) this.focus(place.coordinate, 15.8);
        } else {
          this.recenter();
        }
      }
      this.changed("route");
    }

    /** Back from a detail page to the list. */
    back() {
      this.path = [];
      this.selection = null;
      this.changed("route");
    }

    tapMap(coordinate) {
      const id = this.area.Grid.id(coordinate);
      const block = id === null ? null : this.block(id);
      if (!this.layers.has("demand") || !block || block.score < SF.MINIMUM_DRAWN_SCORE) {
        this.closeDetail();
        return;
      }
      this.open(this.spotForBlock(id) ? { type: "spot", id } : { type: "block", id }, false);
    }

    closeDetail() {
      this.path = [];
      this.selection = null;
      this.detent = "peek";
      this.changed("route");
    }

    focus(coordinate, zoom) {
      this.camera = { id: this.camera.id + 1, center: coordinate, zoom };
      this.changed("camera");
    }

    recenter() {
      this.camera = { id: this.camera.id + 1, fit: true };
      this.changed("camera");
    }

    setDetent(detent) {
      if (this.detent === detent) return;
      this.detent = detent;
      this.changed("detent");
    }

    toggle(layer) {
      if (this.layers.has(layer)) this.layers.delete(layer);
      else this.layers.add(layer);
      this.changed("layers");
    }

    openControls(tab) {
      this.controlTab = tab;
      this.changed("controls");
    }

    // MARK: Model and pilots

    setWeight(feature, value) {
      this.weights[feature] = value;
      this.rescore();
    }

    commitWeights() {
      this.save();
    }

    /** Spots the team approved go first; the rest of the top three fill in. */
    get pilotSites() {
      const approved = this.spots.filter((s) => this.isApproved(s.id));
      const others = this.spots.filter((s) => !this.isApproved(s.id));
      return approved.concat(others).slice(0, 3);
    }

    runPilot() {
      const sites = this.pilotSites;
      if (!sites.length) return;
      const { round: pilotRound, weights } = this.engine.runPilot(this.pilotRounds.length + 1, this.weights, sites);
      this.pilotRounds.push(pilotRound);
      this.weights = weights;
      this.rescore();
      this.save();
      this.showToast(`Pilot round ${pilotRound.id}: error ${percent(pilotRound.errorBefore)} → ${percent(pilotRound.errorAfter)}. Shortlist updated.`, "refresh-cw");
    }

    resetModel() {
      this.weights = SF.Weights.copy(SF.Weights.starting);
      this.pilotRounds = [];
      this.rescore();
      this.save();
    }

    resetEverything() {
      this.weights = SF.Weights.copy(SF.Weights.starting);
      this.pilotRounds = [];
      this.appliedEdits = [];
      this.decisions = new Map();
      this.recentSearches = [];
      this.rebuild();
      this.reports = SF.ReportChecks.seeds(this.area, this.data, (id) => this.block(id), this.spots, new Date(), newID);
      this.closeDetail();
      this.save();
      this.showToast("Demo reset to its starting state.", "rotate-ccw");
    }

    // MARK: Team decisions

    approveSpot(id) {
      this.decisions.set(id, { type: "approved" });
      this.rescore();
      this.save();
      const spot = this.spotForBlock(id);
      this.showToast(`Spot ${spot ? spot.letter : ""} approved. It goes into the next locker pilot.`, "badge-check");
    }

    skipSpot(id, reason) {
      const spot = this.spotForBlock(id);
      this.decisions.set(id, { type: "skipped", reason });
      this.rescore();
      this.save();
      this.showToast(`Spot ${spot ? spot.letter : ""} skipped. The next best block moved onto the shortlist.`, "undo-2");
    }

    clearDecision(id) {
      this.decisions.delete(id);
      this.rescore();
      this.save();
    }

    // MARK: Reports and edits

    submitReport(target, kind, role, note) {
      const check = SF.ReportChecks.check(kind, target, this.data, (id) => this.block(id));
      this.reports.unshift({
        id: newID(), target, kind, role, note: note.trim(), created: new Date().toISOString(),
        check, status: "pending", reviewed: null,
      });
      this.save();
      this.showToast("Sent for review. The map only changes once a reviewer approves it.", "send");
      this.changed("reports");
    }

    approve(report) {
      const stored = this.reports.find((r) => r.id === report.id);
      if (!stored) return;
      stored.status = "approved";
      stored.reviewed = new Date().toISOString();
      let center = null;
      if (stored.target.type === "block") {
        const block = this.block(stored.target.id);
        center = block ? block.center : null;
      }
      const edit = SF.ReportChecks.edit(stored, center);
      if (edit) {
        const summary = `${SF.REPORT_KIND[stored.kind].title}: ${this.titleFor(stored.target)}`;
        this.appliedEdits.push({ id: newID(), edit, summary, reportID: stored.id, date: new Date().toISOString() });
        if (stored.target.type === "place" && this.path.some((r) => sameRoute(r, { type: "place", id: stored.target.id }))) {
          this.closeDetail();
        }
        this.rebuild();
        this.showToast(`Map updated: ${SF.REPORT_KIND[stored.kind].title.toLowerCase()}.`, "map");
      }
      this.save();
      this.changed("reports");
    }

    reject(report) {
      const stored = this.reports.find((r) => r.id === report.id);
      if (!stored) return;
      stored.status = "rejected";
      stored.reviewed = new Date().toISOString();
      this.save();
      this.changed("reports");
    }

    undo(applied) {
      this.appliedEdits = this.appliedEdits.filter((a) => a.id !== applied.id);
      if (applied.reportID) {
        const report = this.reports.find((r) => r.id === applied.reportID);
        if (report) {
          report.status = "pending";
          report.reviewed = null;
        }
      }
      this.rebuild();
      this.save();
    }

    /** A team member confirms a place is still open. Freshness resets to today. */
    confirmOpen(placeID) {
      const place = this.place(placeID);
      if (!place) return;
      this.appliedEdits.push({ id: newID(), edit: { type: "confirmPlace", id: placeID }, summary: `Confirmed open: ${place.name}`, reportID: null, date: new Date().toISOString() });
      this.rebuild();
      this.save();
      this.showToast("Marked as confirmed open today.", "badge-check");
    }

    // MARK: Location

    locateMe() {
      if (!root.navigator || !root.navigator.geolocation) {
        this.showToast("This browser can't share your location.", "navigation-off");
        return;
      }
      root.navigator.geolocation.getCurrentPosition(
        (position) => this.handleLocation({ lat: position.coords.latitude, lon: position.coords.longitude }),
        (error) => {
          if (error && error.code === 1) this.showToast("Location is off. Allow it for this site to check spots on site.", "navigation-off");
          else this.showToast("Couldn't find your location. Try again outdoors.", "navigation-off");
        },
        { enableHighAccuracy: true, timeout: 12000, maximumAge: 30000 },
      );
    }

    handleLocation(coordinate) {
      const id = this.area.Grid.id(coordinate);
      const block = id === null ? null : this.block(id);
      if (!block) {
        this.showToast(`You're outside the ${this.area.name} pilot area.`, "navigation-off");
        return;
      }
      this.userLocation = coordinate;
      this.focus(coordinate, 16.2);
      if (block.score >= SF.MINIMUM_DRAWN_SCORE) {
        this.open(this.spotForBlock(id) ? { type: "spot", id } : { type: "block", id }, false);
        this.showToast(`You're standing in a block that scores ${block.score}.`, "navigation");
      } else {
        this.showToast("You're here. This block has too little demand to score.", "navigation");
      }
    }

    // MARK: Toast

    showToast(message, icon) {
      const toast = { id: newID(), message, icon };
      this.toast = toast;
      this.changed("toast");
      setTimeout(() => {
        if (this.toast && this.toast.id === toast.id) {
          this.toast = null;
          this.changed("toast");
        }
      }, 3500);
    }

    // MARK: Search

    search(text) {
      if (!this.searchEntries) this.searchEntries = SF.Search.entries(this.area, this.spots, this.data);
      return SF.Search.results(text, this.area, this.spots, this.data, 8, this.searchEntries);
    }

    choose(result) {
      this.recentSearches = [result].concat(this.recentSearches.filter((r) => r.id !== result.id)).slice(0, 5);
      this.save();
      if (result.target.type === "route") {
        this.open(result.target.route);
      } else {
        this.closeDetail();
        this.focus(result.target.coordinate, 15.4);
      }
    }

    clearRecentSearches() {
      this.recentSearches = [];
      this.save();
      this.changed("search");
    }

    // MARK: Quality

    get searchBenchmark() {
      if (!this.benchmark) this.benchmark = SF.SearchBenchmark.run(this.area, this.spots, this.data);
      return this.benchmark;
    }

    get qualityMetrics() {
      const metrics = [];
      const last = this.pilotRounds[this.pilotRounds.length - 1];
      metrics.push(last
        ? { id: "error", title: "Prediction error", value: percent(last.errorBefore), target: "10% or less", passes: last.errorBefore <= 0.10,
          detail: "How far predicted orders were from actual locker orders in the latest pilot, before learning. The site-finder version of ETA error." }
        : { id: "error", title: "Prediction error", value: "—", target: "10% or less", passes: null,
          detail: "Run a locker pilot to measure how far predictions are from real orders." });

      const bench = this.searchBenchmark;
      metrics.push({ id: "search", title: "Search finds it first", value: `${bench.passed} of ${bench.total}`, target: "90% or more",
        passes: bench.rate >= 0.9, detail: "Test queries whose first result is right, including typos, abbreviations and Chinese names." });

      const places = this.data.stores.concat(this.data.rivals);
      const fresh = places.filter((p) => !SF.isStale(p)).length;
      metrics.push({ id: "fresh", title: "Stores and rivals checked recently", value: `${fresh} of ${places.length}`, target: "95% or more",
        passes: fresh / Math.max(places.length, 1) >= 0.95,
        detail: "Checked in the last two years. Stale places are the most common way maps go wrong; CDC's live store list and a weekly listings feed would fix this." });

      const reviewed = this.reports.filter((r) => r.status !== "pending");
      const right = reviewed.filter((r) => r.status === "approved").length;
      metrics.push({ id: "precision", title: "Report precision", value: reviewed.length ? `${right} of ${reviewed.length}` : "—", target: "Tracked", passes: null,
        detail: "Reviewed reports that turned out to be right. If this drops, tighten the automated checks." });

      const decided = Array.from(this.decisions.values());
      const approved = decided.filter((d) => d.type === "approved").length;
      metrics.push({ id: "acceptance", title: "Picks the team accepts", value: decided.length ? `${approved} of ${decided.length}` : "—", target: "60% or more",
        passes: decided.length ? approved / decided.length >= 0.6 : null,
        detail: "AI picks approved for a pilot. Like drivers rejecting a route, repeated skips show what the model is missing." });
      return metrics;
    }

    // MARK: Rebuilding

    rebuild() {
      this.data = this.appliedEdits.length
        ? SF.applyEdits(this.area.base, this.appliedEdits.map((a) => a.edit))
        : this.area.base;
      this.engine = new SF.SiteEngine(this.area, this.data);
      // People more than a 5-minute walk from a mapped CDC, per district. Weights don't change this.
      const underserved = this.area.districts.map(() => 0);
      for (const block of this.engine.blocks(this.weights)) {
        if (block.storeDistance > 400 && block.district >= 0 && block.district < underserved.length) {
          underserved[block.district] += this.area.residentsByID.get(block.id) || 0;
        }
      }
      this.underservedByDistrict = underserved;
      this.dataVersion += 1;
      this.rescore();
    }

    rescore() {
      this.blocks = this.engine.blocks(this.weights);
      this.blockIndex = new Map(this.blocks.map((b, i) => [b.id, i]));
      const excludedMap = this.excludedBlocks;
      const excluded = new Set(excludedMap.keys());
      this.spots = this.engine.shortlist(this.blocks, this.weights, excluded);
      this.confidences = new Map(this.spots.map((s) => [s.id, this.engine.confidence(s.block, this.weights, this.evidence(s.id))]));

      // Coarse cells for the whole-territory view: the best block in each 3×3 group.
      const G = this.area.Grid;
      const groups = new Map();
      for (const block of this.blocks) {
        if (block.score < SF.MINIMUM_DRAWN_SCORE) continue;
        const [row, col] = G.rowColumn(block.id);
        const key = Math.trunc(row / 3) * G.columns + Math.trunc(col / 3);
        const current = groups.get(key);
        if (block.score > (current ? current.score : -1)) groups.set(key, block);
      }
      this.coarseCells = Array.from(groups, ([key, best]) => {
        const origin = Math.trunc(key / G.columns) * 3 * G.columns + (key % G.columns) * 3;
        return { id: `c${key}`, blockID: best.id, corners: G.corners(origin, 3), score: best.score };
      });

      const best = this.engine.bestBlocks(this.blocks, excluded);
      this.districtRows = this.area.districts.map((district) => {
        const block = best.get(district.index) || null;
        return {
          district, best: block, bestSpot: block ? this.spotForBlock(block.id) : null,
          mappedStores: this.engine.mappedStores[district.index], expectedStores: this.engine.expectedStores[district.index],
          underserved: this.underservedByDistrict[district.index] || 0,
        };
      }).sort((a, b) => (b.best ? netOrders(b.best) : 0) - (a.best ? netOrders(a.best) : 0));

      this.searchEntries = null;
      this.benchmark = null;
      this.scoreVersion += 1;
      this.changed("scores");
    }

    // MARK: Persistence (this browser only)

    save() {
      if (!this.persists) return;
      const state = {
        weights: this.weights, pilotRounds: this.pilotRounds, appliedEdits: this.appliedEdits, reports: this.reports,
        decisions: Array.from(this.decisions.entries()), recentSearches: this.recentSearches,
      };
      try {
        root.localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
      } catch (error) {
        // Private browsing or storage turned off: the demo still works, it just won't remember.
      }
    }

    /** Returns false on the first visit, when there's nothing saved yet. */
    restore() {
      let state;
      try {
        state = JSON.parse(root.localStorage.getItem(STORAGE_KEY) || "null");
      } catch (error) {
        return false;
      }
      if (!state || !state.weights) return false;
      this.weights = SF.Weights.copy(state.weights);
      this.pilotRounds = state.pilotRounds || [];
      this.appliedEdits = state.appliedEdits || [];
      this.reports = state.reports || [];
      this.decisions = new Map(state.decisions || []);
      this.recentSearches = state.recentSearches || [];
      return true;
    }
  }

  SiteModel.SKIP_REASONS = SKIP_REASONS;
  SiteModel.DETAIL_ZOOM = DETAIL_ZOOM;
  SiteModel.HONG_KONG = HONG_KONG;
  SiteModel.percent = percent;
  SiteModel.sameRoute = sameRoute;
  root.SiteModel = SiteModel;
})(typeof globalThis !== "undefined" ? globalThis : this);
