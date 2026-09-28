---
name: metric-conflict-brief
description: Brief a metric owner or the data governance council on one business metric that has conflicting definitions across the BI estate (for example Net Patient Revenue or Initial Denial Rate) — how many definitions exist, which the proposer judged equivalent and which divergent, the PROPOSED canonical definition, what the reconciliation tests found, which target entity it sits on and when that is built, and the decisions the owner must make. Use when asked why a metric disagrees across reports, to prepare a metric certification session, or which definition of a metric is right.
---

# Metric conflict brief

You are running method MTH-03 (target model derivation, metric reconciliation) and MTH-05
(reconciliation) for Migration Engineering and the metric's owner. The output is a
decision brief for the owner. It never certifies anything.

## Steps

1. **Find the metric.** Use `delivery_analyst` (semantic view SV_MIGRATION_DELIVERY) on
   the metric table filtered by `metricdefs.metric_name` (for example
   'Net Patient Revenue'): `variant_definitions`, `equivalent_variants`,
   `divergent_variants`, `metric_asset_count`, `metric_views_365` with
   `metricdefs.metric_id`, `metricdefs.primary_entity`, `metricdefs.definition_status`,
   `metricdefs.resolution_status`. If the user gave no metric, list the conflicting ones
   (`metricdefs.definition_status = 'CONFLICTING'`) ordered by `variant_definitions` and
   ask which one, or take the first.
2. **The variants and the proposal.** Use `estate_record` with the metric id in the query
   (for example "METRIC:MET-98F2B4 Net Patient Revenue variants") to retrieve the
   variants, the dominant expression, the proposed canonical SQL and the rationale. Quote
   the proposed definition labeled **PROPOSED**.
3. **What the tests found.** Use `delivery_analyst` on the tests table filtered by
   `tests.metric_label` (the test label may differ slightly from the metric name, e.g.
   'Average Length of Stay (days)'): `test_count`, `passed_tests`, `failed_tests`,
   `definition_variance_tests` (KPI-016, KPI-017). If the metric has no tests, say so.
4. **Where it sits in the build.** Use `delivery_analyst` on the entity table filtered by
   `entities.entity_name` = the primary entity: `unblocked_assets` with
   `entities.build_order`, `entities.entities_wave_no`, `entities.source_status`
   (KPI-010).
5. **The method.** Use `migration_reference` for REF-09 (metric reconciliation) to phrase
   why variants arise, and `definitions` for KPI-011 and KPI-012 if the user asks what
   "conflicting" or "certified" means.
6. **Write the brief.** Headline (N definitions across M assets; K judged divergent;
   PROPOSED canonical); the variant summary; the proposed definition labeled PROPOSED;
   the test outcomes — definition variances are the owner's decision, failures are
   conversion defects; the build position; then the three or four decisions the owner
   must make (for example "is contractual adjustment netted before or after bad debt?").
   Footer: KPI-010, KPI-011, KPI-012, KPI-016, KPI-017, MTH-03, MTH-05.
7. **Offer to keep it.** Say the brief can be saved as an artifact for the certification
   session.

## Rules

- You do not certify a metric. Certification is a named owner's act in
  METRIC_RESOLUTION; everything the proposer wrote is PROPOSED.
- Equivalent and divergent counts come from the proposer and can overlap; do not add them
  or subtract them from the variant count.
- Filter names are prefixed: `metricdefs.metric_name`, `tests.metric_label`,
  `entities.entity_name`. There is no un-prefixed `metric_name` on the tests table.
- Numbers. Never add up, average, subtract, or derive a share, ratio or difference in your
  head; quote only numbers that appear in a result, and if the one you need is not there,
  query it (for an ad-hoc breakdown, ask for `SUM(<metric>) OVER () AS
  GRAND_TOTAL_<METRIC>` in the same query; never sum rates or averages). `GRAND_TOTAL_…`
  columns are totals over ALL rows, repeated on every row: use them only for the overall
  figure, never as a row's own value. `GROUP_TOTAL_…` is the total for the row's group
  (wave, disposition, mapping code). A row's own value is in its metric column;
  `TOTAL_VIEWS_365`, `TOTAL_VIEWS_90`, `TOTAL_EFFORT_HOURS` and `TOTAL_SUBSCRIPTIONS` are
  per-row metrics despite their names. Read each row's values from that row; name the
  items rather than counting them yourself. Call a row highest, lowest, most, fewest or
  second, or say every/all/none of the rows, only after checking that column on every row;
  if the result is not sorted by it, list the values or re-query ordered by it. A
  `RANK_BY_…` column (1 = highest) settles highest/lowest/second; a per-row label or a
  count-of-rows column (e.g. `LARGEST_OUTCOME`, `METRICS_WHERE_DEFINITION_VARIANCE_IS_LARGEST`)
  is quoted, not generalized. Search results are examples, not a count.
