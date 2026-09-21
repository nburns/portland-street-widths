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

  map.addLayer({
    id: LYR.narrowings,
    type: "circle",
    source: SRC.narrowings,
    layout: { visibility: "none" },
    paint: {
      // radius carries how much narrower, which is the quantity that says
      // whether a narrowing is a planter or a rounding error
      "circle-radius": [
        "interpolate", ["linear"], ["zoom"],
        10, ["interpolate", ["linear"], ["get", "d"], 3, 1.8, 30, 4.5],
        16, ["interpolate", ["linear"], ["get", "d"], 3, 5, 30, 13],
      ],
      "circle-color": PINCH,
      "circle-opacity": 0.9,
      "circle-stroke-color": "#1b1b1b",
      "circle-stroke-width": ["case", ["boolean", ["feature-state", "hover"], false], 1.6, 0],
    },
  });
}

// The two competing readings of "not more than 18 feet wide at any point".
// Widest-at-most is a block that is never wider than T; narrowest-at-most is a
// block that drops to T somewhere. Independent tests, so a block draws when
// every enabled one passes, and with both off everything in the source draws.
export function blockFilter({ useMax, maxThr, useMin, minThr }) {
  const clauses = ["all"];
  if (useMax) clauses.push(["<=", ["get", "bm"], maxThr]);
  if (useMin) clauses.push(["<=", ["get", "bn"], minThr]);
  return clauses.length === 1 ? ["literal", true] : clauses;
}

export function excludedFilter({ maxThr }) {
  return ["all", [">", ["get", "bm"], maxThr], ["<=", ["get", "sm"], maxThr]];
}
