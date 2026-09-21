import { BOUNDARY, EXCLUDED, PINCH, widthColourExpression } from "./theme.js";

export const SRC = { blocks: "blocks", narrowings: "narrowings", boundary: "boundary" };
export const LYR = {
  boundary: "boundary-line",
  excluded: "blocks-excluded",
  blocks: "blocks-line",
  hover: "blocks-hover",
  narrowings: "narrowings-point",
};

// Line weight has to survive a 6-level zoom range without becoming either a
// hairline or a ribbon, hence the interpolation rather than a constant.
const lineWidth = (base) => [
  "interpolate", ["linear"], ["zoom"],
  10, base * 0.7,
  13, base,
  17, base * 3.2,
];

// blocksData is passed in rather than fetched by URL: main.js already has it
// parsed to build the per-block index, and fetching it twice would double the
// largest transfer on the page for nothing.
export function addDataLayers(map, blocksData) {
  map.addSource(SRC.blocks, { type: "geojson", data: blocksData });
  map.addSource(SRC.narrowings, { type: "geojson", data: "./data/narrowings.geojson" });
  map.addSource(SRC.boundary, { type: "geojson", data: "./data/boundary.geojson" });

  map.addLayer({
    id: LYR.boundary,
    type: "line",
    source: SRC.boundary,
    paint: { "line-color": BOUNDARY, "line-width": 1 },
  });

  // Segments narrow enough on their own, in blocks that widen somewhere else.
  // Only meaningful against the widest-point test - it is exactly what a
  // block-level maximum throws away - so main.js hides it when that test is off.
  map.addLayer({
    id: LYR.excluded,
    type: "line",
    source: SRC.blocks,
    filter: ["==", ["get", "block_id"], -1],
    paint: {
      "line-color": EXCLUDED,
      "line-width": lineWidth(1.6),
      "line-dasharray": [3, 2.2],
      "line-opacity": 0.85,
    },
  });

  map.addLayer({
    id: LYR.blocks,
    type: "line",
    source: SRC.blocks,
    filter: ["==", ["get", "block_id"], -1],
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": widthColourExpression("bm"), "line-width": lineWidth(2.1) },
  });

  // A separate layer rather than a paint change on the one above: the whole
  // block highlights, not just the segment the pointer is over, and a filter
  // is the only way to say that without touching every feature's state.
  map.addLayer({
    id: LYR.hover,
    type: "line",
    source: SRC.blocks,
    filter: ["==", ["get", "block_id"], -1],
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": "#1b1b1b", "line-width": lineWidth(4.6), "line-opacity": 0.9 },
  });

  // Drawn as a line over the street it narrows, because that is its actual
  // shape. It sits above the width ramp so a narrowing on a drawn block reads
  // as emphasis on that block rather than as a separate object, and it still
  // shows on streets the width filter excludes - a narrowing on a 30 ft street
  // is exactly the interesting case.
  map.addLayer({
    id: LYR.narrowings,
    type: "line",
    source: SRC.narrowings,
    layout: { visibility: "none", "line-cap": "round" },
    paint: {
      "line-color": PINCH,
      "line-width": lineWidth(3.4),
      "line-opacity": 0.85,
    },
  });
}

// The same predicate as blocks.js `passes`, expressed for MapLibre. Kept in
// step with it by construction: both read the same four cases off bm and bn.
export function blockFilter(st) {
  const clauses = ["all"];
  if (st.wholeOn)
    clauses.push(st.wholeOp === "le"
      ? ["<=", ["get", "bm"], st.wholeVal]
      : [">=", ["get", "bm"], st.wholeVal]);
  if (st.partOn)
    clauses.push(st.partOp === "le"
      ? ["<=", ["get", "bn"], st.partVal]
      : [">=", ["get", "bn"], st.partVal]);
  return clauses.length === 1 ? ["literal", true] : clauses;
}

// Segments narrow enough on their own, in blocks that widen somewhere else -
// only meaningful against a whole-block-at-most test, which is what it is the
// complement of. main.js hides it otherwise.
export function excludedFilter(st) {
  return ["all", [">", ["get", "bm"], st.wholeVal], ["<=", ["get", "sm"], st.wholeVal]];
}
