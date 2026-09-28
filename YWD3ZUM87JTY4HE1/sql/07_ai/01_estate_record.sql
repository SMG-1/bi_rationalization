-- =============================================================================
-- AI — the estate's own record, rendered as searchable prose
-- -----------------------------------------------------------------------------
-- The copilot answers "why is this report marked RETIRE" from here and from
-- nowhere else: one document per asset disposition (with the rule, the
-- evidence and any human decision), per duplicate cluster, per metric
-- conflict, per target entity, per rule, per wave, and per regulatory
-- obligation. Because the corpus is generated from the decision tables, the
-- copilot cannot describe a disposition the engine did not make.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA AI;

-- Pre-aggregations: every list that goes into a document is built here and
-- joined, because a correlated LISTAGG inside a string concatenation is not
-- something Snowflake will evaluate.
CREATE OR REPLACE VIEW AI.X_CLUSTER_MEMBERS AS
SELECT CLUSTER_ID, LISTAGG('"' || TITLE || '" (' || ASSET_ID || ', ' || PLATFORM || ')', '; ') WITHIN GROUP (ORDER BY IS_CANONICAL DESC, TITLE) AS MEMBERS
FROM CONFORMED.DUPLICATE_CLUSTER GROUP BY 1;

CREATE OR REPLACE VIEW AI.X_METRIC_VARIANTS AS
SELECT m.METRIC_ID, LISTAGG('[' || v.EXPRESSION_LANGUAGE || ', ' || v.ASSET_COUNT || ' assets] ' || v.EXPRESSION, ' || ') WITHIN GROUP (ORDER BY v.ASSET_COUNT DESC) AS VARIANTS
FROM TARGET_MODEL.METRIC m JOIN TARGET_MODEL.METRIC_VARIANT v ON v.FIELD_NAME_KEY = m.FIELD_NAME_KEY GROUP BY 1;

CREATE OR REPLACE VIEW AI.X_METRIC_DIVERGENT AS
SELECT m.METRIC_ID, LISTAGG(d.VALUE:expression::TEXT || ' — ' || d.VALUE:why_different::TEXT || ' Decision: ' || d.VALUE:decision_needed::TEXT, ' || ') AS DIVERGENT_TEXT
FROM TARGET_MODEL.V_METRIC_RECONCILIATION m, LATERAL FLATTEN(INPUT => m.DIVERGENT_VARIANTS) d GROUP BY 1;

CREATE OR REPLACE VIEW AI.X_ENTITY_SOURCES AS
SELECT e.ENTITY_NAME, LISTAGG(s.VALUE:source::TEXT || IFF(s.VALUE:decommissioned::BOOLEAN, ' (DECOMMISSIONED)', '') || IFF(s.VALUE:hosted_vendor::BOOLEAN, ' (HOSTED VENDOR — lineage only)', ''), ', ') AS SOURCES_TEXT
FROM TARGET_MODEL.ENTITY e, LATERAL FLATTEN(INPUT => e.SOURCE_TABLES) s GROUP BY 1;

CREATE OR REPLACE VIEW AI.X_ENTITY_ATTRIBUTES AS
SELECT ENTITY_NAME, LISTAGG(ATTRIBUTE_NAME || ' (' || ATTRIBUTE_CLASS || ', ' || REFERENCING_ASSETS || ' assets)', ', ') WITHIN GROUP (ORDER BY REFERENCING_ASSETS DESC) AS ATTRIBUTES_TEXT
FROM TARGET_MODEL.ENTITY_ATTRIBUTE GROUP BY 1;

CREATE OR REPLACE VIEW AI.X_REG_ASSETS AS
SELECT m.REGISTER_ID, COUNT(*) AS N, LISTAGG('"' || a.TITLE || '" (' || a.ASSET_ID || ')', '; ') AS ASSETS_TEXT
FROM RATIONALIZATION.V_REGULATORY_MATCH m JOIN CONFORMED.ASSET a ON a.ASSET_ID = m.ASSET_ID GROUP BY 1;

CREATE OR REPLACE VIEW AI.X_CONVERSION_DECISIONS AS
SELECT ASSET_ID, LISTAGG(FIELD_NAME || ' (' || COALESCE(AI_RATIONALE, NOTES, 'unresolved ' || ARRAY_TO_STRING(UNRESOLVED_TOKENS, ', ')) || ')', '; ') AS DECISIONS_TEXT
FROM CONVERSION.V_FIELD_CONVERSION WHERE STATUS = 'NEEDS_HUMAN' GROUP BY 1;

CREATE OR REPLACE VIEW AI.ESTATE_RECORD_CORPUS AS
-- one document per asset
SELECT 'ASSET:' || f.ASSET_ID AS DOC_ID, 'asset' AS DOC_KIND, f.TITLE AS SUBJECT,
       f.ASSET_ID || ' — "' || f.TITLE || '" (' || f.PLATFORM || ' ' || f.ASSET_KIND || ', owner ' || COALESCE(f.OWNER_EMAIL, 'unknown')
       || ', ' || COALESCE(f.OWNER_DEPARTMENT, 'no department') || ', subject area ' || COALESCE(f.SUBJECT_AREA, 'unknown') || '). '
       || 'Recommended disposition: ' || f.RECOMMENDED_DISPOSITION || ' by rule ' || f.RULE_ID || ' (' || f.RULE_NAME || ', confidence ' || f.CONFIDENCE || '). '
       || 'Reason: ' || f.REASON || ' '
       || 'Evidence: ' || f.VIEWS_90 || ' views in 90 days, ' || f.VIEWS_365 || ' in 365, ' || f.VIEWERS_90 || ' distinct viewers in 90 days, '
       || f.EXEC_VIEWERS_365 || ' executive viewers, last viewed ' || IFF(f.DAYS_SINCE_LAST_VIEW = 9999, 'never in the extract window', f.DAYS_SINCE_LAST_VIEW || ' days ago')
       || ', ' || f.SUBSCRIPTION_COUNT || ' subscriptions, complexity ' || f.COMPLEXITY_BAND || ' (' || f.COMPLEXITY_POINTS || ' points), data health ' || f.DATA_HEALTH_SCORE || '/100'
       || IFF(f.IS_REGULATORY, ', REGULATORY obligation', '') || IFF(f.HAS_DECOMMISSIONED_SOURCE, ', reads a DECOMMISSIONED source', '')
       || IFF(f.CLUSTER_ID IS NOT NULL, ', member of duplicate cluster ' || f.CLUSTER_ID || ' (' || f.CLUSTER_SIZE || ' assets' || IFF(f.IS_CLUSTER_CANONICAL, ', the canonical', '') || ')', '') || '. '
       || CASE WHEN f.REVIEW_STATUS = 'PENDING' THEN 'Human review: PENDING. Final disposition (provisional): ' || f.FINAL_DISPOSITION || '.'
               ELSE 'Human review: ' || f.REVIEW_STATUS || ' by ' || f.REVIEWER || ' on ' || f.DECIDED_AT::DATE || ' — final disposition ' || f.FINAL_DISPOSITION || '. Note: ' || COALESCE(f.REVIEW_NOTE, '') END
       || IFF(f.IS_SURVIVING, ' Estimated effort ' || ROUND(f.EFFORT_HOURS, 1) || ' hours. Entities: ' || ARRAY_TO_STRING(f.ENTITIES, ', ') || '.', '') AS DOC_TEXT
FROM RATIONALIZATION.V_FINAL_DISPOSITION f
UNION ALL
SELECT 'CLUSTER:' || c.CLUSTER_ID, 'cluster', c.CANONICAL_TITLE,
       c.CLUSTER_ID || ' — duplicate cluster of ' || c.CLUSTER_SIZE || ' assets across ' || c.PLATFORMS || ' in ' || COALESCE(c.SUBJECT_AREA, 'unknown') || '. '
       || 'Canonical: "' || c.CANONICAL_TITLE || '" (' || c.CANONICAL_ASSET_ID || ') carrying ' || ROUND(COALESCE(c.CANONICAL_VIEW_SHARE, 0) * 100) || '% of the cluster''s ' || c.CLUSTER_VIEWS_365 || ' views in 12 months; '
       || c.DEAD_MEMBERS || ' members have not been viewed in a year. Members: ' || m.MEMBERS || '.'
FROM CONFORMED.V_DUPLICATE_CLUSTER_SUMMARY c JOIN AI.X_CLUSTER_MEMBERS m ON m.CLUSTER_ID = c.CLUSTER_ID
UNION ALL
SELECT 'METRIC:' || m.METRIC_ID, 'metric', m.METRIC_NAME,
       m.METRIC_ID || ' — metric "' || m.METRIC_NAME || '" on ' || COALESCE(m.PRIMARY_ENTITY, 'an undetermined entity') || ': ' || m.DEFINITION_STATUS || ', '
       || m.VARIANT_COUNT || ' distinct definitions across ' || m.LANGUAGES || ' used by ' || m.ASSET_COUNT || ' surviving assets (' || m.VIEWS_365 || ' views). '
       || 'Dominant definition (' || m.DOMINANT_SHARE_PCT || '% of assets, ' || m.DOMINANT_LANGUAGE || '): ' || m.DOMINANT_EXPRESSION || '. '
       || 'All variants: ' || COALESCE(v.VARIANTS, '') || '. '
       || CASE WHEN m.RESOLUTION_STATUS IS NULL THEN 'No definition has been proposed yet.'
               ELSE 'Resolution ' || m.RESOLUTION_STATUS || ' (proposed by ' || m.PROPOSED_BY || COALESCE(' using ' || m.MODEL_USED, '') || '): canonical name "' || COALESCE(m.CANONICAL_NAME, '') || '", definition ' || COALESCE(m.DEFINITION_SQL, '') || '. ' || COALESCE(m.DEFINITION_TEXT, '')
                    || ' ' || COALESCE(m.EQUIVALENT_COUNT, 0) || ' variants judged equivalent, ' || COALESCE(m.DIVERGENT_COUNT, 0) || ' divergent' || COALESCE(': ' || dv.DIVERGENT_TEXT, '') || '. '
                    || 'Rationale: ' || COALESCE(m.RATIONALE, '') || IFF(m.RESOLUTION_STATUS = 'CERTIFIED', ' Certified by ' || m.CERTIFIED_BY || '.', ' NOT certified; a named owner must certify.') END
FROM TARGET_MODEL.V_METRIC_RECONCILIATION m
LEFT JOIN AI.X_METRIC_VARIANTS v ON v.METRIC_ID = m.METRIC_ID
LEFT JOIN AI.X_METRIC_DIVERGENT dv ON dv.METRIC_ID = m.METRIC_ID
UNION ALL
SELECT 'ENTITY:' || e.ENTITY_NAME, 'entity', e.ENTITY_NAME,
       e.ENTITY_NAME || ' — target ' || e.ENTITY_ROLE || ' in ' || e.SUBJECT_AREA || ', grain: ' || COALESCE(e.GRAIN, 'to be declared') || '. '
       || 'Unblocks ' || e.SURVIVING_ASSETS || ' surviving assets (' || e.DEPENDING_ASSETS || ' including INVESTIGATE), ' || e.EXEC_ASSETS || ' executive-read, ' || e.REGULATORY_ASSETS || ' regulatory; used by ' || e.SUBJECT_AREAS_USING || ' subject areas' || IFF(e.IS_SHARED, ' (SHARED — foundation wave)', '') || '. '
       || 'First needed in wave ' || e.FIRST_WAVE_NEEDED || ', build order ' || b.BUILD_ORDER || ', ' || b.ATTRIBUTES || ' attributes, ' || b.METRICS || ' metrics (' || b.CONFLICTING_METRICS || ' conflicting), indicative build ' || b.BUILD_HOURS_INDICATIVE || ' hours (TO CONFIRM). '
       || 'Source status: ' || e.SOURCE_STATUS || '. Sources: ' || COALESCE(es.SOURCES_TEXT, '') || '. '
       || 'Attributes: ' || COALESCE(ea.ATTRIBUTES_TEXT, '') || '.'
FROM TARGET_MODEL.ENTITY e
JOIN TARGET_MODEL.V_BUILD_BACKLOG b ON b.ENTITY_NAME = e.ENTITY_NAME
LEFT JOIN AI.X_ENTITY_SOURCES es ON es.ENTITY_NAME = e.ENTITY_NAME
LEFT JOIN AI.X_ENTITY_ATTRIBUTES ea ON ea.ENTITY_NAME = e.ENTITY_NAME
UNION ALL
SELECT 'RULE:' || r.RULE_ID, 'rule', r.RULE_NAME,
       r.RULE_ID || ' — rule "' || r.RULE_NAME || '", priority ' || r.PRIORITY || ', disposition ' || r.DISPOSITION || ', confidence ' || r.CONFIDENCE || IFF(r.IS_ENABLED, '', ' (DISABLED)') || '. '
       || 'Condition: ' || r.CONDITION_SQL || '. Rationale: ' || r.RATIONALE || ' In the latest run it assigned ' || COALESCE(h.ASSETS, 0) || ' assets (' || COALESCE(h.OVERRIDDEN, 0) || ' overridden by reviewers).'
FROM RATIONALIZATION.DISPOSITION_RULE r LEFT JOIN RATIONALIZATION.V_RULE_HITS h ON h.RULE_ID = r.RULE_ID
UNION ALL
SELECT 'POLICY:' || p.POLICY_KEY, 'policy', p.POLICY_KEY,
       'Scoring policy ' || p.POLICY_KEY || ' = ' || p.POLICY_VALUE || '. ' || p.DESCRIPTION || ' Set by ' || p.SET_BY || ' on ' || p.SET_AT::DATE || '.'
FROM RATIONALIZATION.SCORING_POLICY p
UNION ALL
SELECT 'WAVE:' || w.WAVE_NO || ':' || REPLACE(w.SUBJECT_AREA, ' ', '_'), 'wave', w.WAVE_NAME || ' — ' || w.SUBJECT_AREA,
       'Wave ' || w.WAVE_NO || ' (' || w.WAVE_NAME || ') — ' || w.SUBJECT_AREA || ': ' || w.ASSETS || ' assets, ' || w.EFFORT_HOURS || ' estimated hours. '
       || 'Required entities: ' || ARRAY_TO_STRING(w.REQUIRED_ENTITIES, ', ') || '. ' || w.NOTE
FROM RATIONALIZATION.WAVE_PLAN w
UNION ALL
SELECT 'REG:' || r.REGISTER_ID, 'regulatory', r.OBLIGATION,
       r.REGISTER_ID || ' — ' || r.OBLIGATION || ' (' || r.AUTHORITY || ', ' || r.CADENCE || ', owner ' || r.OWNER_ROLE || '). ' || r.NOTE
       || ' Title pattern: ' || r.TITLE_PATTERN || '. Matches ' || COALESCE(x.N, 0) || ' assets: ' || COALESCE(x.ASSETS_TEXT, 'none') || '.'
FROM RATIONALIZATION.REGULATORY_REGISTER r LEFT JOIN AI.X_REG_ASSETS x ON x.REGISTER_ID = r.REGISTER_ID
UNION ALL
SELECT 'CONVERSION:' || r.ASSET_ID, 'conversion', r.TITLE,
       r.ASSET_ID || ' — conversion packet for "' || r.TITLE || '" (' || r.PLATFORM || ', ' || r.FINAL_DISPOSITION || ', wave ' || COALESCE(r.WAVE_NO, 0) || '): status ' || r.CONVERSION_STATUS || ', '
       || r.CALC_FIELDS || ' calculated fields — ' || r.AUTO_FIELDS || ' converted automatically, ' || r.REVIEW_FIELDS || ' need review, ' || r.HUMAN_FIELDS || ' need a human decision, ' || r.AI_ASSISTED_FIELDS || ' assisted by the model. '
       || IFF(r.ENTITIES_WITHOUT_SOURCE > 0, r.ENTITIES_WITHOUT_SOURCE || ' target entities have no live source yet. ', '')
       || COALESCE('Decisions: ' || d.DECISIONS_TEXT, '')
FROM CONVERSION.V_ASSET_CONVERSION_READINESS r LEFT JOIN AI.X_CONVERSION_DECISIONS d ON d.ASSET_ID = r.ASSET_ID
UNION ALL
SELECT 'TEST:' || t.TEST_ID, 'test', t.METRIC_LABEL || ' — ' || t.TITLE,
       t.TEST_ID || ' — reconciliation of "' || t.METRIC_LABEL || '" for "' || t.TITLE || '" (' || t.ASSET_ID || ', ' || t.PLATFORM || '), period ' || t.PERIOD_LABEL || ': ' || t.OUTCOME
       || '. Target (certified) value ' || t.TARGET_VALUE || ', source snapshot ' || t.SOURCE_VALUE || ', variance ' || COALESCE(ROUND(t.VARIANCE_PCT, 3), 0) || '% against materiality ' || t.MATERIALITY_PCT || '%. '
       || 'Source expression (' || t.SOURCE_LANGUAGE || '): ' || t.SOURCE_EXPRESSION || '. ' || t.SNAPSHOT_NOTE
FROM CONVERSION.V_TEST_RESULT t;

-- Materialized so the search service indexes a stable table; rebuild after any run.
CREATE OR REPLACE TABLE AI.ESTATE_RECORD_DOCS AS SELECT * FROM AI.ESTATE_RECORD_CORPUS;

SELECT DOC_KIND, COUNT(*) FROM AI.ESTATE_RECORD_DOCS GROUP BY 1 ORDER BY 2 DESC;
