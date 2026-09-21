-- Blocks: stretches of roadway between two intersections, or between an
-- intersection and a dead end.
--
-- A centerline segment is NOT a block. The source splits runs mid-block at
-- jurisdiction changes, address-range breaks and the like: 28,970 of 112,070
-- segments touch a node where exactly two segments meet, which is a continuation
-- rather than an intersection. Any "at no point wider than X between two
-- intersections" test evaluated per segment is therefore too permissive.
--
-- Node degree is computed over the whole four-county network so that a node at
-- the city limit is not mistaken for a dead end.
LOAD spatial;

CREATE OR REPLACE TABLE node_degree AS
WITH ends AS (
  SELECT street_oid, f_node AS node FROM streets WHERE f_node IS NOT NULL
  UNION ALL
  SELECT street_oid, t_node AS node FROM streets WHERE t_node IS NOT NULL
)
SELECT node, count(*) AS degree FROM ends GROUP BY node;

-- Two segments belong to the same block when they meet at a degree-2 node.
CREATE OR REPLACE TABLE block_adj AS
WITH ends AS (
  SELECT street_oid, f_node AS node FROM streets WHERE f_node IS NOT NULL
  UNION ALL
  SELECT street_oid, t_node AS node FROM streets WHERE t_node IS NOT NULL
), pass_through AS (
  SELECT e.street_oid, e.node FROM ends e JOIN node_degree d USING (node)
  WHERE d.degree = 2
)
SELECT a.street_oid AS x, b.street_oid AS y
FROM pass_through a JOIN pass_through b USING (node)
WHERE a.street_oid <> b.street_oid;

-- Connected components over those adjacencies. Chains are short - a handful of
-- segments - so the all-pairs closure is cheap.
CREATE OR REPLACE TABLE block_member AS
WITH RECURSIVE reach(seg, root) AS (
  SELECT street_oid, street_oid FROM streets
  UNION
  SELECT a.y, r.root FROM reach r JOIN block_adj a ON a.x = r.seg
)
SELECT seg AS street_oid, min(root) AS block_id
FROM reach GROUP BY seg;

-- Block attributes, resolved deterministically.
--
-- 885 blocks carry more than one street name and 238 more than one type code,
-- because a block is a run between intersections and the source splits it
-- wherever a name or a classification changes. `mode()` picks among ties by
-- whichever row a parallel aggregate happened to finish first, so SW Fern St
-- and SW Upper Drive Pl - one segment each, identical geometry and widths -
-- traded places between runs and churned five committed artifacts for no
-- information.
--
-- The rule here is the value covering the most centerline length, ties broken
-- by the value itself. Length beats segment count: a block named A for 400 ft
-- and B for 100 ft is A whether or not B was split into three pieces. Stages
-- 08 and 09 read this rather than recomputing their own.
CREATE OR REPLACE TABLE block_attr AS
WITH per_name AS (
  SELECT m.block_id, sg.full_name AS v, sum(s.len_ft) AS len
  FROM block_member m
  JOIN street_segment s USING (street_oid)
  JOIN seg             sg USING (street_oid)
  GROUP BY 1, 2
), per_type AS (
  SELECT m.block_id, sg.type_code AS v, sum(s.len_ft) AS len
  FROM block_member m
  JOIN street_segment s USING (street_oid)
  JOIN seg             sg USING (street_oid)
  GROUP BY 1, 2
), per_fclass AS (
  SELECT m.block_id, p.functional_class AS v, sum(s.len_ft) AS len
  FROM block_member m
  JOIN street_segment s USING (street_oid)
  JOIN pms_portland    p ON p.localid = s.localid
  GROUP BY 1, 2
), pick_name AS (
  SELECT block_id, v FROM (
    SELECT block_id, v, row_number() OVER (PARTITION BY block_id ORDER BY len DESC, v) AS rn
    FROM per_name) WHERE rn = 1
), pick_type AS (
  SELECT block_id, v FROM (
    SELECT block_id, v, row_number() OVER (PARTITION BY block_id ORDER BY len DESC, v) AS rn
    FROM per_type) WHERE rn = 1
), pick_fclass AS (
  SELECT block_id, v FROM (
    SELECT block_id, v, row_number() OVER (PARTITION BY block_id ORDER BY len DESC, v) AS rn
    FROM per_fclass) WHERE rn = 1
)
SELECT
  b.block_id,
  n.v AS full_name,
  t.v AS type_code,
  f.v AS functional_class
FROM (SELECT DISTINCT block_id FROM block_member) b
LEFT JOIN pick_name   n USING (block_id)
LEFT JOIN pick_type   t USING (block_id)
LEFT JOIN pick_fclass f USING (block_id);

-- One row per block, carrying the worst case along its whole length. Widths are
-- maxima over the block's segments, and each segment's own max over its
-- pavement sections - the finest resolution the source data supports.
CREATE OR REPLACE TABLE block AS
SELECT
  m.block_id,
  count(*)                                            AS n_segments,
  count(*) FILTER (WHERE s.street_oid IS NOT NULL)    AS n_portland_segments,
  round(sum(s.len_ft), 1)                             AS portland_len_ft,
  round(sum(s.len_ft) / 5280.0, 4)                    AS portland_len_mi,
  any_value(a.full_name)                              AS full_name,
  any_value(a.type_code)                              AS type_code,

  -- roadway (curb to curb), from PBOT pavement records
  max(s.road_width_max_ft)                            AS road_width_max_ft,
  min(s.road_width_min_ft)                            AS road_width_min_ft,
  count(*) FILTER (WHERE s.road_width_max_ft IS NULL) AS n_missing_road_width,

  -- right of way, derived
  max(s.row_width_max_ft)                             AS row_width_max_ft,
  min(s.row_width_min_ft)                             AS row_width_min_ft,
  count(*) FILTER (WHERE s.row_width_ft IS NULL)      AS n_missing_row_width,
  count(*) FILTER (WHERE s.row_confidence NOT IN ('high', 'medium')) AS n_row_not_confident,
  bool_or(s.row_flag_at_transect_cap)                 AS any_row_at_cap
FROM block_member m
JOIN streets  t ON t.street_oid = m.street_oid
JOIN block_attr a ON a.block_id = m.block_id
LEFT JOIN street_segment s ON s.street_oid = m.street_oid
GROUP BY m.block_id
HAVING count(*) FILTER (WHERE s.street_oid IS NOT NULL) > 0;

SELECT
  count(*)                                              AS portland_blocks,
  round(sum(portland_len_ft) / 5280.0, 1)               AS miles,
  round(avg(n_segments), 2)                             AS avg_segments_per_block,
  count(*) FILTER (WHERE n_segments > 1)                AS blocks_spanning_multiple_segments
FROM block;

-- ===========================================================================
-- "Not more than 18 feet wide at any point between two intersections or
-- between an intersection and the end of the roadway."
--
-- A maximum-along-the-whole-block test, which is why the block table above
-- exists. Evaluated on both widths, because 18 ft is a roadway figure: as a
-- right-of-way threshold it selects almost nothing.
--
-- A block only qualifies if EVERY one of its segments has a width on record.
-- A block with a gap cannot be shown to stay under 18 ft at every point, so it
-- is excluded rather than assumed to pass.
-- ===========================================================================
CREATE OR REPLACE TABLE narrow_block AS
SELECT *,
       road_width_max_ft <= 18 AS qualifies_18ft
FROM block
WHERE n_missing_road_width = 0;

.print
.print ========== roadway never wider than 18 ft, whole block ==========
SELECT
  count(*) FILTER (WHERE qualifies_18ft)                                  AS blocks,
  round(sum(portland_len_ft) FILTER (WHERE qualifies_18ft) / 5280.0, 1)   AS miles,
  count(*)                                                                AS blocks_testable,
  round(sum(portland_len_ft) / 5280.0, 1)                                 AS miles_testable,
  round(100.0 * sum(portland_len_ft) FILTER (WHERE qualifies_18ft)
        / nullif(sum(portland_len_ft), 0), 2)                             AS pct_of_testable
FROM narrow_block;

.print
.print ========== threshold sensitivity ==========
SELECT thr AS max_width_ft,
       count(*) FILTER (WHERE road_width_max_ft <= thr) AS blocks,
       round(sum(portland_len_ft) FILTER (WHERE road_width_max_ft <= thr) / 5280.0, 1) AS miles
FROM narrow_block, (SELECT unnest([14, 16, 18, 20, 22, 24]) AS thr)
GROUP BY thr ORDER BY thr;

.print
.print ========== how much of the city cannot be tested ==========
SELECT
  count(*) FILTER (WHERE n_missing_road_width > 0) AS blocks_with_gaps,
  round(sum(portland_len_ft) FILTER (WHERE n_missing_road_width > 0) / 5280.0, 1) AS miles_with_gaps
FROM block;

SELECT type_code, count(*) AS blocks, round(sum(portland_len_ft) / 5280.0, 1) AS miles
FROM block WHERE n_missing_road_width > 0
GROUP BY type_code ORDER BY miles DESC LIMIT 5;

.print
.print ========== same test on the right of way, for contrast ==========
SELECT
  count(*) FILTER (WHERE row_width_max_ft <= 18)                                  AS blocks,
  round(sum(portland_len_ft) FILTER (WHERE row_width_max_ft <= 18) / 5280.0, 1)   AS miles
FROM block WHERE n_missing_row_width = 0;

.print
.print ========== PaveWidth instead of RoadWidth ==========
-- RoadWidth is the graded roadway, PaveWidth the paved surface. They differ on
-- gravel streets and shouldered highways, and the choice moves the answer.
WITH pw AS (
  SELECT s.street_oid, max(p.pave_width_ft) AS pave_max_ft
  FROM street_segment s JOIN pms_portland p ON p.localid = s.localid
  GROUP BY s.street_oid
), b AS (
  SELECT m.block_id,
         max(pw.pave_max_ft)                              AS pave_max_ft,
         count(*) FILTER (WHERE pw.pave_max_ft IS NULL)   AS missing,
         sum(s.len_ft)                                    AS len_ft
  FROM block_member m
  JOIN street_segment s ON s.street_oid = m.street_oid
  LEFT JOIN pw ON pw.street_oid = m.street_oid
  GROUP BY m.block_id
)
SELECT count(*) AS blocks, round(sum(len_ft) / 5280.0, 1) AS miles
FROM b WHERE missing = 0 AND pave_max_ft <= 18;

.print
.print ========== per segment vs per block: why the unit matters ==========
SELECT 'per segment (too permissive)' AS method,
       count(*) AS n, round(sum(len_ft) / 5280.0, 1) AS miles
FROM street_segment WHERE road_width_max_ft <= 18
UNION ALL
SELECT 'per block (as written)', count(*), round(sum(portland_len_ft) / 5280.0, 1)
FROM narrow_block WHERE qualifies_18ft;

.print
.print ========== the qualifying blocks, longest first ==========
SELECT full_name, round(portland_len_ft) AS len_ft, n_segments,
       road_width_min_ft, road_width_max_ft, row_width_max_ft
FROM narrow_block WHERE qualifies_18ft
ORDER BY portland_len_ft DESC LIMIT 12;
