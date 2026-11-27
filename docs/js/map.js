/* CDC Site Finder: the map, translated from the app's AppleSiteMap/GoogleSiteMap behaviour.
 * Demand cells (3×3 groups when zoomed out), place pins with the collision pass, spot pins that fold
 * together when they'd overlap, the selected spot's 400 m ring, and camera moves that keep the
 * target clear of the search bar and the sheet. */
(function (root) {
  "use strict";
  const SF = root.SF;
  const SiteModel = root.SiteModel;

  const DEMAND = [[22, "#FCE9B8"], [38, "#F9D27A"], [52, "#F4B63E"], [66, "#EC961C"], [78, "#D96A0E"]];
  const HK_BOUNDS = [[22.15, 113.82], [22.57, 114.45]];

  function demandColor(score) {
    let color = null;
    for (const [from, hex] of DEMAND) if (score >= from) color = hex;
    return color;
  }

  function esc(value) {
    return String(value).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
  }

  function selectedBlockID(selection) {
    return selection && (selection.type === "spot" || selection.type === "block") ? selection.id : null;
  }

  class SiteMap {
    constructor(model, element, ui) {
      this.model = model;
      this.ui = ui;
      this.dark = root.matchMedia("(prefers-color-scheme: dark)");
      this.reducedMotion = root.matchMedia("(prefers-reduced-motion: reduce)");

      const map = L.map(element, {
        zoomControl: false,
        zoomSnap: 0,
        zoomDelta: 1,
        wheelPxPerZoomLevel: 100,
        minZoom: 9,
        maxZoom: 19,
        maxBounds: [[21.85, 113.5], [22.85, 114.8]],
        maxBoundsViscosity: 0.7,
      });
      this.map = map;
      L.control.zoom({ position: "bottomright" }).addTo(map);
      map.attributionControl.setPrefix('<a href="https://leafletjs.com">Leaflet</a>');
      L.tileLayer("https://tile.openstreetmap.org/{z}/{x}/{y}.png", {
        maxZoom: 19,
        attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors',
      }).addTo(map);

      this.renderer = L.canvas({ padding: 0.3 });
      this.demandLayer = L.layerGroup().addTo(map);
      this.highlightLayer = L.layerGroup().addTo(map);
      this.placeMarkers = new Map();
      this.spotMarkers = new Map();
      this.spotKeys = new Map();
      this.ring = null;
      this.userMarker = null;
      this.cameraID = model.camera.id;
      this.dataVersion = model.dataVersion;
      this.frame = null;

      this.fitHongKong(false);
      map.on("moveend", () => this.scheduleRedraw());
      map.on("click", (event) => this.handleClick(event.latlng));
      this.dark.addEventListener("change", () => this.scheduleRedraw());
      model.subscribe((kinds) => this.update(kinds));
      this.redraw();
    }

    update(kinds) {
      if (this.model.dataVersion !== this.dataVersion) {
        this.dataVersion = this.model.dataVersion;
        for (const marker of this.placeMarkers.values()) marker.remove();
        this.placeMarkers.clear();
      }
      if (kinds.has("camera") && this.model.camera.id !== this.cameraID) {
        this.cameraID = this.model.camera.id;
        this.applyCamera();
      }
      if (kinds.has("scores") || kinds.has("layers") || kinds.has("route") || kinds.has("state")) this.scheduleRedraw();
      if (kinds.has("location")) this.drawUser();
    }

    scheduleRedraw() {
      if (this.frame) return;
      this.frame = root.requestAnimationFrame(() => {
        this.frame = null;
        this.redraw();
      });
    }

    redraw() {
      this.drawDemand();
      this.drawRing();
      this.layoutPins();
      this.drawUser();
    }

    // MARK: Camera

    fitHongKong(animated) {
      const insets = this.ui.insets();
      const options = {
        paddingTopLeft: [insets.left + 8, insets.top + 8],
        paddingBottomRight: [insets.right + 8, insets.bottom + 8],
      };
      if (animated && !this.reducedMotion.matches) this.map.flyToBounds(HK_BOUNDS, Object.assign({ duration: 0.8 }, options));
      else this.map.fitBounds(HK_BOUNDS, options);
    }

    /** Centres the target in the part of the map that isn't under the search bar or the sheet. */
    applyCamera() {
      const camera = this.model.camera;
      if (camera.fit) {
        this.fitHongKong(true);
        return;
      }
      const insets = this.ui.insets();
      const zoom = camera.zoom;
      const point = this.map.project(L.latLng(camera.center.lat, camera.center.lon), zoom)
        .add([(insets.right - insets.left) / 2, (insets.bottom - insets.top) / 2]);
      const center = this.map.unproject(point, zoom);
      if (this.reducedMotion.matches) this.map.setView(center, zoom);
      else this.map.flyTo(center, zoom, { duration: 0.8 });
    }

    // MARK: Demand cells

    visibleRegion(share) {
      const b = this.map.getBounds();
      const dLat = (b.getNorth() - b.getSouth()) * share;
      const dLon = (b.getEast() - b.getWest()) * share;
      return { minLat: b.getSouth() - dLat, maxLat: b.getNorth() + dLat, minLon: b.getWest() - dLon, maxLon: b.getEast() + dLon };
    }

    drawDemand() {
      this.demandLayer.clearLayers();
      this.highlightLayer.clearLayers();
      if (!this.model.layers.has("demand")) return;
      const zoom = this.map.getZoom();
      for (const cell of this.model.drawCells(this.visibleRegion(0.3), zoom)) {
        const color = demandColor(cell.score);
        if (!color) continue;
        const c = cell.corners;
        L.rectangle([[c[0].lat, c[0].lon], [c[2].lat, c[2].lon]], {
          renderer: this.renderer, stroke: false, fillColor: color, fillOpacity: 0.5, interactive: false,
        }).addTo(this.demandLayer);
      }
      const selected = selectedBlockID(this.model.selection);
      if (selected !== null && zoom >= SiteModel.DETAIL_ZOOM && this.model.block(selected)) {
        const c = this.model.area.Grid.corners(selected);
        L.rectangle([[c[0].lat, c[0].lon], [c[2].lat, c[2].lon]], {
          renderer: this.renderer, fill: false, color: this.dark.matches ? "#F7B500" : "#4A2511", weight: 2.5, interactive: false,
        }).addTo(this.highlightLayer);
      }
    }

    drawRing() {
      if (this.ring) {
        this.ring.remove();
        this.ring = null;
      }
      const selection = this.model.selection;
      const spot = selection && selection.type === "spot" ? this.model.spotForBlock(selection.id) : null;
      if (!spot) return;
      this.ring = L.circle([spot.block.center.lat, spot.block.center.lon], {
        radius: 400, color: this.dark.matches ? "#F7B500" : "#4A2511", opacity: 0.85, weight: 1.5,
        fillColor: "#F7B500", fillOpacity: 0.12, interactive: false,
      }).addTo(this.map);
    }

    drawUser() {
      const here = this.model.userLocation;
      if (!here) return;
      const latlng = [here.lat, here.lon];
      if (!this.userMarker) {
        this.userMarker = L.marker(latlng, {
          icon: L.divIcon({ className: "", html: '<span class="user-dot"></span><span class="sr-only">You are here</span>', iconSize: [18, 18], iconAnchor: [9, 9] }),
          keyboard: false, interactive: false, zIndexOffset: 4000,
        }).addTo(this.map);
      } else {
        this.userMarker.setLatLng(latlng);
      }
    }

    // MARK: Pins

    spotIcon(spot, more, selected, approved) {
      const size = selected ? 44 : 36;
      const label = (approved ? `✓ ${spot.block.score}` : `${spot.block.score}`) + (more ? ` +${more}` : "");
      const spoken = `${spot.title}, score ${spot.block.score}` + (more ? `, and ${more} more spots nearby. Zoom in to see them` : "");
      return L.divIcon({
        className: `spot-pin${selected ? " is-selected" : ""}`,
        html: `<span class="spot-letter" style="width:${size}px;height:${size}px" aria-hidden="true">${esc(spot.letter)}</span>`
          + `<span class="spot-score" aria-hidden="true">${esc(label)}</span><span class="sr-only">${esc(spoken)}</span>`,
        iconSize: null,
        iconAnchor: [size / 2, size / 2],
      });
    }

    placeIcon(place) {
      const kind = SF.KIND[place.kind];
      const d = kind.diameter;
      const name = place.kind === "cdcStore" ? `Café de Coral, ${place.name}` : place.name;
      const spoken = `${name}, ${kind.title}` + (SF.isStale(place) ? ", needs a check" : "");
      return L.divIcon({
        className: "",
        html: `<span class="place-pin" style="width:${d}px;height:${d}px;background:${kind.color}">${root.icon(kind.icon, { size: Math.round(d * 0.5) })}</span><span class="sr-only">${esc(spoken)}</span>`,
        iconSize: [d, d],
        iconAnchor: [d / 2, d / 2],
      });
    }

    layoutPins() {
      const model = this.model;
      const map = this.map;
      const size = map.getSize();
      const bounds = { x: 0, y: 0, width: size.x, height: size.y };
      const point = (c) => map.latLngToContainerPoint([c.lat, c.lon]);

      // Spots first: pins that would overlap fold into the best-ranked one, which shows "+N".
      const spotPoints = model.spots.map((spot) => ({ id: spot.id, point: point(spot.block.center) }));
      const selection = model.selection;
      const keep = selection && selection.type === "spot" ? selection.id : null;
      const groups = SF.PinLayout.groupSpots(spotPoints, keep);
      const shortlisted = new Set(model.spots.map((s) => s.id));
      for (const [id, marker] of this.spotMarkers) {
        if (!shortlisted.has(id)) {
          marker.remove();
          this.spotMarkers.delete(id);
          this.spotKeys.delete(id);
        }
      }
      for (const spot of model.spots) {
        let marker = this.spotMarkers.get(spot.id);
        const more = groups.get(spot.id);
        if (more === undefined) {
          if (marker) marker.remove();
          continue;
        }
        const selected = keep === spot.id;
        const approved = model.isApproved(spot.id);
        if (!marker) {
          marker = L.marker([spot.block.center.lat, spot.block.center.lon], { keyboard: true, riseOnHover: true });
          const id = spot.id;
          marker.on("click", () => model.open({ type: "spot", id }));
          this.spotMarkers.set(spot.id, marker);
        }
        const key = `${spot.letter}|${spot.block.score}|${more}|${selected}|${approved}`;
        if (this.spotKeys.get(spot.id) !== key) {
          marker.setIcon(this.spotIcon(spot, more, selected, approved));
          marker.setZIndexOffset(selected ? 3000 : 2000 - spot.rank * 10);
          this.spotKeys.set(spot.id, key);
        }
        if (!map.hasLayer(marker)) marker.addTo(map);
      }

      // Then places, in priority order, skipping any that would collide.
      const kinds = new Set();
      for (const layer of model.layers) for (const kind of SF.LAYER[layer].kinds) kinds.add(kind);
      const reserved = [];
      for (const s of spotPoints) {
        if (groups.has(s.id)) reserved.push(s.point, { x: s.point.x + 30, y: s.point.y });
      }
      const area = map.getBounds().pad(0.1);
      const candidates = [];
      if (kinds.size) {
        for (const place of SF.allPlaces(model.data)) {
          if (!kinds.has(place.kind) || !area.contains([place.coordinate.lat, place.coordinate.lon])) continue;
          candidates.push({ id: place.id, kind: place.kind, point: point(place.coordinate), place });
        }
      }
      const alwaysShow = new Set(selection && selection.type === "place" ? [selection.id] : []);
      const result = SF.PinLayout.visible(candidates, reserved, bounds, alwaysShow);
      const wanted = new Map();
      for (const c of candidates) if (result.visible.has(c.id)) wanted.set(c.id, c.place);
      for (const [id, marker] of this.placeMarkers) {
        if (!wanted.has(id)) {
          marker.remove();
          this.placeMarkers.delete(id);
        }
      }
      for (const [id, place] of wanted) {
        if (this.placeMarkers.has(id)) continue;
        const marker = L.marker([place.coordinate.lat, place.coordinate.lon], {
          icon: this.placeIcon(place), keyboard: true, zIndexOffset: 1000 - SF.KIND[place.kind].priority * 100,
        });
        marker.on("click", () => model.open({ type: "place", id }));
        marker.addTo(map);
        this.placeMarkers.set(id, marker);
      }
      if (model.hiddenPinCount !== result.hiddenOnScreen) {
        model.hiddenPinCount = result.hiddenOnScreen;
        model.changed("pins");
      }
    }

    // MARK: Taps

    handleClick(latlng) {
      const model = this.model;
      const zoom = this.map.getZoom();
      const coordinate = { lat: latlng.lat, lon: latlng.lng };
      if (zoom < SiteModel.DETAIL_ZOOM && model.layers.has("demand")) {
        // Zoomed out, a cell stands for 9 blocks: open its best block and zoom in.
        const cell = model.drawCells(this.visibleRegion(0), zoom).find((c) => {
          const lats = c.corners.map((p) => p.lat);
          const lons = c.corners.map((p) => p.lon);
          return coordinate.lat >= Math.min(...lats) && coordinate.lat <= Math.max(...lats)
            && coordinate.lon >= Math.min(...lons) && coordinate.lon <= Math.max(...lons);
        });
        if (cell) {
          model.open(model.spotForBlock(cell.blockID) ? { type: "spot", id: cell.blockID } : { type: "block", id: cell.blockID });
          return;
        }
      }
      model.tapMap(coordinate);
    }
  }

  root.SiteMap = SiteMap;
})(typeof globalThis !== "undefined" ? globalThis : this);
