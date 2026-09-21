# Portland right-of-way widths

The platted right-of-way width — the corridor between property lines — for every
street segment in Portland, Oregon, in a local DuckDB database.

No Portland or Metro dataset publishes this. It is derived here by measuring the
gap between the taxlots on either side of each street centerline. Curb-to-curb
width comes along from PBOT's pavement records, because it is the thing that
makes a ROW figure interpretable: ROW minus roadway is the sidewalk, planting
strip and setback space.

39,103 street segments, defined as those whose midpoint falls inside the
Portland city boundary. The taxlot download reaches past the city line so that
streets *on* the boundary still have lots on both sides to measure against, but
nothing outside Portland is exported.

## Run it

```sh
git clone <remote> street-widths && cd street-widths
./setup.sh
open out/map.html
```

`setup.sh` checks for the tools it needs, downloads the source data, verifies
it, and builds everything. It is safe to re-run; every stage skips work already
done. Needs `duckdb`, `curl`, `make` and Python 3 (stdlib only - nothing to pip
install).

Budget about 20 minutes on a first run, nearly all of it download. The 863 MB
of source GeoJSON is not in the repo. Once it is local, the pipeline - load,
456k transect measurements, join, validate, export - runs in about 80 seconds.

To drive the stages yourself:

```sh
make fetch      # download only
make verify     # check data/raw/ against the published fetch
make            # load -> measure -> validate -> export
make map        # rebuild out/map.html
make shell      # interactive DuckDB on the result
```

`make` is incremental: each SQL stage re-runs only when its script or its input
changed. `make clean-db` drops the database and `out/`, keeping the downloads.
`make clean` also deletes `data/raw/`, which means a full re-download.

## The site

`site/` is a Vite build of the map on MapLibre GL JS, published to GitHub Pages
by `.github/workflows/pages.yml` on every push that touches it.

```sh
make site-data     # regenerate site/public/data/*.geojson from the database
make basemap       # 19 MB Portland slice of the Protomaps planet build
make site-dev      # vite dev server
make site          # production build into site/dist
```

**The data is committed; the basemap is not.** CI cannot rebuild the DuckDB
pipeline — that wants 863 MB of source data and twenty minutes — so the four
GeoJSON files the page reads are in the tree (1.5 MB) and the workflow only
runs `npm ci && vite build`. Regenerate them with `make site-data` whenever a
pipeline stage changes, and commit the result.

The basemap is a single PMTiles archive read with HTTP range requests: no tile
server, no API key, no vendor account, which is the only arrangement in which
"static site" and "basemap" are both true. `site/scripts/basemap.sh` extracts
the Portland bounding box from the Protomaps daily planet build; CI runs the
same script and caches the result by month, because Protomaps keeps only about
two weeks of builds and a pinned date would fail silently later.

**The site degrades rather than breaks when the basemap is missing**, drawing
on a flat ground with the city boundary for orientation, and the toggle
disables itself. It detects the archive by its `PMTiles` magic bytes rather
than by HTTP status, because a static host serving an SPA fallback answers a
missing file with `200 text/html` — and MapLibre then stalls forever trying to
parse HTML as tiles, which presents as an empty page rather than as an error.

`viz/` still builds the older single-file canvas map (`make map`), which inlines
all of its data into one self-contained HTML file. The two now draw the same
thing from the same database; see the note at the end of this README.

## What is in the repo

The pipeline (`fetch/`, `sql/`, `viz/`, `Makefile`) and the finished exports in
`out/`. You can use the results without running anything.

Not in the repo, because it is ~1.5 GB that git would keep forever:

- `data/raw/` - the upstream GeoJSON. `./setup.sh` downloads it.
- `data/street_widths.duckdb` - a 640 MB intermediate rebuilt in 80 seconds.

What is versioned instead is `fetch/expected.json`: the size and SHA-256 of all
195 source files as they were when these results were produced. `make verify`
checks a fresh download against it, so "am I looking at the same data the
README describes?" has an answer without storing a gigabyte to get it.

Expect that check to report changes eventually. The city's ArcGIS exports are
not byte-stable, and the layers themselves are revised. A mismatch means the
numbers here may no longer reproduce exactly - it does not mean the download
failed. `python3 fetch/verify.py --write` adopts the current download as the
new baseline.

`out/map.html` is self-contained - all data is inlined, and the only external
reference is Google Fonts. Drop it on any static host, or open it from disk.

## What it found

| | segments | miles |
|---|---|---|
| ROW measured on both sides | 32,575 (83%) | 2,154 |
| of those, high or medium confidence | 23,661 (61%) | 1,428 |
| one-sided estimate only | 1,686 (4%) | 101 |
| no measurement possible | 4,842 (12%) | 326 |

Coverage is near-total on streets that have a platted right of way at all:
**97.1% of local streets** (`type_code` 1500, 1,521 miles) and 93.6% of the next
class down. What is left out is mostly things with no ROW to find — private
roads and driveways measure at ~6%, freeway corridors at 34-54%.

**Median right of way: 60 ft. Median roadway: 30 ft. Median left over: 24 ft.**
Those come from the 20,227 high-confidence segments covering 1,197 miles. 24 ft
is two 6 ft sidewalks and two 6 ft planting strips — the standard Portland
residential cross-section, recovered from the data rather than assumed.

The width distribution lands where Portland's plats say it should: 60 ft on
11,974 segments (754 miles), 50 ft on 7,665 (555 miles), then 80 ft and 40 ft.
Among high-confidence segments the modal widths are 60 ft (9,286), 50 ft (4,916),
80 ft (865) and 40 ft (715) — round platted numbers, not a smear.

**The centerline is not reliably centred in the right of way.** 54.5% of
segments sit within 1 ft of centre, but 12.7% are off by more than 10 ft. That
is why `row_left_ft` and `row_right_ft` are exported separately; for anything
frontage- or setback-related the two halves matter more than the total.

## Output

`out/portland_row_confident.csv` — 23,638 segments, high and medium confidence
only, transect reach not clipped. **Use this for aggregate claims.**

`out/portland_street_widths.{geojson,gpkg,csv,parquet}` — all 39,103 segments
with every column and flag. `out/portland_street_summary.csv` — per street name.
`out/validation.txt` — the full report described below.

ROW columns:

| column | meaning |
|---|---|
| `row_width_ft` | median of the per-transect widths. The headline number. |
| `row_width_mode_ft` | mode of the per-transect widths rounded to the foot |
| `row_width_spread_ft` | max minus min across transects — the confidence signal |
| `row_width_any_ft` | best effort including one-sided estimates; equals `row_width_ft` wherever both edges were found |
| `row_left_ft`, `row_right_ft` | centerline to each ROW edge |
| `row_offcenter_ft` | `row_right_ft - row_left_ft` |
| `row_confidence` | `high` (≥5 transects, spread ≤1 ft) / `medium` (≥3, ≤5 ft) / `low` / `estimated` / `none` |
| `row_n_transects`, `row_n_measured` | how many transects were cast, and how many produced a width |
| `row_flag_at_transect_cap` | an edge was only found at the 250 ft reach limit, so the width is a lower bound |
| `row_flag_centerline_in_taxlot`, `row_flag_missing_lots` | why some transects failed |

**`row_width_ft` vs `row_width_mode_ft`.** On regular residential blocks they
agree. On arterials they diverge, and the mode is usually the platted figure:
NE 82nd Ave comes out at a 132 ft length-weighted mean but an 80 ft mode,
because segments abutting large setback commercial parcels pull the mean up.
Prefer the mode when you want the plat, the median when you want the actual
distance to the nearest private property.

Roadway columns: `road_width_ft` (curb-to-curb, length-weighted across the
segment's pavement sections), `pave_width_ft`, `lanes`, `has_curb`,
`surface_type`, `pci`, `functional_class`, and `non_roadway_ft` =
`row_width_ft - road_width_ft`.

Geometry in the GeoJSON/GPKG exports is EPSG:4326. Widths are in feet, the unit
PBOT records them in. Internally everything is EPSG:2913 (Oregon North,
international feet) so lengths need no conversion.

## How the measurement works

For each centerline segment:

1. Inset 40 ft from each end, then cast a perpendicular transect every 25 ft of
   what remains — at least 5 per segment, at most 40. Insetting matters:
   Portland is full of 137 ft half-block segments, and sampling by *fraction* of
   length puts the outer transects inside the cross-street intersection, where
   there are no taxlots to measure against. Segments too short to inset 40 ft
   give up 35% of their length at each end instead.
2. Estimate the local bearing from a 20 ft chord, take the perpendicular, and
   extend the transect 250 ft either side of the centerline.
3. Intersect the transect with every nearby taxlot and project each crossing
   onto the transect axis as a signed distance from the centerline.
4. The nearest blocked interval on each side gives the two ROW edges.
5. Median across transects is the width; the spread is the confidence.

Projection arithmetic rather than polygon differencing is what makes this
tractable: it reduces the whole thing to a `min`/`max` aggregation and answers
"which gap is the street" exactly, since only intervals on either side of zero
can be the road edges. 456k transects against 284k taxlots runs in 16 seconds.

Candidate transect/taxlot pairs come from an explicit 300 ft integer tile join
plus a plain-arithmetic bounding-box test. DuckDB will not reliably choose a
spatial join at this scale, and a nested loop over it is not finishable.

A transect produces no width, and says why, when:

- a taxlot straddles the centerline (`centerline_in_taxlot`, 12.5% of transects)
  — private roads, condo plats, or a lot drawn over the street
- no taxlot within 250 ft on one side (`no_lot_one_side`, 5.4%) — these feed
  `row_width_any_ft` as a doubled one-sided estimate, never `row_width_ft`
- none on either side (`no_lots_either_side`, 2.2%) — bridges, the river,
  freeway corridors, airport and large industrial parcels

## Width at any point: the curb profile

Every width above comes from PBOT's Pavement Management System, which records
one `PaveWidth` per pavement section. ORS 801.368 asks whether a roadway is
"not more than 18 feet wide **at any point** between two intersections", and a
pavement section is not a point. A stormwater planter, a curb extension or a
parking-lane island is invisible to it: SE Taylor at SE 50th is on record as a
flat 30 ft, and a pair of bioswales pinches it to 20.3 ft over 25 ft of block.

`sql/11_curb_profile.sql` measures curb to curb every 5 ft off the curb-line
dataset, using the stage 02 transect machinery with points instead of
intervals. 2.75M stations in about 30 seconds. Two departures from stage 02:

- **The reach is adaptive**, `max(25, PaveWidth/2 + 20)` ft rather than a flat
  250. A long reach lets a transect crossing a driveway curb-cut find the curb
  on the far side of the street and report a roadway twice as wide as it is.
  Sizing the window from the PMS width means a missing curb yields NULL, which
  is excluded, rather than a wrong number.
- **Curb returns are excluded.** They flare the gap to 36-42 ft over the last
  15 ft of a segment that ends at an intersection. Stations within 30 ft of an
  end whose node has degree ≠ 2 are dropped; degree-2 ends are mid-block
  continuations and keep theirs. Note the direction: excluding corners *lowers*
  the block maximum, so it makes blocks more likely to pass. The report prints
  the maximum both ways — the median corner inflation is 7.5 ft.

**It agrees with PBOT.** Across 1.43M mid-block stations the median absolute
difference from `PaveWidth` is **0.19 ft**, and 78.6% are within 2 ft. That is
what makes it credible, and the 21% that are not is why it does not replace
PMS: `narrow_residential` and `nrr_convertible` are untouched, and the curb
profile sits beside them.

**Not every curb is a roadway edge**, and this is the thing to understand
before quoting any number from it. The measurement takes the nearest curb
crossing on each side, and where that is an island or an interior line it is
measuring something else. Two cases, handled differently:

- A transect meeting *median curb on both sides* has measured the median. On
  N Hayden Bay Dr it returns 4.7 ft, from -2.6 to +2.1 of the centerline.
  That is the same class of error as a curb return, so those 16,601 stations
  are excluded outright rather than flagged.
- Everything else is **labelled, not guessed at**. SE Clinton at SE 77th comes
  out at a flat 8.0 ft from two shoulder lines at ±4.0 ft, on a
  street PBOT records as 22 ft and uncurbed. No threshold separates that from
  a real narrow street: the centerline is off-centre by more than 10 ft on
  12.7% of segments, so an edge 4 ft away is ordinary on a genuinely narrow
  road. A geometric rule cutting edges within 5 ft would discard 14,514
  stations on local streets whose median width is 15 ft — the exact population
  of interest. So each block carries `edge_quality`: `street curb` (3110/3120
  throughout), `mixed`, or `no street curb`.

That distinction decides how the headline reads:

| | blocks | miles |
|---|---|---|
| testable blocks (≥80% of stations measured) | 27,378 | 1,986.1 |
| maximum ≤ 18 ft — never wider, the reading in stages 06 and 08 | 362 | 22.4 |
| of those, street curb on both sides at every station | **39** | **1.8** |
| minimum ≤ 18 ft — narrow somewhere, the alternative reading | 1,518 | 141.9 |

313 of the 362 have no street curb anywhere along them. The honest number for
"measured, at every point, against an unambiguous roadway edge" is 39 blocks.

**The statute is not settled and the export does not pretend otherwise.**
"Not more than 18 feet wide at any point" reads as a maximum — "any" under
negation is universal, ORS 811.111(1)(d)(A) attaches the 15 mph limit to
driving on "an alley or a narrow residential roadway" (a whole facility), and
the "between two intersections" clause is surplusage unless it names the extent
over which a maximum is taken. But no Oregon appellate decision, AG opinion or
ODOT guidance construing ORS 801.368 was found, so `curb_max_ft` and
`curb_min_ft` are both exported and neither reading is baked in.

Two PBOT documents also disagree on whether paint counts. The City Traffic
Engineer's memo of 23 September 2022, *Setting safe speed limits on Portland
streets*, p. 2: "Streets that meet ORS 801.368 where **pavement** is not wider
than 18 feet. Pavement markings that create an 18 foot or narrower travel way
do not constitute a 'narrow residential street'." The Pedestrian Design Guide
adopted four months earlier (§B.5.4.3, p. 44) says the opposite: "Projects may
restripe roadways to provide a travelway that is 18 feet or less to meet this
requirement… narrowed to 18 feet or less with painted line(s), wands, planters,
and other furniture as appropriate." Which is why `block_edge_line` splits each
block into `already_18_ft` (pavement that is physically narrow, which satisfies
even the memo) and `needs_line_ft` (footage that would need an edge line, which
runs into it). The same guide measures the travelway "exclusive of shoulders
and/or on-street parking" — `sql/08_narrow_residential.sql` assumes the
opposite about parking, and that disagreement is not resolved here.

### Narrowings

`out/curb_pinch_points.geojson` inventories 783 places where a street is
materially narrower than itself: at least 3 ft under its own median, no wider
than 24 ft, running at least 10 ft, bounded by street curb on both sides. The
criterion is relative because an absolute one fails in both directions — a
20 ft cut misses the SE Taylor bioswales at 20.3 ft while admitting freeway
ramps that drop from 60 ft to 8 ft at a gore curb.

338 are on locally classified streets. 150 reach 18 ft or less. The map has
them on a toggle.

### Outputs

`out/curb_profile.txt` — the report, including the inferred `CurbType` domain.
`out/curb_profile_by_block.csv` — per block: the five-number width summary,
`edge_quality`, station counts by edge type, the edge-line arithmetic, and
`width_test_18ft` / `confident_18ft`.
`out/curb_pinch_points.geojson` — one point per narrowing, at its narrowest
station.

## Confidence

**Sidewalks fall inside the measured right of way.** A sidewalk polygon lies
within the ROW by definition, and PBOT's sidewalk dataset shares no lineage with
Metro's taxlots. Taking the nearest sidewalk on each side of 15,417 sampled
transects: **92.7% sit inside the derived ROW edges**, median overshoot 0.0 ft.
5.2% overshoot by more than 10 ft.

(Counting *every* sidewalk a transect crosses rather than the nearest one gives
a bogus 36% failure rate — a 250 ft reach crosses neighbouring streets'
sidewalks, which are correctly outside this segment's ROW.)

**Transects agree with each other.** 51.7% of segments are `high` confidence
with a median spread of 0.0 ft — the signature of parallel platted lot lines,
which is what a real right of way looks like. `low` confidence segments have a
median spread of 37 ft and should not be trusted individually.

**The leftover space is plausible.** ROW minus roadway is 16-30 ft on 59.8% of
segments and 6-16 ft on 8.2%; only 0.3% come out negative.

**Curb-to-curb cross-check.** PBOT's Curb Extension Policy dataset carries its
own `Pavement_RoadWidthFt`, maintained separately and sharing no key with the
pavement system. Matched geometrically, 5,912 segments overlap: 5,298 agree
exactly, 93.7% within 2 ft, median absolute difference 0.0 ft.

Named streets come out where they should: NE Alberta 56.4 ft ROW around 28.3 ft
of roadway, NE Siskiyou 58.8 around 28.1, SE Hawthorne 64.4 around 40.6,
SW Broadway 85.3 around 49.7, SE Powell 100.7 around 58.4.

## Sources

| dataset | what it gives | where |
|---|---|---|
| Taxlots (Public) | parcel polygons; the gap between them is the right of way | [Metro RLIS](https://rlisdiscovery.oregonmetro.gov/datasets/b3cabe5845ec47eab61c54e0c631313c) |
| Streets | centerline geometry, names, address ranges | [PDX open data, layer 68](https://gis-pdx.opendata.arcgis.com/datasets/PDX::streets-3/about) |
| Pavement Management System | `RoadWidth`, `PaveWidth`, lanes, surface, PCI | [PDX open data, layer 71](https://gis-pdx.opendata.arcgis.com/datasets/PDX::pavement-management-system/about) |
| Sidewalks | polygons; independent check on the derived ROW edges | [PDX open data, layer 77](https://gis-pdx.opendata.arcgis.com/datasets/PDX::sidewalks/about) |
| Curb Extension Policy | independent `Pavement_RoadWidthFt`, cross-check only | [PDX open data, layer 1432](https://gis-pdx.opendata.arcgis.com/datasets/PDX::curb-extension-policy/about) |
| Unimproved Right of Way | streets platted but never built | [PDX open data, layer 208](https://gis-pdx.opendata.arcgis.com/datasets/PDX::unimproved-right-of-way/about) |
| City Boundaries | defines which segments are Portland's | [PDX open data, layer 10](https://gis-pdx.opendata.arcgis.com/datasets/PDX::city-boundaries/about) |
| Curbs | curb and shoulder lines; the 5 ft width profile is measured off these | [PDX open data, layer 74](https://gis-pdx.opendata.arcgis.com/datasets/PDX::curbs/about) |

PMS and the centerlines join on the street segment id: PMS `LocationID` is a
four-character prefix, the literal `SEG`, then the `Streets.LOCALID` value.

## Caveats worth knowing before you use the numbers

**This is derived, not authoritative.** It is as good as the taxlot geometry,
which is county assessor cartography rather than survey. It reproduces known
platted widths on regular blocks and is weaker where lot lines are irregular,
where the street was widened by dedication, and around curves and cul-de-sacs.
Check `row_confidence` before trusting any single segment, and use
`out/portland_row_confident.csv` for anything aggregate.

**Multnomah County taxlots stop at the property line — that is the assumption
the whole thing rests on.** Checked: Metro also publishes a "Taxlots with Right
of Way" layer, and its explicit ROW polygons exist only in Washington County
(2,484 of them, 4 inside Portland). For Portland the gap is real, and the
sidewalk check confirms it is the right gap.

**455 segments have a ROW edge at the 250 ft transect reach**, meaning the
nearest lot was only found at the limit and the true width may be wider. These
are freeway corridors, Airport Way and similar. `row_flag_at_transect_cap`
marks them; treat their widths as lower bounds. 1,051 segments come out wider
than 200 ft, nearly all freeway.

**`LCITY`/`RCITY` on the centerline dataset is the postal city, not the
jurisdiction.** Filtering on it yields 55,301 "Portland" segments, ~16,000 of
which are Washington and Clackamas County streets that merely carry a Portland
mailing address. This pipeline uses the city boundary polygon instead; the two
definitions agree with `LEFT_JUR = 'PORT'` on 38,979 of 39,103 segments.

**`RoadWidth` and `PaveWidth` are not documented.** PBOT's metadata lists the
fields with types and no definitions. From the data, `RoadWidth` behaves as the
graded roadway (curb to curb where there are curbs) and `PaveWidth` as the paved
surface: they are equal on 25,363 of 29,523 records, and diverge on ODOT
highways with shoulders and on the ~991 records with `PaveWidth = 1`, which look
like gravel streets. That reading is inference; confirming it with PBOT is one
email.

**`TYPE` on the centerline dataset has no published domain.** It is carried
through as `type_code` unmapped. Empirically 1500 is local streets,
1450/1400/1300 step up through collectors and arterials, 1700 is private roads
(PMS `MaintResp` = `PRIVATE`), 1800 is unnamed driveway-like segments with no
pavement records, and 111x/112x are freeways and ramps.

**`CurbType` has no published domain either.** Inferred in
`sql/11_curb_profile.sql` and reported in `out/curb_profile.txt`: 3110 is the
running street curb (56,183 features, 2,982 mi, median 200 ft long and 16 ft
from the centerline), 3120 is the corner return (41,068 features, median 24 ft
long, 90% within 60 ft of an intersection), 3130 is median and island curb
(2,843 features, sitting 5 ft from the centerline), 3140 is the shoulder line
and 3150 is flexcurb. Only 3110 and 3120 are unambiguously a roadway edge, and
`edge_quality` in the curb-profile exports says which of them bounded each
block's measurement.

**Known bad values exist upstream.** PMS has 37 null `RoadWidth`, 12 records
wider than 100 ft (one at 887 ft, which is not a street width), and 102 where
`PaveWidth > RoadWidth`, contradicting the apparent semantics. 92 taxlots have
self-touching rings and are repaired with `ST_MakeValid` at load; the count is
reported rather than hidden.

## Validation

`make validate` writes `out/validation.txt`: ROW coverage and confidence, why
each missing measurement is missing, the sidewalk containment check, the width
distribution, modal widths, centerline centring, coverage by street type,
plausibility of the leftover space, an outlier census, PMS join coverage, the
curb-extension cross-check, and a spot check on a known block.

## Two maps, for now

`out/map.html` (from `viz/`) and `site/` render the same blocks from the same
database. That is duplication, and it is deliberate only for as long as it
takes to decide which survives: the canvas version is a single file you can
email or open from disk with no server and no dependencies, and the MapLibre
version has a basemap, real zoom, and about six hundred fewer lines of
hand-rolled rendering. Keeping both means every change to the width logic has
to be made twice.
