---
name: rationalization-review-pack
description: Produce the BI Program Office's rationalization review pack for one department, platform or subject area (or the whole estate) — what survives, what retires and how many views it carries, the delivered-but-unread reports to ask about, the largest duplicate clusters and their canonical, the rules that did the work, and the owner notes to send. Use when asked to review a department's or platform's dispositions, to prepare for an owner review meeting, which reports can be switched off, or what a platform's estate looks like after rationalization.
---

# Rationalization review pack

You are running methods MTH-01 (rationalization rule engine) and MTH-02 (duplicate
detection) for the BI Program Office. The output is a pack a program lead takes into a
review with the owning department. It is a list of recommendations and questions for
named reviewers, not a list of decisions.

## Steps

1. **Scope.** If the user named a department, platform or subject area, use it.
   Filter names in `estate_analyst` (semantic view SV_BI_ESTATE) are exactly
   `assets.owner_department`, `assets.platform` (TABLEAU, POWER_BI, SAP_BO,
   MEDEANALYTICS) and `assets.subject_area`. Cluster fields are prefixed:
   `clusters.cluster_id`, `clusters.canonical_title`, `clusters.cluster_platforms`,
   `clusters.cluster_subject_area`; there is no un-prefixed cluster `platforms` or
   `subject_area`.
2. **Dispositions.** One `estate_analyst` query in scope grouped by
   `assets.final_disposition`: `asset_count`, `total_views_365`, `total_effort_hours`,
   `effort_if_migrated_as_is`. Read every row from this one result. Also ask for
   `survival_rate` and `retirement_view_share` in scope (KPI-003, KPI-004).
3. **The rules that did the work.** `estate_analyst` grouped by `assets.rule_priority`,
   `assets.rule_id`, `assets.rule_name`: `asset_count`, `overridden_assets`. Present in
   rule-priority order (first match wins).
4. **Delivered but never opened.** `estate_analyst` with `assets.rule_id = 'R055'` in
   scope: `assets.title`, `assets.platform`, `assets.owner_department`,
   `total_subscriptions`, `total_views_90`, top ten by subscriptions (KPI-005). These go
   to INVESTIGATE, never RETIRE: ask the recipients.
5. **Retirement, with its blind spots.** `estate_analyst` with
   `assets.final_disposition = 'RETIRE'` in scope, grouped by `assets.rule_id`:
   `retired_assets`, `retired_views_365`, `total_subscriptions`. Say in the same sentence
   that view counts cannot see inbox reading, exports or embedded use, and that R010/R020
   only fire with no subscription.
6. **Duplicates.** `estate_analyst` on clusters in scope (by
   `clusters.cluster_subject_area`, or for a platform by `clusters.cluster_platforms`
   containing it): `cluster_members`, `cluster_views_365`, `cluster_dead_members` with
   `clusters.cluster_id` and `clusters.canonical_title`, top five by members (KPI-006).
7. **Evidence for the headline asset.** For the most-subscribed R055 asset and the
   largest cluster, use `estate_record` with the id or title in the query (for example
   "Provider wRVU Productivity (FINAL)" or "CLUSTER:DUP-0006") and quote the rule reason
   and evidence. Use `migration_reference` REF-01 (why usage lies) and REF-24 (owner
   notification) for the method sentence.
8. **Write the pack.** Headline (assets in scope, share that survives, share of views the
   retirement carries); the disposition table (offer a bar chart); the rule table; the
   R055 list; the retirement paragraph with the blind spots; the clusters with their
   canonical; then a short draft owner note per list ("these N reports will be retired
   after a 30-day notice unless you tell us who reads them"). Footer: KPI-001, KPI-002,
   KPI-003, KPI-004, KPI-005, KPI-006, KPI-007 (DRAFT), MTH-01, MTH-02, and the extract
   date 2026-08-15.
9. **Offer to keep it.** Say the pack can be saved as an artifact and re-run before each
   owner review.

## Rules

- A disposition is a recommendation until a named reviewer accepts or overrides it. You
  do not record a decision; you draft the note.
- Never cite a low view count as proof of disuse without naming subscriptions, scheduled
  delivery and embedded consumption in the same sentence.
- Effort hours are band-rate estimates (KPI-007, KPI-008, DRAFT). Say "estimated effort",
  never "hours saved" or a cost saving.
- `total_views_365` is interactive views only; do not call it "users" or "readers".
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
