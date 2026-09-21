// The width ramp and the few colours the map draws with.
//
// Lightness rises as the street narrows, so salience follows the subject
// rather than fighting it, and every step clears 3.3:1 on the canvas ground.
// The bins are the legend, the histogram and the line colour all at once, so
// they live here rather than being restated in each.
export const BINS = [
  { max: 14, color: "#d0f4f2", label: "≤ 14" },
  { max: 16, color: "#97e4e6", label: "15–16" },
  { max: 18, color: "#68cfd6", label: "17–18" },
  { max: 20, color: "#4cb0ba", label: "19–20" },
  { max: 22, color: "#3e8f99", label: "21–22" },
  { max: 24, color: "#33707a", label: "23–24" },
  // Reachable only through the narrowest-point test: a block that drops to the
  // threshold somewhere but widens past the top of the scale elsewhere.
  { max: Infinity, color: "#27545c", label: "> 24" },
];

export const CANVAS = "#0b1418";
export const BORDER = "#35505a";
export const EXCLUDED = "#e0a340";
// Narrowings are a third kind of thing - a point, not a width and not an
// exclusion state - so they get a hue outside both existing scales.
export const PINCH = "#c9a7f5";

export const binFor = (w) => BINS.find((b) => w <= b.max) ?? BINS.at(-1);

// MapLibre `step` expression over the same bins, so the line colour cannot
// drift from the legend beside it.
export function widthColourExpression(property = "bm") {
  const steps = ["step", ["get", property], BINS[0].color];
  for (const bin of BINS.slice(0, -1)) steps.push(bin.max + 1, nextColour(bin));
  return steps;
}

function nextColour(bin) {
  return BINS[BINS.indexOf(bin) + 1].color;
}
