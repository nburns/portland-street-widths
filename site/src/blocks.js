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
        bm: p.bm,
        bn: p.bn,
        bl: p.bl,
        nseg: p.nseg,
        rw: p.rw,
      });
    } else if (p.rw != null) {
      // right of way is per segment; the block's widest is the useful one
      const b = byId.get(p.block_id);
      b.rw = b.rw == null ? p.rw : Math.max(b.rw, p.rw);
    }
  }
  return [...byId.values()];
}

// Each control owns one end of the block's width profile, in either
// direction: bm is the widest point, bn the narrowest.
//
//   whole block at most X    bm <= X   never wider than X - the statute
//   whole block at least X   bm >= X   gets at least this wide somewhere
//   narrow part at most X    bn <= X   drops to X somewhere
//   narrow part at least X   bn >= X   never narrower than X
//
// Fixing one statistic per control is what keeps every pair meaningful. An
// earlier version read "whole block at least X" as a universal (bn >= X),
// which made the most useful query - wider than 18 overall, narrowed to 18
// somewhere - a contradiction that always returned nothing.
export const passes = (b, st) =>
  (!st.wholeOn || (st.wholeOp === "le" ? b.bm <= st.wholeVal : b.bm >= st.wholeVal)) &&
  (!st.partOn || (st.partOp === "le" ? b.bn <= st.partVal : b.bn >= st.partVal));

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
      if (b.bm <= lo || b.bm > bin.max) continue;
      total += b.bl / 5280;
      if (passes(b, state)) { miles += b.bl / 5280; count++; }
    }
    return { bin, miles, blocks: count, total, active: count > 0 };
  });
}
