import maplibregl from "maplibre-gl";
import "maplibre-gl/dist/maplibre-gl.css";
import "./style.css";

import { registerPmtilesProtocol, basemapAvailable, baseStyle } from "./basemap.js";
import { addDataLayers, blockFilter, excludedFilter, LYR } from "./layers.js";
import { indexBlocks, binStats, passes } from "./blocks.js";
import { renderSummary, renderReadout, renderControls, renderNotes, onBinClick } from "./panel.js";

const PORTLAND = { center: [-122.658, 45.522], zoom: 10.6 };

const state = {
  maxThr: 18,
  minThr: 18,
  useMax: true,
  useMin: false,
  showExcluded: false,
  showPinch: false,
  showBasemap: true,
};

let blockById = new Map();
let blocks = [];
let totals = null;
let hoverBlock = null;
let hoverNarrowing = null;
let map = null;

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
  totals = totalsJson;

  if (!basemapOk) {
    state.showBasemap = false;
    const box = document.getElementById("togBasemap");
    box.checked = false;
    box.disabled = true;
    box.closest("label").title = "No basemap.pmtiles found \u2014 run `make basemap`";
  }

  renderNotes(totals);

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
  map.setFilter(LYR.excluded, excludedFilter(state));
  map.setLayoutProperty(
    LYR.excluded,
    "visibility",
    state.showExcluded && state.useMax ? "visible" : "none"
  );
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
  renderSummary(binStats(blocks, state), totals);
  applyFilters();
}

function wireEvents(blocksGeojson) {
  const on = (id, ev, fn) => document.getElementById(id).addEventListener(ev, fn);

  on("thrMax", "input", (e) => { state.maxThr = +e.target.value; state.useMax = true; refresh(); });
  on("thrMin", "input", (e) => { state.minThr = +e.target.value; state.useMin = true; refresh(); });
  on("useMax", "change", (e) => { state.useMax = e.target.checked; refresh(); });
  on("useMin", "change", (e) => { state.useMin = e.target.checked; refresh(); });
  on("togExcluded", "change", (e) => { state.showExcluded = e.target.checked; refresh(); });
  on("togPinch", "change", (e) => {
    state.showPinch = e.target.checked;
    if (!state.showPinch) hoverNarrowing = null;
    refresh();
  });
  on("togBasemap", "change", (e) => setBasemap(e.target.checked, blocksGeojson));

  // Clicking a legend row drives whichever test is active. With only the
  // narrowest-point test on it would otherwise silently move a control the
  // reader has switched off.
  onBinClick((v) => {
    if (state.useMax || !state.useMin) { state.useMax = true; state.maxThr = Math.min(24, v); }
    else state.minThr = Math.min(24, v);
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
