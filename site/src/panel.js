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
    `${blocks.toLocaleString()} blocks · ` +
    `${((miles / totals.testable_miles) * 100).toFixed(1)}% of ` +
    `${fmt1(totals.testable_miles)} testable miles`;

  $("legend").innerHTML = stats
    .map(
      (s) =>
        `<div class="legend-row" style="opacity:${s.active ? 1 : 0.34}">` +
        `<span class="swatch" style="background:${s.bin.color}"></span>` +
        `<span>${s.bin.label} ft</span>` +
        `<span class="legend-num">${fmt1(s.miles)} mi</span></div>`
    )
    .join("");

  // Bars scale against the unfiltered distribution so they stop rescaling as
  // the sliders move, but report the passing miles.
  const peak = Math.max(...stats.map((s) => s.total), 1);
  $("bars").innerHTML = stats
    .map(
      (s) =>
        `<button class="bar-row" type="button" aria-pressed="${s.active}" ` +
        `data-w="${Number.isFinite(s.bin.max) ? s.bin.max : 24}">` +
        `<span class="bar-label">${s.bin.label}</span>` +
        `<span class="bar-track"><span class="bar-fill" style="width:` +
        `${((s.miles / peak) * 100).toFixed(1)}%;background:${s.bin.color}"></span></span>` +
        `<span class="bar-num">${fmt1(s.miles)}</span></button>`
    )
    .join("");
}

export function onBarClick(handler) {
  $("bars").addEventListener("click", (e) => {
    const el = e.target.closest(".bar-row");
    if (el) handler(+el.dataset.w);
  });
}

export function renderReadout({ block, narrowing }) {
  const el = $("readout");

  if (narrowing) {
    const p = narrowing;
    el.innerHTML =
      '<p class="eyebrow">Narrowing</p>' +
      `<p class="readout-name">${esc(p.street)}</p>` +
      '<dl class="readout-grid">' +
      `<dt>Narrowest</dt><dd>${p.w} ft</dd>` +
      `<dt>Street elsewhere</dt><dd>${p.s} ft</dd>` +
      `<dt>Narrower by</dt><dd>${p.d} ft</dd>` +
      `<dt>Runs for</dt><dd>${p.l} ft</dd>` +
      "</dl>";
    return;
  }

  if (!block) {
    el.innerHTML =
      '<p class="eyebrow">Block detail</p>' +
      '<p class="readout-empty">Point at a highlighted block.</p>';
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
    '<p class="eyebrow">Block detail</p>' +
    `<p class="readout-name">${esc(block.street)}</p>` +
    '<dl class="readout-grid">' +
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
  $("grpMax").classList.toggle("thr-off", !state.useMax);
  $("grpMin").classList.toggle("thr-off", !state.useMin);
}

export function renderNotes(totals) {
  $("noteNarrowings").textContent = totals.narrowings.toLocaleString();
  $("noteNarrowings18").textContent = totals.narrowings_under_18.toLocaleString();
  $("noteUntestable").textContent =
    `${totals.untestable_blocks.toLocaleString()} blocks — ` +
    `${fmt1(totals.untestable_miles)} miles — cannot be tested at all`;
}
