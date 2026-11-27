/* CDC Site Finder: the scoring engine, translated line by line from the iPhone app's Swift code
 * (ios/CDCSiteFinder/Model: Places, SiteEngine, Explain, Reports, SearchIndex, PinLayout).
 * It reads the same two data files as the app, so the website and the app give the same answers.
 * No browser APIs here, so it also runs in the command-line parity test (tools/web_parity). */
(function (root) {
  "use strict";

  // MARK: Small helpers that match Swift's behaviour

  /** Swift's `rounded()`: halves round away from zero. */
  function round(x) {
    return x < 0 ? -Math.round(-x) : Math.round(x);
  }

  const grouping = new Intl.NumberFormat("en-US");
  function formatted(n) {
    return grouping.format(n);
  }

  /** First element with the largest key, like Swift's `max(by:)`. */
  function maxBy(list, key) {
    let best = null;
    let bestKey = -Infinity;
    for (const item of list) {
      const k = key(item);
      if (best === null || k > bestKey) {
        best = item;
        bestKey = k;
      }
    }
    return best;
  }

  // MARK: Places

  const Geo = {
    /** Distance in metres. An equirectangular approximation is accurate to well under 1% at city scale. */
    meters(a, b) {
      const midLatitude = (a.lat + b.lat) / 2 * Math.PI / 180;
      const dx = (b.lon - a.lon) * Math.cos(midLatitude) * 111320;
      const dy = (b.lat - a.lat) * 110540;
      return Math.sqrt(dx * dx + dy * dy);
    },

    /** Compass bearing from `a` to `b`, in degrees clockwise from north. */
    bearing(a, b) {
      const midLatitude = (a.lat + b.lat) / 2 * Math.PI / 180;
      const dx = (b.lon - a.lon) * Math.cos(midLatitude) * 111320;
      const dy = (b.lat - a.lat) * 110540;
      const degrees = Math.atan2(dx, dy) * 180 / Math.PI;
      return degrees < 0 ? degrees + 360 : degrees;
    },

    formatDistance(meters) {
      if (!Number.isFinite(meters)) return "—";
      return meters < 1000 ? `${round(meters / 10) * 10} m` : `${(meters / 1000).toFixed(1)} km`;
    },

    /** "about 21,000" for explanations, rounded so it doesn't pretend to be exact. */
    roughCount(value) {
      const rounded = value >= 10000 ? round(value / 1000) * 1000 : round(value / 100) * 100;
      return formatted(Math.trunc(rounded));
    },
  };

  const PLACE_KINDS = ["cdcStore", "university", "school", "office", "mtr", "rival"];
  const KIND = {
    cdcStore: { title: "Café de Coral", priority: 0, icon: "utensils", color: "#4A2511", diameter: 30 },
    university: { title: "University campus", priority: 1, icon: "graduation-cap", color: "#34495E", diameter: 30 },
    school: { title: "School", priority: 4, icon: "book", color: "#34495E", diameter: 26 },
    office: { title: "Office cluster", priority: 3, icon: "building-2", color: "#5D6166", diameter: 26 },
    mtr: { title: "MTR station", priority: 2, icon: "tram-front", color: "#B8372D", diameter: 26 },
    rival: { title: "Rival fast-food outlet", priority: 5, icon: "store", color: "#8A8178", diameter: 22 },
  };

  const Freshness = {
    staleAfterDays: 730,

    describe(daysAgo) {
      if (daysAgo === 0) return "today";
      if (daysAgo === 1) return "yesterday";
      if (daysAgo < 60) return `${daysAgo} days ago`;
      if (daysAgo < 730) return `${Math.trunc(daysAgo / 30)} months ago`;
      return `${Math.trunc(daysAgo / 365)} years ago`;
    },

    /** "120 days", "5 months", "3 years": for sentences like "not checked for 3 years". */
    duration(days) {
      if (days < 60) return `${days} day${days === 1 ? "" : "s"}`;
      if (days < 730) return `${Math.trunc(days / 30)} months`;
      return `${Math.trunc(days / 365)} years`;
    },
  };

  /** Restaurants open and close; schools and stations come from official lists and rarely change. */
  function isStale(place) {
    return (place.kind === "cdcStore" || place.kind === "rival") && place.confirmedDaysAgo > Freshness.staleAfterDays;
  }

  // MARK: Inputs and weights

  const FEATURES = ["appOrders", "schools", "offices", "rivals", "footfall", "rent"];
  const FEATURE = {
    appOrders: {
      title: "Homes with no CDC nearby", short: "Homes", icon: "house", penalty: false,
      source: "Where people live: OpenStreetMap homes scaled to 2021 Census district totals. Stands in for Club 100 and eatCDC orders",
      updated: "Homes downloaded 27 Nov 2026 · Census 2021",
    },
    schools: {
      title: "Schools and campuses", short: "Schools", icon: "graduation-cap", penalty: false,
      source: "Schools and university campuses from OpenStreetMap", updated: "Downloaded 27 Nov 2026",
    },
    offices: {
      title: "Offices and young workers", short: "Offices", icon: "building-2", penalty: false,
      source: "Office and commercial buildings from OpenStreetMap", updated: "Downloaded 27 Nov 2026",
    },
    rivals: {
      title: "Rivals nearby", short: "Rivals", icon: "store", penalty: true,
      source: "Fairwood, Maxim's MX, Tai Hing and McDonald's outlets from OpenStreetMap",
      updated: "Downloaded 27 Nov 2026 · outlets last checked at different times",
    },
    footfall: {
      title: "Footfall and MTR exits", short: "Footfall", icon: "tram-front", penalty: false,
      source: "MTR stations from OpenStreetMap", updated: "Downloaded 27 Nov 2026",
    },
    rent: {
      title: "Rents (shop density)", short: "Rent", icon: "key-round", penalty: true,
      source: "Shop density from OpenStreetMap, standing in for ground-floor rents", updated: "Downloaded 27 Nov 2026",
    },
  };

  const Weights = {
    /** The model's starting guess, before any pilot data. */
    starting: Object.freeze({ appOrders: 0.30, schools: 0.20, offices: 0.20, rivals: 0.08, footfall: 0.20, rent: 0.06 }),
    /** What the real world rewards in this simulation. The model never sees these numbers; it only sees
     * locker sales generated from them, and has to learn its way towards them. */
    hiddenTruth: Object.freeze({ appOrders: 0.34, schools: 0.30, offices: 0.10, rivals: 0.12, footfall: 0.16, rent: 0.05 }),

    total(w) {
      let sum = 0;
      for (const f of FEATURES) sum += w[f] || 0;
      return sum;
    },

    copy(w) {
      const out = {};
      for (const f of FEATURES) out[f] = w[f] || 0;
      return out;
    },
  };

  function ordersTotal(orders) {
    return orders.lunch + orders.afterSchool + orders.evening;
  }

  /** New orders a day once sales moved from the nearest CDC are taken out. */
  function netOrders(block) {
    return ordersTotal(block.orders) * (1 - block.cannibalisation);
  }

  function contribution(block, feature, weights) {
    const value = (weights[feature] || 0) * (block.features[feature] || 0);
    return FEATURE[feature].penalty ? -value : value;
  }

  const SPOT_KIND = {
    schoolCluster: "School cluster",
    university: "University campus",
    officeHub: "Office hub",
    transitHub: "Transit hub",
    housingArea: "Housing area",
  };

  const FORMAT = {
    locker: { title: "Locker", icon: "grid-3x3", detail: "A 40-slot pickup locker refilled from the nearest kitchen three times a day. Cheapest way to test demand." },
    kiosk: { title: "Pop-up kiosk", icon: "shopping-bag", detail: "A small counter with a reduced menu. Needs a shopfront and two staff at peak." },
    store: { title: "Full store", icon: "utensils", detail: "A full Café de Coral. Only worth it once lockers and kiosks prove steady demand." },
  };

  const LEVELS = ["low", "medium", "high"];
  const LEVEL = {
    low: { title: "Low", margin: 0.28, rank: 0 },
    medium: { title: "Medium", margin: 0.18, rank: 1 },
    high: { title: "High", margin: 0.10, rank: 2 },
  };

  function rangeText(confidence) {
    return `${round(confidence.low)}–${round(confidence.high)}`;
  }

  function confidenceReason(confidence) {
    let text = `Moves most if the ${FEATURE[confidence.sensitiveTo].short.toLowerCase()} weight is off.`;
    if (confidence.evidence) {
      text += ` Tested in pilot round ${confidence.evidence.round}: ${round(confidence.evidence.result.predicted)} predicted,`
        + ` ${round(confidence.evidence.result.actual)} actual.`;
    } else {
      text += " Not piloted yet, so the range is wide.";
    }
    if (confidence.coverageNote) text += " " + confidence.coverageNote;
    return text;
  }

  // MARK: The Hong Kong data (AreaData)

  const ESTIMATED_STORE_TOTAL = 168;

  const UNIVERSITY_ALIASES = [
    ["City University of Hong Kong", ["CityU", "城大"]],
    ["The Chinese University of Hong Kong", ["CUHK", "中大"]],
    ["The University of Hong Kong", ["HKU", "港大"]],
    ["HKU", ["HKU", "港大"]],
    ["The Hong Kong University of Science and Technology", ["HKUST", "UST", "科大"]],
    ["The Hong Kong Polytechnic University", ["PolyU", "理大"]],
    ["Hong Kong Baptist University", ["HKBU", "浸大"]],
    ["Lingnan University", ["嶺大"]],
    ["The Education University of Hong Kong", ["EdUHK", "教大"]],
    ["Hong Kong Metropolitan University", ["HKMU", "Open University", "公開大學", "都大"]],
    ["Hong Kong Shue Yan University", ["Shue Yan", "樹仁"]],
    ["The Hang Seng University of Hong Kong", ["HSUHK", "恒大"]],
  ];

  const DISTRICT_ALIASES = {
    central: ["Central", "Sheung Wan", "Sai Ying Pun", "Kennedy Town", "Mid-Levels", "中環", "上環", "堅尼地城"],
    wanchai: ["Causeway Bay", "Happy Valley", "CWB", "銅鑼灣", "跑馬地"],
    eastern: ["North Point", "Quarry Bay", "Tai Koo", "Shau Kei Wan", "Chai Wan", "北角", "鰂魚涌", "太古", "柴灣"],
    southern: ["Aberdeen", "Ap Lei Chau", "Stanley", "Wong Chuk Hang", "香港仔", "鴨脷洲", "赤柱"],
    ytm: ["Mong Kok", "Tsim Sha Tsui", "TST", "Jordan", "Yau Ma Tei", "旺角", "尖沙咀", "佐敦", "油麻地"],
    ssp: ["Cheung Sha Wan", "Mei Foo", "Lai Chi Kok", "Shek Kip Mei", "長沙灣", "美孚", "荔枝角"],
    kc: ["Hung Hom", "Kai Tak", "To Kwa Wan", "Ho Man Tin", "紅磡", "啟德", "土瓜灣", "何文田"],
    wts: ["Diamond Hill", "Lok Fu", "Tsz Wan Shan", "San Po Kong", "鑽石山", "樂富", "慈雲山", "新蒲崗"],
    kt: ["Kowloon Bay", "Lam Tin", "Ngau Tau Kok", "Yau Tong", "九龍灣", "藍田", "牛頭角", "油塘"],
    kwaitsing: ["Tsing Yi", "Kwai Fong", "Kwai Chung", "Kwai Hing", "青衣", "葵芳", "葵涌", "葵興"],
    tsuenwan: ["Tsuen Wan West", "Ma Wan", "荃灣西", "馬灣"],
    tuenmun: ["Siu Hong", "Tuen Mun Town Centre", "兆康", "屯門市中心"],
    yuenlong: ["Tin Shui Wai", "Long Ping", "TSW", "天水圍", "朗屏"],
    north: ["Sheung Shui", "Fanling", "上水", "粉嶺"],
    taipo: ["Tai Po Market", "Tai Wo", "大埔墟", "太和"],
    shatin: ["Ma On Shan", "Tai Wai", "Fo Tan", "MOS", "馬鞍山", "大圍", "火炭"],
    saikung: ["Tseung Kwan O", "TKO", "Hang Hau", "LOHAS Park", "將軍澳", "坑口", "康城"],
    islands: ["Tung Chung", "Lantau", "Discovery Bay", "Cheung Chau", "東涌", "大嶼山", "愉景灣", "長洲"],
  };

  /** Builds everything that depends only on the two data files: grid, raster, districts and places. */
  function loadArea(placesFile, cellsFile) {
    const g = cellsFile.grid;
    const Grid = {
      minLat: g.minLat,
      minLon: g.minLon,
      latStep: g.latStep,
      lonStep: g.lonStep,
      rows: g.rows,
      columns: g.columns,
      cellHeight: g.latStep * 110540,
      cellWidth: g.lonStep * Math.cos(22.35 * Math.PI / 180) * 111320,

      id(coordinate) {
        const row = Math.floor((coordinate.lat - g.minLat) / g.latStep);
        const col = Math.floor((coordinate.lon - g.minLon) / g.lonStep);
        if (row < 0 || row >= g.rows || col < 0 || col >= g.columns) return null;
        return row * g.columns + col;
      },

      rowColumn(id) {
        return [Math.trunc(id / g.columns), id % g.columns];
      },

      center(id) {
        const [row, col] = this.rowColumn(id);
        return { lat: g.minLat + (row + 0.5) * g.latStep, lon: g.minLon + (col + 0.5) * g.lonStep };
      },

      corners(id, span = 1) {
        const [row, col] = this.rowColumn(id);
        const lat = g.minLat + row * g.latStep;
        const lon = g.minLon + col * g.lonStep;
        const height = g.latStep * span;
        const width = g.lonStep * span;
        return [{ lat, lon }, { lat, lon: lon + width }, { lat: lat + height, lon: lon + width }, { lat: lat + height, lon }];
      },
    };

    const raster = cellsFile.cells.map((row) => ({
      id: Math.trunc(row[0]), residents: row[1], office: row[2], shops: row[3], district: Math.trunc(row[4]),
    }));

    const weighted = placesFile.districts.map(() => ({ lat: 0, lon: 0, weight: 0 }));
    for (const cell of raster) {
      if (!(cell.residents > 0)) continue;
      const center = Grid.center(cell.id);
      const w = weighted[cell.district];
      w.lat += center.lat * cell.residents;
      w.lon += center.lon * cell.residents;
      w.weight += cell.residents;
    }
    const AREA_CENTER = { lat: 22.365, lon: 114.125 };
    const districts = placesFile.districts.map((record, index) => {
      const w = weighted[index];
      return {
        index, key: record.key, name: record.name, nameZH: record.nameZH, population: record.population,
        aliases: DISTRICT_ALIASES[record.key] || [],
        center: w.weight > 0 ? { lat: w.lat / w.weight, lon: w.lon / w.weight } : AREA_CENTER,
        title: `${record.name} District`,
      };
    });

    function places(kind) {
      const out = [];
      for (const record of placesFile.places) {
        if (record.kind !== kind) continue;
        let aliases = (record.aliases || []).slice();
        if (kind === "university") {
          const hit = UNIVERSITY_ALIASES.find(([match]) => record.name.startsWith(match));
          if (hit) aliases = aliases.concat(hit[1]);
        }
        out.push({
          id: record.id, name: record.name, nameZH: record.nameZH, kind,
          coordinate: { lat: record.lat, lon: record.lon }, detail: record.detail, aliases,
          confirmedDaysAgo: record.confirmedDaysAgo, district: record.district, source: record.source || "OpenStreetMap",
        });
      }
      return out;
    }

    /** Office pins: the densest office blocks, at least 1.2 km apart, named by their MTR station. */
    function officeClusters() {
      const stations = places("mtr");
      const picked = [];
      const dense = raster.filter((cell) => cell.office >= 150).sort((a, b) => b.office - a.office);
      for (const cell of dense) {
        if (picked.length >= 30) break;
        const center = Grid.center(cell.id);
        if (picked.every((other) => Geo.meters(Grid.center(other.id), center) >= 1200)) picked.push(cell);
      }
      return picked.map((cell) => {
        const center = Grid.center(cell.id);
        const hit = nearest(stations, center);
        const station = hit ? hit.place : null;
        const near = station ? station.name.split(" station").join("") : "Hong Kong";
        const nearZH = station ? Array.from(station.nameZH).slice(0, -1).join("") : "香港";
        return {
          id: `office-${cell.id}`, name: `${near} office cluster`, nameZH: `${nearZH}商業區`, kind: "office",
          coordinate: center, detail: "Office and commercial buildings (OpenStreetMap)", aliases: [],
          confirmedDaysAgo: 30, district: cell.district, source: "OpenStreetMap",
        };
      });
    }

    const base = Object.freeze({
      stores: places("cdcStore"), universities: places("university"), schools: places("school"),
      offices: officeClusters(), stations: places("mtr"), rivals: places("rival"),
    });

    const area = {
      name: "Hong Kong", center: AREA_CENTER, Grid, raster, districts, base,
      totalPopulation: districts.reduce((sum, d) => sum + d.population, 0),
      residentsByID: new Map(raster.map((cell) => [cell.id, cell.residents])),
      referenceScale: null,
    };
    // Inputs are scaled against the original data, not the edited data, so an approved edit
    // (a rival closing, say) only changes the blocks around it.
    area.baseRawCells = rawCells(area, base);
    area.referenceScale = referenceScale(area.baseRawCells);
    return area;
  }

  // MARK: The map database (AreaDataset)

  function allPlaces(data) {
    return [].concat(data.stores, data.universities, data.offices, data.stations, data.schools, data.rivals);
  }

  const LIST_FOR_KIND = {
    cdcStore: "stores", university: "universities", school: "schools", office: "offices", mtr: "stations", rival: "rivals",
  };

  /** Applies approved edits in order. Each list is copied, so the base data never changes. */
  function applyEdits(base, edits) {
    const data = {};
    for (const key of Object.values(LIST_FOR_KIND)) data[key] = base[key].map((place) => place);
    for (const edit of edits) {
      switch (edit.type) {
        case "removePlace":
          // Keep at least one store, so "sales taken from the nearest CDC" always has an answer.
          if (data.stores.length === 1 && data.stores[0].id === edit.id) break;
          for (const key of Object.values(LIST_FOR_KIND)) data[key] = data[key].filter((p) => p.id !== edit.id);
          break;
        case "addPlace": {
          const key = LIST_FOR_KIND[edit.place.kind];
          if (!data[key].some((p) => p.id === edit.place.id)) data[key].push(edit.place);
          break;
        }
        case "confirmPlace":
          for (const key of Object.values(LIST_FOR_KIND)) {
            data[key] = data[key].map((p) => (p.id === edit.id ? Object.assign({}, p, { confirmedDaysAgo: 0 }) : p));
          }
          break;
        default:
          break;
      }
    }
    return data;
  }

  function nearest(places, point) {
    let best = null;
    let bestDistance = Infinity;
    for (const place of places) {
      const distance = Geo.meters(point, place.coordinate);
      if (distance < bestDistance) {
        best = place;
        bestDistance = distance;
      }
    }
    return best ? { place: best, distance: bestDistance } : null;
  }

  // MARK: Inputs for every block (SiteEngine.rawCells)

  function falloff(distance, radius) {
    return Math.exp(-(distance * distance) / (radius * radius));
  }

  /** Places grouped by grid block, so each block only looks at its neighbours. */
  function placeBuckets(area, places) {
    const buckets = new Map();
    for (const place of places) {
      const id = area.Grid.id(place.coordinate);
      if (id === null) continue;
      if (!buckets.has(id)) buckets.set(id, []);
      buckets.get(id).push(place);
    }
    return function near(row, column, radius) {
      const found = [];
      const G = area.Grid;
      for (let r = Math.max(0, row - radius); r <= Math.min(G.rows - 1, row + radius); r++) {
        for (let c = Math.max(0, column - radius); c <= Math.min(G.columns - 1, column + radius); c++) {
          const list = buckets.get(r * G.columns + c);
          if (list) for (const place of list) found.push(place);
        }
      }
      return found;
    };
  }

  const NO_STORE = { id: "none", name: "No CDC store", nameZH: "", kind: "cdcStore", coordinate: { lat: 0, lon: 0 }, detail: "", aliases: [], confirmedDaysAgo: 7, district: 0, source: "OpenStreetMap" };

  function rawCells(area, data) {
    const G = area.Grid;
    const rasterByID = new Map(area.raster.map((cell) => [cell.id, cell]));
    const schools = placeBuckets(area, data.schools);
    const universities = placeBuckets(area, data.universities);
    const rivals = placeBuckets(area, data.rivals);
    const stations = placeBuckets(area, data.stations);

    return area.raster.map((cell) => {
      const [row, col] = G.rowColumn(cell.id);
      const center = G.center(cell.id);

      // Homes, offices and shops spread a little into neighbouring blocks.
      let residents = 0, office = 0, shops = 0, catchment = 0;
      for (let dr = -2; dr <= 2; dr++) {
        for (let dc = -2; dc <= 2; dc++) {
          const r = row + dr, c = col + dc;
          if (r < 0 || r >= G.rows || c < 0 || c >= G.columns) continue;
          const other = rasterByID.get(r * G.columns + c);
          if (!other) continue;
          const distance = Math.hypot(dr * G.cellHeight, dc * G.cellWidth);
          residents += other.residents * falloff(distance, 350);
          office += other.office * falloff(distance, 420);
          shops += other.shops * falloff(distance, 380);
          if (distance <= 420) catchment += other.residents;
        }
      }

      function sum(near, radius, reach, weight = 1) {
        let total = 0;
        for (const place of near(row, col, reach)) total += weight * falloff(Geo.meters(center, place.coordinate), radius);
        return total;
      }

      const hit = nearest(data.stores, center);
      const storeDistance = hit ? hit.distance : Infinity;
      // Homes only count as unserved demand when there's no CDC within easy walking distance.
      const unserved = 1 - Math.exp(-storeDistance / 380);

      return {
        id: cell.id, center,
        features: {
          appOrders: residents * unserved,
          schools: sum(schools, 420, 4) + sum(universities, 480, 4, 1.8),
          offices: office,
          rivals: sum(rivals, 260, 3),
          footfall: sum(stations, 300, 3),
          rent: shops,
        },
        nearestStore: hit ? hit.place : NO_STORE, storeDistance, district: cell.district, catchment,
      };
    });
  }

  /** Where each input reaches 1.0, as a percentile of the original data. */
  const SCALE_PERCENTILE = { appOrders: 0.995, schools: 0.99, offices: 0.99, rivals: 0.99, footfall: 0.97, rent: 0.99 };

  function referenceScale(cells) {
    const scale = {};
    for (const f of FEATURES) {
      const values = [];
      for (const cell of cells) if (cell.features[f] > 0) values.push(cell.features[f]);
      if (values.length === 0) continue;
      values.sort((a, b) => a - b);
      scale[f] = values[Math.min(values.length - 1, Math.trunc(values.length * SCALE_PERCENTILE[f]))];
    }
    return scale;
  }

  // MARK: The engine (SiteEngine)

  const MINIMUM_DRAWN_SCORE = 22;
  const MINIMUM_STORE_GAP = 320;
  const MINIMUM_SPOT_SPACING = 650;
  const SHORTLIST_COUNT = 10;
  /** Keeps the shortlist spread across Hong Kong instead of piling into one district. */
  const MAX_SPOTS_PER_DISTRICT = 2;
  const SENSITIVE_SPREAD = 0.12;

  function orders(score, features) {
    const total = 0.0565 * Math.pow(score, 1.6);
    const f = (feature) => features[feature] || 0;
    const lunch = 0.30 + 0.55 * f("offices") + 0.20 * f("footfall");
    const afterSchool = 0.12 + 0.75 * f("schools");
    const evening = 0.25 + 0.40 * f("appOrders") + 0.25 * f("footfall");
    const share = lunch + afterSchool + evening;
    return { lunch: total * lunch / share, afterSchool: total * afterSchool / share, evening: total * evening / share };
  }

  function format(block) {
    const n = netOrders(block);
    return n < 95 ? "locker" : n < 170 ? "kiosk" : "store";
  }

  class SiteEngine {
    constructor(area, data) {
      this.area = area;
      this.data = data;
      const scale = area.referenceScale;
      const raw = data === area.base ? area.baseRawCells : rawCells(area, data);
      this.cells = raw.map((cell) => {
        const scaled = {};
        for (const f of FEATURES) {
          const top = scale[f] || 0;
          scaled[f] = top > 0 ? Math.min(1, cell.features[f] / top) : 0;
        }
        return Object.assign({}, cell, { features: scaled });
      });
      this.indexByID = new Map(this.cells.map((cell, index) => [cell.id, index]));
      const mapped = area.districts.map(() => 0);
      for (const store of data.stores) if (store.district >= 0 && store.district < mapped.length) mapped[store.district] += 1;
      this.mappedStores = mapped;
      this.expectedStores = area.districts.map((d) => ESTIMATED_STORE_TOTAL * d.population / area.totalPopulation);
    }

    get blockCount() {
      return this.cells.length;
    }

    blocks(weights) {
      return this.cells.map((cell) => this.makeBlock(cell, weights));
    }

    /** One block, without scoring the whole grid. Used for sensitivity checks and pilots. */
    block(id, weights) {
      const index = this.indexByID.get(id);
      if (index === undefined) throw new Error(`No block ${id} in the dataset`);
      return this.makeBlock(this.cells[index], weights);
    }

    makeBlock(cell, weights) {
      let positiveTotal = 0;
      for (const f of FEATURES) if (!FEATURE[f].penalty) positiveTotal += weights[f] || 0;
      const scale = Math.max(positiveTotal, 0.01) * 0.62;
      let raw = 0;
      for (const f of FEATURES) {
        const value = (weights[f] || 0) * (cell.features[f] || 0);
        raw += FEATURE[f].penalty ? -value : value;
      }
      // Soft ceiling: strong blocks approach 100 without piling up at it.
      const exactScore = 100 * (1 - Math.exp(-1.9 * Math.max(0, raw / scale)));
      const cannibalisation = Number.isFinite(cell.storeDistance) ? 0.32 * Math.exp(-cell.storeDistance / 360) : 0;
      return {
        id: cell.id, center: cell.center, features: cell.features, nearestStore: cell.nearestStore,
        storeDistance: cell.storeDistance, district: cell.district, catchment: cell.catchment,
        score: round(exactScore), orders: orders(exactScore, cell.features), cannibalisation,
      };
    }

    /** Share of a district's likely CDC stores that are on the map (capped at 1). */
    coverage(district) {
      if (!(this.expectedStores[district] > 0)) return 1;
      return Math.min(1, this.mappedStores[district] / this.expectedStores[district]);
    }

    coverageNote(district) {
      if (this.coverage(district) >= 0.6) return null;
      const name = this.area.districts[district].name;
      return `Only ${this.mappedStores[district]} of about ${round(this.expectedStores[district])} CDC stores in ${name} are mapped, so check for a nearby branch before deciding.`;
    }

    confidence(block, weights, evidence) {
      const base = netOrders(block);
      const values = [base];
      let sensitiveTo = "appOrders";
      let biggestSwing = -1;
      for (const f of FEATURES) {
        let swing = 0;
        for (const factor of [0.7, 1.3]) {
          const nudged = Weights.copy(weights);
          nudged[f] *= factor;
          const value = netOrders(this.block(block.id, nudged));
          values.push(value);
          swing = Math.max(swing, Math.abs(value - base));
        }
        if (swing > biggestSwing) {
          biggestSwing = swing;
          sensitiveTo = f;
        }
      }
      const spread = (Math.max(...values) - Math.min(...values)) / Math.max(base, 1);
      // Before a pilot the model is an unvalidated guess, so it never claims High.
      const sensitive = spread >= SENSITIVE_SPREAD;
      let level = evidence ? (sensitive ? "medium" : "high") : (sensitive ? "low" : "medium");
      const note = evidence ? null : this.coverageNote(block.district);
      if (note && LEVEL[level].rank > 0) level = LEVELS[LEVEL[level].rank - 1];
      return {
        level, low: base * (1 - LEVEL[level].margin), high: base * (1 + LEVEL[level].margin),
        sensitiveTo, evidence: evidence || null, coverageNote: note,
      };
    }

    eligible(block, excluded) {
      return block.storeDistance >= MINIMUM_STORE_GAP && !excluded.has(block.id);
    }

    shortlist(blocks, weights, excluded = new Set(), count = SHORTLIST_COUNT) {
      const picked = [];
      const perDistrict = new Map();
      const candidates = blocks.filter((b) => this.eligible(b, excluded))
        .map((b) => ({ b, n: netOrders(b) }))
        .sort((x, y) => y.n - x.n);
      for (const { b } of candidates) {
        if (picked.length >= count) break;
        if ((perDistrict.get(b.district) || 0) >= MAX_SPOTS_PER_DISTRICT) continue;
        if (!picked.every((p) => Geo.meters(p.center, b.center) >= MINIMUM_SPOT_SPACING)) continue;
        picked.push(b);
        perDistrict.set(b.district, (perDistrict.get(b.district) || 0) + 1);
      }
      return picked.map((block, index) => {
        const kind = this.kind(block, weights);
        const letter = String.fromCharCode(65 + index);
        return {
          id: block.id, letter, rank: index + 1, block, kind, landmark: this.landmark(block, kind),
          format: format(block), title: `Spot ${letter} · ${SPOT_KIND[kind]}`,
        };
      });
    }

    /** The best block in each district, by new orders a day. */
    bestBlocks(blocks, excluded = new Set()) {
      const best = new Map();
      for (const block of blocks) {
        if (!this.eligible(block, excluded)) continue;
        const current = best.get(block.district);
        if (netOrders(block) > (current ? netOrders(current) : -1)) best.set(block.district, block);
      }
      return best;
    }

    /** Why a block that isn't shortlisted was left out. */
    exclusionReason(block, spots, excluded) {
      if (excluded.has(block.id)) return `Taken off the shortlist: ${excluded.get(block.id)}.`;
      if (block.storeDistance < MINIMUM_STORE_GAP) {
        return `Within ${MINIMUM_STORE_GAP} m of the ${block.nearestStore.name} CDC, which already serves it.`;
      }
      const near = spots.find((s) => Geo.meters(s.block.center, block.center) < MINIMUM_SPOT_SPACING);
      if (near) return `Too close to Spot ${near.letter}. Two sites this near would split the same customers.`;
      const sameDistrict = spots.filter((s) => s.block.district === block.district);
      const last = spots[spots.length - 1];
      if (sameDistrict.length >= MAX_SPOTS_PER_DISTRICT && netOrders(block) > (last ? netOrders(last.block) : 0)) {
        const weakest = sameDistrict[sameDistrict.length - 1];
        const letters = sameDistrict.map((s) => s.letter).join(" and ");
        return `Spots ${letters} already cover ${this.area.districts[block.district].name} (weakest: ~${round(netOrders(weakest.block))} a day). The shortlist keeps at most two per district so it spreads across Hong Kong.`;
      }
      return `Fewer expected new orders than the ${spots.length} shortlisted spots.`;
    }

    /** Named after the strongest local driver. */
    kind(block, weights) {
      const top = maxBy(["schools", "offices", "footfall"], (f) => contribution(block, f, weights));
      const strength = top ? (block.features[top] || 0) : 0;
      if (strength < 0.3) return "housingArea";
      if (top === "schools") {
        const university = nearest(this.data.universities, block.center);
        return (university ? university.distance : Infinity) < 550 ? "university" : "schoolCluster";
      }
      if (top === "offices") return "officeHub";
      if (top === "footfall") return "transitHub";
      return "housingArea";
    }

    landmark(block, kind) {
      const d = this.data;
      const pool = kind === "university" ? d.universities
        : kind === "schoolCluster" ? d.schools.concat(d.universities)
        : kind === "officeHub" ? d.offices : d.stations;
      const hit = nearest(pool, block.center);
      return hit ? hit.place : null;
    }

    /** Daily locker sales a pilot "observes": the hidden truth plus a small fixed wobble per block. */
    observedOrders(blockID, roundNumber) {
      const truth = this.block(blockID, Weights.hiddenTruth);
      const wobble = 1 + 0.05 * Math.sin(blockID * 12.9898 + roundNumber * 78.233);
      return netOrders(truth) * wobble;
    }

    /** Runs a 4-week locker pilot at the given spots, then nudges each weight towards whatever
     * explains the gap between predicted and actual sales. */
    runPilot(roundNumber, weights, tested) {
      const observed = tested.map((spot) => this.observedOrders(spot.block.id, roundNumber));
      const updated = Weights.copy(weights);
      const learningRate = 0.9;
      for (let i = 0; i < 4; i++) {
        const gradients = {};
        for (const f of FEATURES) gradients[f] = 0;
        tested.forEach((spot, index) => {
          const predicted = netOrders(this.block(spot.block.id, updated));
          const ratio = (observed[index] - predicted) / Math.max(predicted, 1);
          for (const f of FEATURES) gradients[f] += ratio * (spot.block.features[f] || 0);
        });
        for (const f of FEATURES) {
          const gradient = gradients[f] / Math.max(tested.length, 1);
          const step = FEATURE[f].penalty ? -gradient : gradient;
          updated[f] = Math.min(0.6, Math.max(0.02, updated[f] * Math.exp(learningRate * step)));
        }
        // Keep the total fixed so the weights read as shares and don't drift upwards together.
        const scale = Weights.total(weights) / Math.max(Weights.total(updated), 0.01);
        for (const f of FEATURES) updated[f] *= scale;
      }
      const results = tested.map((spot, index) => ({
        blockID: spot.block.id, letter: spot.letter, kind: spot.kind,
        predicted: netOrders(this.block(spot.block.id, weights)), actual: observed[index],
      }));
      const error = (r) => Math.abs(r.actual - r.predicted) / r.actual;
      const errorBefore = results.reduce((sum, r) => sum + error(r), 0) / Math.max(results.length, 1);
      let errorAfter = 0;
      tested.forEach((spot, index) => {
        errorAfter += Math.abs(observed[index] - netOrders(this.block(spot.block.id, updated))) / observed[index];
      });
      errorAfter /= Math.max(results.length, 1);
      return {
        round: { id: roundNumber, results, weightsBefore: Weights.copy(weights), weightsAfter: Weights.copy(updated), errorBefore, errorAfter },
        weights: updated,
      };
    }
  }

  // MARK: Directions (Wayfinding)

  const Wayfinding = {
    walkingSpeed: 80,
    detour: 1.3,

    walkMinutes(meters) {
      return Math.max(1, round(meters * this.detour / this.walkingSpeed));
    },

    compass(bearing) {
      const names = [["north", "北"], ["north-east", "東北"], ["east", "東"], ["south-east", "東南"],
        ["south", "南"], ["south-west", "西南"], ["west", "西"], ["north-west", "西北"]];
      const normalised = ((bearing % 360) + 360) % 360;
      const [english, chinese] = names[Math.trunc((normalised + 22.5) / 45) % 8];
      return { english, chinese };
    },

    describe(point, data) {
      const landmark = this.nearestLandmark(point, data);
      const hit = nearest(data.stations, point);
      if (!hit) {
        const english = landmark ? `Next to ${landmark.name}` : "No MTR station nearby";
        const chinese = landmark ? `近${landmark.nameZH}` : "附近沒有港鐵站";
        return { english, chinese, short: english, walkMinutes: null, station: null };
      }
      const station = hit.place;
      const minutes = this.walkMinutes(hit.distance);
      let english, chinese, short;
      if (hit.distance < 120) {
        english = `Right outside ${station.name}`;
        chinese = `${station.nameZH}出口附近`;
        short = `At ${station.name}`;
      } else {
        const direction = this.compass(Geo.bearing(station.coordinate, point));
        english = `${minutes} min walk ${direction.english} of ${station.name}`;
        chinese = `${station.nameZH}${direction.chinese}面步行約${minutes}分鐘`;
        short = `${minutes} min from ${station.name}`;
      }
      if (landmark) {
        english += `, next to ${landmark.name}`;
        chinese += `，近${landmark.nameZH}`;
      }
      return { english, chinese, short, walkMinutes: minutes, station };
    },

    /** The closest named landmark (campus, school or office) within a short walk. */
    nearestLandmark(point, data) {
      const hit = nearest(data.universities.concat(data.schools, data.offices), point);
      return hit && hit.distance < 300 ? hit.place : null;
    },
  };

  // MARK: Plain-language reasons (Explain)

  const Explain = {
    why(block, weights, data, rank) {
      const strong = ["appOrders", "schools", "offices", "footfall"]
        .filter((f) => (block.features[f] || 0) >= 0.35)
        .map((f) => ({ f, c: contribution(block, f, weights) }))
        .sort((a, b) => b.c - a.c)
        .slice(0, 2)
        .map((x) => x.f);
      const drag = maxBy(["rivals", "rent"].filter((f) => Math.abs(contribution(block, f, weights)) >= 0.025),
        (f) => Math.abs(contribution(block, f, weights)));
      if (strong.length === 0) return "Low demand here: none of the four demand inputs is strong.";
      const lead = rank != null ? `Ranked #${rank} because of ` : `Scores ${block.score} because of `;
      let sentence = lead + strong.map((f) => this.phrase(f, block, data)).join(" and ") + ".";
      if (drag) sentence += ` Held back by ${this.phrase(drag, block, data)}.`;
      return sentence;
    },

    phrase(feature, block, data) {
      switch (feature) {
        case "appOrders":
          return `about ${Geo.roughCount(block.catchment)} residents within a 5-minute walk and no CDC nearby`;
        case "schools": {
          const hit = nearest(data.universities.concat(data.schools), block.center);
          if (hit && hit.distance < 650) return `${hit.place.name} ${Geo.formatDistance(hit.distance)} away`;
          return "schools nearby";
        }
        case "offices": {
          const hit = nearest(data.offices, block.center);
          if (hit && hit.distance < 650) return `office workers at ${hit.place.name}`;
          return "office workers nearby";
        }
        case "footfall": {
          const hit = nearest(data.stations, block.center);
          return hit ? `foot traffic from ${hit.place.name}` : "busy streets";
        }
        case "rivals": {
          const count = data.rivals.filter((r) => Geo.meters(r.coordinate, block.center) < 350).length;
          return count === 0 ? "rivals nearby" : count === 1 ? "a rival within 350 m" : `${count} rivals within 350 m`;
        }
        default:
          return "high rents";
      }
    },

    /** Sentences comparing a spot with the top pick, for the compare view. */
    tradeOffs(spot, top) {
      const lines = [];
      const orderGap = round(netOrders(spot.block) - netOrders(top.block));
      if (orderGap !== 0) {
        lines.push(orderGap > 0 ? `${orderGap} more new orders a day than ${top.letter}.` : `${-orderGap} fewer new orders a day than ${top.letter}.`);
      }
      const cannibalGap = spot.block.cannibalisation - top.block.cannibalisation;
      if (Math.abs(cannibalGap) >= 0.02) {
        lines.push(cannibalGap > 0
          ? `Takes more sales from ${spot.block.nearestStore.name} (${this.percentText(spot.block.cannibalisation)}).`
          : `Takes fewer sales from existing stores (${this.percentText(spot.block.cannibalisation)} vs ${this.percentText(top.block.cannibalisation)}).`);
      }
      const gap = (f) => (spot.block.features[f] || 0) - (top.block.features[f] || 0);
      if (Math.abs(gap("rent")) >= 0.2) lines.push(gap("rent") > 0 ? `Higher rent than ${top.letter}.` : `Lower rent than ${top.letter}.`);
      if (Math.abs(gap("rivals")) >= 0.2) lines.push(gap("rivals") > 0 ? `More rivals nearby than ${top.letter}.` : `Fewer rivals nearby than ${top.letter}.`);
      if (Math.abs(gap("schools")) >= 0.25) lines.push(gap("schools") > 0 ? "More after-school demand." : "Less after-school demand.");
      if (Math.abs(gap("offices")) >= 0.25) lines.push(gap("offices") > 0 ? "Busier at lunch with office workers." : "Fewer office workers at lunch.");
      return lines.length ? lines : [`Close to ${top.letter} on every input.`];
    },

    percentText(value) {
      return `${round(value * 100)}%`;
    },

    /** "Very low" … "Very high", for the input bars and the compare table. */
    level(value) {
      return value < 0.15 ? "Very low" : value < 0.35 ? "Low" : value < 0.6 ? "Medium" : value < 0.8 ? "High" : "Very high";
    },
  };

  // MARK: Reports (ReportChecks)

  const REPORT_KIND = {
    closed: { title: "Closed permanently", icon: "octagon-x" },
    newRival: { title: "A new rival opened here", icon: "store" },
    newOffice: { title: "A new office building here", icon: "building-2" },
    noSpace: { title: "No space for a locker", icon: "square-slash" },
  };

  const ROLES = ["fieldScout", "storeStaff", "member"];
  const ROLE = {
    fieldScout: { title: "Field scout", trust: "High trust: checked on site", trustRank: 2 },
    storeStaff: { title: "Store staff", trust: "Medium trust: works nearby", trustRank: 1 },
    member: { title: "Club 100 member", trust: "Low trust: customer feedback", trustRank: 0 },
  };

  const VERDICT = {
    agrees: "Check agrees",
    disagrees: "Check disagrees",
    unsure: "Check unsure",
  };

  /** `hashValue` changes between launches in Swift; this doesn't (64-bit wrapping, like Swift's &* and &+). */
  function hashValueStable(text) {
    let h = 5381n;
    for (const ch of text) h = BigInt.asIntN(64, h * 33n + BigInt(ch.codePointAt(0)));
    return h;
  }

  const ReportChecks = {
    options(target) {
      return target.type === "place" ? ["closed"] : ["newRival", "newOffice", "noSpace"];
    },

    /** Compares a new report with what the data already says. */
    check(kind, target, data, block) {
      if (kind === "closed" && target.type === "place") {
        const place = allPlaces(data).find((p) => p.id === target.id);
        if (!place) return { verdict: "agrees", detail: "Already removed from the map." };
        switch (place.kind) {
          case "cdcStore": {
            const h = hashValueStable(target.id);
            const magnitude = h < 0n ? -h : h;
            const meals = 1800 + Number(magnitude % 900n);
            return { verdict: "disagrees", detail: `This store sold about ${formatted(meals)} meals last week. A permanent closure would come from Operations, not a report.` };
          }
          case "rival":
            if (isStale(place)) {
              return { verdict: "agrees", detail: `Nobody has checked it on OpenStreetMap for ${Freshness.duration(place.confirmedDaysAgo)}, so a closure is plausible.` };
            }
            return { verdict: "disagrees", detail: `Listings confirmed it open ${Freshness.describe(place.confirmedDaysAgo)}.` };
          case "school":
          case "university":
            return { verdict: "disagrees", detail: "Still on the Education Bureau school list." };
          case "mtr":
            return { verdict: "disagrees", detail: "MTR still lists this station as open." };
          default:
            return { verdict: "unsure", detail: `Office data was last refreshed ${Freshness.describe(place.confirmedDaysAgo)}.` };
        }
      }
      if (kind === "newRival" && target.type === "block") {
        const b = block(target.id);
        const rivals = b ? (b.features.rivals || 0) : 0;
        return rivals < 0.2
          ? { verdict: "unsure", detail: "No rival is listed within 250 m yet. The next weekly listings refresh will confirm it." }
          : { verdict: "agrees", detail: "Listings already show rivals close by, so one more fits the pattern." };
      }
      if (kind === "newOffice" && target.type === "block") {
        return { verdict: "unsure", detail: "Office data refreshes monthly, so this isn't confirmed yet." };
      }
      if (kind === "noSpace" && target.type === "block") {
        const b = block(target.id);
        const rent = b ? (b.features.rent || 0) : 0;
        return rent > 0.45
          ? { verdict: "agrees", detail: "Few vacant ground-floor units are listed in this high-rent block." }
          : { verdict: "unsure", detail: `${2 + target.id % 4} vacant units are listed nearby. Worth a second look.` };
      }
      return { verdict: "unsure", detail: "No automated check for this kind of report." };
    },

    /** The map change an approved report makes. */
    edit(report, blockCenter) {
      const t = report.target;
      const role = ROLE[report.role].title.toLowerCase();
      if (report.kind === "closed" && t.type === "place") return { type: "removePlace", id: t.id };
      if (report.kind === "newRival" && t.type === "block") {
        if (!blockCenter) return null;
        return { type: "addPlace", place: { id: `reported-rival-${t.id}`, name: "New rival (reported)", nameZH: "新對手", kind: "rival", coordinate: blockCenter, detail: `Reported by ${role}`, aliases: [], confirmedDaysAgo: 0, district: 0, source: "OpenStreetMap" } };
      }
      if (report.kind === "newOffice" && t.type === "block") {
        if (!blockCenter) return null;
        return { type: "addPlace", place: { id: `reported-office-${t.id}`, name: "New office building (reported)", nameZH: "新寫字樓", kind: "office", coordinate: blockCenter, detail: `Reported by ${role}`, aliases: [], confirmedDaysAgo: 0, district: 0, source: "OpenStreetMap" } };
      }
      if (report.kind === "noSpace" && t.type === "block") {
        return { type: "excludeBlock", id: t.id, reason: `no space for a locker (${role} report)` };
      }
      return null;
    },

    /** Reports waiting in the queue on first launch, so the review flow has something to show. */
    seeds(area, data, block, spots, now, newID) {
      const daysAgo = (days) => new Date(now.getTime() - days * 86400000).toISOString();
      const make = (target, kind, role, note, age) => ({
        id: newID(), target, kind, role, note, created: daysAgo(age),
        check: this.check(kind, target, data, block), status: "pending", reviewed: null,
      });
      const seeds = [];
      // The rival nobody has checked for longest: store staff say it's gone.
      const oldest = maxBy(data.rivals, (r) => r.confirmedDaysAgo);
      if (oldest) seeds.push(make({ type: "place", id: oldest.id }, "closed", "storeStaff", "Shutters down for weeks and a 'for lease' sign is up.", 2));
      // A customer says a busy CDC is closed: the automated check should disagree.
      if (data.stores.some((s) => s.id === "argyle")) {
        seeds.push(make({ type: "place", id: "argyle" }, "closed", "member", "It was closed when I went at lunch??", 1));
      }
      const id = area.Grid.id({ lat: 22.3290, lon: 114.1655 });
      if (id !== null && block(id)) {
        seeds.push(make({ type: "block", id }, "newRival", "storeStaff", "A new mainland noodle chain opened across the road.", 3));
      }
      // A field scout checked one of the shortlisted spots and found no room for a locker.
      if (spots.length >= 5) {
        seeds.push(make({ type: "block", id: spots[4].id }, "noSpace", "fieldScout", "Walked the block: no vacant ground-floor units, and the mall won't take a locker.", 4));
      }
      return seeds;
    },
  };

  // MARK: Search (SearchIndex)

  const LAYERS = ["demand", "stores", "schools", "offices", "mtr", "rivals"];
  const LAYER = {
    demand: { title: "Demand", icon: "grid-3x3", kinds: [] },
    stores: { title: "CDC stores", icon: "utensils", kinds: ["cdcStore"] },
    schools: { title: "Schools", icon: "graduation-cap", kinds: ["school", "university"] },
    offices: { title: "Offices", icon: "building-2", kinds: ["office"] },
    mtr: { title: "MTR", icon: "tram-front", kinds: ["mtr"] },
    rivals: { title: "Rivals", icon: "store", kinds: ["rival"] },
  };

  function layerFor(kind) {
    return LAYERS.find((layer) => LAYER[layer].kinds.includes(kind)) || "stores";
  }

  const Search = {
    normalise(text) {
      return text.toLowerCase().normalize("NFD").replace(/\p{M}/gu, "").normalize("NFC")
        .split(/\s+/u).filter(Boolean).join(" ");
    },

    tokens(text) {
      return text.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
    },

    /** Lower is better: whole-string prefix, then every word matched by prefix, then substring,
     * then every word matched with one typo. */
    matchRank(query, text) {
      const q = this.normalise(query);
      const t = this.normalise(text);
      if (!q) return null;
      if (t.startsWith(q)) return 0;
      const queryTokens = this.tokens(q);
      const words = this.tokens(t);
      if (queryTokens.length === 0) return t.includes(q) ? 2 : null;
      if (queryTokens.every((token) => words.some((w) => w.startsWith(token)))) return 1;
      // "mongkok" for "Mong Kok": two whole words written together count as a word match.
      const compact = queryTokens.join("");
      const compactLength = Array.from(compact).length;
      const pairs = [];
      for (let i = 0; i < words.length - 1; i++) pairs.push(words[i] + words[i + 1]);
      if (compactLength >= 4 && pairs.includes(compact)) return 1;
      if (t.includes(q)) return 2;
      // A whole word plus the start of the next one ranks lower, so "hkust" finds HKUST rather than "HKU station".
      if (compactLength >= 4 && pairs.some((pair) => pair.startsWith(compact))) return 2;
      if (queryTokens.some((token) => Array.from(token).length >= 4)
        && queryTokens.every((token) => words.some((w) => this.fuzzyPrefix(token, w)))) return 3;
      return null;
    },

    /** True if `token` starts `word`, allowing one typo (two for long words). */
    fuzzyPrefix(token, word) {
      if (word.startsWith(token)) return true;
      const t = Array.from(token);
      const w = Array.from(word);
      if (t.length < 4) return false;
      const allowed = t.length >= 8 ? 2 : 1;
      for (const length of [t.length - 1, t.length, t.length + 1]) {
        if (length > 0 && length <= w.length && this.editDistance(t, w.slice(0, length)) <= allowed) return true;
      }
      return false;
    },

    editDistance(a, b) {
      if (a.length === 0) return b.length;
      if (b.length === 0) return a.length;
      let previous = Array.from({ length: b.length + 1 }, (_, i) => i);
      for (let i = 1; i <= a.length; i++) {
        const current = [i].concat(new Array(b.length).fill(0));
        for (let j = 1; j <= b.length; j++) {
          current[j] = Math.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
        }
        previous = current;
      }
      return previous[b.length];
    },

    entries(area, spots, data) {
      const placeEntry = (place) => {
        const title = place.kind === "cdcStore" ? `Café de Coral · ${place.name}` : place.name;
        const result = {
          id: place.id, title, subtitle: `${place.nameZH} · ${KIND[place.kind].title}`,
          icon: LAYER[layerFor(place.kind)].icon, target: { type: "route", route: { type: "place", id: place.id } },
          coordinate: place.coordinate,
        };
        const extra = place.kind === "cdcStore" ? ["cdc", "大家樂", "cafe de coral"] : [];
        return { result, text: [title, result.subtitle, place.detail].concat(place.aliases, extra).join(" ") };
      };
      // Order breaks ties between equally good matches: spots, then stations, then districts, then the rest.
      let entries = spots.map((spot) => {
        const result = {
          id: `spot-${spot.id}`, title: spot.title,
          subtitle: `Score ${spot.block.score} · ~${round(netOrders(spot.block))} orders a day`,
          icon: "star", target: { type: "route", route: { type: "spot", id: spot.id } }, coordinate: spot.block.center,
        };
        return { result, text: `${result.title} spot ${spot.letter}` };
      });
      entries = entries.concat(data.stations.map(placeEntry));
      entries = entries.concat(area.districts.map((district) => {
        const result = {
          id: `district-${district.key}`, title: district.title,
          subtitle: `${district.nameZH} · ${formatted(district.population)} people`,
          icon: "map-pin", target: { type: "area", coordinate: district.center }, coordinate: district.center,
        };
        return { result, text: [district.title, district.nameZH].concat(district.aliases).join(" ") };
      }));
      entries = entries.concat([].concat(data.stores, data.universities, data.offices, data.rivals, data.schools).map(placeEntry));
      return entries;
    },

    results(query, area, spots, data, limit = 8, entries = null) {
      const normalisedQuery = this.normalise(query);
      if (!normalisedQuery) return [];
      const list = entries || this.entries(area, spots, data);
      const scored = [];
      list.forEach((entry, index) => {
        const rank = this.matchRank(normalisedQuery, entry.text);
        if (rank !== null) scored.push([entry.result, rank, index]);
      });
      scored.sort((a, b) => (a[1] - b[1]) || (a[2] - b[2]));
      return scored.slice(0, limit).map((x) => x[0]);
    },
  };

  /** Real queries the team would type, with what the first result should be. */
  const SearchBenchmark = {
    cases: [
      ["mong kok", "Mong Kok", "station name"],
      ["mongkok", "Mong Kok", "written together"],
      ["旺角", "Mong Kok", "Chinese name"],
      ["kowlon tong", "Kowloon Tong", "typo"],
      ["tsuen wann", "Tsuen Wan", "typo"],
      ["tai po", "Tai Po", "district or station"],
      ["tko", "Sai Kung", "neighbourhood abbreviation"],
      ["將軍澳", "Tseung Kwan O", "Chinese name"],
      ["tin shui wai", "Tin Shui Wai", "neighbourhood"],
      ["tung chung", "Tung Chung", "neighbourhood"],
      ["cityu", "City University", "abbreviation"],
      ["城大", "City University", "Cantonese short name"],
      ["polyu", "Polytechnic", "abbreviation"],
      ["hkust", "Science and Technology", "abbreviation"],
      ["中大", "Chinese University", "Cantonese short name"],
      ["open university", "Metropolitan", "old name"],
      ["大家樂", "Café de Coral", "brand in Chinese"],
      ["nathan road", "Café de Coral", "store address"],
      ["fairwood", "Fairwood", "rival brand"],
      ["麥當勞", "McDonald's", "rival in Chinese"],
    ].map(([query, expected, note]) => ({ query, expected, note })),

    run(area, spots, data) {
      const all = this.cases.slice();
      if (spots.length) all.push({ query: "spot a", expected: spots[0].title, note: "shortlist letter" });
      const entries = Search.entries(area, spots, data);
      const failures = [];
      const rows = all.map((c) => {
        const first = Search.results(c.query, area, spots, data, 1, entries)[0];
        const passed = !!first && first.title.includes(c.expected);
        if (!passed) failures.push(`"${c.query}" (${c.note}) → ${first ? first.title : "no result"}`);
        return { testCase: c, first, passed };
      });
      return { passed: all.length - failures.length, total: all.length, failures, rows, rate: all.length ? (all.length - failures.length) / all.length : 0 };
    },
  };

  // MARK: Pin collisions (PinLayout)

  const PinLayout = {
    spacing: 30,
    spotFootprint: { width: 86, height: 44 },

    /** Shows pins in priority order and hides any that would overlap one already placed. */
    visible(candidates, reserved, bounds, alwaysShow = new Set(), spacing = 30) {
      const placed = reserved.slice();
      const visible = new Set();
      let hidden = 0;
      for (const c of candidates) {
        if (alwaysShow.has(c.id)) {
          visible.add(c.id);
          placed.push(c.point);
        }
      }
      const ordered = candidates.filter((c) => !alwaysShow.has(c.id))
        .sort((a, b) => (KIND[a.kind].priority - KIND[b.kind].priority) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
      for (const c of ordered) {
        const inside = c.point.x >= bounds.x && c.point.x <= bounds.x + bounds.width && c.point.y >= bounds.y && c.point.y <= bounds.y + bounds.height;
        if (!inside) {
          visible.add(c.id);
          continue;
        }
        if (placed.every((p) => Math.hypot(p.x - c.point.x, p.y - c.point.y) >= spacing)) {
          visible.add(c.id);
          placed.push(c.point);
        } else {
          hidden += 1;
        }
      }
      return { visible, hiddenOnScreen: hidden };
    },

    /** Spot pins that would overlap fold into the best-ranked one, which then shows "+N". */
    groupSpots(spots, keep = null) {
      const leaders = [];
      const counts = new Map();
      const ordered = spots.filter((s) => s.id === keep).concat(spots.filter((s) => s.id !== keep));
      for (const spot of ordered) {
        const leader = leaders.find((l) => Math.abs(l.point.x - spot.point.x) < this.spotFootprint.width
          && Math.abs(l.point.y - spot.point.y) < this.spotFootprint.height);
        if (leader) counts.set(leader.id, counts.get(leader.id) + 1);
        else {
          leaders.push(spot);
          counts.set(spot.id, 0);
        }
      }
      return counts;
    },
  };

  root.SF = {
    round, formatted, Geo, Freshness, isStale, PLACE_KINDS, KIND, FEATURES, FEATURE, Weights, netOrders, contribution,
    ordersTotal, SPOT_KIND, FORMAT, LEVEL, rangeText, confidenceReason, loadArea, allPlaces, applyEdits, nearest,
    SiteEngine, Wayfinding, Explain, REPORT_KIND, ROLES, ROLE, VERDICT, ReportChecks, LAYERS, LAYER, layerFor,
    Search, SearchBenchmark, PinLayout, ESTIMATED_STORE_TOTAL, MINIMUM_DRAWN_SCORE, MINIMUM_STORE_GAP,
    MINIMUM_SPOT_SPACING, SHORTLIST_COUNT, MAX_SPOTS_PER_DISTRICT,
  };
})(typeof globalThis !== "undefined" ? globalThis : this);
