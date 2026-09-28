-- =============================================================================
-- CONVERSION — workbook specifications and conversion readiness
-- -----------------------------------------------------------------------------
-- For every asset that survives as MIGRATE or REBUILD, one JSON document that
-- says what the Sigma workbook is: the certified dataset (target entity) it
-- sits on, its pages and elements with columns, the converted formulas, the
-- controls, and the list of things a person still has to decide. This is the
-- packet an analytics engineer opens, not a blank canvas.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA CONVERSION;

CREATE OR REPLACE VIEW V_ASSET_CONVERSION_READINESS AS
WITH nosrc AS (
    SELECT f.ASSET_ID, COUNT(*) AS ENTITIES_WITHOUT_SOURCE
    FROM RATIONALIZATION.V_FINAL_DISPOSITION f, LATERAL FLATTEN(INPUT => f.ENTITIES) x
    JOIN TARGET_MODEL.ENTITY e ON e.ENTITY_NAME = x.VALUE::TEXT AND e.SOURCE_STATUS <> 'SOURCE_AVAILABLE'
    GROUP BY 1
)
SELECT f.ASSET_ID, f.TITLE, f.PLATFORM, f.FINAL_DISPOSITION, f.SUBJECT_AREA, w.WAVE_NO, f.COMPLEXITY_BAND,
       COUNT(fc.FIELD_ID)                                         AS CALC_FIELDS,
       COUNT_IF(fc.STATUS = 'AUTO')                               AS AUTO_FIELDS,
       COUNT_IF(fc.STATUS = 'NEEDS_REVIEW')                       AS REVIEW_FIELDS,
       COUNT_IF(fc.STATUS = 'NEEDS_HUMAN')                        AS HUMAN_FIELDS,
       COUNT_IF(fc.METHOD = 'RULES+AI')                           AS AI_ASSISTED_FIELDS,
       ROUND(COUNT_IF(fc.STATUS = 'AUTO') / NULLIF(COUNT(fc.FIELD_ID), 0) * 100) AS AUTO_PCT,
       COALESCE(MAX(n.ENTITIES_WITHOUT_SOURCE), 0)                AS ENTITIES_WITHOUT_SOURCE,
       CASE WHEN COUNT(fc.FIELD_ID) = 0 THEN 'READY'
            WHEN COUNT_IF(fc.STATUS = 'NEEDS_HUMAN') = 0 AND COUNT_IF(fc.STATUS = 'NEEDS_REVIEW') = 0 THEN 'READY'
            WHEN COUNT_IF(fc.STATUS = 'NEEDS_HUMAN') = 0 THEN 'REVIEW'
            ELSE 'BLOCKED' END                                     AS CONVERSION_STATUS
FROM RATIONALIZATION.V_FINAL_DISPOSITION f
LEFT JOIN RATIONALIZATION.V_ASSET_WAVE w ON w.ASSET_ID = f.ASSET_ID
LEFT JOIN FIELD_CONVERSION fc ON fc.ASSET_ID = f.ASSET_ID
LEFT JOIN nosrc n ON n.ASSET_ID = f.ASSET_ID
WHERE f.FINAL_DISPOSITION IN ('MIGRATE', 'REBUILD')
GROUP BY f.ASSET_ID, f.TITLE, f.PLATFORM, f.FINAL_DISPOSITION, f.SUBJECT_AREA, w.WAVE_NO, f.COMPLEXITY_BAND;

-- Each part of the spec is aggregated per asset first, then assembled: Snowflake
-- will not evaluate correlated array subqueries inside OBJECT_CONSTRUCT.
CREATE OR REPLACE TABLE WORKBOOK_SPEC AS
WITH ds AS (
    SELECT x.ASSET_ID, ARRAY_AGG(OBJECT_CONSTRUCT('certified_dataset', 'ANALYTICS.' || e.ENTITY_NAME,
                                                  'role', e.ENTITY_ROLE, 'source_status', e.SOURCE_STATUS)) AS DATA_SOURCES
    FROM (SELECT DISTINCT ASSET_ID, CONFORMED_ENTITY FROM CONFORMED.ASSET_DATA_SOURCE WHERE CONFORMED_ENTITY IS NOT NULL) x
    JOIN TARGET_MODEL.ENTITY e ON e.ENTITY_NAME = x.CONFORMED_ENTITY
    GROUP BY 1
), pages AS (
    SELECT c.ASSET_ID, ARRAY_AGG(OBJECT_CONSTRUCT(
               'name', c.NAME,
               'elements', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(
                   'type', CASE WHEN c.VIZ_TYPE ILIKE '%table%' OR c.VIZ_TYPE ILIKE '%matrix%' OR c.VIZ_TYPE ILIKE '%Cross%' THEN 'table'
                                WHEN c.VIZ_TYPE ILIKE '%kpi%' OR c.VIZ_TYPE ILIKE '%card%' OR c.VIZ_TYPE ILIKE '%Cell%' THEN 'kpi'
                                WHEN c.VIZ_TYPE ILIKE '%line%' OR c.VIZ_TYPE ILIKE '%area%' THEN 'line'
                                WHEN c.VIZ_TYPE ILIKE '%bar%' OR c.VIZ_TYPE ILIKE '%column%' THEN 'bar'
                                WHEN c.VIZ_TYPE ILIKE '%pie%' THEN 'pie'
                                WHEN c.VIZ_TYPE ILIKE '%map%' THEN 'map'
                                ELSE 'table /* from ' || c.VIZ_TYPE || ' */' END,
                   'source_visual', c.VIZ_TYPE,
                   'groupings', c.DIMENSIONS,
                   'values', c.MEASURES,
                   'filters', c.FILTERS,
                   'has_control', c.HAS_PARAMETER)))) WITHIN GROUP (ORDER BY c.NAME) AS PAGES
    FROM CONFORMED.ASSET_COMPONENT c GROUP BY 1
), formulas AS (
    SELECT v.ASSET_ID,
           ARRAY_AGG(OBJECT_CONSTRUCT('name', v.FIELD_NAME, 'sigma', v.EFFECTIVE_EXPRESSION, 'status', v.STATUS,
                                      'source', v.EFFECTIVE_SOURCE, 'confidence', v.CONFIDENCE, 'from', v.SOURCE_EXPRESSION))
             WITHIN GROUP (ORDER BY v.STATUS, v.FIELD_NAME) AS FORMULAS,
           ARRAY_AGG(DISTINCT REGEXP_SUBSTR(v.EFFECTIVE_EXPRESSION, '\\[[^\\]]+-Control\\]')) AS CONTROLS
    FROM V_FIELD_CONVERSION v GROUP BY 1
), decisions AS (
    SELECT v.ASSET_ID,
           ARRAY_AGG(OBJECT_CONSTRUCT('field', v.FIELD_NAME,
                                      'why', COALESCE(v.AI_RATIONALE, v.NOTES, 'unresolved: ' || ARRAY_TO_STRING(v.UNRESOLVED_TOKENS, ', ')))) AS DECISIONS
    FROM V_FIELD_CONVERSION v WHERE v.STATUS = 'NEEDS_HUMAN' GROUP BY 1
)
SELECT r.ASSET_ID, r.TITLE, r.PLATFORM, r.FINAL_DISPOSITION, r.WAVE_NO, r.CONVERSION_STATUS,
       OBJECT_CONSTRUCT(
         'workbook', OBJECT_CONSTRUCT('name', r.TITLE, 'source_asset', OBJECT_CONSTRUCT('platform', r.PLATFORM, 'id', r.ASSET_ID),
                                      'disposition', r.FINAL_DISPOSITION, 'wave', r.WAVE_NO),
         'data_sources', COALESCE(ds.DATA_SOURCES, ARRAY_CONSTRUCT()),
         'pages', COALESCE(p.PAGES, ARRAY_CONSTRUCT()),
         'formulas', COALESCE(f.FORMULAS, ARRAY_CONSTRUCT()),
         'controls', ARRAY_COMPACT(COALESCE(f.CONTROLS, ARRAY_CONSTRUCT())),
         'decisions', COALESCE(d.DECISIONS, ARRAY_CONSTRUCT()),
         'readiness', OBJECT_CONSTRUCT('status', r.CONVERSION_STATUS, 'auto_pct', r.AUTO_PCT,
                                       'human_fields', r.HUMAN_FIELDS, 'entities_without_source', r.ENTITIES_WITHOUT_SOURCE)
       ) AS SPEC
FROM V_ASSET_CONVERSION_READINESS r
LEFT JOIN ds ON ds.ASSET_ID = r.ASSET_ID
LEFT JOIN pages p ON p.ASSET_ID = r.ASSET_ID
LEFT JOIN formulas f ON f.ASSET_ID = r.ASSET_ID
LEFT JOIN decisions d ON d.ASSET_ID = r.ASSET_ID;

CREATE OR REPLACE VIEW V_READINESS_SUMMARY AS
SELECT WAVE_NO, CONVERSION_STATUS, COUNT(*) AS ASSETS, SUM(CALC_FIELDS) AS CALC_FIELDS, SUM(AUTO_FIELDS) AS AUTO_FIELDS,
       SUM(HUMAN_FIELDS) AS HUMAN_FIELDS, ROUND(AVG(AUTO_PCT)) AS AVG_AUTO_PCT
FROM V_ASSET_CONVERSION_READINESS GROUP BY 1, 2 ORDER BY 1, 2;
