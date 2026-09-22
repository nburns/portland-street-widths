const $ = (id) => document.getElementById(id);
const fmt1 = (n) =>
  n.toLocaleString(undefined, { minimumFractionDigits: 1, maximumFractionDigits: 1 });
const esc = (s) =>
  String(s).replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]);

// The denominator is counted off the blocks actually shipped, not read from
// totals.json: totals counts only blocks with a PBOT pavement record, and the
// map also carries the ones measured from curb lines. Quoting the smaller
// figure under the larger map is how a page starts lying quietly.
export function renderSummary(stats, totals, universe) {
  let miles = 0, blocks = 0;
  for (const s of stats) { miles += s.miles; blocks += s.blocks; }

  $("heroMiles").textContent = fmt1(miles);
  $("heroSub").textContent =
    `${blocks.toLocaleString()} blocks of ${universe.blocks.toLocaleString()} eligible ` +
    `(${fmt1(universe.miles)} miles two-way, residential and not arterial)`;

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
    [
      "Narrowest point",
      `${block.wn} ft` + (block.nsrc === "curb" ? " *" : ""),
    ],
    ["Widest point", `${block.wx} ft`],
    ["Block length", `${block.bl.toLocaleString()} ft`],
    [
      "Edge line needed",
      block.sh <= 0 ? "none" : `${block.sh} ft each side`,
    ],
    ["Width from", block.src === "pms" ? "PBOT pavement record" : "curb lines (no PBOT record)"],
  ];
  // The asterisk earns an explanation rather than sitting there as decoration.
  const footnote =
    block.nsrc === "curb" && block.src === "pms"
      ? '<p class="hint">* narrowest point measured from the curb lines; ' +
        "PBOT's pavement record does not go below " +
        `${block.wx} ft on this block.</p>`
      : "";
  if (block.rw != null) rows.push(["Right of way", `${block.rw.toFixed(0)} ft`]);

  el.innerHTML =
    `<p class="readout-name">${esc(block.street)}</p>` +
    "<dl>" +
    rows.map((r) => `<dt>${r[0]}</dt><dd>${r[1]}</dd>`).join("") +
    "</dl>" +
    footnote;
}

export function renderControls(state) {
  $("thr").value = String(state.val);
  $("thrVal").textContent = String(state.val);
  $("op").value = state.op;
  $(state.reading === "part" ? "readPart" : "readWhole").checked = true;

  // Above 18 ft the widest-point reading stops being a question about what
  // qualifies and becomes one about what an edge line would reach, so the hint
  // says which question is on screen.
  const shoulder = Math.max(0, (state.val - 18) / 2);
  $("thrHint").innerHTML =
    state.reading === "part"
      ? `The block drops to ${state.val} ft or less somewhere along it.`
      : state.val <= 18
        ? `The block is never wider than ${state.val} ft.`
        : `The block never exceeds ${state.val} ft, so an edge line of ` +
          `<strong>${shoulder.toFixed(1).replace(/\.0$/, "")} ft each side</strong> ` +
          "would bring its travel way to 18.";
}

export function renderNotes(totals) {
  $("noteNarrowings").textContent = totals.narrowings.toLocaleString();
  $("noteNarrowings18").textContent = totals.narrowings_under_18.toLocaleString();
  $("noteUntestable").textContent =
    `${totals.untestable_blocks.toLocaleString()} blocks — ` +
    `${fmt1(totals.untestable_miles)} miles — have no PBOT pavement width at all`;
}

// Derived figures the prose quotes, computed from the blocks actually shipped
// rather than restated by hand, so the sentence cannot drift from the map.
export function renderDerivedNotes(blocks) {
  const miles = (pred) =>
    fmt1(blocks.filter(pred).reduce((a, b) => a + b.bl, 0) / 5280);
  $("noteSomewhere").textContent = miles((b) => b.wn <= 18);
  $("noteConvertible").textContent = miles((b) => b.wx <= 24);
  $("noteEligible").textContent = miles(() => true);
  $("noteStrict").textContent = miles((b) => b.wx <= 18);
  const curbWon = blocks.filter((b) => b.wn <= 18 && b.nsrc === "curb");
  $("noteCurbWon").textContent = curbWon.length.toLocaleString();
  $("noteCurbWonMiles").textContent =
    fmt1(curbWon.reduce((a, b) => a + b.bl, 0) / 5280);
}

