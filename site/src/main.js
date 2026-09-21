import maplibregl from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import "./style.css";

import { registerPmtilesProtocol, basemapAvailable, baseStyle } from "./basemap.js";
import { addDataLayers, blockFilter, LYR } from "./layers.js";
import { indexBlocks, binStats, passes } from "./blocks.js";
import { renderSummary, renderReadout, renderControls, renderNotes,
         renderDerivedNotes, onBinClick } from "./panel.js";

const PORTLAND = { center: [-122.658, 45.522], zoom: 10.6 };

const state = {
  // Defaults to "narrow somewhere", which is how ORS 801.368's "not more than
  // 18 feet wide at any point" is read here. The stricter "never wider"
  // construction is one radio button away.
  reading: "part", op: "le", val: 18,
  showPinch: false,
  showBasemap: true,
};

let blockById = new Map();
let blocks = [];
let totals = null;
let hoverBlock = null;
let hoverNarrowing = null;
let map = null;
let universe = { blocks: 0, miles: 0 };

// A failed data fetch must not render as an empty map, which would read as
// "no narrow streets in Portland" rather than as a broken page.
async function fetchJson(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${url}: ${res.status} ${res.statusText}`);
  return res.json();
}

function fatal(err) {
  console.error(err);
  document.getElementById("map").innerHTML =
    `<p class="load-error">Could not load the map data.<br><code>${
      String(err.message ?? err).replace(/[<>&]/g, "")
    }</code></p>`;
}

init().catch(fatal);

async function init() {
  registerPmtilesProtocol();

  const [blocksGeojson, totalsJson, basemapOk] = await Promise.all([
    fetchJson("./data/blocks.geojson"),
    fetchJson("./data/totals.json"),
    basemapAvailable(),
  ]);

  blocks = indexBlocks(blocksGeojson);
  blockById = new Map(blocks.map((b) => [b.id, b]));
  universe = { blocks: blocks.length, miles: blocks.reduce((a, b) => a + b.bl, 0) / 5280 };
  totals = totalsJson;

  if (!basemapOk) {
    state.showBasemap = false;
    const box = document.getElementById("togBasemap");
    box.checked = false;
    box.disabled = true;
    box.closest("label").title = "No basemap.pmtiles found \u2014 run `make basemap`";
  }

  renderNotes(totals);
  renderDerivedNotes(blocks);

  map = new maplibregl.Map({
    container: "map",
    style: baseStyle(state.showBasemap),
    ...PORTLAND,
    attributionControl: { compact: true },
    dragRotate: false,
    maxZoom: 19,
  });
  if (import.meta.env.DEV) window.__map = map;
  map.addControl(new maplibregl.NavigationControl({ showCompass: false }), "top-right");
  map.addControl(new maplibregl.ScaleControl({ unit: "imperial" }), "bottom-right");
  map.touchZoomRotate.disableRotation();

  // Surfaced rather than swallowed: a tile or sprite that fails to load is
  // worth seeing in the console, and must not be mistaken for "no data".
  map.on("error", (e) => console.error("maplibre:", e.error ?? e));

  // Wrapped because a throw in here is otherwise invisible: MapLibre swallows
  // handler exceptions, leaving a drawn basemap with an empty control panel
  // and nothing in the console to say why.
  map.on("load", () => {
    try {
      addDataLayers(map, blocksGeojson);
      refresh();
      wireEvents(blocksGeojson);
    } catch (err) {
      fatal(err);
    }
  });
}

// The basemap is a whole different style, so toggling it means rebuilding the
// style and re-adding the data layers on top - hence going back through load.
function setBasemap(on, blocksGeojson) {
  state.showBasemap = on;
  map.setStyle(baseStyle(on));
  map.once("styledata", () => {
    addDataLayers(map, blocksGeojson);
    applyFilters();
  });
}

function applyFilters() {
  if (!map.getLayer(LYR.blocks)) return;
  map.setFilter(LYR.blocks, blockFilter(state));
  map.setLayoutProperty(LYR.narrowings, "visibility", state.showPinch ? "visible" : "none");
  map.setFilter(
    LYR.hover,
    hoverBlock == null ? ["==", ["get", "block_id"], -1] : ["==", ["get", "block_id"], hoverBlock.id]
  );
}

function refresh() {
  renderControls(state);
  if (hoverBlock && !passes(hoverBlock, state)) hoverBlock = null;
  renderReadout({ block: hoverBlock, narrowing: hoverNarrowing });
  renderSummary(binStats(blocks, state), totals, universe);
  applyFilters();
}

function wireEvents(blocksGeojson) {
  const on = (id, ev, fn) => document.getElementById(id).addEventListener(ev, fn);

  on("thr", "input", (e) => { state.val = +e.target.value; refresh(); });
  on("op", "change", (e) => { state.op = e.target.value; refresh(); });
  on("readPart", "change", () => { state.reading = "part"; refresh(); });
  on("readWhole", "change", () => { state.reading = "whole"; refresh(); });
  on("togPinch", "change", (e) => {
    state.showPinch = e.target.checked;
    if (!state.showPinch) hoverNarrowing = null;
    refresh();
  });
  on("togBasemap", "change", (e) => setBasemap(e.target.checked, blocksGeojson));

  // A legend row is a whole-block maximum, so it drives that control and says
  // so by switching it on rather than moving something invisible.
  onBinClick((v) => {
    state.op = "le";
    state.val = Math.min(40, v);
    refresh();
  });

  // A narrowing is the smaller target, so it wins over the block beneath it.
  map.on("mousemove", (e) => {
    const pt = [
      [e.point.x - 6, e.point.y - 6],
      [e.point.x + 6, e.point.y + 6],
    ];
    const near = state.showPinch
      ? map.queryRenderedFeatures(pt, { layers: [LYR.narrowings] })
      : [];
    const onBlock = near.length ? [] : map.queryRenderedFeatures(pt, { layers: [LYR.blocks] });

    const nextNarrowing = near.length ? near[0].properties : null;
    const nextBlock = onBlock.length
      ? blockById.get(onBlock[0].properties.block_id) ?? null
      : null;

    const changed =
      (nextNarrowing?.pid ?? null) !== (hoverNarrowing?.pid ?? null) ||
      (nextBlock?.id ?? null) !== (hoverBlock?.id ?? null);
    if (changed) {
      hoverNarrowing = nextNarrowing;
      hoverBlock = nextBlock;
      map.getCanvas().style.cursor = nextNarrowing || nextBlock ? "pointer" : "";
      renderReadout({ block: hoverBlock, narrowing: hoverNarrowing });
      applyFilters();
    }
  });

  map.on("mouseout", () => {
    if (hoverBlock || hoverNarrowing) {
      hoverBlock = null;
      hoverNarrowing = null;
      renderReadout({ block: null, narrowing: null });
      applyFilters();
    }
  });
}
