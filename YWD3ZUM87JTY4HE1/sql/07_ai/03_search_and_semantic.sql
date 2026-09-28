-- =============================================================================
-- AI — Cortex Search services and the two semantic views
-- -----------------------------------------------------------------------------
-- Two audiences ask two kinds of question, so there are two semantic views:
--
--   SV_BI_ESTATE           the BI Program Office: what is in the estate, what
--                          each asset's disposition is and which rule set it,
--                          what the usage can and cannot see, duplicate
--                          clusters, effort, waves
--   SV_MIGRATION_DELIVERY  Migration Engineering (data team, analytics
--                          engineers, metric owners): the target-model build
--                          order, conflicting metric definitions, source
--                          columns needing a decision, calculated-field
--                          conversion, readiness, reconciliation tests
--
-- Every metric COMMENT ends with the certified KPI id it implements (and the
-- method id), from GOVERNANCE.KPI_DEFINITION (sql/06b_definitions). The
-- AI_VERIFIED_QUERIES are the certified questions in GOVERNANCE.QUESTION_CATALOG;
-- the ONBOARDING_QUESTION ones are what CoWork offers before anyone types.
--
-- This file is also re-run by the Setup Wizard (APP.PIPELINE_STEP 140), so it
-- is self-contained and idempotent.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE WAREHOUSE BI_MOD_WH;
USE SCHEMA AI;

-- The estate record carries its id in DOC_ID ('ASSET:TAB-…', 'CLUSTER:DUP-0006',
-- 'METRIC:MET-98F2B4', 'RULE:R055', 'TEST:TC-0106') and a TITLE for citations.
CREATE OR REPLACE CORTEX SEARCH SERVICE AI.ESTATE_RECORD_SEARCH
    ON DOC_TEXT
    ATTRIBUTES DOC_ID, DOC_KIND, SUBJECT, TITLE
    WAREHOUSE = BI_MOD_WH
    TARGET_LAG = '24 hours'
    COMMENT = 'The estate''s own record: every asset disposition with rule and evidence, duplicate clusters, metric conflicts, target entities, rules, policy, waves, regulatory obligations, conversion packets, reconciliation tests.'
AS SELECT DOC_TEXT, DOC_ID, DOC_KIND, SUBJECT, DOC_ID || ' — ' || SUBJECT AS TITLE FROM AI.ESTATE_RECORD_DOCS;

CREATE OR REPLACE CORTEX SEARCH SERVICE AI.MIGRATION_REFERENCE_SEARCH
    ON DOC_TEXT
    ATTRIBUTES DOC_ID, TITLE, TOPIC
    WAREHOUSE = BI_MOD_WH
    TARGET_LAG = '24 hours'
    COMMENT = 'The migration reference that ships with the accelerator: why usage lies, disposition vocabulary, duplicate detection, metric reconciliation, Tableau/DAX/BO/MedeAnalytics to Sigma guides, reconciliation, wave planning.'
AS SELECT DOC_TEXT, DOC_ID, TITLE, TOPIC FROM AI.MIGRATION_REFERENCE;

-- ============================================================ base views ===
-- Flags are 0/1 so a rate is a plain AVG and a count is a plain SUM.

-- One row per asset (2,800): disposition, rule, scores, usage, effort, wave.
CREATE OR REPLACE VIEW AI.ASSET_SEMANTIC_BASE AS
SELECT f.ASSET_ID, f.PLATFORM, f.ASSET_KIND, f.TITLE, f.OWNER_DEPARTMENT, COALESCE(f.SUBJECT_AREA, 'Unknown') AS SUBJECT_AREA,
       f.RECOMMENDED_DISPOSITION, f.FINAL_DISPOSITION, f.RULE_ID, f.RULE_NAME, dr.PRIORITY AS RULE_PRIORITY, f.CONFIDENCE, f.REVIEW_STATUS,
       f.IS_SURVIVING, f.IS_REGULATORY, f.HAS_DECOMMISSIONED_SOURCE, f.CLUSTER_ID IS NOT NULL AS IS_IN_DUPLICATE_CLUSTER, f.IS_CLUSTER_CANONICAL,
       f.CLUSTER_ID AS ASSET_CLUSTER_ID,
       f.SUBSCRIPTION_COUNT > 0 AS HAS_SUBSCRIPTIONS,
       f.COMPLEXITY_BAND, f.COMPLEXITY_POINTS, f.USAGE_SCORE, f.CRITICALITY_SCORE, f.DATA_HEALTH_SCORE,
       f.VIEWS_90, f.VIEWS_365, f.VIEWERS_90, f.EXEC_VIEWERS_365, f.DAYS_SINCE_LAST_VIEW, f.SUBSCRIPTION_COUNT,
       f.EFFORT_HOURS, f.EFFORT_HOURS_IF_MIGRATED_AS_IS,
       w.WAVE_NO,
       r.CONVERSION_STATUS, r.CALC_FIELDS, r.AUTO_FIELDS, r.HUMAN_FIELDS,
       a.IS_PERSONAL_SPACE, a.IS_CERTIFIED, a.CREATED_AT::DATE AS CREATED_DATE, a.MODIFIED_AT::DATE AS MODIFIED_DATE,
       1 AS ASSET_COUNT,
       IFF(f.IS_SURVIVING, 1, 0)                                   AS SURVIVING_FLAG,
       IFF(f.FINAL_DISPOSITION = 'RETIRE', 1, 0)                   AS RETIRE_FLAG,
       IFF(f.FINAL_DISPOSITION = 'RETIRE', f.VIEWS_365, 0)         AS RETIRED_VIEWS_365,
       IFF(f.SUBSCRIPTION_COUNT > 0 AND f.VIEWS_90 = 0, 1, 0)      AS DELIVERED_UNREAD_FLAG,
       IFF(f.CLUSTER_ID IS NOT NULL, 1, 0)                         AS IN_CLUSTER_FLAG,
       IFF(f.IS_REGULATORY, 1, 0)                                  AS REGULATORY_FLAG,
       IFF(f.REVIEW_STATUS = 'OVERRIDE', 1, 0)                     AS OVERRIDDEN_FLAG,
       IFF(f.REVIEW_STATUS <> 'PENDING', 1, 0)                     AS REVIEWED_FLAG
FROM RATIONALIZATION.V_FINAL_DISPOSITION f
JOIN CONFORMED.ASSET a ON a.ASSET_ID = f.ASSET_ID
JOIN RATIONALIZATION.DISPOSITION_RULE dr ON dr.RULE_ID = f.RULE_ID
LEFT JOIN RATIONALIZATION.V_ASSET_WAVE w ON w.ASSET_ID = f.ASSET_ID
LEFT JOIN CONVERSION.V_ASSET_CONVERSION_READINESS r ON r.ASSET_ID = f.ASSET_ID;

-- One row per calculated field sent to conversion (2,332 on MIGRATE, REBUILD
-- and INVESTIGATE assets), with the asset's disposition and wave.
CREATE OR REPLACE VIEW AI.FIELD_SEMANTIC_BASE AS
SELECT v.FIELD_ID, v.ASSET_ID, v.ASSET_TITLE, v.PLATFORM, v.FIELD_NAME, v.SOURCE_LANGUAGE, v.COMPLEXITY_TAG,
       v.STATUS AS CONVERSION_FIELD_STATUS, v.METHOD AS CONVERSION_METHOD, v.CONFIDENCE AS FIELD_CONFIDENCE,
       v.SOURCE_EXPRESSION, v.EFFECTIVE_EXPRESSION AS SIGMA_EXPRESSION, v.NOTES AS CONVERSION_NOTES, v.AI_RATIONALE,
       d.FINAL_DISPOSITION AS ASSET_DISPOSITION, COALESCE(d.SUBJECT_AREA, 'Unknown') AS FIELD_SUBJECT_AREA, w.WAVE_NO AS FIELD_WAVE_NO,
       IFF(v.STATUS = 'AUTO', 1, 0)          AS AUTO_FLAG,
       IFF(v.STATUS = 'NEEDS_REVIEW', 1, 0)  AS REVIEW_FLAG,
       IFF(v.STATUS = 'NEEDS_HUMAN', 1, 0)   AS HUMAN_FLAG,
       IFF(v.MODEL_USED IS NOT NULL, 1, 0)   AS AI_ASSISTED_FLAG
FROM CONVERSION.V_FIELD_CONVERSION v
JOIN RATIONALIZATION.V_FINAL_DISPOSITION d ON d.ASSET_ID = v.ASSET_ID
LEFT JOIN RATIONALIZATION.V_ASSET_WAVE w ON w.ASSET_ID = v.ASSET_ID;

-- One row per named metric (42) with its reconciliation state.
CREATE OR REPLACE VIEW AI.METRIC_SEMANTIC_BASE AS
SELECT METRIC_ID, METRIC_NAME, PRIMARY_ENTITY, DEFINITION_STATUS, COALESCE(RESOLUTION_STATUS, 'NONE') AS RESOLUTION_STATUS,
       VARIANT_COUNT, EQUIVALENT_COUNT, DIVERGENT_COUNT, ASSET_COUNT AS METRIC_ASSETS, VIEWS_365 AS METRIC_VIEWS_365,
       LANGUAGES, DOMINANT_LANGUAGE, DOMINANT_SHARE_PCT, CANONICAL_NAME,
       IFF(DEFINITION_STATUS = 'CONFLICTING', 1, 0)   AS CONFLICTING_FLAG,
       IFF(RESOLUTION_STATUS = 'CERTIFIED', 1, 0)     AS CERTIFIED_FLAG
FROM TARGET_MODEL.V_METRIC_RECONCILIATION;

-- One row per reconciliation test in the latest run (120).
CREATE OR REPLACE VIEW AI.TEST_SEMANTIC_BASE AS
SELECT TEST_ID, ASSET_ID, TITLE AS TEST_ASSET_TITLE, PLATFORM AS TEST_PLATFORM, METRIC_LABEL, PERIOD_LABEL, OUTCOME,
       USES_CERTIFIED_DEFINITION, TARGET_VALUE, SOURCE_VALUE, VARIANCE_PCT, MATERIALITY_PCT, SNAPSHOT_NOTE,
       IFF(OUTCOME = 'PASS', 1, 0)                 AS PASS_FLAG,
       IFF(OUTCOME = 'FAIL', 1, 0)                 AS FAIL_FLAG,
       IFF(OUTCOME = 'DEFINITION_VARIANCE', 1, 0)  AS VARIANCE_FLAG
FROM CONVERSION.V_TEST_RESULT;

-- One row per source column traced from surviving lineage (728).
CREATE OR REPLACE VIEW AI.SOURCE_SEMANTIC_BASE AS
SELECT SOURCE_COLUMN, ENTITY_NAME AS SOURCE_ENTITY_NAME, ATTRIBUTE_NAME, SOURCE_DATABASE,
       COALESCE(SYSTEM_FAMILY, 'SharePoint spreadsheet') AS SYSTEM_FAMILY,
       SPLIT_PART(MAPPING_STATUS, ' ', 1) AS MAPPING_CODE, MAPPING_STATUS AS MAPPING_GUIDANCE,
       REFERENCING_ASSETS, FIRST_WAVE_NEEDED AS SOURCE_WAVE_NO,
       IFF(SPLIT_PART(MAPPING_STATUS, ' ', 1) <> 'MAPPED', 1, 0) AS NEEDS_DECISION_FLAG
FROM TARGET_MODEL.V_SOURCE_TO_TARGET_MAP;

-- One row per target entity (52) with its build order.
CREATE OR REPLACE VIEW AI.ENTITY_SEMANTIC_BASE AS
SELECT BUILD_ORDER, WAVE_NO AS ENTITY_WAVE_NO, ENTITY_NAME, ENTITY_ROLE, SUBJECT_AREA AS ENTITY_SUBJECT_AREA, GRAIN, IS_SHARED,
       ASSETS_UNBLOCKED, EXEC_ASSETS, REGULATORY_ASSETS, ATTRIBUTES, METRICS AS ENTITY_METRICS, CONFLICTING_METRICS AS ENTITY_CONFLICTING_METRICS,
       SOURCE_TABLES, SOURCE_STATUS, BUILD_HOURS_INDICATIVE
FROM TARGET_MODEL.V_BUILD_BACKLOG;

-- One row per MIGRATE/REBUILD asset (514) with its conversion readiness.
CREATE OR REPLACE VIEW AI.READINESS_SEMANTIC_BASE AS
SELECT ASSET_ID AS READY_ASSET_ID, TITLE AS READY_TITLE, PLATFORM AS READY_PLATFORM, FINAL_DISPOSITION AS READY_DISPOSITION,
       COALESCE(SUBJECT_AREA, 'Unknown') AS READY_SUBJECT_AREA, WAVE_NO AS READY_WAVE_NO, COMPLEXITY_BAND AS READY_COMPLEXITY_BAND,
       CONVERSION_STATUS AS READINESS_STATUS, AUTO_PCT, ENTITIES_WITHOUT_SOURCE,
       IFF(CONVERSION_STATUS = 'READY', 1, 0)   AS READY_FLAG,
       IFF(CONVERSION_STATUS = 'BLOCKED', 1, 0) AS BLOCKED_FLAG
FROM CONVERSION.V_ASSET_CONVERSION_READINESS;

-- ---------------------------------------------------------------------
-- SV_BI_ESTATE — the BI Program Office view
-- ---------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW AI.SV_BI_ESTATE
    TABLES (
        assets AS AI.ASSET_SEMANTIC_BASE PRIMARY KEY (ASSET_ID)
            WITH SYNONYMS = ('reports', 'dashboards', 'workbooks', 'BI estate', 'BI assets', 'inventory')
            COMMENT = 'One row per BI asset (Tableau workbook, Power BI report, SAP BusinessObjects document, MedeAnalytics report or dashboard) with its rationalization disposition, the rule that set it, scores, usage, delivery, effort, wave and conversion readiness. Extract date 2026-08-15',
        clusters AS CONFORMED.V_DUPLICATE_CLUSTER_SUMMARY PRIMARY KEY (CLUSTER_ID)
            WITH SYNONYMS = ('duplicate clusters', 'duplicate groups', 'copies', 'versions of the same report')
            COMMENT = 'One row per duplicate cluster found by MTH-02: size, platforms, the canonical asset every other member consolidates into, views and dead members'
    )
    DIMENSIONS (
        assets.asset_id AS ASSET_ID COMMENT = 'Asset identifier, e.g. TAB-…, PBI-…, BO-…, MEDE-…',
        assets.platform AS PLATFORM WITH SYNONYMS = ('BI tool', 'source platform', 'tool') COMMENT = 'TABLEAU, POWER_BI, SAP_BO or MEDEANALYTICS',
        assets.asset_kind AS ASSET_KIND COMMENT = 'WORKBOOK, REPORT, PAGINATED_REPORT, DASHBOARD, WEBI_DOCUMENT or CRYSTAL_REPORT',
        assets.title AS TITLE WITH SYNONYMS = ('report name', 'asset name', 'dashboard name') COMMENT = 'Asset title as it appears in the source platform',
        assets.owner_department AS OWNER_DEPARTMENT WITH SYNONYMS = ('department', 'owning department', 'business owner') COMMENT = 'Department of the owner per the HR directory',
        assets.subject_area AS SUBJECT_AREA WITH SYNONYMS = ('domain', 'business area') COMMENT = 'Business subject area derived from the source tables the asset reads, e.g. Revenue Cycle, Encounters & Access, Health Plan Claims',
        assets.recommended_disposition AS RECOMMENDED_DISPOSITION COMMENT = 'What the rule engine recommended (MTH-01): RETIRE, CONSOLIDATE, MIGRATE, REBUILD, SELF_SERVICE, INVESTIGATE',
        assets.final_disposition AS FINAL_DISPOSITION WITH SYNONYMS = ('disposition', 'decision', 'outcome') COMMENT = 'The recommendation after human review (equals the recommendation while review is pending): RETIRE, CONSOLIDATE, MIGRATE, REBUILD, SELF_SERVICE, INVESTIGATE',
        assets.rule_id AS RULE_ID WITH SYNONYMS = ('rule') COMMENT = 'The rule that assigned the recommendation, e.g. R020 Zombie, R055 Delivered but never opened, R030 Duplicate',
        assets.rule_name AS RULE_NAME COMMENT = 'Rule name, e.g. Zombie, Delivered but never opened, Duplicate of a canonical asset',
        assets.rule_priority AS RULE_PRIORITY COMMENT = 'Order the rule is evaluated in (first match wins, MTH-01); R055 runs at 25, before consolidation at 30',
        assets.confidence AS CONFIDENCE COMMENT = 'HIGH or MEDIUM confidence of the rule',
        assets.review_status AS REVIEW_STATUS WITH SYNONYMS = ('review decision') COMMENT = 'PENDING, ACCEPT, OVERRIDE or DEFER — the human review gate',
        assets.is_surviving AS IS_SURVIVING COMMENT = 'TRUE when the final disposition is MIGRATE, REBUILD or SELF_SERVICE (KPI-003)',
        assets.is_regulatory AS IS_REGULATORY COMMENT = 'Matches an obligation in the regulatory register (protected from retirement)',
        assets.has_decommissioned_source AS HAS_DECOMMISSIONED_SOURCE COMMENT = 'Reads at least one decommissioned source system',
        assets.is_in_duplicate_cluster AS IS_IN_DUPLICATE_CLUSTER COMMENT = 'Member of a duplicate cluster (KPI-006)',
        assets.is_cluster_canonical AS IS_CLUSTER_CANONICAL COMMENT = 'The canonical member of its cluster',
        assets.asset_cluster_id AS ASSET_CLUSTER_ID COMMENT = 'The duplicate cluster the asset belongs to, e.g. DUP-0006; NULL when not clustered',
        assets.has_subscriptions AS HAS_SUBSCRIPTIONS COMMENT = 'TRUE when the asset is delivered by subscription or schedule (read without a logged view)',
        assets.complexity_band AS COMPLEXITY_BAND COMMENT = 'S, M, L or XL',
        assets.wave_no AS WAVE_NO WITH SYNONYMS = ('wave', 'migration wave') COMMENT = 'Migration wave 1-4 for surviving assets; NULL for assets that do not migrate',
        assets.conversion_status AS CONVERSION_STATUS COMMENT = 'READY, REVIEW or BLOCKED (KPI-015); NULL when not converting',
        assets.is_personal_space AS IS_PERSONAL_SPACE COMMENT = 'Lives in a personal project/workspace/favorites folder',
        assets.is_certified AS IS_CERTIFIED COMMENT = 'Certified / endorsed in the source platform',
        assets.days_since_last_view AS DAYS_SINCE_LAST_VIEW COMMENT = 'Days from the last interactive view to the extract date; 9999 = never viewed in the window',
        assets.views_90_raw AS VIEWS_90 COMMENT = 'Raw interactive views in the last 90 days for one asset (use the metric total_views_90 to aggregate)',
        assets.subscriptions_raw AS SUBSCRIPTION_COUNT COMMENT = 'Raw subscription / scheduled-recipient count for one asset (use total_subscriptions to aggregate)',
        assets.created_date AS CREATED_DATE COMMENT = 'Created date',
        assets.modified_date AS MODIFIED_DATE COMMENT = 'Last modified date',
        clusters.cluster_id AS clusters.CLUSTER_ID COMMENT = 'Duplicate cluster id, e.g. DUP-0006',
        clusters.canonical_title AS CANONICAL_TITLE WITH SYNONYMS = ('canonical report', 'surviving copy') COMMENT = 'Title of the canonical asset the rest of the cluster consolidates into',
        clusters.canonical_asset_id AS CANONICAL_ASSET_ID COMMENT = 'Asset id of the canonical member',
        clusters.cluster_platforms AS clusters.PLATFORMS COMMENT = 'Platforms represented in the cluster, e.g. TABLEAU, SAP_BO, POWER_BI',
        clusters.cluster_platform_count AS clusters.PLATFORM_COUNT COMMENT = 'Number of platforms in the cluster; above 1 = cross-platform',
        clusters.cluster_subject_area AS clusters.SUBJECT_AREA COMMENT = 'Subject area of the cluster'
    )
    METRICS (
        assets.asset_count AS SUM(assets.ASSET_COUNT) WITH SYNONYMS = ('number of assets', 'number of reports', 'how many reports') COMMENT = 'Number of BI assets (KPI-001)',
        assets.surviving_assets AS SUM(assets.SURVIVING_FLAG) WITH SYNONYMS = ('survivors', 'assets that migrate') COMMENT = 'Assets whose final disposition is MIGRATE, REBUILD or SELF_SERVICE (KPI-003, MTH-01)',
        assets.survival_rate AS AVG(assets.SURVIVING_FLAG) WITH SYNONYMS = ('share that survives') COMMENT = 'Share of assets that survive, 0 to 1 (KPI-003, MTH-01)',
        assets.retired_assets AS SUM(assets.RETIRE_FLAG) COMMENT = 'Assets whose final disposition is RETIRE (KPI-003 complement, MTH-01)',
        assets.total_views_90 AS SUM(assets.VIEWS_90) COMMENT = 'Interactive views in the last 90 days; excludes subscription and scheduled delivery (KPI-002)',
        assets.total_views_365 AS SUM(assets.VIEWS_365) WITH SYNONYMS = ('views', 'usage', 'views last year') COMMENT = 'Interactive views in the last 365 days; excludes subscription and scheduled delivery (KPI-002)',
        assets.retired_views_365 AS SUM(assets.RETIRED_VIEWS_365) COMMENT = 'Interactive views in the last 365 days carried by assets that RETIRE (KPI-004)',
        assets.retirement_view_share AS DIV0(assets.retired_views_365, assets.total_views_365) WITH SYNONYMS = ('views lost to retirement') COMMENT = 'Share of 365-day views carried by retired assets, 0 to 1 (KPI-004, MTH-01)',
        assets.delivered_unread_assets AS SUM(assets.DELIVERED_UNREAD_FLAG) WITH SYNONYMS = ('emailed but never opened', 'subscription only reports') COMMENT = 'Assets with a subscription or schedule and no interactive view in 90 days (KPI-005, MTH-01 rule R055)',
        assets.clustered_assets AS SUM(assets.IN_CLUSTER_FLAG) COMMENT = 'Assets that belong to a duplicate cluster (KPI-006, MTH-02)',
        assets.regulatory_assets AS SUM(assets.REGULATORY_FLAG) COMMENT = 'Assets matching the regulatory register (MTH-01 rule R040)',
        assets.overridden_assets AS SUM(assets.OVERRIDDEN_FLAG) WITH SYNONYMS = ('overrides') COMMENT = 'Assets whose recommendation a named reviewer overrode (MTH-01 review gate)',
        assets.reviewed_assets AS SUM(assets.REVIEWED_FLAG) COMMENT = 'Assets with a recorded human review decision (MTH-01 review gate)',
        assets.total_effort_hours AS SUM(assets.EFFORT_HOURS) WITH SYNONYMS = ('effort', 'hours after rationalization') COMMENT = 'Indicative migration effort in hours under the final disposition; band-rate estimate TO CONFIRM (KPI-007, DRAFT, MTH-01)',
        assets.effort_if_migrated_as_is AS SUM(assets.EFFORT_HOURS_IF_MIGRATED_AS_IS) WITH SYNONYMS = ('as-is hours', 'lift and shift hours') COMMENT = 'Indicative hours if every asset were converted as-is with no rationalization (KPI-008, DRAFT, MTH-01)',
        assets.effort_hours_avoided AS assets.effort_if_migrated_as_is - assets.total_effort_hours WITH SYNONYMS = ('estimated effort avoided') COMMENT = 'Estimated effort avoided: as-is hours minus hours under the final disposition — a difference between two estimates, not a saving (KPI-009, DRAFT, MTH-01)',
        assets.effort_reduction_pct AS DIV0(assets.effort_if_migrated_as_is - assets.total_effort_hours, assets.effort_if_migrated_as_is) WITH SYNONYMS = ('effort reduction') COMMENT = 'Share of as-is effort avoided by rationalization, 0 to 1 — a ratio of two estimates (KPI-009, DRAFT, MTH-01)',
        assets.total_subscriptions AS SUM(assets.SUBSCRIPTION_COUNT) WITH SYNONYMS = ('subscribers', 'scheduled recipients') COMMENT = 'Subscriptions and scheduled recipients (KPI-005 context)',
        assets.avg_usage_score AS AVG(assets.USAGE_SCORE) COMMENT = 'Average usage score 0-100 (MTH-01)',
        assets.avg_criticality AS AVG(assets.CRITICALITY_SCORE) COMMENT = 'Average criticality score 0-100 (MTH-01)',
        assets.avg_complexity_points AS AVG(assets.COMPLEXITY_POINTS) COMMENT = 'Average complexity points (MTH-01)',
        assets.avg_data_health AS AVG(assets.DATA_HEALTH_SCORE) COMMENT = 'Average data health 0-100 (MTH-01)',
        clusters.cluster_count AS COUNT(clusters.CLUSTER_ID) WITH SYNONYMS = ('number of clusters', 'duplicate sets') COMMENT = 'Number of duplicate clusters (KPI-006, MTH-02)',
        clusters.cluster_members AS SUM(clusters.CLUSTER_SIZE) WITH SYNONYMS = ('cluster size', 'copies in cluster') COMMENT = 'Assets in the clusters, canonical included (KPI-006, MTH-02)',
        clusters.cluster_views_365 AS SUM(clusters.CLUSTER_VIEWS_365) COMMENT = 'Interactive views in 365 days across the cluster members (KPI-002)',
        clusters.cluster_dead_members AS SUM(clusters.DEAD_MEMBERS) COMMENT = 'Cluster members with no interactive view in the zombie window (MTH-02)',
        clusters.avg_canonical_view_share AS AVG(clusters.CANONICAL_VIEW_SHARE) COMMENT = 'Share of a cluster''s views carried by its canonical member (MTH-02)'
    )
    COMMENT = 'BI estate rationalization for Ridgeline Health (synthetic), for the BI Program Office: assets, dispositions and the rules that set them, usage and delivery, duplicate clusters, effort, waves. Every metric cites the KPI id it implements.'
    AI_VERIFIED_QUERIES (
        vq_po_01 AS (
            QUESTION 'What is the estimated effort avoided by rationalization compared to migrating everything as-is, by platform?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION TRUE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT PLATFORM, EFFORT_IF_MIGRATED_AS_IS AS EFFORT_HOURS_IF_MIGRATED_AS_IS, TOTAL_EFFORT_HOURS AS EFFORT_HOURS_FINAL_DISPOSITION, EFFORT_HOURS_AVOIDED, EFFORT_REDUCTION_PCT, RANK() OVER (ORDER BY EFFORT_REDUCTION_PCT DESC) AS RANK_BY_EFFORT_REDUCTION_PCT, SUM(EFFORT_IF_MIGRATED_AS_IS) OVER () AS GRAND_TOTAL_EFFORT_HOURS_IF_MIGRATED_AS_IS, SUM(TOTAL_EFFORT_HOURS) OVER () AS GRAND_TOTAL_EFFORT_HOURS_FINAL_DISPOSITION, SUM(EFFORT_HOURS_AVOIDED) OVER () AS GRAND_TOTAL_EFFORT_HOURS_AVOIDED, DIV0(SUM(EFFORT_HOURS_AVOIDED) OVER (), SUM(EFFORT_IF_MIGRATED_AS_IS) OVER ()) AS GRAND_TOTAL_EFFORT_REDUCTION_PCT FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_BI_ESTATE METRICS assets.effort_if_migrated_as_is, assets.total_effort_hours, assets.effort_hours_avoided, assets.effort_reduction_pct DIMENSIONS assets.platform) ORDER BY EFFORT_HOURS_IF_MIGRATED_AS_IS DESC'
        ),
        vq_po_02 AS (
            QUESTION 'How many assets get each final disposition, and how many views and effort hours do they carry?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION TRUE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT FINAL_DISPOSITION, ASSET_COUNT, RANK() OVER (ORDER BY ASSET_COUNT DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY ASSET_COUNT DESC) = 1, '' (most)'', IFF(RANK() OVER (ORDER BY ASSET_COUNT DESC) = COUNT(*) OVER (), '' (fewest)'', '''')) AS RANK_BY_ASSET_COUNT, TOTAL_VIEWS_365 AS VIEWS_365, RANK() OVER (ORDER BY TOTAL_VIEWS_365 DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY TOTAL_VIEWS_365 DESC) = 1, '' (most)'', IFF(RANK() OVER (ORDER BY TOTAL_VIEWS_365 DESC) = COUNT(*) OVER (), '' (fewest)'', '''')) AS RANK_BY_VIEWS_365, DIV0(TOTAL_VIEWS_365, SUM(TOTAL_VIEWS_365) OVER ()) AS ROW_SHARE_OF_ALL_VIEWS_365, TOTAL_EFFORT_HOURS AS EFFORT_HOURS_FINAL_DISPOSITION, RANK() OVER (ORDER BY TOTAL_EFFORT_HOURS DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY TOTAL_EFFORT_HOURS DESC) = 1, '' (most)'', IFF(RANK() OVER (ORDER BY TOTAL_EFFORT_HOURS DESC) = COUNT(*) OVER (), '' (fewest)'', '''')) AS RANK_BY_EFFORT_HOURS FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_BI_ESTATE METRICS assets.asset_count, assets.total_views_365, assets.total_effort_hours DIMENSIONS assets.final_disposition) ORDER BY ASSET_COUNT DESC'
        ),
        vq_po_03 AS (
            QUESTION 'Which reports are delivered by subscription but never opened, and which departments own them?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION TRUE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT RANK() OVER (ORDER BY TOTAL_SUBSCRIPTIONS DESC) AS RANK_BY_SUBSCRIPTIONS, ASSET_ID, TITLE, PLATFORM, OWNER_DEPARTMENT, TOTAL_SUBSCRIPTIONS AS SUBSCRIPTIONS, TOTAL_VIEWS_90 AS VIEWS_90, SUM(ASSET_COUNT) OVER () AS GRAND_TOTAL_DELIVERED_UNREAD_REPORTS FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_BI_ESTATE METRICS assets.total_subscriptions, assets.total_views_90, assets.asset_count DIMENSIONS assets.asset_id, assets.title, assets.platform, assets.owner_department WHERE assets.rule_id = ''R055'') ORDER BY SUBSCRIPTIONS DESC, TITLE, ASSET_ID LIMIT 20'
        ),
        vq_po_04 AS (
            QUESTION 'Which are the ten largest duplicate clusters (ties included), and which report is canonical in each?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION TRUE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT CLUSTER_ID, CANONICAL_TITLE, CLUSTER_MEMBERS, RANK() OVER (ORDER BY CLUSTER_MEMBERS DESC) || '' of '' || COUNT(*) OVER () || '' clusters'' AS RANK_BY_CLUSTER_MEMBERS FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_BI_ESTATE METRICS clusters.cluster_members DIMENSIONS clusters.cluster_id, clusters.canonical_title) QUALIFY RANK() OVER (ORDER BY CLUSTER_MEMBERS DESC) <= 10 ORDER BY CLUSTER_MEMBERS DESC, CLUSTER_ID'
        ),
        vq_po_05 AS (
            QUESTION 'How many assets did each disposition rule catch, in the order the rules run, and how many did reviewers override?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION FALSE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT RULE_PRIORITY, RULE_ID, RULE_NAME, RECOMMENDED_DISPOSITION, ASSET_COUNT AS ASSETS_CAUGHT, OVERRIDDEN_ASSETS, SUM(OVERRIDDEN_ASSETS) OVER () AS GRAND_TOTAL_OVERRIDDEN_ASSETS FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_BI_ESTATE METRICS assets.asset_count, assets.overridden_assets DIMENSIONS assets.rule_priority, assets.rule_id, assets.rule_name, assets.recommended_disposition) ORDER BY RULE_PRIORITY'
        ),
        vq_po_06 AS (
            QUESTION 'What does each migration wave carry — surviving assets, effort hours and views?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION FALSE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT WAVE_NO::INT AS WAVE, SURVIVING_ASSETS, TOTAL_EFFORT_HOURS AS EFFORT_HOURS_FINAL_DISPOSITION, TOTAL_VIEWS_365 AS VIEWS_365 FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_BI_ESTATE METRICS assets.surviving_assets, assets.total_effort_hours, assets.total_views_365 DIMENSIONS assets.wave_no WHERE assets.is_surviving) ORDER BY WAVE'
        ),
        vq_po_07 AS (
            QUESTION 'How is the MedeAnalytics estate dispositioned, and which rules set it?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION FALSE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT FINAL_DISPOSITION, SUM(ASSET_COUNT) OVER (PARTITION BY FINAL_DISPOSITION) AS GROUP_TOTAL_DISPOSITION_ASSET_COUNT, RULE_ID, RULE_NAME, ASSET_COUNT AS RULE_ASSET_COUNT, SUM(ASSET_COUNT) OVER () AS GRAND_TOTAL_MEDEANALYTICS_ASSETS FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_BI_ESTATE METRICS assets.asset_count DIMENSIONS assets.final_disposition, assets.rule_id, assets.rule_name WHERE assets.platform = ''MEDEANALYTICS'') ORDER BY GROUP_TOTAL_DISPOSITION_ASSET_COUNT DESC, FINAL_DISPOSITION, RULE_ASSET_COUNT DESC'
        ),
        vq_po_08 AS (
            QUESTION 'Which ten departments own the most assets being retired, and how many views do those retired assets still have?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION FALSE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT RANK() OVER (ORDER BY RETIRED_ASSETS DESC) AS RANK_BY_RETIRED_ASSETS, OWNER_DEPARTMENT, RETIRED_ASSETS, RETIRED_VIEWS_365 FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_BI_ESTATE METRICS assets.retired_assets, assets.retired_views_365 DIMENSIONS assets.owner_department) ORDER BY RETIRED_ASSETS DESC, OWNER_DEPARTMENT LIMIT 10'
        )
    );

-- ---------------------------------------------------------------------
-- SV_MIGRATION_DELIVERY — the Migration Engineering view
-- ---------------------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW AI.SV_MIGRATION_DELIVERY
    TABLES (
        entities AS AI.ENTITY_SEMANTIC_BASE PRIMARY KEY (ENTITY_NAME)
            WITH SYNONYMS = ('target entities', 'target model', 'build backlog', 'facts and dimensions', 'data products')
            COMMENT = 'One row per target-model entity derived from surviving lineage (MTH-03): wave, build order, how many surviving assets it unblocks, attributes, metrics, source status',
        metricdefs AS AI.METRIC_SEMANTIC_BASE PRIMARY KEY (METRIC_ID)
            WITH SYNONYMS = ('business metrics', 'measures', 'metric definitions', 'KPIs in the estate')
            COMMENT = 'One row per named metric computed by two or more assets in the estate: how many definitions (variants) exist, how many the proposer judged equivalent or divergent, and the resolution status (PROPOSED until a named owner certifies)',
        sources AS AI.SOURCE_SEMANTIC_BASE PRIMARY KEY (SOURCE_COLUMN)
            WITH SYNONYMS = ('source columns', 'source to target map', 'lineage', 'mapping')
            COMMENT = 'One row per source column traced from surviving assets'' lineage to a target attribute, with its mapping status: MAPPED, HOSTED_VENDOR (MedeAnalytics domain — lineage only), SOURCE_DECOMMISSIONED or SPREADSHEET',
        fields AS AI.FIELD_SEMANTIC_BASE PRIMARY KEY (FIELD_ID)
            WITH SYNONYMS = ('calculated fields', 'calcs', 'formulas', 'expressions', 'DAX measures')
            COMMENT = 'One row per calculated field sent to conversion (fields on MIGRATE, REBUILD and INVESTIGATE assets): source language and expression, the Sigma expression, status AUTO / NEEDS_REVIEW / NEEDS_HUMAN, the construct (complexity tag) and the asset''s wave',
        readiness AS AI.READINESS_SEMANTIC_BASE PRIMARY KEY (READY_ASSET_ID)
            WITH SYNONYMS = ('conversion readiness', 'workbook specs', 'ready to convert')
            COMMENT = 'One row per MIGRATE or REBUILD asset with its conversion readiness: READY (every field AUTO), REVIEW (some need review), BLOCKED (at least one needs a human decision)',
        tests AS AI.TEST_SEMANTIC_BASE PRIMARY KEY (TEST_ID)
            WITH SYNONYMS = ('reconciliation tests', 'test results', 'acceptance tests', 'parallel run')
            COMMENT = 'One row per reconciliation test in the latest run: the legacy report''s value versus the certified target value for the period, variance, materiality and outcome PASS / FAIL / DEFINITION_VARIANCE (MTH-05)'
    )
    DIMENSIONS (
        entities.entity_name AS ENTITY_NAME WITH SYNONYMS = ('entity', 'table to build') COMMENT = 'Target entity, e.g. DIM_PROVIDER, FACT_DENIAL',
        entities.entity_role AS ENTITY_ROLE COMMENT = 'FACT or DIM',
        entities.entities_subject_area AS ENTITY_SUBJECT_AREA COMMENT = 'Subject area of the entity (column SUBJECT_AREA); Shared for conformed dimensions',
        entities.grain AS GRAIN COMMENT = 'The grain of the entity',
        entities.is_shared AS IS_SHARED COMMENT = 'TRUE when two or more subject areas use it (built in wave 0, the foundation)',
        entities.source_status AS SOURCE_STATUS COMMENT = 'SOURCE_AVAILABLE, NEEDS_SYSTEM_OF_RECORD or NEEDS_NEW_SOURCE',
        entities.entities_wave_no AS ENTITY_WAVE_NO WITH SYNONYMS = ('build wave') COMMENT = 'First wave that needs the entity (column WAVE_NO); 0 = foundation',
        entities.build_order AS BUILD_ORDER WITH SYNONYMS = ('build sequence', 'priority') COMMENT = 'Build order: wave, then shared first, then most assets unblocked (MTH-03)',
        metricdefs.metric_id AS METRIC_ID COMMENT = 'Metric id, e.g. MET-98F2B4 (stable hash of the normalized name)',
        metricdefs.metric_name AS METRIC_NAME WITH SYNONYMS = ('metric', 'measure name') COMMENT = 'Metric name as the estate uses it, e.g. Net Patient Revenue, Initial Denial Rate',
        metricdefs.primary_entity AS PRIMARY_ENTITY COMMENT = 'The fact entity the metric is computed on',
        metricdefs.definition_status AS DEFINITION_STATUS COMMENT = 'SINGLE_DEFINITION, MINOR_VARIANCE or CONFLICTING (KPI-011)',
        metricdefs.resolution_status AS RESOLUTION_STATUS COMMENT = 'PROPOSED (by the AI proposer), CERTIFIED (by a named owner) or NONE (KPI-012)',
        metricdefs.dominant_language AS DOMINANT_LANGUAGE COMMENT = 'Expression language of the most common variant',
        metricdefs.canonical_name AS CANONICAL_NAME COMMENT = 'Canonical name in the proposal (PROPOSED, not certified)',
        sources.source_column AS SOURCE_COLUMN COMMENT = 'database.schema.table.column in the source system',
        sources.sources_entity_name AS SOURCE_ENTITY_NAME COMMENT = 'Target entity the column feeds (column ENTITY_NAME)',
        sources.attribute_name AS ATTRIBUTE_NAME COMMENT = 'Target attribute the column feeds',
        sources.system_family AS SYSTEM_FAMILY WITH SYNONYMS = ('source system') COMMENT = 'Source system family, e.g. Epic Clarity, Workday, MedeAnalytics (hosted), MEDITECH (retired), SharePoint spreadsheet',
        sources.mapping_code AS MAPPING_CODE WITH SYNONYMS = ('mapping status') COMMENT = 'MAPPED, HOSTED_VENDOR, SOURCE_DECOMMISSIONED or SPREADSHEET (KPI-018)',
        sources.mapping_guidance AS MAPPING_GUIDANCE COMMENT = 'What to do about the column, e.g. map from your own system of record before the contract ends',
        sources.sources_wave_no AS SOURCE_WAVE_NO COMMENT = 'First wave that needs the column (column FIRST_WAVE_NEEDED)',
        fields.field_id AS FIELD_ID COMMENT = 'Calculated field id',
        fields.field_name AS FIELD_NAME WITH SYNONYMS = ('calculated field name', 'measure') COMMENT = 'Field name in the source asset',
        fields.fields_asset_title AS ASSET_TITLE COMMENT = 'Title of the asset the field lives in',
        fields.fields_platform AS fields.PLATFORM COMMENT = 'TABLEAU, POWER_BI, SAP_BO or MEDEANALYTICS',
        fields.source_language AS SOURCE_LANGUAGE WITH SYNONYMS = ('language', 'formula language') COMMENT = 'TABLEAU_CALC, DAX, BO_FORMULA or MEDE (MedeAnalytics report builder)',
        fields.complexity_tag AS COMPLEXITY_TAG WITH SYNONYMS = ('construct', 'pattern') COMMENT = 'Construct: SIMPLE, STRING, LOD, TABLE_CALC, TIME_INTEL, CONTEXT, ITERATOR, PARAMETER, RLS, EXTERNAL_SCRIPT, MERGED_DIM, VENDOR_DEFINED',
        fields.conversion_field_status AS CONVERSION_FIELD_STATUS WITH SYNONYMS = ('conversion status') COMMENT = 'AUTO, NEEDS_REVIEW or NEEDS_HUMAN (KPI-013, KPI-014, MTH-04)',
        fields.conversion_method AS CONVERSION_METHOD COMMENT = 'RULES or the residual model pass that produced the formula',
        fields.source_expression AS SOURCE_EXPRESSION COMMENT = 'The expression in the source tool',
        fields.sigma_expression AS SIGMA_EXPRESSION COMMENT = 'The generated Sigma expression (a draft until reviewed; never final by itself)',
        fields.conversion_notes AS CONVERSION_NOTES COMMENT = 'Why the field needs review or a human: the rule notes, e.g. LOD has no one-line Sigma equivalent',
        fields.asset_disposition AS ASSET_DISPOSITION COMMENT = 'Final disposition of the field''s asset: MIGRATE, REBUILD or INVESTIGATE',
        fields.fields_subject_area AS FIELD_SUBJECT_AREA COMMENT = 'Subject area of the field''s asset',
        fields.fields_wave_no AS FIELD_WAVE_NO COMMENT = 'Wave of the field''s asset; NULL for INVESTIGATE assets',
        readiness.ready_asset_id AS READY_ASSET_ID COMMENT = 'Asset id',
        readiness.ready_title AS READY_TITLE COMMENT = 'Asset title',
        readiness.ready_platform AS READY_PLATFORM COMMENT = 'TABLEAU, POWER_BI, SAP_BO or MEDEANALYTICS',
        readiness.ready_disposition AS READY_DISPOSITION COMMENT = 'MIGRATE or REBUILD',
        readiness.ready_subject_area AS READY_SUBJECT_AREA COMMENT = 'Subject area',
        readiness.ready_wave_no AS READY_WAVE_NO COMMENT = 'Migration wave 1-4',
        readiness.readiness_status AS READINESS_STATUS WITH SYNONYMS = ('readiness state') COMMENT = 'READY, REVIEW or BLOCKED (KPI-015, MTH-04)',
        tests.test_id AS TEST_ID COMMENT = 'Test id, e.g. TC-0106',
        tests.test_asset_title AS TEST_ASSET_TITLE COMMENT = 'Title of the legacy report under test',
        tests.test_platform AS TEST_PLATFORM COMMENT = 'Platform of the legacy report',
        tests.metric_label AS METRIC_LABEL WITH SYNONYMS = ('tested metric') COMMENT = 'Certified metric tested, e.g. Net Patient Revenue, Initial Denial Rate, Cash Collections',
        tests.period_label AS PERIOD_LABEL COMMENT = 'Test period, e.g. FY2026 Q4 (Apr-Jun 2026)',
        tests.outcome AS OUTCOME WITH SYNONYMS = ('test outcome', 'result') COMMENT = 'PASS (within materiality), FAIL (certified definition, beyond materiality — a conversion defect) or DEFINITION_VARIANCE (the legacy report used a variant definition — an owner decision) (MTH-05)',
        tests.uses_certified_definition AS USES_CERTIFIED_DEFINITION COMMENT = 'TRUE when the legacy report used the certified definition',
        tests.snapshot_note AS SNAPSHOT_NOTE COMMENT = 'How the legacy snapshot value was obtained (simulated in the demo)'
    )
    METRICS (
        entities.entity_count AS COUNT(entities.ENTITY_NAME) WITH SYNONYMS = ('number of entities') COMMENT = 'Number of target entities (MTH-03)',
        entities.unblocked_assets AS SUM(entities.ASSETS_UNBLOCKED) WITH SYNONYMS = ('reports unblocked', 'assets unblocked') COMMENT = 'Surviving assets whose lineage reads the entity; not additive across entities (an asset reading two entities counts in both) (KPI-010, MTH-03)',
        entities.exec_assets_unblocked AS SUM(entities.EXEC_ASSETS) COMMENT = 'Surviving assets with an executive audience that read the entity (KPI-010 context)',
        entities.entity_attributes AS SUM(entities.ATTRIBUTES) COMMENT = 'Attributes derived for the entity (MTH-03)',
        entities.entity_conflicting_metrics AS SUM(entities.ENTITY_CONFLICTING_METRICS) COMMENT = 'Conflicting metrics whose primary entity this is (KPI-011)',
        entities.build_hours_indicative AS SUM(entities.BUILD_HOURS_INDICATIVE) COMMENT = 'Indicative build hours for the entity — TO CONFIRM against the data team''s velocity (MTH-03)',
        metricdefs.metric_count AS COUNT(metricdefs.METRIC_ID) COMMENT = 'Number of named metrics (KPI-011 denominator)',
        metricdefs.conflicting_metric_count AS SUM(metricdefs.CONFLICTING_FLAG) WITH SYNONYMS = ('conflicting metrics', 'metrics that disagree') COMMENT = 'Metrics whose most common definition covers under 80% of the assets computing them (KPI-011, MTH-03)',
        metricdefs.certified_metric_count AS SUM(metricdefs.CERTIFIED_FLAG) WITH SYNONYMS = ('certified metrics') COMMENT = 'Metrics a named owner has certified (KPI-012)',
        metricdefs.variant_definitions AS SUM(metricdefs.VARIANT_COUNT) WITH SYNONYMS = ('variants', 'number of definitions') COMMENT = 'Distinct definitions (variants) across the estate (KPI-011)',
        metricdefs.equivalent_variants AS SUM(metricdefs.EQUIVALENT_COUNT) COMMENT = 'Variants the proposer judged equivalent to the proposed canonical (PROPOSED, KPI-011)',
        metricdefs.divergent_variants AS SUM(metricdefs.DIVERGENT_COUNT) WITH SYNONYMS = ('definitions that actually differ') COMMENT = 'Variants the proposer judged divergent — a different number (PROPOSED, KPI-011)',
        metricdefs.metric_asset_count AS SUM(metricdefs.METRIC_ASSETS) COMMENT = 'Assets that compute the metric',
        metricdefs.metric_views_365 AS SUM(metricdefs.METRIC_VIEWS_365) COMMENT = 'Interactive views in 365 days on assets that compute the metric (KPI-002)',
        sources.source_column_count AS COUNT(sources.SOURCE_COLUMN) WITH SYNONYMS = ('source columns traced') COMMENT = 'Source columns traced from surviving lineage (KPI-018 denominator, MTH-03)',
        sources.columns_needing_decision AS SUM(sources.NEEDS_DECISION_FLAG) WITH SYNONYMS = ('unmapped columns', 'columns needing a decision') COMMENT = 'Source columns whose mapping status is not MAPPED (KPI-018, MTH-03)',
        sources.source_referencing_assets AS SUM(sources.REFERENCING_ASSETS) COMMENT = 'Asset references to the columns; not distinct assets',
        fields.field_count AS COUNT(fields.FIELD_ID) WITH SYNONYMS = ('number of calculated fields') COMMENT = 'Calculated fields sent to conversion (KPI-013 denominator, MTH-04)',
        fields.auto_fields AS SUM(fields.AUTO_FLAG) COMMENT = 'Fields converted automatically with status AUTO (KPI-013, MTH-04)',
        fields.review_fields AS SUM(fields.REVIEW_FLAG) COMMENT = 'Fields with status NEEDS_REVIEW (MTH-04)',
        fields.human_fields AS SUM(fields.HUMAN_FLAG) WITH SYNONYMS = ('fields needing a human', 'human decisions') COMMENT = 'Fields with status NEEDS_HUMAN — a modeling decision, not a formula (KPI-014, MTH-04)',
        fields.auto_conversion_rate AS AVG(fields.AUTO_FLAG) WITH SYNONYMS = ('automation rate', 'auto rate') COMMENT = 'Share of calculated fields converted automatically, 0 to 1 (KPI-013, MTH-04)',
        fields.human_decision_rate AS AVG(fields.HUMAN_FLAG) COMMENT = 'Share of calculated fields needing a human decision, 0 to 1 (KPI-014, MTH-04)',
        fields.ai_assisted_fields AS SUM(fields.AI_ASSISTED_FLAG) COMMENT = 'Fields the residual model pass looked at (MTH-04)',
        fields.avg_field_confidence AS AVG(fields.FIELD_CONFIDENCE) COMMENT = 'Average rule-translation confidence 0 to 1 (MTH-04)',
        readiness.readiness_asset_count AS COUNT(readiness.READY_ASSET_ID) COMMENT = 'MIGRATE and REBUILD assets with a readiness state (KPI-015)',
        readiness.ready_assets AS SUM(readiness.READY_FLAG) COMMENT = 'Assets READY to convert (KPI-015, MTH-04)',
        readiness.blocked_assets AS SUM(readiness.BLOCKED_FLAG) COMMENT = 'Assets BLOCKED on at least one human decision (KPI-015, MTH-04)',
        readiness.ready_rate AS AVG(readiness.READY_FLAG) COMMENT = 'Share of converting assets READY, 0 to 1 (KPI-015, MTH-04)',
        tests.test_count AS COUNT(tests.TEST_ID) WITH SYNONYMS = ('number of tests') COMMENT = 'Reconciliation tests in the latest run (KPI-016 denominator, MTH-05)',
        tests.passed_tests AS SUM(tests.PASS_FLAG) COMMENT = 'Tests within materiality (KPI-016, MTH-05)',
        tests.failed_tests AS SUM(tests.FAIL_FLAG) WITH SYNONYMS = ('conversion defects') COMMENT = 'Tests beyond materiality on the certified definition — a conversion defect (MTH-05)',
        tests.definition_variance_tests AS SUM(tests.VARIANCE_FLAG) WITH SYNONYMS = ('definition variances') COMMENT = 'Tests beyond materiality where the legacy report used a variant definition — an owner decision, not a defect (KPI-017, MTH-05)',
        tests.pass_rate AS AVG(tests.PASS_FLAG) COMMENT = 'Share of tests that pass, 0 to 1 (KPI-016, MTH-05)',
        tests.avg_variance_pct AS AVG(tests.VARIANCE_PCT) COMMENT = 'Average absolute variance between legacy and target value, percent (MTH-05)',
        tests.avg_materiality_pct AS AVG(tests.MATERIALITY_PCT) COMMENT = 'Materiality threshold, percent (MTH-05)'
    )
    COMMENT = 'Migration delivery for Ridgeline Health (synthetic), for Migration Engineering: target-model build order, conflicting metric definitions, source columns needing a decision, calculated-field conversion to Sigma, readiness and reconciliation tests. Every metric cites the KPI id it implements.'
    AI_VERIFIED_QUERIES (
        vq_me_01 AS (
            QUESTION 'Which target entities should the data team build first, and how many reports does each unblock?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION TRUE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT BUILD_ORDER, ENTITY_NAME, ENTITIES_WAVE_NO::INT AS ENTITY_WAVE, IS_SHARED, SOURCE_STATUS, UNBLOCKED_ASSETS AS REPORTS_UNBLOCKED, RANK() OVER (ORDER BY UNBLOCKED_ASSETS DESC) AS RANK_BY_REPORTS_UNBLOCKED, COUNT_IF(SOURCE_STATUS <> ''SOURCE_AVAILABLE'') OVER () AS ENTITIES_NEEDING_A_SOURCE_DECISION FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_MIGRATION_DELIVERY METRICS entities.unblocked_assets DIMENSIONS entities.build_order, entities.entity_name, entities.entities_wave_no, entities.is_shared, entities.source_status WHERE entities.entities_wave_no = 0) ORDER BY BUILD_ORDER'
        ),
        vq_me_02 AS (
            QUESTION 'Which metrics have conflicting definitions across the estate, how many of their variants did the proposer judge divergent, and did it judge every variant exactly once?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION TRUE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT METRIC_NAME, VARIANT_DEFINITIONS, DIVERGENT_VARIANTS, RANK() OVER (ORDER BY DIVERGENT_VARIANTS DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY DIVERGENT_VARIANTS DESC) = 1, '' (most)'', IFF(DIVERGENT_VARIANTS = MIN(DIVERGENT_VARIANTS) OVER (), '' (fewest)'', '''')) AS RANK_BY_DIVERGENT_VARIANTS, EQUIVALENT_VARIANTS, CASE WHEN DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS = VARIANT_DEFINITIONS THEN ''judged exactly once: '' || (DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS) || '' judgments for '' || VARIANT_DEFINITIONS || '' variants'' WHEN DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS > VARIANT_DEFINITIONS THEN ''judgments overlap: '' || (DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS) || '' judgments for '' || VARIANT_DEFINITIONS || '' variants ('' || (DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS - VARIANT_DEFINITIONS) || '' more than variants), so some variants were counted more than once'' ELSE ''not all judged: '' || (DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS) || '' judgments for '' || VARIANT_DEFINITIONS || '' variants, so at least '' || (VARIANT_DEFINITIONS - DIVERGENT_VARIANTS - EQUIVALENT_VARIANTS) || '' judged neither divergent nor equivalent'' END AS PROPOSER_JUDGMENT, COUNT_IF(DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS = VARIANT_DEFINITIONS) OVER () AS METRICS_JUDGED_EXACTLY_ONCE, COUNT_IF(DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS <> VARIANT_DEFINITIONS) OVER () AS METRICS_NOT_JUDGED_EXACTLY_ONCE, COUNT_IF(DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS > VARIANT_DEFINITIONS) OVER () AS METRICS_WITH_OVERLAPPING_JUDGMENTS, COUNT_IF(DIVERGENT_VARIANTS + EQUIVALENT_VARIANTS < VARIANT_DEFINITIONS) OVER () AS METRICS_WITH_UNJUDGED_VARIANTS, RESOLUTION_STATUS FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_MIGRATION_DELIVERY METRICS metricdefs.variant_definitions, metricdefs.divergent_variants, metricdefs.equivalent_variants DIMENSIONS metricdefs.metric_name, metricdefs.resolution_status WHERE metricdefs.definition_status = ''CONFLICTING'') ORDER BY DIVERGENT_VARIANTS DESC, VARIANT_DEFINITIONS DESC, METRIC_NAME'
        ),
        vq_me_03 AS (
            QUESTION 'How much of the calculated-field conversion to Sigma is automatic, overall and by source language?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION TRUE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT SOURCE_LANGUAGE, FIELD_COUNT, AUTO_FIELDS, ROUND(100 * AUTO_CONVERSION_RATE, 1) AS AUTO_CONVERSION_PCT, RANK() OVER (ORDER BY AUTO_CONVERSION_RATE DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY AUTO_CONVERSION_RATE DESC) = 1, '' (highest)'', IFF(RANK() OVER (ORDER BY AUTO_CONVERSION_RATE DESC) = COUNT(*) OVER (), '' (lowest)'', '''')) AS RANK_BY_AUTO_CONVERSION_PCT, FIELD_COUNT - AUTO_FIELDS AS NEEDS_REVIEW_OR_HUMAN_FIELDS, RANK() OVER (ORDER BY FIELD_COUNT - AUTO_FIELDS DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY FIELD_COUNT - AUTO_FIELDS DESC) = 1, '' (most)'', IFF(RANK() OVER (ORDER BY FIELD_COUNT - AUTO_FIELDS DESC) = COUNT(*) OVER (), '' (fewest)'', '''')) AS RANK_BY_NEEDS_REVIEW_OR_HUMAN_FIELDS, ROUND(100 * (MAX(AUTO_CONVERSION_RATE) OVER () - MIN(AUTO_CONVERSION_RATE) OVER ()), 1) AS AUTO_PCT_GAP_HIGHEST_MINUS_LOWEST_POINTS, SUM(FIELD_COUNT) OVER () AS GRAND_TOTAL_FIELD_COUNT, SUM(AUTO_FIELDS) OVER () AS GRAND_TOTAL_AUTO_FIELDS, ROUND(100 * DIV0(SUM(AUTO_FIELDS) OVER (), SUM(FIELD_COUNT) OVER ()), 1) AS GRAND_TOTAL_AUTO_CONVERSION_PCT, SUM(FIELD_COUNT - AUTO_FIELDS) OVER () AS GRAND_TOTAL_NEEDS_REVIEW_OR_HUMAN_FIELDS, ROUND(100 * DIV0(SUM(FIELD_COUNT - AUTO_FIELDS) OVER (), SUM(FIELD_COUNT) OVER ()), 1) AS GRAND_TOTAL_NEEDS_REVIEW_OR_HUMAN_PCT FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_MIGRATION_DELIVERY METRICS fields.field_count, fields.auto_fields, fields.auto_conversion_rate DIMENSIONS fields.source_language) ORDER BY AUTO_CONVERSION_PCT DESC'
        ),
        vq_me_04 AS (
            QUESTION 'What did the reconciliation tests find for each metric — pass, fail or definition variance?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION TRUE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT METRIC_LABEL, TEST_COUNT, RANK() OVER (ORDER BY TEST_COUNT DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY TEST_COUNT DESC) = 1, '' (most)'', IFF(RANK() OVER (ORDER BY TEST_COUNT DESC) = COUNT(*) OVER (), '' (fewest)'', '''')) AS RANK_BY_TEST_COUNT, PASSED_TESTS, FAILED_TESTS, DEFINITION_VARIANCE_TESTS, PASS_RATE, RANK() OVER (ORDER BY PASS_RATE DESC) || '' of '' || COUNT(*) OVER () || IFF(RANK() OVER (ORDER BY PASS_RATE DESC) = 1, '' (highest)'', IFF(RANK() OVER (ORDER BY PASS_RATE DESC) = COUNT(*) OVER (), '' (lowest)'', '''')) AS RANK_BY_PASS_RATE, CASE WHEN DEFINITION_VARIANCE_TESTS > PASSED_TESTS AND DEFINITION_VARIANCE_TESTS > FAILED_TESTS THEN ''DEFINITION_VARIANCE'' WHEN PASSED_TESTS > DEFINITION_VARIANCE_TESTS AND PASSED_TESTS > FAILED_TESTS THEN ''PASS'' WHEN FAILED_TESTS > PASSED_TESTS AND FAILED_TESTS > DEFINITION_VARIANCE_TESTS THEN ''FAIL'' WHEN PASSED_TESTS = DEFINITION_VARIANCE_TESTS THEN ''TIE: PASS = DEFINITION_VARIANCE'' ELSE ''TIE'' END AS LARGEST_OUTCOME, COUNT_IF(DEFINITION_VARIANCE_TESTS > PASSED_TESTS AND DEFINITION_VARIANCE_TESTS > FAILED_TESTS) OVER () AS METRICS_WHERE_DEFINITION_VARIANCE_IS_LARGEST, COUNT_IF(NOT (DEFINITION_VARIANCE_TESTS > PASSED_TESTS AND DEFINITION_VARIANCE_TESTS > FAILED_TESTS)) OVER () AS METRICS_WHERE_DEFINITION_VARIANCE_IS_NOT_LARGEST, COUNT_IF(FAILED_TESTS > 0) OVER () AS METRICS_WITH_A_FAILED_TEST FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_MIGRATION_DELIVERY METRICS tests.test_count, tests.passed_tests, tests.failed_tests, tests.definition_variance_tests, tests.pass_rate DIMENSIONS tests.metric_label) ORDER BY PASS_RATE DESC, TEST_COUNT DESC'
        ),
        vq_me_05 AS (
            QUESTION 'How many assets in each wave are ready, in review or blocked for conversion?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION FALSE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT READY_WAVE_NO::INT AS WAVE, READY_ASSETS, READINESS_ASSET_COUNT - READY_ASSETS - BLOCKED_ASSETS AS REVIEW_ASSETS, BLOCKED_ASSETS, READINESS_ASSET_COUNT AS WAVE_CONVERTING_ASSETS, READY_RATE FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_MIGRATION_DELIVERY METRICS readiness.readiness_asset_count, readiness.ready_assets, readiness.blocked_assets, readiness.ready_rate DIMENSIONS readiness.ready_wave_no) ORDER BY WAVE'
        ),
        vq_me_06 AS (
            QUESTION 'Which constructs in wave 1 still need a human decision, and how many fields each?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION FALSE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT COMPLEXITY_TAG, HUMAN_FIELDS, RANK() OVER (ORDER BY HUMAN_FIELDS DESC) AS RANK_BY_HUMAN_FIELDS FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_MIGRATION_DELIVERY METRICS fields.human_fields DIMENSIONS fields.complexity_tag WHERE fields.fields_wave_no = 1) WHERE HUMAN_FIELDS > 0 ORDER BY HUMAN_FIELDS DESC, COMPLEXITY_TAG'
        ),
        vq_me_07 AS (
            QUESTION 'Which reconciliation test failed, on which report, and by how much against materiality?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION FALSE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT TEST_ID, TEST_ASSET_TITLE, TEST_PLATFORM, METRIC_LABEL, PERIOD_LABEL, ROUND(AVG_VARIANCE_PCT, 4) AS VARIANCE_PCT, ROUND(AVG_MATERIALITY_PCT, 4) AS MATERIALITY_PCT, ROUND(AVG_VARIANCE_PCT - AVG_MATERIALITY_PCT, 4) AS VARIANCE_ABOVE_MATERIALITY_PCT_POINTS FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_MIGRATION_DELIVERY METRICS tests.avg_variance_pct, tests.avg_materiality_pct DIMENSIONS tests.test_id, tests.test_asset_title, tests.test_platform, tests.metric_label, tests.period_label WHERE tests.outcome = ''FAIL'')'
        ),
        vq_me_08 AS (
            QUESTION 'How many source columns need a decision before the target model can be built, and from which systems?'
            VERIFIED_AT 1790208000 ONBOARDING_QUESTION FALSE VERIFIED_BY '(Steward = Morgan Ellery)'
            SQL 'SELECT MAPPING_CODE, SYSTEM_FAMILY, COLUMNS_NEEDING_DECISION, SUM(COLUMNS_NEEDING_DECISION) OVER () AS GRAND_TOTAL_COLUMNS_NEEDING_DECISION FROM SEMANTIC_VIEW(BI_MODERNIZATION.AI.SV_MIGRATION_DELIVERY METRICS sources.columns_needing_decision DIMENSIONS sources.mapping_code, sources.system_family) WHERE COLUMNS_NEEDING_DECISION > 0 ORDER BY COLUMNS_NEEDING_DECISION DESC, SYSTEM_FAMILY'
        )
    );

-- CREATE OR REPLACE drops grants: re-grant here. The demo database is readable
-- by PUBLIC by design (synthetic data; see sql/08_app/01_app_objects.sql).
GRANT SELECT ON VIEW AI.ASSET_SEMANTIC_BASE     TO ROLE PUBLIC;
GRANT SELECT ON VIEW AI.FIELD_SEMANTIC_BASE     TO ROLE PUBLIC;
GRANT SELECT ON VIEW AI.METRIC_SEMANTIC_BASE    TO ROLE PUBLIC;
GRANT SELECT ON VIEW AI.TEST_SEMANTIC_BASE      TO ROLE PUBLIC;
GRANT SELECT ON VIEW AI.SOURCE_SEMANTIC_BASE    TO ROLE PUBLIC;
GRANT SELECT ON VIEW AI.ENTITY_SEMANTIC_BASE    TO ROLE PUBLIC;
GRANT SELECT ON VIEW AI.READINESS_SEMANTIC_BASE TO ROLE PUBLIC;
GRANT SELECT ON SEMANTIC VIEW AI.SV_BI_ESTATE          TO ROLE PUBLIC;
GRANT SELECT ON SEMANTIC VIEW AI.SV_MIGRATION_DELIVERY TO ROLE PUBLIC;
GRANT USAGE ON CORTEX SEARCH SERVICE AI.ESTATE_RECORD_SEARCH       TO ROLE PUBLIC;
GRANT USAGE ON CORTEX SEARCH SERVICE AI.MIGRATION_REFERENCE_SEARCH TO ROLE PUBLIC;

SELECT 'search services + semantic views SV_BI_ESTATE, SV_MIGRATION_DELIVERY created' AS STATUS;
