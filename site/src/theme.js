// The width ramp.
//
// Darker is narrower, against a light basemap: the darkest line has the most
// contrast with the ground, so salience follows the subject. (The reverse of
// what a dark basemap wants, which is why this changed with the basemap.)
// Single hue, monotonic in lightness, so the order reads without the legend.
export const BINS = [
  { max: 14, color: "#08304a", label: "≤ 14" },
  { max: 16, color: "#0d4f70", label: "15–16" },
  { max: 18, color: "#146f93", label: "17–18" },
  { max: 20, color: "#2e90ad", label: "19–20" },
  { max: 22, color: "#62aec4", label: "21–22" },
  { max: 24, color: "#97cbd9", label: "23–24" },
  // Reachable only through the narrowest-point test: a block that drops to the
  // threshold somewhere but widens past the top of the scale elsewhere.
  { max: Infinity, color: "#c3e0e8", label: "> 24" },
];

export const BOUNDARY = "#9aa4a8";
export const EXCLUDED = "#b45309";
export const PINCH = "#7e22ce";

export const binFor = (w) => BINS.find((b) => w <= b.max) ?? BINS.at(-1);

// MapLibre `step` expression over the same bins, so the line colour cannot
// drift from the legend beside it.
export function widthColourExpression(property = "bm") {
  const steps = ["step", ["get", property], BINS[0].color];
  for (let i = 0; i < BINS.length - 1; i++) steps.push(BINS[i].max + 1, BINS[i + 1].color);
  return steps;
}
