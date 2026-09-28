-- =============================================================================
-- RATIONALIZATION — wave plan
-- -----------------------------------------------------------------------------
-- Surviving assets are grouped by subject area, because that is how the
-- target model gets built: the data team delivers FACT_DENIAL and DIM_PAYER,
-- and every denial report becomes convertible at once. Subject areas are
-- ordered by what they carry (executive audience, readers, obligations) and
-- cut into waves of roughly equal effort. Wave 0 is the foundation: the
-- conformed dimensions more than one subject area depends on.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA RATIONALIZATION;

CREATE OR REPLACE TABLE SUBJECT_AREA_PRIORITY AS
WITH s AS (
    SELECT COALESCE(SUBJECT_AREA, 'Unknown') AS SUBJECT_AREA,
           COUNT(*)                                         AS SURVIVING_ASSETS,
           COUNT_IF(FINAL_DISPOSITION = 'MIGRATE')          AS MIGRATE_ASSETS,
           COUNT_IF(FINAL_DISPOSITION = 'REBUILD')          AS REBUILD_ASSETS,
           COUNT_IF(FINAL_DISPOSITION = 'SELF_SERVICE')     AS SELF_SERVICE_ASSETS,
           COUNT_IF(EXEC_VIEWERS_365 > 0)                   AS EXEC_ASSETS,
           COUNT_IF(IS_REGULATORY)                          AS REGULATORY_ASSETS,
           SUM(VIEWS_365)                                   AS VIEWS_365,
           SUM(EFFORT_HOURS)                                AS EFFORT_HOURS,
           AVG(CRITICALITY_SCORE)                           AS AVG_CRITICALITY
    FROM V_FINAL_DISPOSITION
    WHERE IS_SURVIVING
    GROUP BY 1
), scored AS (
    SELECT *,
           -- readers and executives first; regulatory deadlines pull forward
           ROUND(0.45 * VIEWS_365 / NULLIF(MAX(VIEWS_365) OVER (), 0) * 100
               + 0.35 * EXEC_ASSETS / NULLIF(MAX(EXEC_ASSETS) OVER (), 0) * 100
               + 0.20 * LEAST(REGULATORY_ASSETS, 3) / 3 * 100, 1) AS PRIORITY_SCORE
    FROM s
), ordered AS (
    SELECT *, ROW_NUMBER() OVER (ORDER BY PRIORITY_SCORE DESC) AS PRIORITY_RANK,
           SUM(EFFORT_HOURS) OVER (ORDER BY PRIORITY_SCORE DESC ROWS UNBOUNDED PRECEDING) AS CUM_EFFORT,
           SUM(EFFORT_HOURS) OVER () AS TOTAL_EFFORT
    FROM scored
)
SELECT SUBJECT_AREA, SURVIVING_ASSETS, MIGRATE_ASSETS, REBUILD_ASSETS, SELF_SERVICE_ASSETS, EXEC_ASSETS,
       REGULATORY_ASSETS, VIEWS_365, ROUND(EFFORT_HOURS) AS EFFORT_HOURS, AVG_CRITICALITY, PRIORITY_SCORE, PRIORITY_RANK,
       LEAST(POLICY('WAVE_COUNT'), 1 + FLOOR((CUM_EFFORT - EFFORT_HOURS) / (TOTAL_EFFORT / POLICY('WAVE_COUNT')))) AS WAVE_NO
FROM ordered;

-- Entities each subject area needs, and which are shared.
CREATE OR REPLACE VIEW V_SUBJECT_AREA_ENTITIES AS
SELECT f.SUBJECT_AREA, e.VALUE::TEXT AS CONFORMED_ENTITY, COUNT(DISTINCT f.ASSET_ID) AS ASSETS
FROM V_FINAL_DISPOSITION f, LATERAL FLATTEN(INPUT => f.ENTITIES) e
WHERE f.IS_SURVIVING
GROUP BY 1, 2;

CREATE OR REPLACE TABLE WAVE_PLAN AS
WITH shared AS (
    SELECT CONFORMED_ENTITY, COUNT(DISTINCT SUBJECT_AREA) AS AREAS, SUM(ASSETS) AS ASSETS
    FROM V_SUBJECT_AREA_ENTITIES GROUP BY 1 HAVING COUNT(DISTINCT SUBJECT_AREA) >= 2
)
SELECT 0 AS WAVE_NO, 'Foundation — conformed dimensions and the certified dataset pattern' AS WAVE_NAME,
       'Shared' AS SUBJECT_AREA, 0 AS ASSETS, 0 AS EFFORT_HOURS,
       (SELECT ARRAY_AGG(CONFORMED_ENTITY) WITHIN GROUP (ORDER BY ASSETS DESC) FROM shared WHERE CONFORMED_ENTITY LIKE 'DIM_%') AS REQUIRED_ENTITIES,
       'Built once, reused by every wave. No report converts until the dimensions it joins exist in the target.' AS NOTE
UNION ALL
SELECT p.WAVE_NO, 'Wave ' || p.WAVE_NO, p.SUBJECT_AREA, p.SURVIVING_ASSETS, p.EFFORT_HOURS,
       (SELECT ARRAY_AGG(CONFORMED_ENTITY) WITHIN GROUP (ORDER BY ASSETS DESC) FROM V_SUBJECT_AREA_ENTITIES e WHERE e.SUBJECT_AREA = p.SUBJECT_AREA),
       'Priority ' || p.PRIORITY_RANK || ' (score ' || p.PRIORITY_SCORE || '): ' || p.EXEC_ASSETS || ' executive-read assets, '
         || p.VIEWS_365 || ' views in 12 months' || IFF(p.REGULATORY_ASSETS > 0, ', ' || p.REGULATORY_ASSETS || ' regulatory', '') || '.'
FROM SUBJECT_AREA_PRIORITY p
ORDER BY 1, 5 DESC;

CREATE OR REPLACE VIEW V_ASSET_WAVE AS
SELECT f.*, COALESCE(p.WAVE_NO, POLICY('WAVE_COUNT')) AS WAVE_NO
FROM V_FINAL_DISPOSITION f
LEFT JOIN SUBJECT_AREA_PRIORITY p ON p.SUBJECT_AREA = COALESCE(f.SUBJECT_AREA, 'Unknown')
WHERE f.IS_SURVIVING;

CREATE OR REPLACE VIEW V_WAVE_SUMMARY AS
SELECT WAVE_NO, COUNT(*) AS ASSETS, COUNT(DISTINCT SUBJECT_AREA) AS SUBJECT_AREAS,
       LISTAGG(DISTINCT SUBJECT_AREA, ', ') WITHIN GROUP (ORDER BY SUBJECT_AREA) AS AREAS,
       ROUND(SUM(EFFORT_HOURS)) AS EFFORT_HOURS, SUM(VIEWS_365) AS VIEWS_365,
       COUNT_IF(FINAL_DISPOSITION = 'MIGRATE') AS MIGRATE_ASSETS, COUNT_IF(FINAL_DISPOSITION = 'REBUILD') AS REBUILD_ASSETS,
       COUNT_IF(FINAL_DISPOSITION = 'SELF_SERVICE') AS SELF_SERVICE_ASSETS
FROM V_ASSET_WAVE GROUP BY 1 ORDER BY 1;
