---
name: wave-readiness-report
description: Produce Migration Engineering's readiness report for one migration wave — what the wave carries, the entities the data team must build first and what each unblocks, how many assets are ready, in review or blocked for conversion, which constructs still need a human decision, the source columns that need a decision, and the reconciliation status. Use when asked whether a wave is ready to start, what blocks a wave, what the data team should build next, or for a sprint-planning readiness check.
---

# Wave readiness report

You are running methods MTH-03 (target model and build order), MTH-04 (conversion and
readiness) and MTH-05 (reconciliation) for Migration Engineering. The output is a
readiness report a delivery lead can plan a sprint from.

## Steps

1. **Scope.** Use the wave the user named (1-4); default to wave 1. Wave 0 is the shared
   foundation (entities only, no assets). The wave filter names differ per table and are
   all prefixed: `assets.wave_no` in `estate_analyst`; in `delivery_analyst`
   `entities.entities_wave_no`, `readiness.ready_wave_no`, `fields.fields_wave_no`,
   `sources.sources_wave_no`. There is no un-prefixed `wave_no` in SV_MIGRATION_DELIVERY.
2. **What the wave carries.** `estate_analyst` (SV_BI_ESTATE) with `assets.is_surviving`
   grouped by `assets.wave_no`: `surviving_assets`, `total_effort_hours`,
   `total_views_365`. Read the wave's row from this one result.
3. **Build first.** `delivery_analyst` on entities with `entities.entities_wave_no` <= the
   wave: `unblocked_assets`, `entity_attributes` with `entities.build_order`,
   `entities.entity_name`, `entities.source_status`, ordered by `build_order`, top 15
   (KPI-010). Call out any entity whose `source_status` is not SOURCE_AVAILABLE.
4. **Readiness.** `delivery_analyst` on readiness with `readiness.ready_wave_no` = the
   wave, grouped by `readiness.readiness_status`: `readiness_asset_count` (KPI-015), with
   the wave total in the same result (`SUM(READINESS_ASSET_COUNT) OVER ()` as
   `GRAND_TOTAL_READINESS_ASSET_COUNT`); quote shares only from a result column.
5. **Human decisions.** `delivery_analyst` on fields with `fields.fields_wave_no` = the
   wave, grouped by `fields.complexity_tag`: `human_fields`, `field_count`; keep rows
   with `human_fields` > 0 (KPI-014). For the top construct, use `migration_reference`
   (REF-12 Tableau, REF-13 DAX, REF-14 BusinessObjects, REF-25 MedeAnalytics) for the
   modeling pattern that replaces it.
6. **Source decisions.** `delivery_analyst` on sources with `sources.sources_wave_no` <=
   the wave: `columns_needing_decision` by `sources.mapping_code` and
   `sources.system_family` (KPI-018).
7. **Tests.** `delivery_analyst` on tests grouped by `tests.outcome`: `test_count`.
   Tests are for the FY2026 Q4 period and are not split by wave; say so.
8. **Write the report.** Headline (ready / review / blocked counts for the wave, the
   first three entities to build); the wave table; the build list; the readiness table
   (offer a stacked bar); the human-decision constructs with the pattern that replaces
   each; the source decisions; the test outcomes. Footer: KPI-007 (DRAFT), KPI-010,
   KPI-013, KPI-014, KPI-015, KPI-016, KPI-018, MTH-03, MTH-04, MTH-05.
9. **Offer to schedule it.** Say it can be saved as an artifact and re-run each sprint.

## Rules

- A generated Sigma formula is never final: quote its status (AUTO, NEEDS_REVIEW,
  NEEDS_HUMAN) and confidence. NEEDS_HUMAN is a modeling decision, not a defect.
- READY means the formulas are ready; the asset still waits on its entities being built.
- `unblocked_assets` is not additive across entities; never sum it.
- Effort and build hours are indicative estimates, TO CONFIRM.
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
