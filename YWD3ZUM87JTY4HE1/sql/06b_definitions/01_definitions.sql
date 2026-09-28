-- =============================================================================
-- BI Rationalization & Migration Workbench — the trusted-definitions plane
-- -----------------------------------------------------------------------------
-- A rationalization is argued with numbers: "40% of the estate retires and
-- carries half a percent of the views", "75% fewer hours than migrating as-is",
-- "22 metrics disagree with themselves". Each of those words — asset, view,
-- survive, effort, conflicting, ready, pass — has a definition, an owner and a
-- method, and a program office that cannot say which is arguing about
-- vocabulary instead of decisions. So the definitions are first-class objects,
-- and every metric in the two semantic views cites one by id.
--
--   KPI_DEFINITION         what a term means, formula, grain, owner, version
--   METHOD_REGISTRY        how the analysis is done (rule engine, duplicate
--                          detection, model derivation, conversion,
--                          reconciliation, question certification)
--   QUESTION_CATALOG       the certified questions each team is offered, each
--                          traced to KPI ids and a method, with plain SQL a
--                          steward verified against the marts
--   DEFINITION_CHANGE_LOG  what changed, when, why, who signed it, and which
--                          questions re-opened
--
-- These describe the ACCELERATOR's own measures of the migration. The estate's
-- business metrics (Net Patient Revenue, Initial Denial Rate …) live in
-- TARGET_MODEL.METRIC / METRIC_RESOLUTION and are certified there by their
-- owners; KPI-011 and KPI-012 count them. Steward and reviewer names are
-- fictional. Owner "roles" are business roles at the fictional Ridgeline Health.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE WAREHOUSE BI_MOD_WH;
USE SCHEMA GOVERNANCE;

CREATE OR REPLACE TABLE GOVERNANCE.KPI_DEFINITION (
    KPI_ID          TEXT PRIMARY KEY,
    KPI_NAME        TEXT,
    TEAM            TEXT,          -- Program Office | Migration Engineering | Shared
    DEFINITION      TEXT,
    FORMULA         TEXT,
    GRAIN           TEXT,
    NUMERATOR       TEXT,
    DENOMINATOR     TEXT,
    SOURCE_OBJECT   TEXT,
    METHOD_ID       TEXT,
    OWNER_ROLE      TEXT,
    STATUS          TEXT,          -- CERTIFIED | DRAFT | DEPRECATED
    VERSION         NUMBER(3,0),
    EFFECTIVE_FROM  DATE,
    CAVEATS         TEXT
);

INSERT INTO GOVERNANCE.KPI_DEFINITION VALUES
('KPI-001','Estate asset','Shared',
 'One consumable BI artifact in a source platform: a Tableau workbook, a Power BI report, an SAP BusinessObjects Web Intelligence or Crystal document, or a MedeAnalytics report or dashboard. The unit every disposition, effort estimate and wave is counted in.',
 'COUNT(*) FROM CONFORMED.ASSET',
 'asset','Assets in the conformed model','n/a','CONFORMED.ASSET; AI.SV_BI_ESTATE assets.asset_count','MTH-01','BI Program Office','CERTIFIED',1,'2026-06-01',
 'A Tableau workbook is one asset however many sheets it has; a Power BI report is the asset, not its dataset. Datasets, universes and extracts are lineage, not assets.'),
('KPI-002','Interactive views','Shared',
 'A logged, user-initiated open of an asset in the source platform over a trailing window ending at the extract date (90 or 365 days). Subscription e-mails, scheduled deliveries, exports and embedded consumption are NOT views; they are counted separately as subscriptions.',
 'SUM(views) FROM CONFORMED.USAGE_DAILY WHERE view_date > AS_OF_DATE() - window',
 'asset × window','Interactive view events','n/a','CONFORMED.USAGE_SUMMARY (VIEWS_90, VIEWS_365); AI.SV_BI_ESTATE assets.total_views_365','MTH-01','BI Program Office','CERTIFIED',2,'2026-07-01',
 'Version 2 removed subscription deliveries from the view count; v1 had counted each delivered e-mail as a view, which made delivered-but-unread reports look used. Usage never proves disuse: a report read only in the inbox has zero views — see KPI-005 and rule R055. Windows run to the extract date (2026-08-15), never CURRENT_DATE.'),
('KPI-003','Survival rate','Program Office',
 'The share of estate assets whose final disposition (after the human review gate) is MIGRATE, REBUILD or SELF_SERVICE — the assets that exist in the target platform as themselves.',
 'COUNT_IF(final_disposition IN (''MIGRATE'',''REBUILD'',''SELF_SERVICE'')) / COUNT(*)',
 'estate or any slice of it','Surviving assets','All assets in the slice (KPI-001)','RATIONALIZATION.V_FINAL_DISPOSITION (IS_SURVIVING); AI.SV_BI_ESTATE assets.survival_rate','MTH-01','BI Program Office','CERTIFIED',2,'2026-07-15',
 'Version 2 excludes CONSOLIDATE: a consolidated asset''s requirements fold into its canonical, which is the survivor; counting both double-counted the content. INVESTIGATE is not surviving until a reviewer decides. Quote the review status: most dispositions are still recommendations (PENDING).'),
('KPI-004','Retirement view share','Program Office',
 'The share of all interactive views in the last 365 days that were on assets whose final disposition is RETIRE — how much reading the retirement actually removes.',
 'SUM(views_365 WHERE final_disposition = ''RETIRE'') / SUM(views_365)',
 'estate or any slice','365-day views on retired assets','All 365-day views in the slice','RATIONALIZATION.V_RATIONALIZATION_SUMMARY (PCT_OF_VIEWS); AI.SV_BI_ESTATE assets.retirement_view_share','MTH-01','BI Program Office','CERTIFIED',1,'2026-06-01',
 'Views, not people: one heavy reader of a retired report can be most of its views. Pair with the owner notification window (REF-24) before anything is switched off.'),
('KPI-005','Delivered-but-unread asset','Program Office',
 'An asset with at least one active subscription or scheduled recipient and no interactive view in the last 90 days. It may be read in the inbox, so it is never retired on usage alone.',
 'COUNT_IF(subscription_count > 0 AND views_90 = 0)',
 'asset','Assets meeting the condition','n/a','RATIONALIZATION.DISPOSITION_RULE R055; AI.SV_BI_ESTATE assets.delivered_unread_assets','MTH-01','BI Program Office','CERTIFIED',1,'2026-07-15',
 'The condition is rule R055, which sends the asset to INVESTIGATE (ask the recipients) rather than RETIRE. Because R055 runs at priority 25, before consolidation (CHG-0001), every asset meeting the condition is caught by R055; reviewers may still override to MIGRATE.'),
('KPI-006','Duplicate cluster','Program Office',
 'A set of two or more assets that answer the same question, found structurally by MTH-02 (normalized title plus a shared conformed entity, or shared entities and metrics with close titles, joined transitively). Each cluster has one canonical member; the rest consolidate into it.',
 'COUNT(DISTINCT cluster_id); clustered assets = SUM(cluster_size)',
 'cluster','Clusters (or assets in clusters)','n/a','CONFORMED.DUPLICATE_CLUSTER, CONFORMED.V_DUPLICATE_CLUSTER_SUMMARY; AI.SV_BI_ESTATE clusters.cluster_count','MTH-02','BI Program Office','CERTIFIED',2,'2026-07-01',
 'Version 2 requires a shared entity even for identical titles and strips standalone numbers from the title key (CHG-0003). Cluster size counts the canonical. A cluster is a consolidation candidate list, not a decision.'),
('KPI-007','Effort hours under the final disposition','Program Office',
 'Indicative hours to deliver each asset under its final disposition: MIGRATE = conversion hours by complexity band plus the validation share; REBUILD = the same times the rebuild multiplier; SELF_SERVICE and CONSOLIDATE a fixed small number; INVESTIGATE half a conversion; RETIRE zero.',
 'SUM(CASE final_disposition ... END) using SCORING_POLICY band rates',
 'asset','Estimated hours','n/a','RATIONALIZATION.V_FINAL_DISPOSITION (EFFORT_HOURS); AI.SV_BI_ESTATE assets.total_effort_hours','MTH-01','BI Program Office','DRAFT',1,'2026-06-01',
 'DRAFT: band rates (6/16/40/80 h, rebuild x1.5, validation +25%) are TO CONFIRM on the first wave''s measured velocity. An estimate for sequencing, never a proposal or quote.'),
('KPI-008','Effort hours if migrated as-is','Program Office',
 'Indicative hours to convert every asset as-is, with no rationalization: conversion hours by complexity band plus the validation share, for all assets.',
 'SUM(conversion_hours_base * (1 + validation_share))',
 'asset','Estimated hours','n/a','RATIONALIZATION.V_FINAL_DISPOSITION (EFFORT_HOURS_IF_MIGRATED_AS_IS); AI.SV_BI_ESTATE assets.effort_if_migrated_as_is','MTH-01','BI Program Office','DRAFT',1,'2026-06-01',
 'DRAFT: same band rates as KPI-007, TO CONFIRM. The counterfactual a per-dashboard quote implies.'),
('KPI-009','Effort reduction','Program Office',
 'The share of as-is effort (KPI-008) that the final dispositions avoid: (KPI-008 - KPI-007) / KPI-008.',
 '(SUM(as_is_hours) - SUM(final_hours)) / SUM(as_is_hours)',
 'estate or any slice','As-is hours minus final hours','As-is hours','AI.SV_BI_ESTATE assets.effort_reduction_pct, assets.effort_hours_avoided','MTH-01','BI Program Office','DRAFT',1,'2026-06-01',
 'DRAFT: a ratio between two estimates. Say "a reduction in estimated effort", never "hours saved" or a cost saving; nothing has been measured. REBUILD assets cost MORE than as-is (x1.5), so a slice of mostly REBUILD can show a negative reduction.'),
('KPI-010','Assets unblocked by an entity','Migration Engineering',
 'The number of surviving assets whose lineage reads a target entity: once the entity is built and certified, those assets can be converted.',
 'COUNT(DISTINCT surviving asset reading the entity)',
 'entity','Surviving assets reading the entity','n/a','TARGET_MODEL.ENTITY (SURVIVING_ASSETS), TARGET_MODEL.V_BUILD_BACKLOG (ASSETS_UNBLOCKED); AI.SV_MIGRATION_DELIVERY entities.unblocked_assets','MTH-03','Data Platform Lead','CERTIFIED',1,'2026-06-01',
 'Not additive across entities: an asset reading DIM_PROVIDER and FACT_DENIAL counts under both, and is convertible only when BOTH exist.'),
('KPI-011','Conflicting metric','Migration Engineering',
 'A metric name computed by two or more assets with more than one distinct definition, where the most common definition covers less than 80% of the assets computing it.',
 'VARIANT_COUNT > 1 AND DOMINANT_SHARE < 0.80',
 'metric name','Metrics meeting the condition','Metrics computed by two or more assets','TARGET_MODEL.METRIC (DEFINITION_STATUS); AI.SV_MIGRATION_DELIVERY metricdefs.conflicting_metric_count','MTH-03','Data Governance Council','CERTIFIED',1,'2026-06-01',
 'Variant = a distinct normalized expression. Equivalent / divergent counts come from the AI proposer (PROPOSED) and can overlap — the proposer may list a variant in both — so they need not sum to the variant count.'),
('KPI-012','Certified metric','Migration Engineering',
 'A business metric whose canonical definition a named owner has certified in TARGET_MODEL.METRIC_RESOLUTION (STATUS = CERTIFIED, CERTIFIED_BY set). Only a person certifies.',
 'COUNT_IF(resolution.status = ''CERTIFIED'')',
 'metric','Certified metrics','n/a','TARGET_MODEL.METRIC_RESOLUTION; AI.SV_MIGRATION_DELIVERY metricdefs.certified_metric_count','MTH-03','Data Governance Council','CERTIFIED',1,'2026-06-01',
 'PROPOSED rows (written by the AI proposer) are not certified and never count. Zero certified is the honest starting state.'),
('KPI-013','Auto-conversion rate','Migration Engineering',
 'The share of calculated fields sent to conversion whose status is AUTO: the rule catalog (plus in-code handling or the residual pass) produced a Sigma formula with confidence at least 0.85, no unresolved tokens and no rule that demands a human.',
 'COUNT_IF(status = ''AUTO'') / COUNT(*)',
 'calculated field','AUTO fields','Calculated fields on MIGRATE, REBUILD and INVESTIGATE assets','CONVERSION.FIELD_CONVERSION; AI.SV_MIGRATION_DELIVERY fields.auto_conversion_rate','MTH-04','Analytics Engineering Lead','CERTIFIED',1,'2026-06-01',
 'AUTO is not reviewed-and-final; it is eligible for spot-check. Sigma function names are TO CONFIRM against the client''s release.'),
('KPI-014','Human-decision field','Migration Engineering',
 'A calculated field whose status is NEEDS_HUMAN: a construct with no one-line Sigma equivalent (LOD, filter context, time intelligence, iterators, RLS, external scripts), a vendor-defined measure with no exported definition, or rule confidence below 0.6.',
 'COUNT_IF(status = ''NEEDS_HUMAN'')',
 'calculated field','NEEDS_HUMAN fields','n/a (rate: over all converting fields)','CONVERSION.FIELD_CONVERSION; AI.SV_MIGRATION_DELIVERY fields.human_fields, fields.human_decision_rate','MTH-04','Analytics Engineering Lead','CERTIFIED',2,'2026-08-20',
 'Version 2 (CHG-0004) counts MedeAnalytics vendor-defined measures as NEEDS_HUMAN with "redefine on the certified dataset", where v1 had left them as translation failures. A human-decision field is a modeling decision, not a defect.'),
('KPI-015','Conversion readiness','Migration Engineering',
 'The state of a MIGRATE or REBUILD asset''s conversion: READY when every calculated field is AUTO (or it has none), REVIEW when some need review but none needs a human, BLOCKED when at least one needs a human decision.',
 'CASE WHEN human = 0 AND review = 0 THEN READY WHEN human = 0 THEN REVIEW ELSE BLOCKED END',
 'asset','Assets in the state','MIGRATE and REBUILD assets','CONVERSION.V_ASSET_CONVERSION_READINESS; AI.SV_MIGRATION_DELIVERY readiness.ready_rate','MTH-04','Analytics Engineering Lead','CERTIFIED',1,'2026-06-01',
 'Readiness is about formulas only. An asset can be READY and still wait on its entities being built (KPI-010).'),
('KPI-016','Reconciliation pass rate','Migration Engineering',
 'The share of reconciliation tests in the latest run whose absolute variance between the legacy report''s value and the certified target value for the same period is within the metric''s materiality threshold.',
 'COUNT_IF(outcome = ''PASS'') / COUNT(*)',
 'test (asset × metric × period)','PASS tests','Tests in the latest run','CONVERSION.V_TEST_RESULT, CONVERSION.V_TEST_SUMMARY; AI.SV_MIGRATION_DELIVERY tests.pass_rate','MTH-05','Analytics Engineering Lead','CERTIFIED',1,'2026-06-01',
 'The legacy source values are simulated in the demo. A low pass rate here is mostly definition variance (KPI-017), not conversion defects.'),
('KPI-017','Definition variance','Migration Engineering',
 'A reconciliation test beyond materiality where the legacy report used a variant definition of the metric rather than the certified one. The number differs because the definition differs — an owner decision, not an engineering fix.',
 'COUNT_IF(variance_pct > materiality_pct AND NOT uses_certified_definition)',
 'test','DEFINITION_VARIANCE tests','Tests in the latest run','CONVERSION.V_TEST_RESULT; AI.SV_MIGRATION_DELIVERY tests.definition_variance_tests','MTH-05','Data Governance Council','CERTIFIED',1,'2026-06-01',
 'A FAIL is the same gap on a report that used the certified definition — that one is a conversion defect.'),
('KPI-018','Source columns needing a decision','Migration Engineering',
 'Source columns traced from surviving assets'' lineage whose mapping status is not MAPPED: HOSTED_VENDOR (a MedeAnalytics hosted domain — lineage only), SOURCE_DECOMMISSIONED (map from the replacement system) or SPREADSHEET (needs a system of record or a governed upload).',
 'COUNT_IF(mapping_status <> ''MAPPED'')',
 'source column','Columns needing a decision','Source columns traced','TARGET_MODEL.V_SOURCE_TO_TARGET_MAP; AI.SV_MIGRATION_DELIVERY sources.columns_needing_decision','MTH-03','Data Platform Lead','CERTIFIED',1,'2026-06-01',
 'HOSTED_VENDOR columns cannot be sourced from the vendor after the contract ends; map them from your own system of record first (REF-25).');

-- ------------------------------------------------------------- methods ---
CREATE OR REPLACE TABLE GOVERNANCE.METHOD_REGISTRY (
    METHOD_ID       TEXT PRIMARY KEY,
    METHOD_NAME     TEXT,
    TEAM            TEXT,
    PURPOSE         TEXT,
    STEPS           TEXT,          -- the codified procedure, numbered
    THRESHOLDS      TEXT,
    IMPLEMENTED_IN  TEXT,
    OWNER_ROLE      TEXT,
    STATUS          TEXT,
    VERSION         NUMBER(3,0),
    EFFECTIVE_FROM  DATE,
    LIMITATIONS     TEXT
);

INSERT INTO GOVERNANCE.METHOD_REGISTRY VALUES
('MTH-01','Rationalization rule engine','Program Office',
 'Give every asset one recommended disposition with the rule, the reason and the evidence, then route it through a named human review, and estimate effort under the result.',
 '1. Profile each asset: usage (views and viewers in 90/365 days, days since last view, owner view share, trend), delivery (subscriptions, schedules), complexity points and band, criticality, data health, duplicate cluster, regulatory match, source systems. ' ||
 '2. Evaluate the rules in DISPOSITION_RULE in priority order; the first rule whose CONDITION_SQL is true sets the disposition and writes REASON_SQL and the evidence: R010 broken and unread, R020 zombie, R055 delivered but never opened (INVESTIGATE), R030 duplicate of a canonical (CONSOLIDATE), R040 regulatory obligation (MIGRATE), R050 personal space unshared, R060 low usage with no executive audience, R065 decaying, R070 personal analysis (SELF_SERVICE), R080 rebuild on a certified dataset, R090 convert (MIGRATE). ' ||
 '3. Zombie and broken rules skip regulatory assets, so the register protects obligations; delivered-but-unread runs before consolidation so an e-mailed report is never folded away without asking its recipients. ' ||
 '4. A named reviewer ACCEPTs, OVERRIDEs or DEFERs; the final disposition is the review decision, else the recommendation. ' ||
 '5. Effort under the final disposition and as-is uses the SCORING_POLICY band rates (KPI-007, KPI-008). ' ||
 '6. Surviving assets are grouped by subject area, ordered by executive audience, readers and obligations, and cut into four waves of roughly equal effort; wave 0 is the shared foundation.',
 'zombie: no view in 365 days and no subscription; low usage: <= 5 views and <= 2 viewers in 90 days; decay ratio < 0.35; self-service owner share >= 0.80; complexity bands S < 10, M < 25, L < 45 points; effort S 6 h, M 16 h, L 40 h, XL 80 h, rebuild x1.5, validation +25%',
 'RATIONALIZATION.SCORING_POLICY, DISPOSITION_RULE, SP_RUN_RATIONALIZATION, DISPOSITION_REVIEW, V_FINAL_DISPOSITION, WAVE_PLAN','BI Program Office','CERTIFIED',2,'2026-07-15',
 'Usage logs cannot see inbox reading, exports or embedded consumption; that is why R055 exists and why RETIRE is a recommendation until an owner is notified (REF-24). All time windows run to the extract date (2026-08-15). Effort band rates are TO CONFIRM.'),
('MTH-02','Duplicate detection and canonical selection','Program Office',
 'Find the assets that answer the same question across platforms and pick the one to keep.',
 '1. Build a signature per asset: the conformed entities it reads and the calculated measures it names. ' ||
 '2. Normalize titles into a title key: lower-case, strip copy/version/draft/test/final words, years and standalone numbers, and audience suffixes (- Exec Summary, - Ops Huddle, by ...). ' ||
 '3. Candidate pairs, blocked on subject area: the same or a near-identical title key (Jaro-Winkler >= 94) AND at least one shared conformed entity; OR a signature of at least three items with Jaccard >= 0.85 AND a related title (Jaro-Winkler >= 86). Generic titles (untitled, sheet1, ad hoc) never match on title. ' ||
 '4. Join pairs into clusters by label propagation, so A~B and B~C puts A and C together. ' ||
 '5. Canonical = certified first, then not in a personal or sandbox space, then most read in 365 days, most viewers, most recently modified. Every other member is a CONSOLIDATE candidate into the canonical (rule R030).',
 'cluster size >= 2; title match needs Jaro-Winkler >= 94 plus a shared entity (v2); content match needs signature Jaccard >= 0.85 and title Jaro-Winkler >= 86',
 'CONFORMED.ASSET_SIGNATURE, DUPLICATE_PAIR, DUPLICATE_CLUSTER, DUPLICATE_CLUSTER_MEMBER, V_DUPLICATE_CLUSTER_SUMMARY','BI Program Office','CERTIFIED',2,'2026-07-01',
 'Structural similarity is not semantic identity: two reports on the same entities with the same measure names can filter differently. The consolidation note to the owner asks what the duplicate does that the canonical does not.'),
('MTH-03','Target model derivation and build order','Migration Engineering',
 'Derive the future-state model from what survives, not from what exists, and order the build by what it unblocks.',
 '1. Trace every surviving asset''s lineage to conformed entities and attributes (source column -> attribute key). ' ||
 '2. An entity exists in the target model if a surviving asset reads it; attributes are the union of what surviving assets read. ' ||
 '3. Entities used by two or more subject areas are shared and go to wave 0 (the foundation); others go to the first wave that needs them. ' ||
 '4. Map each source column: MAPPED, HOSTED_VENDOR, SOURCE_DECOMMISSIONED or SPREADSHEET (KPI-018). ' ||
 '5. Group calculated measures by normalized name into metrics; count distinct definitions (variants) and flag CONFLICTING when the dominant one covers under 80% (KPI-011). The AI proposer writes a PROPOSED canonical per conflicting metric; only a named owner certifies (KPI-012). ' ||
 '6. Build order = wave, then shared first, then most surviving assets unblocked (KPI-010). Generate DDL, dbt model and schema.yml per entity.',
 'shared: used by >= 2 subject areas; conflicting: dominant definition share < 0.80; metric must be computed by >= 2 assets',
 'TARGET_MODEL.ENTITY, ENTITY_ATTRIBUTE, METRIC, METRIC_VARIANT, METRIC_RESOLUTION, V_BUILD_BACKLOG, V_SOURCE_TO_TARGET_MAP, GENERATED_ARTIFACT','Data Platform Lead','CERTIFIED',1,'2026-06-01',
 'Lineage-derived: anything no surviving report reads is not modeled. MedeAnalytics lineage stops at the vendor domain column. Build hours per entity are indicative, TO CONFIRM.'),
('MTH-04','Expression conversion and readiness','Migration Engineering',
 'Translate every calculated field on converting assets into a Sigma formula, say how sure we are, and never present a draft as final.',
 '1. Classify each expression (SIMPLE, STRING, LOD, TABLE_CALC, TIME_INTEL, CONTEXT, ITERATOR, PARAMETER, RLS, EXTERNAL_SCRIPT, MERGED_DIM, VENDOR_DEFINED). ' ||
 '2. Apply the rule catalog for the source language (Tableau calc, DAX, BO formula, MedeAnalytics report builder) in priority order; each rule carries a confidence and may demand a human. ' ||
 '3. Handle IF/ELSEIF/CASE, SWITCH(TRUE()), DIVIDE and CALCULATE(agg, filters) in code. ' ||
 '4. Multiply confidences; halve for each unresolved token. Status: NEEDS_HUMAN if a rule demands it or confidence < 0.6; AUTO if confidence >= 0.85 and nothing unresolved; else NEEDS_REVIEW. ' ||
 '5. Send the lowest-confidence residual to Claude via CORTEX.COMPLETE with a JSON schema, restricted to the SIGMA_FUNCTION allow-list; it may resolve to AUTO or confirm requires_human with the modeling pattern named. It never writes FINAL_EXPRESSION. ' ||
 '6. Asset readiness: READY / REVIEW / BLOCKED from its fields (KPI-015); one workbook spec per asset.',
 'AUTO >= 0.85 confidence and no unresolved token; NEEDS_HUMAN < 0.60 or rule-flagged; residual batch 200 fields',
 'CONVERSION.CONVERSION_RULE, SIGMA_FUNCTION, SP_TRANSLATE_FIELDS, SP_AI_TRANSLATE, FIELD_CONVERSION, V_ASSET_CONVERSION_READINESS, WORKBOOK_SPEC','Analytics Engineering Lead','CERTIFIED',2,'2026-08-20',
 'Sigma function names follow Sigma''s documentation and are TO CONFIRM per release. Model output drifts run to run; the residual pass is a draft for a person. Constructs with no one-line equivalent get a modeling pattern (grouped child table, grouping-level total, Snowpark), not a forced formula.'),
('MTH-05','Reconciliation and acceptance','Migration Engineering',
 'Prove a converted asset shows the right number before anyone signs it off, and separate conversion defects from definition disagreements.',
 '1. For each converting asset that computes a certified metric, create a test: the legacy report''s value for the period against the certified target SQL on the TARGET mart. ' ||
 '2. Evaluate each certified target SQL once per run. ' ||
 '3. Variance = |target - source| / |source| x 100. ' ||
 '4. PASS if variance <= the metric''s materiality; otherwise DEFINITION_VARIANCE if the legacy report used a variant definition, FAIL if it used the certified one. ' ||
 '5. A named business owner signs off in ACCEPTANCE_SIGNOFF; the harness never signs.',
 'materiality 0.5% (money) to 2% (rates); period FY2026 Q4 (Apr-Jun 2026)',
 'CONVERSION.METRIC_TEST_TEMPLATE, TEST_CASE, SP_RUN_RECONCILIATION, TEST_RESULT, V_TEST_RESULT, V_TEST_SUMMARY, ACCEPTANCE_SIGNOFF','Analytics Engineering Lead','CERTIFIED',1,'2026-06-01',
 'In the demo the legacy source snapshot values are simulated from the certified value; the target side is genuinely evaluated. Only 8 certified metric templates are tested.'),
('MTH-06','Question certification','Shared',
 'Decide which questions the copilot answers from steward-verified SQL, and keep them honest as definitions change.',
 '1. A team proposes a question it asks repeatedly. ' ||
 '2. The steward writes the SQL against the semantic view using only certified KPIs, runs it, and checks the answer is plausible on the live data. ' ||
 '3. The question is recorded in QUESTION_CATALOG with its KPI ids, method, SQL and verifier, and added to the semantic view''s AI_VERIFIED_QUERIES; up to four per view are offered as onboarding questions. ' ||
 '4. Cortex Analyst reuses the verified SQL when a user''s question matches. ' ||
 '5. Any change to a KPI or method it depends on re-opens certification; the change log records it.',
 'n/a',
 'GOVERNANCE.QUESTION_CATALOG, AI.SV_BI_ESTATE and AI.SV_MIGRATION_DELIVERY (AI_VERIFIED_QUERIES)','BI Program Office','CERTIFIED',1,'2026-06-01',
 'Certification means the SQL answers the question as defined. It does not mean the question is the right one to ask, and it does not certify the estate''s business metrics (KPI-012).');

-- ---------------------------------------------------- question catalog ---
CREATE OR REPLACE TABLE GOVERNANCE.QUESTION_CATALOG (
    QUESTION_ID     TEXT PRIMARY KEY,
    TEAM            TEXT,
    QUESTION        TEXT,
    KPI_IDS         TEXT,
    METHOD_ID       TEXT,
    SEMANTIC_VIEW   TEXT,
    IS_ONBOARDING   BOOLEAN,
    STATUS          TEXT,
    VERIFIED_BY     TEXT,
    VERIFIED_AT     DATE,
    CERTIFIED_SQL   TEXT
);

INSERT INTO GOVERNANCE.QUESTION_CATALOG VALUES
('Q-PO-01','Program Office','What is the estimated effort avoided by rationalization compared to migrating everything as-is, by platform?','KPI-007, KPI-008, KPI-009','MTH-01','AI.SV_BI_ESTATE',TRUE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT PLATFORM, SUM(EFFORT_HOURS_IF_MIGRATED_AS_IS) AS EFFORT_HOURS_IF_MIGRATED_AS_IS, SUM(EFFORT_HOURS) AS EFFORT_HOURS_FINAL_DISPOSITION, SUM(EFFORT_HOURS_IF_MIGRATED_AS_IS) - SUM(EFFORT_HOURS) AS EFFORT_HOURS_AVOIDED, DIV0(SUM(EFFORT_HOURS_IF_MIGRATED_AS_IS) - SUM(EFFORT_HOURS), SUM(EFFORT_HOURS_IF_MIGRATED_AS_IS)) AS EFFORT_REDUCTION_PCT, RANK() OVER (ORDER BY EFFORT_REDUCTION_PCT DESC) AS RANK_BY_EFFORT_REDUCTION_PCT, SUM(SUM(EFFORT_HOURS_IF_MIGRATED_AS_IS)) OVER () AS GRAND_TOTAL_EFFORT_HOURS_IF_MIGRATED_AS_IS, SUM(SUM(EFFORT_HOURS)) OVER () AS GRAND_TOTAL_EFFORT_HOURS_FINAL_DISPOSITION, SUM(SUM(EFFORT_HOURS_IF_MIGRATED_AS_IS) - SUM(EFFORT_HOURS)) OVER () AS GRAND_TOTAL_EFFORT_HOURS_AVOIDED, DIV0(SUM(SUM(EFFORT_HOURS_IF_MIGRATED_AS_IS) - SUM(EFFORT_HOURS)) OVER (), SUM(SUM(EFFORT_HOURS_IF_MIGRATED_AS_IS)) OVER ()) AS GRAND_TOTAL_EFFORT_REDUCTION_PCT FROM RATIONALIZATION.V_FINAL_DISPOSITION GROUP BY PLATFORM ORDER BY EFFORT_HOURS_IF_MIGRATED_AS_IS DESC'),
('Q-PO-02','Program Office','How many assets get each final disposition, and how many views and effort hours do they carry?','KPI-001, KPI-002, KPI-003, KPI-004, KPI-007','MTH-01','AI.SV_BI_ESTATE',TRUE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT FINAL_DISPOSITION, COUNT(*) AS ASSET_COUNT, RANK() OVER (ORDER BY COUNT(*) DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY COUNT(*) DESC) = 1, '' (most)'', IFF(RANK() OVER (ORDER BY COUNT(*) DESC) = COUNT(*) OVER (), '' (fewest)'', '''')) AS RANK_BY_ASSET_COUNT, SUM(VIEWS_365) AS VIEWS_365, RANK() OVER (ORDER BY SUM(VIEWS_365) DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY SUM(VIEWS_365) DESC) = 1, '' (most)'', IFF(RANK() OVER (ORDER BY SUM(VIEWS_365) DESC) = COUNT(*) OVER (), '' (fewest)'', '''')) AS RANK_BY_VIEWS_365, DIV0(SUM(VIEWS_365), SUM(SUM(VIEWS_365)) OVER ()) AS ROW_SHARE_OF_ALL_VIEWS_365, SUM(EFFORT_HOURS) AS EFFORT_HOURS_FINAL_DISPOSITION, RANK() OVER (ORDER BY SUM(EFFORT_HOURS) DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY SUM(EFFORT_HOURS) DESC) = 1, '' (most)'', IFF(RANK() OVER (ORDER BY SUM(EFFORT_HOURS) DESC) = COUNT(*) OVER (), '' (fewest)'', '''')) AS RANK_BY_EFFORT_HOURS FROM RATIONALIZATION.V_FINAL_DISPOSITION GROUP BY FINAL_DISPOSITION ORDER BY ASSET_COUNT DESC'),
('Q-PO-03','Program Office','Which reports are delivered by subscription but never opened, and which departments own them?','KPI-002, KPI-005','MTH-01','AI.SV_BI_ESTATE',TRUE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT RANK() OVER (ORDER BY SUBSCRIPTION_COUNT DESC) AS RANK_BY_SUBSCRIPTIONS, ASSET_ID, TITLE, PLATFORM, OWNER_DEPARTMENT, SUBSCRIPTION_COUNT AS SUBSCRIPTIONS, VIEWS_90, COUNT(*) OVER () AS GRAND_TOTAL_DELIVERED_UNREAD_REPORTS FROM RATIONALIZATION.V_FINAL_DISPOSITION WHERE RULE_ID = ''R055'' ORDER BY SUBSCRIPTIONS DESC, TITLE, ASSET_ID LIMIT 20'),
('Q-PO-04','Program Office','Which are the ten largest duplicate clusters (ties included), and which report is canonical in each?','KPI-006','MTH-02','AI.SV_BI_ESTATE',TRUE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT CLUSTER_ID, CANONICAL_TITLE, CLUSTER_SIZE AS CLUSTER_MEMBERS, RANK() OVER (ORDER BY CLUSTER_SIZE DESC) || '' of '' || COUNT(*) OVER () || '' clusters'' AS RANK_BY_CLUSTER_MEMBERS FROM CONFORMED.V_DUPLICATE_CLUSTER_SUMMARY QUALIFY RANK() OVER (ORDER BY CLUSTER_SIZE DESC) <= 10 ORDER BY CLUSTER_MEMBERS DESC, CLUSTER_ID'),
('Q-PO-05','Program Office','How many assets did each disposition rule catch, in the order the rules run, and how many did reviewers override?','KPI-001','MTH-01','AI.SV_BI_ESTATE',FALSE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT PRIORITY AS RULE_PRIORITY, RULE_ID, RULE_NAME, DISPOSITION AS RECOMMENDED_DISPOSITION, ASSETS AS ASSETS_CAUGHT, OVERRIDDEN AS OVERRIDDEN_ASSETS, SUM(OVERRIDDEN) OVER () AS GRAND_TOTAL_OVERRIDDEN_ASSETS FROM RATIONALIZATION.V_RULE_HITS WHERE ASSETS > 0 ORDER BY RULE_PRIORITY'),
('Q-PO-06','Program Office','What does each migration wave carry — surviving assets, effort hours and views?','KPI-003, KPI-007, KPI-002','MTH-01','AI.SV_BI_ESTATE',FALSE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT WAVE_NO::INT AS WAVE, COUNT(*) AS SURVIVING_ASSETS, SUM(EFFORT_HOURS) AS EFFORT_HOURS_FINAL_DISPOSITION, SUM(VIEWS_365) AS VIEWS_365 FROM RATIONALIZATION.V_FINAL_DISPOSITION f JOIN RATIONALIZATION.V_ASSET_WAVE w USING (ASSET_ID) WHERE f.IS_SURVIVING GROUP BY 1 ORDER BY WAVE'),
('Q-PO-07','Program Office','How is the MedeAnalytics estate dispositioned, and which rules set it?','KPI-001, KPI-003','MTH-01','AI.SV_BI_ESTATE',FALSE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT FINAL_DISPOSITION, SUM(COUNT(*)) OVER (PARTITION BY FINAL_DISPOSITION) AS GROUP_TOTAL_DISPOSITION_ASSET_COUNT, RULE_ID, RULE_NAME, COUNT(*) AS RULE_ASSET_COUNT, SUM(COUNT(*)) OVER () AS GRAND_TOTAL_MEDEANALYTICS_ASSETS FROM RATIONALIZATION.V_FINAL_DISPOSITION WHERE PLATFORM = ''MEDEANALYTICS'' GROUP BY FINAL_DISPOSITION, RULE_ID, RULE_NAME ORDER BY GROUP_TOTAL_DISPOSITION_ASSET_COUNT DESC, FINAL_DISPOSITION, RULE_ASSET_COUNT DESC'),
('Q-PO-08','Program Office','Which ten departments own the most assets being retired, and how many views do those retired assets still have?','KPI-003, KPI-004','MTH-01','AI.SV_BI_ESTATE',FALSE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT RANK() OVER (ORDER BY COUNT_IF(FINAL_DISPOSITION = ''RETIRE'') DESC) AS RANK_BY_RETIRED_ASSETS, OWNER_DEPARTMENT, COUNT_IF(FINAL_DISPOSITION = ''RETIRE'') AS RETIRED_ASSETS, SUM(IFF(FINAL_DISPOSITION = ''RETIRE'', VIEWS_365, 0)) AS RETIRED_VIEWS_365 FROM RATIONALIZATION.V_FINAL_DISPOSITION GROUP BY OWNER_DEPARTMENT ORDER BY RETIRED_ASSETS DESC, OWNER_DEPARTMENT LIMIT 10'),
('Q-ME-01','Migration Engineering','Which target entities should the data team build first, and how many reports does each unblock?','KPI-010','MTH-03','AI.SV_MIGRATION_DELIVERY',TRUE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT BUILD_ORDER, ENTITY_NAME, WAVE_NO::INT AS ENTITY_WAVE, IS_SHARED, SOURCE_STATUS, ASSETS_UNBLOCKED AS REPORTS_UNBLOCKED, RANK() OVER (ORDER BY ASSETS_UNBLOCKED DESC) AS RANK_BY_REPORTS_UNBLOCKED, COUNT_IF(SOURCE_STATUS <> ''SOURCE_AVAILABLE'') OVER () AS ENTITIES_NEEDING_A_SOURCE_DECISION FROM TARGET_MODEL.V_BUILD_BACKLOG WHERE WAVE_NO = 0 ORDER BY BUILD_ORDER'),
('Q-ME-02','Migration Engineering','Which metrics have conflicting definitions across the estate, how many of their variants did the proposer judge divergent, and did it judge every variant exactly once?','KPI-011, KPI-012','MTH-03','AI.SV_MIGRATION_DELIVERY',TRUE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT METRIC_NAME, VARIANT_DEFINITIONS, DIVERGENT_VARIANTS, RANK() OVER (ORDER BY DIVERGENT_VARIANTS DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY DIVERGENT_VARIANTS DESC) = 1, '' (most)'', IFF(DIVERGENT_VARIANTS = MIN(DIVERGENT_VARIANTS) OVER (), '' (fewest)'', '''')) AS RANK_BY_DIVERGENT_VARIANTS, EQUIVALENT_VARIANTS, CASE WHEN DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS = VARIANT_DEFINITIONS THEN ''judged exactly once: '' || (DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS) || '' judgments for '' || VARIANT_DEFINITIONS || '' variants'' WHEN DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS > VARIANT_DEFINITIONS THEN ''judgments overlap: '' || (DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS) || '' judgments for '' || VARIANT_DEFINITIONS || '' variants ('' || (DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS - VARIANT_DEFINITIONS) || '' more than variants), so some variants were counted more than once'' ELSE ''not all judged: '' || (DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS) || '' judgments for '' || VARIANT_DEFINITIONS || '' variants, so at least '' || (VARIANT_DEFINITIONS - DIVERGENT_VARIANTS - EQUIVALENT_VARIANTS) || '' judged neither divergent nor equivalent'' END AS PROPOSER_JUDGMENT, COUNT_IF(DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS = VARIANT_DEFINITIONS) OVER () AS METRICS_JUDGED_EXACTLY_ONCE, COUNT_IF(DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS <> VARIANT_DEFINITIONS) OVER () AS METRICS_NOT_JUDGED_EXACTLY_ONCE, COUNT_IF(DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS > VARIANT_DEFINITIONS) OVER () AS METRICS_WITH_OVERLAPPING_JUDGMENTS, COUNT_IF(DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS < VARIANT_DEFINITIONS) OVER () AS METRICS_WITH_UNJUDGED_VARIANTS, RESOLUTION_STATUS FROM (SELECT METRIC_NAME, VARIANT_COUNT AS VARIANT_DEFINITIONS, DIVERGENT_COUNT AS DIVERGENT_VARIANTS, EQUIVALENT_COUNT AS EQUIVALENT_VARIANTS, RESOLUTION_STATUS FROM TARGET_MODEL.V_METRIC_RECONCILIATION WHERE DEFINITION_STATUS = ''CONFLICTING'') ORDER BY DIVERGENT_VARIANTS DESC, VARIANT_DEFINITIONS DESC, METRIC_NAME'),
('Q-ME-03','Migration Engineering','How much of the calculated-field conversion to Sigma is automatic, overall and by source language?','KPI-013, KPI-014','MTH-04','AI.SV_MIGRATION_DELIVERY',TRUE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT SOURCE_LANGUAGE, N_FIELDS AS FIELD_COUNT, N_AUTO AS AUTO_FIELDS, ROUND(100 * DIV0(N_AUTO, N_FIELDS), 1) AS AUTO_CONVERSION_PCT, RANK() OVER (ORDER BY DIV0(N_AUTO, N_FIELDS) DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY DIV0(N_AUTO, N_FIELDS) DESC) = 1, '' (highest)'', IFF(RANK() OVER (ORDER BY DIV0(N_AUTO, N_FIELDS) DESC) = COUNT(*) OVER (), '' (lowest)'', '''')) AS RANK_BY_AUTO_CONVERSION_PCT, N_FIELDS - N_AUTO AS NEEDS_REVIEW_OR_HUMAN_FIELDS, RANK() OVER (ORDER BY N_FIELDS - N_AUTO DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY N_FIELDS - N_AUTO DESC) = 1, '' (most)'', IFF(RANK() OVER (ORDER BY N_FIELDS - N_AUTO DESC) = COUNT(*) OVER (), '' (fewest)'', '''')) AS RANK_BY_NEEDS_REVIEW_OR_HUMAN_FIELDS, ROUND(100 * (MAX(DIV0(N_AUTO, N_FIELDS)) OVER () - MIN(DIV0(N_AUTO, N_FIELDS)) OVER ()), 1) AS AUTO_PCT_GAP_HIGHEST_MINUS_LOWEST_POINTS, SUM(N_FIELDS) OVER () AS GRAND_TOTAL_FIELD_COUNT, SUM(N_AUTO) OVER () AS GRAND_TOTAL_AUTO_FIELDS, ROUND(100 * DIV0(SUM(N_AUTO) OVER (), SUM(N_FIELDS) OVER ()), 1) AS GRAND_TOTAL_AUTO_CONVERSION_PCT, SUM(N_FIELDS - N_AUTO) OVER () AS GRAND_TOTAL_NEEDS_REVIEW_OR_HUMAN_FIELDS, ROUND(100 * DIV0(SUM(N_FIELDS - N_AUTO) OVER (), SUM(N_FIELDS) OVER ()), 1) AS GRAND_TOTAL_NEEDS_REVIEW_OR_HUMAN_PCT FROM (SELECT SOURCE_LANGUAGE, COUNT(*) AS N_FIELDS, COUNT_IF(STATUS = ''AUTO'') AS N_AUTO FROM CONVERSION.V_FIELD_CONVERSION GROUP BY SOURCE_LANGUAGE) ORDER BY AUTO_CONVERSION_PCT DESC'),
('Q-ME-04','Migration Engineering','What did the reconciliation tests find for each metric — pass, fail or definition variance?','KPI-016, KPI-017','MTH-05','AI.SV_MIGRATION_DELIVERY',TRUE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT METRIC_LABEL, TESTS AS TEST_COUNT, RANK() OVER (ORDER BY TESTS DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY TESTS DESC) = 1, '' (most)'', IFF(RANK() OVER (ORDER BY TESTS DESC) = COUNT(*) OVER (), '' (fewest)'', '''')) AS RANK_BY_TEST_COUNT, PASSED AS PASSED_TESTS, FAILED AS FAILED_TESTS, DEFINITION_VARIANCES AS DEFINITION_VARIANCE_TESTS, DIV0(PASSED, TESTS) AS PASS_RATE, RANK() OVER (ORDER BY PASS_RATE DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY PASS_RATE DESC) = 1, '' (highest)'', IFF(RANK() OVER (ORDER BY PASS_RATE DESC) = COUNT(*) OVER (), '' (lowest)'', '''')) AS RANK_BY_PASS_RATE, CASE WHEN DEFINITION_VARIANCES > PASSED AND DEFINITION_VARIANCES > FAILED THEN ''DEFINITION_VARIANCE'' WHEN PASSED > DEFINITION_VARIANCES AND PASSED > FAILED THEN ''PASS'' WHEN FAILED > PASSED AND FAILED > DEFINITION_VARIANCES THEN ''FAIL'' WHEN PASSED = DEFINITION_VARIANCES THEN ''TIE: PASS = DEFINITION_VARIANCE'' ELSE ''TIE'' END AS LARGEST_OUTCOME, COUNT_IF(DEFINITION_VARIANCES > PASSED AND DEFINITION_VARIANCES > FAILED) OVER () AS METRICS_WHERE_DEFINITION_VARIANCE_IS_LARGEST, COUNT_IF(NOT (DEFINITION_VARIANCES > PASSED AND DEFINITION_VARIANCES > FAILED)) OVER () AS METRICS_WHERE_DEFINITION_VARIANCE_IS_NOT_LARGEST, COUNT_IF(FAILED > 0) OVER () AS METRICS_WITH_A_FAILED_TEST FROM CONVERSION.V_TEST_SUMMARY ORDER BY PASS_RATE DESC, TEST_COUNT DESC'),
('Q-ME-05','Migration Engineering','How many assets in each wave are ready, in review or blocked for conversion?','KPI-015','MTH-04','AI.SV_MIGRATION_DELIVERY',FALSE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT WAVE_NO::INT AS WAVE, SUM(IFF(CONVERSION_STATUS = ''READY'', ASSETS, 0)) AS READY_ASSETS, SUM(IFF(CONVERSION_STATUS = ''REVIEW'', ASSETS, 0)) AS REVIEW_ASSETS, SUM(IFF(CONVERSION_STATUS = ''BLOCKED'', ASSETS, 0)) AS BLOCKED_ASSETS, SUM(ASSETS) AS WAVE_CONVERTING_ASSETS, DIV0(READY_ASSETS, WAVE_CONVERTING_ASSETS) AS READY_RATE FROM CONVERSION.V_READINESS_SUMMARY GROUP BY 1 ORDER BY WAVE'),
('Q-ME-06','Migration Engineering','Which constructs in wave 1 still need a human decision, and how many fields each?','KPI-014','MTH-04','AI.SV_MIGRATION_DELIVERY',FALSE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT f.COMPLEXITY_TAG, COUNT_IF(f.STATUS = ''NEEDS_HUMAN'') AS HUMAN_FIELDS, RANK() OVER (ORDER BY HUMAN_FIELDS DESC) AS RANK_BY_HUMAN_FIELDS FROM CONVERSION.V_FIELD_CONVERSION f JOIN RATIONALIZATION.V_ASSET_WAVE w ON w.ASSET_ID = f.ASSET_ID WHERE w.WAVE_NO = 1 GROUP BY 1 HAVING HUMAN_FIELDS > 0 ORDER BY HUMAN_FIELDS DESC, f.COMPLEXITY_TAG'),
('Q-ME-07','Migration Engineering','Which reconciliation test failed, on which report, and by how much against materiality?','KPI-016, KPI-017','MTH-05','AI.SV_MIGRATION_DELIVERY',FALSE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT TEST_ID, TITLE AS TEST_ASSET_TITLE, PLATFORM AS TEST_PLATFORM, METRIC_LABEL, PERIOD_LABEL, ROUND(VARIANCE_PCT, 4) AS VARIANCE_PCT, ROUND(MATERIALITY_PCT, 4) AS MATERIALITY_PCT, ROUND(VARIANCE_PCT - MATERIALITY_PCT, 4) AS VARIANCE_ABOVE_MATERIALITY_PCT_POINTS FROM CONVERSION.V_TEST_RESULT WHERE OUTCOME = ''FAIL'''),
('Q-ME-08','Migration Engineering','How many source columns need a decision before the target model can be built, and from which systems?','KPI-018','MTH-03','AI.SV_MIGRATION_DELIVERY',FALSE,'CERTIFIED','steward: Morgan Ellery','2026-09-25',
 'SELECT SPLIT_PART(MAPPING_STATUS, '' '', 1) AS MAPPING_CODE, COALESCE(SYSTEM_FAMILY, ''SharePoint spreadsheet'') AS SYSTEM_FAMILY, COUNT(*) AS COLUMNS_NEEDING_DECISION, SUM(COUNT(*)) OVER () AS GRAND_TOTAL_COLUMNS_NEEDING_DECISION FROM TARGET_MODEL.V_SOURCE_TO_TARGET_MAP WHERE SPLIT_PART(MAPPING_STATUS, '' '', 1) <> ''MAPPED'' GROUP BY 1, 2 ORDER BY COLUMNS_NEEDING_DECISION DESC, SYSTEM_FAMILY');

-- ------------------------------------------------------------ change log ---
CREATE OR REPLACE TABLE GOVERNANCE.DEFINITION_CHANGE_LOG (
    CHANGE_ID     TEXT PRIMARY KEY,
    OBJECT_ID     TEXT,
    CHANGED_AT    TIMESTAMP_NTZ,
    FROM_VERSION  NUMBER(3,0),
    TO_VERSION    NUMBER(3,0),
    CHANGE        TEXT,
    REASON        TEXT,
    SIGNED_BY     TEXT,
    REOPENED_QUESTIONS TEXT
);
INSERT INTO GOVERNANCE.DEFINITION_CHANGE_LOG VALUES
('CHG-0001','MTH-01','2026-07-15 10:20:00',1,2,'Rule R055 (delivered but never opened) moved from priority 55 to 25, ahead of R030 consolidation; KPI-003 and KPI-005 re-stated.',
 'Under v1 an e-mailed report with no logged views could be consolidated into a canonical before anyone asked its recipients, which silently breaks a delivery people rely on. Delivery is evidence of use that the view log cannot see.',
 'steward: Morgan Ellery','Q-PO-02, Q-PO-03, Q-PO-05'),
('CHG-0002','KPI-003','2026-07-15 10:25:00',1,2,'Survival rate excludes CONSOLIDATE; only MIGRATE, REBUILD and SELF_SERVICE survive.',
 'Under v1 consolidated members counted as surviving because their requirements survive in the canonical, so the canonical''s content was counted once per copy and the survival rate overstated what the target platform will hold.',
 'steward: Morgan Ellery','Q-PO-02, Q-PO-06, Q-PO-08'),
('CHG-0003','MTH-02','2026-07-01 14:05:00',1,2,'Title matches must also share a conformed entity, and standalone numbers are stripped from the title key.',
 'Under v1 unrelated drafts with generic titles ("Untitled 12", "Untitled 36") formed one large false cluster, and numbered copies of a real report did not match each other.',
 'steward: Morgan Ellery','Q-PO-04'),
('CHG-0004','KPI-014','2026-08-20 16:40:00',1,2,'MedeAnalytics vendor-defined measures classified NEEDS_HUMAN with "redefine on the certified dataset"; their assets route to REBUILD via R080 (MTH-04 v2).',
 'A hosted platform does not export its standard measure definitions, so no formula can be translated; v1 counted them as translation failures, which read as a defect in the converter rather than a decision the metric owner has to make.',
 'steward: Morgan Ellery','Q-ME-03, Q-ME-06, Q-PO-07');

SELECT 'definitions plane: '
    || (SELECT COUNT(*) FROM GOVERNANCE.KPI_DEFINITION)        || ' KPIs, '
    || (SELECT COUNT(*) FROM GOVERNANCE.METHOD_REGISTRY)       || ' methods, '
    || (SELECT COUNT(*) FROM GOVERNANCE.QUESTION_CATALOG)      || ' certified questions, '
    || (SELECT COUNT(*) FROM GOVERNANCE.DEFINITION_CHANGE_LOG) || ' changes' AS STATUS;
