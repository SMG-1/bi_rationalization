-- =============================================================================
-- RATIONALIZATION — SEEDS: scoring policy, regulatory register, disposition rules,
-- the review table. Run ONCE at deploy. The in-app pipeline never touches this file,
-- so a client's edits to these tables survive every re-run.
-- -----------------------------------------------------------------------------
-- Nothing here is hard-coded into a query. Thresholds live in SCORING_POLICY,
-- obligations live in REGULATORY_REGISTER, and the rule conditions live in
-- DISPOSITION_RULE (next file). At a client the engagement edits the tables;
-- the engine does not change.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA RATIONALIZATION;

CREATE OR REPLACE TABLE SCORING_POLICY (
    POLICY_KEY    TEXT PRIMARY KEY,
    POLICY_VALUE  NUMBER(12,4),
    DESCRIPTION   TEXT,
    SET_BY        TEXT DEFAULT CURRENT_USER(),
    SET_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
INSERT INTO SCORING_POLICY (POLICY_KEY, POLICY_VALUE, DESCRIPTION) VALUES
  ('ZOMBIE_DAYS',              365, 'No interactive view in this many days = zombie'),
  ('LOW_USAGE_VIEWS_90',         5, 'At or below this many views in 90 days counts as low usage'),
  ('LOW_USAGE_VIEWERS_90',       2, 'At or below this many distinct viewers in 90 days counts as low usage'),
  ('DECAY_RATIO',              0.35, 'Views last 90 / prior 90 below this = decaying'),
  ('SELF_SERVICE_OWNER_SHARE', 0.80, 'Owner share of views at or above this = a personal analysis, not a report'),
  ('COMPLEXITY_BAND_S_MAX',      10, 'Complexity points: S below this'),
  ('COMPLEXITY_BAND_M_MAX',      25, 'Complexity points: M below this'),
  ('COMPLEXITY_BAND_L_MAX',      45, 'Complexity points: L below this, XL above'),
  ('EFFORT_HOURS_S',              6, 'Conversion hours, band S (TO CONFIRM — calibrate on the first wave)'),
  ('EFFORT_HOURS_M',             16, 'Conversion hours, band M (TO CONFIRM)'),
  ('EFFORT_HOURS_L',             40, 'Conversion hours, band L (TO CONFIRM)'),
  ('EFFORT_HOURS_XL',            80, 'Conversion hours, band XL (TO CONFIRM)'),
  ('REBUILD_MULTIPLIER',        1.5, 'Rebuild on a certified dataset costs this multiple of a conversion'),
  ('VALIDATION_SHARE',         0.25, 'Reconciliation and sign-off as a share of build effort'),
  ('SELF_SERVICE_HOURS',          2, 'Hours to onboard an author to a governed dataset instead of converting'),
  ('CONSOLIDATE_HOURS',           1, 'Hours to fold a duplicate''s differences into the canonical as requirements'),
  ('WAVE_COUNT',                  4, 'Number of migration waves after the foundation wave');

-- Obligations the usage numbers cannot see. A cost-report worksheet is opened
-- once a year by two people and is not optional. Patterns are matched
-- against titles AND against an explicit asset list the engagement maintains.
CREATE OR REPLACE TABLE REGULATORY_REGISTER (
    REGISTER_ID     TEXT PRIMARY KEY,
    OBLIGATION      TEXT,
    AUTHORITY       TEXT,
    TITLE_PATTERN   TEXT,
    CADENCE         TEXT,
    OWNER_ROLE      TEXT,
    NOTE            TEXT
);
INSERT INTO REGULATORY_REGISTER VALUES
  ('REG-01', 'Medicare Cost Report (CMS-2552-10) worksheet support', 'CMS', '.*cost report.*', 'Annual', 'Reimbursement Director', 'Low-frequency, mandatory; supports the filed cost report and audit'),
  ('REG-02', 'EEO-1 Component 1 workforce report', 'EEOC', '.*eeo-?1.*', 'Annual', 'HR Compliance', 'Filed annually; retained for audit'),
  ('REG-03', 'NHSN healthcare-associated infection reporting', 'CDC NHSN / CMS IQR', '.*(nhsn|hospital-acquired infection).*', 'Monthly', 'Infection Prevention', 'Feeds CMS Hospital IQR; penalties for non-reporting'),
  ('REG-04', 'Core measures / chart-abstracted measures', 'CMS IQR / Joint Commission', '.*core measure.*', 'Quarterly', 'Quality Director', 'Abstraction support and submission review'),
  ('REG-05', 'SEP-1 sepsis bundle', 'CMS IQR', '.*sep-?1.*|.*sepsis bundle.*', 'Quarterly', 'Quality Director', 'Chart-abstracted measure'),
  ('REG-06', 'Medical loss ratio', 'CMS / state DOI', '.*medical loss ratio.*|.*\\bmlr\\b.*', 'Annual', 'Health Plan Finance', 'Rebate calculation; audited'),
  ('REG-07', 'ACO quality measure submission', 'CMS MSSP', '.*aco quality.*', 'Annual', 'Population Health', 'Web Interface / eCQM submission support'),
  ('REG-08', 'Antimicrobial stewardship reporting', 'CMS CoP / Joint Commission', '.*antimicrobial stewardship.*', 'Quarterly', 'Pharmacy Director', 'Condition of Participation since 2020');

CREATE OR REPLACE TABLE REGULATORY_ASSET (
    ASSET_ID TEXT, REGISTER_ID TEXT, ADDED_BY TEXT DEFAULT CURRENT_USER(), NOTE TEXT
);

CREATE OR REPLACE VIEW V_REGULATORY_MATCH AS
SELECT DISTINCT a.ASSET_ID, r.REGISTER_ID, r.OBLIGATION, r.AUTHORITY
FROM CONFORMED.ASSET a
JOIN REGULATORY_REGISTER r ON REGEXP_LIKE(LOWER(a.TITLE), r.TITLE_PATTERN)
UNION
SELECT ra.ASSET_ID, ra.REGISTER_ID, r.OBLIGATION, r.AUTHORITY
FROM REGULATORY_ASSET ra JOIN REGULATORY_REGISTER r ON r.REGISTER_ID = ra.REGISTER_ID;



CREATE OR REPLACE TABLE DISPOSITION_RULE (
    RULE_ID          TEXT PRIMARY KEY,
    PRIORITY         NUMBER,
    DISPOSITION      TEXT,      -- RETIRE | CONSOLIDATE | MIGRATE | REBUILD | SELF_SERVICE | INVESTIGATE
    CONFIDENCE       TEXT,      -- HIGH | MEDIUM
    RULE_NAME        TEXT,
    CONDITION_SQL    TEXT,      -- boolean expression over V_ASSET_PROFILE columns
    REASON_SQL       TEXT,      -- text expression over V_ASSET_PROFILE columns
    IS_ENABLED       BOOLEAN DEFAULT TRUE,
    RATIONALE        TEXT
);

INSERT INTO DISPOSITION_RULE (RULE_ID, PRIORITY, DISPOSITION, CONFIDENCE, RULE_NAME, CONDITION_SQL, REASON_SQL, RATIONALE) VALUES
('R010', 10, 'RETIRE', 'HIGH', 'Broken and unread',
 'HAS_DECOMMISSIONED_SOURCE AND VIEWS_90 = 0 AND SUBSCRIPTION_COUNT = 0 AND NOT IS_REGULATORY',
 '''Reads a decommissioned source system and has had no interactive view in '' || LEAST(DAYS_SINCE_LAST_VIEW, 9999) || '' days. It cannot be producing current numbers.''',
 'A report on a retired system with nobody opening it is the safest retirement in the estate.'),

('R040', 40, 'MIGRATE', 'HIGH', 'Regulatory obligation',
 'IS_REGULATORY',
 '''Matches a regulatory obligation ('' || REGULATORY_OBLIGATIONS || ''). Usage is '' || VIEWS_365 || '' views in 12 months, which is irrelevant: the obligation, not the audience, keeps it.''',
 'Usage statistics cannot see an annual filing. The register overrides the numbers: the zombie and broken rules are written to skip regulatory assets, and duplicates of a regulatory canonical consolidate into it, so what reaches this rule is the asset that actually serves the obligation.'),

('R020', 20, 'RETIRE', 'HIGH', 'Zombie',
 'DAYS_SINCE_LAST_VIEW > RATIONALIZATION.POLICY(''ZOMBIE_DAYS'') AND SUBSCRIPTION_COUNT = 0 AND NOT IS_REGULATORY',
 '''No interactive view in '' || IFF(DAYS_SINCE_LAST_VIEW = 9999, ''the full extract window'', DAYS_SINCE_LAST_VIEW || '' days'') || '', no subscription, no regulatory obligation.''',
 'A year with no reader and no delivery. The owner is notified; silence for 30 days confirms. Runs before duplicate consolidation so a dead copy is retired, not consolidated, and never touches a regulatory asset.'),

('R030', 30, 'CONSOLIDATE', 'HIGH', 'Duplicate of a canonical asset',
 'CLUSTER_ID IS NOT NULL AND NOT IS_CLUSTER_CANONICAL',
 '''One of '' || CLUSTER_SIZE || '' assets in cluster '' || CLUSTER_ID || '' built on the same entities and metrics. The canonical is "'' || CANONICAL_TITLE || ''" ('' || CANONICAL_ASSET_ID || ''); this one carried '' || VIEWS_365 || '' views in 12 months.''',
 'Migrate the cluster once. Differences between members become requirements on the canonical, not separate assets.'),

('R050', 50, 'RETIRE', 'MEDIUM', 'Personal space, unshared',
 'IS_PERSONAL_SPACE AND VIEWERS_365 <= 1',
 '''Lives in a personal space and was read by '' || VIEWERS_365 || '' person in 12 months (owner share of views '' || ROUND(OWNER_VIEW_SHARE * 100) || ''%). Archive, do not migrate.''',
 'Personal analyses are not reports. Authors keep the ability to rebuild them on the governed dataset.'),

('R055', 25, 'INVESTIGATE', 'MEDIUM', 'Delivered but never opened',
 'SUBSCRIPTION_COUNT > 0 AND VIEWS_90 = 0',
 '''Delivered to '' || SUBSCRIPTION_COUNT || '' subscribers ('' || EXEC_SUBSCRIBER_COUNT || '' executives) but zero interactive views in 90 days. The usage data cannot tell whether the emailed copy is read. Confirm with recipients before deciding.''',
 'The trap in every usage-only rationalization: an email-delivered report looks dead in the view counts and is the CFO''s Monday morning. Runs before consolidation on purpose — folding a delivered report into a canonical without asking its recipients silently breaks a delivery.'),

('R060', 60, 'RETIRE', 'MEDIUM', 'Low usage, no executive audience',
 'VIEWS_90 <= RATIONALIZATION.POLICY(''LOW_USAGE_VIEWS_90'') AND VIEWERS_90 <= RATIONALIZATION.POLICY(''LOW_USAGE_VIEWERS_90'') AND EXEC_VIEWERS_365 = 0 AND SUBSCRIPTION_COUNT = 0',
 '''Only '' || VIEWS_90 || '' views by '' || VIEWERS_90 || '' people in 90 days, no executive reader, no subscription. Owner confirmation required before retirement.''',
 'Below the usage floor and without a protected audience. Medium confidence: the owner gets a say.'),

('R065', 65, 'INVESTIGATE', 'MEDIUM', 'Decaying',
 'TREND_RATIO_90 IS NOT NULL AND TREND_RATIO_90 < RATIONALIZATION.POLICY(''DECAY_RATIO'') AND VIEWS_90 > RATIONALIZATION.POLICY(''LOW_USAGE_VIEWS_90'')',
 '''Usage fell to '' || ROUND(TREND_RATIO_90 * 100) || ''% of the prior quarter ('' || VIEWS_PRIOR_90 || '' to '' || VIEWS_90 || '' views). Something replaced it or the need went away; find out which before converting it.''',
 'A decaying asset migrated as-is arrives dead. Ask first.'),

('R070', 70, 'SELF_SERVICE', 'MEDIUM', 'Personal analysis on shared data',
 'OWNER_VIEW_SHARE >= RATIONALIZATION.POLICY(''SELF_SERVICE_OWNER_SHARE'') AND VIEWERS_365 <= 3 AND NOT IS_REGULATORY',
 '''The owner accounts for '' || ROUND(OWNER_VIEW_SHARE * 100) || ''% of views and '' || VIEWERS_365 || '' people read it. This is an analysis, not a report: give the author the governed dataset in Sigma and let them rebuild it in an afternoon.''',
 'Converting one-reader analyses is where migration hours disappear. A governed dataset plus an author is cheaper and leaves something reusable.'),

('R080', 80, 'REBUILD', 'HIGH', 'Rebuild on a certified dataset',
 'COMPLEXITY_BAND IN (''L'', ''XL'') OR HAS_CUSTOM_SQL OR SPECIAL_COUNT > 0 OR VENDOR_DEFINED_COUNT > 0 OR HAS_DECOMMISSIONED_SOURCE OR HAS_UNMANAGED_SOURCE OR SOURCE_SYSTEM_COUNT > 1',
 '''Complexity '' || COMPLEXITY_BAND || '' ('' || COMPLEXITY_POINTS || '' points: '' || LOD_COUNT || '' LOD, '' || TIME_INTEL_COUNT || '' time-intelligence, '' || TABLE_CALC_COUNT || '' table calcs, '' || CONTEXT_COUNT || '' context)'' || IFF(HAS_CUSTOM_SQL, ''; custom SQL'', '''') || IFF(VENDOR_DEFINED_COUNT > 0, ''; '' || VENDOR_DEFINED_COUNT || '' vendor-defined measures whose definitions are not exported — redefine on the certified dataset'', '''') || IFF(HAS_DECOMMISSIONED_SOURCE, ''; still reads a decommissioned source'', '''') || IFF(HAS_UNMANAGED_SOURCE, ''; joins a spreadsheet'', '''') || IFF(SOURCE_SYSTEM_COUNT > 1, ''; blends '' || SOURCE_SYSTEM_COUNT || '' source systems'', '''') || ''. Logic belongs in the target model, not in the workbook.''',
 'The things that make a workbook complex are the things that should not live in a workbook. Move them into the certified dataset and the converted asset becomes simple.'),

('R090', 90, 'MIGRATE', 'HIGH', 'Convert',
 'TRUE',
 '''Active ('' || VIEWS_90 || '' views, '' || VIEWERS_90 || '' viewers in 90 days), complexity '' || COMPLEXITY_BAND || '', sources cataloged. Convert with the expression translator and reconcile.''',
 'Everything that survives the earlier rules and is simple enough to convert mechanically.');


-- ------------------------------------------------------ the human gate ------
CREATE TABLE IF NOT EXISTS DISPOSITION_REVIEW (
    REVIEW_ID          NUMBER IDENTITY,
    ASSET_ID           TEXT,
    REVIEWER           TEXT DEFAULT CURRENT_USER(),
    REVIEWER_ROLE      TEXT,
    DECISION           TEXT,        -- ACCEPT | OVERRIDE | DEFER
    FINAL_DISPOSITION  TEXT,
    NOTE               TEXT,
    DECIDED_AT         TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

