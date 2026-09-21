const $ = (id) => document.getElementById(id);
const fmt1 = (n) =>
  n.toLocaleString(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const esc = (s) =>
  String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);

export function renderSummary(stats, totals) {
  let miles = 0, blocks = 0;
  for (const s of stats) { miles += s.miles; blocks += s.blocks; }

  $("heroMiles").textContent = fmt1(miles);
  $("heroSub").textContent =
    `${blocks.toLocaleString()} blocks, ` +
    `${((miles / totals.testable_miles) * 100).toFixed(1)}% of ` +
    `${fmt1(totals.testable_miles)} testable miles`;

  // One table instead of a legend and a histogram: they were the same numbers
  // twice, and the swatch carries the ramp without a second chart.
  $("legend").querySelector("tbody").innerHTML = stats
    .map(
      (s) =>
        `<tr aria-pressed="${s.active}" data-w="${Number.isFinite(s.bin.max) ? s.bin.max : 24}">` +
        `<td><span class="swatch" style="background:${s.bin.color}"></span>` +
        `${s.bin.label} ft</td>` +
        `<td>${fmt1(s.miles)}</td></tr>`
    )
    .join("");
}

export function onBinClick(handler) {
  $("legend").addEventListener("click", (e) => {
    const row = e.target.closest("tr[data-w]");
    if (row) handler(+row.dataset.w);
  });
}

export function renderReadout({ block, narrowing }) {
  const el = $("readout");

  if (narrowing) {
    const p = narrowing;
    el.innerHTML =
      `<p class="readout-name">${esc(p.street)} — narrowing</p>` +
      "<dl>" +
      `<dt>Narrowest</dt><dd>${p.w} ft</dd>` +
      `<dt>Street elsewhere</dt><dd>${p.s} ft</dd>` +
      `<dt>Narrower by</dt><dd>${p.d} ft</dd>` +
      `<dt>Runs for</dt><dd>${p.l} ft</dd>` +
      "</dl>";
    return;
  }

  if (!block) {
    el.innerHTML = '<p class="hint">Point at a highlighted block.</p>';
    return;
  }

  const rows = [
    ["Widest point", `${block.bm} ft`],
    ["Narrowest point", `${block.bn} ft`],
    ["Block length", `${block.bl.toLocaleString()} ft`],
    ["Segments", String(block.nseg)],
  ];
  if (block.rw != null) rows.push(["Right of way", `${block.rw.toFixed(0)} ft`]);

  el.innerHTML =
    `<p class="readout-name">${esc(block.street)}</p>` +
    "<dl>" +
    rows.map((r) => `<dt>${r[0]}</dt><dd>${r[1]}</dd>`).join("") +
    "</dl>";
}

export function renderControls(state) {
  $("thrMax").value = String(state.maxThr);
  $("maxVal").textContent = String(state.maxThr);
  $("thrMin").value = String(state.minThr);
  $("minVal").textContent = String(state.minThr);
  $("useMax").checked = state.useMax;
  $("useMin").checked = state.useMin;
}

export function renderNotes(totals) {
  $("noteNarrowings").textContent = totals.narrowings.toLocaleString();
  $("noteNarrowings18").textContent = totals.narrowings_under_18.toLocaleString();
  $("noteUntestable").textContent =
    `${totals.untestable_blocks.toLocaleString()} blocks — ` +
    `${fmt1(totals.untestable_miles)} miles — cannot be tested at all`;
}
