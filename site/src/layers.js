import { BOUNDARY, PINCH, widthColourExpression } from "./theme.js";

export const SRC = { blocks: "blocks", narrowings: "narrowings", boundary: "boundary" };
export const LYR = {
  boundary: "boundary-line",
  blocks: "blocks-line",
  hover: "blocks-hover",
  narrowings: "narrowings-point",
};

// Line weight has to survive a 6-level zoom range without becoming either a
// hairline or a ribbon, hence the interpolation rather than a constant.
// Weighted for the zoom the page opens at. A block is a few hundred feet, so
// at city scale it is a tick a few pixels long: at the old weight 1,475 of
// them rendered and the map still read as empty.
const lineWidth = (base) => [
  "interpolate", ["linear"], ["zoom"],
  9, base * 1.1,
  13, base * 1.7,
  17, base * 4.5,
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

  map.addLayer({
    id: LYR.blocks,
    type: "line",
    source: SRC.blocks,
    filter: ["==", ["get", "block_id"], -1],
    layout: { "line-cap": "round", "line-join": "round" },
    paint: { "line-color": widthColourExpression("wn"), "line-width": lineWidth(2.1) },
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

// The same predicate as blocks.js `passes`, expressed for MapLibre.
export function blockFilter(st) {
  const prop = st.reading === "part" ? "wn" : "wx";
  return st.op === "le"
    ? ["<=", ["get", prop], st.val]
    : [">=", ["get", prop], st.val];
}
