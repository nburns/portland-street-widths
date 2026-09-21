import { BINS } from "./theme.js";

// The GeoJSON is one feature per centerline segment, because that is what has
// geometry. Every quantity the panel reports is per block, though, and a block
// averages 1.14 segments - so summing feature lengths would count most blocks
// twice. This collapses to one record per block_id first.
export function indexBlocks(featureCollection) {
  const byId = new Map();
  for (const f of featureCollection.features) {
    const p = f.properties;
    if (!byId.has(p.block_id)) {
      byId.set(p.block_id, {
        id: p.block_id,
        street: p.street,
        wx: p.wx,
        wn: p.wn,
        bl: p.bl,
        nseg: p.nseg,
        rw: p.rw,
        src: p.src,
        sh: p.sh,
        nrr: p.nrr,
      });
    } else if (p.rw != null) {
      // right of way is per segment; the block's widest is the useful one
      const b = byId.get(p.block_id);
      b.rw = b.rw == null ? p.rw : Math.max(b.rw, p.rw);
    }
  }
  return [...byId.values()];
}

// One reading at a time, because the two are alternative constructions of the
// same sentence rather than conditions that stack. `reading` picks which end
// of the block's width profile the threshold applies to: wn is its narrowest
// point, wx its widest.
//
//   somewhere, at most X    wn <= X   18 ft or less at some point
//   never wider, at most X  wx <= X   18 ft or less at every point
//
// Widths are PaveWidth where PBOT records one and curb-measured where it does
// not, which is why `src` travels with the block: the two are not the same
// kind of evidence and the readout says which it is.
export const passes = (b, st) => {
  const w = st.reading === "part" ? b.wn : b.wx;
  return st.op === "le" ? w <= st.val : w >= st.val;
};

// Counted over the blocks currently drawn rather than over the whole dataset,
// because with two independent tests no bin is wholly in or out: a 23-24 ft
// bin can hold blocks that pass on their minimum and blocks that do not. The
// panel therefore always reports what is on screen. `total` is the unfiltered
// figure, kept so the bars can scale against something that does not move as
// the sliders are dragged.
export function binStats(blocks, state) {
  return BINS.map((bin, i) => {
    const lo = i === 0 ? 0 : BINS[i - 1].max;
    let miles = 0, count = 0, total = 0;
    for (const b of blocks) {
      if (b.wn <= lo || b.wn > bin.max) continue;
      total += b.bl / 5280;
      if (passes(b, state)) { miles += b.bl / 5280; count++; }
    }
    return { bin, miles, blocks: count, total, active: count > 0 };
  });
}
