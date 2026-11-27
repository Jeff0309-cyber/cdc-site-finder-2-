// Prints the website engine's answers as JSON, in the same shape as swift_dump.swift.
// Run with macOS's built-in JavaScript engine (see README.md in this folder):
//   jsc tools/web_parity/js_dump.js -- docs/js/engine.js docs/data
/* global read, load, print, arguments */
const [enginePath, dataDir] = arguments;
load(enginePath);
const SF = globalThis.SF;
const area = SF.loadArea(JSON.parse(read(`${dataDir}/hk_places.json`)), JSON.parse(read(`${dataDir}/hk_cells.json`)));
const data = area.base;
const engine = new SF.SiteEngine(area, data);
const w = SF.Weights.starting;
const blocks = engine.blocks(w);
const spots = engine.shortlist(blocks, w);
const r6 = (x) => SF.round(x * 1e6) / 1e6;
const net = SF.netOrders;

const out = {};
out.blockCount = blocks.length;
out.drawn = blocks.filter((b) => b.score >= SF.MINIMUM_DRAWN_SCORE).length;
out.scoreSum = blocks.reduce((s, b) => s + b.score, 0);
out.netSum = r6(blocks.reduce((s, b) => s + net(b), 0) / 1000);
out.offices = data.offices.slice(0, 5).map((p) => p.name);
out.officeCount = data.offices.length;
out.districtCenters = area.districts.slice(0, 4).map((d) => [r6(d.center.lat), r6(d.center.lon)]);

out.spots = spots.map((spot) => {
  const b = spot.block;
  const c = engine.confidence(b, w, null);
  const d = SF.Wayfinding.describe(b.center, data);
  return {
    letter: spot.letter, id: b.id, score: b.score, net: r6(net(b)), kind: SF.SPOT_KIND[spot.kind],
    format: SF.FORMAT[spot.format].title, level: SF.LEVEL[c.level].title, range: SF.rangeText(c), sensitiveTo: c.sensitiveTo,
    coverageNote: c.coverageNote || "", english: d.english, chinese: d.chinese, short: d.short,
    why: SF.Explain.why(b, w, data, spot.rank), landmark: spot.landmark ? spot.landmark.name : "",
    store: b.nearestStore.name, storeDistance: SF.Geo.formatDistance(b.storeDistance),
    lunch: r6(b.orders.lunch), afterSchool: r6(b.orders.afterSchool), evening: r6(b.orders.evening),
  };
});

const best = engine.bestBlocks(blocks);
out.districtBest = area.districts.map((d) => {
  const b = best.get(d.index);
  return b ? [d.name, b.id, r6(net(b))] : [d.name, -1, 0];
});
out.mappedStores = engine.mappedStores;

const blockByID = new Map(blocks.map((b) => [b.id, b]));
const eleventh = blocks.filter((b) => b.storeDistance >= SF.MINIMUM_STORE_GAP).sort((a, b) => net(b) - net(a))[10];
const nearStore = blocks.find((b) => b.storeDistance < 200 && b.score > 40);
out.exclusion = [eleventh, nearStore].map((b) => engine.exclusionReason(b, spots, new Map()));
out.blockWhy = [eleventh, nearStore].map((b) => SF.Explain.why(b, w, data, null));
out.tradeOffs = spots.slice(1, 3).map((s) => SF.Explain.tradeOffs(s, spots[0]));

const pilot = engine.runPilot(1, w, spots.slice(0, 3));
const weightsAfter = {};
for (const f of SF.FEATURES) weightsAfter[f] = r6(pilot.weights[f]);
out.pilot = {
  errorBefore: r6(pilot.round.errorBefore), errorAfter: r6(pilot.round.errorAfter), weightsAfter,
  results: pilot.round.results.map((r) => [r.letter, r6(r.predicted), r6(r.actual)]),
};
const afterBlocks = engine.blocks(pilot.weights);
out.afterPilotSpots = engine.shortlist(afterBlocks, pilot.weights).map((s) => [s.letter, s.id, r6(net(s.block))]);

const bench = SF.SearchBenchmark.run(area, spots, data);
const entries = SF.Search.entries(area, spots, data);
out.search = {
  passed: bench.passed, total: bench.total,
  first: SF.SearchBenchmark.cases.map((c) => SF.Search.results(c.query, area, spots, data, 3, entries).map((r) => r.title)),
};

const seeds = SF.ReportChecks.seeds(area, data, (id) => blockByID.get(id), spots, new Date(), () => "x");
out.seeds = seeds.map((r) => [r.kind, r.role, `${r.target.type}:${r.target.id}`, r.check.verdict, r.check.detail]);

let oldest = null;
for (const r of data.rivals) if (!oldest || r.confirmedDaysAgo > oldest.confirmedDaysAgo) oldest = r;
const edited = new SF.SiteEngine(area, SF.applyEdits(data, [{ type: "removePlace", id: oldest.id }]));
const editedBlocks = edited.blocks(w);
out.afterClosure = edited.shortlist(editedBlocks, w).map((s) => [s.letter, s.id, r6(net(s.block))]);
out.afterClosureNetSum = r6(editedBlocks.reduce((s, b) => s + net(b), 0) / 1000);

print(JSON.stringify(out));
