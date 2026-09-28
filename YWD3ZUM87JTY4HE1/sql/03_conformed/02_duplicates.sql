-- =============================================================================
-- CONFORMED — duplicate clusters
-- -----------------------------------------------------------------------------
-- "Seventeen versions of the census report" is the finding every
-- rationalization leads with, and it has to be found structurally, not by
-- eye. Two assets are candidates for the same cluster when they share a
-- normalized title OR when they sit on the same conformed entities AND
-- compute the same named metrics AND their titles are close. Candidates are
-- then joined into clusters by label propagation, so A~B and B~C puts A and C
-- together even though they were never compared directly.
--
-- Each cluster nominates a CANONICAL asset: certified first, then the most
-- read, then the most recently maintained. Everything else in the cluster is
-- a consolidation candidate INTO the canonical.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA CONFORMED;

-- Per-asset signature: the entities it reads and the metrics it names.
CREATE OR REPLACE TABLE ASSET_SIGNATURE AS
SELECT a.ASSET_ID, a.TITLE_KEY,
       COALESCE(e.ENTITIES, ARRAY_CONSTRUCT())     AS ENTITIES,
       COALESCE(m.METRIC_KEYS, ARRAY_CONSTRUCT())  AS METRIC_KEYS,
       COALESCE(e.SUBJECT_AREA, 'Unknown')         AS SUBJECT_AREA,
       ARRAY_CAT(COALESCE(e.ENTITIES, ARRAY_CONSTRUCT()), COALESCE(m.METRIC_KEYS, ARRAY_CONSTRUCT())) AS SIGNATURE
FROM ASSET a
LEFT JOIN (
    SELECT ASSET_ID,
           ARRAY_AGG(DISTINCT CONFORMED_ENTITY) WITHIN GROUP (ORDER BY CONFORMED_ENTITY) AS ENTITIES,
           MODE(SUBJECT_AREA) AS SUBJECT_AREA
    FROM ASSET_DATA_SOURCE WHERE CONFORMED_ENTITY IS NOT NULL GROUP BY 1
) e ON e.ASSET_ID = a.ASSET_ID
LEFT JOIN (
    SELECT ASSET_ID, ARRAY_AGG(DISTINCT 'M:' || FIELD_NAME_KEY) WITHIN GROUP (ORDER BY 'M:' || FIELD_NAME_KEY) AS METRIC_KEYS
    FROM ASSET_FIELD WHERE FIELD_KIND = 'CALCULATED' AND ROLE = 'MEASURE' GROUP BY 1
) m ON m.ASSET_ID = a.ASSET_ID;

-- Candidate pairs, blocked on subject area so this is not an n-squared scan
-- of the whole estate.
CREATE OR REPLACE TABLE DUPLICATE_PAIR AS
SELECT x.ASSET_ID AS ASSET_ID_A, y.ASSET_ID AS ASSET_ID_B,
       JAROWINKLER_SIMILARITY(x.TITLE_KEY, y.TITLE_KEY)                  AS TITLE_SIMILARITY,
       ARRAY_SIZE(ARRAY_INTERSECTION(x.SIGNATURE, y.SIGNATURE))
         / NULLIF(ARRAY_SIZE(x.SIGNATURE) + ARRAY_SIZE(y.SIGNATURE)
                  - ARRAY_SIZE(ARRAY_INTERSECTION(x.SIGNATURE, y.SIGNATURE)), 0) AS SIGNATURE_JACCARD,
       CASE WHEN x.TITLE_KEY = y.TITLE_KEY THEN 'SAME_TITLE'
            WHEN JAROWINKLER_SIMILARITY(x.TITLE_KEY, y.TITLE_KEY) >= 94 THEN 'NEAR_TITLE'
            ELSE 'SAME_CONTENT' END                                      AS MATCH_BASIS
FROM ASSET_SIGNATURE x
JOIN ASSET_SIGNATURE y
  ON x.SUBJECT_AREA = y.SUBJECT_AREA AND x.ASSET_ID < y.ASSET_ID
-- A shared title is evidence only when the two assets also read the same
-- thing: "Untitled 12" and "Untitled 36" share a title and nothing else.
WHERE (x.TITLE_KEY = y.TITLE_KEY AND x.TITLE_KEY NOT IN ('', 'untitled', 'sheet1', 'ad hoc')
       AND ARRAY_SIZE(ARRAY_INTERSECTION(x.ENTITIES, y.ENTITIES)) >= 1)
   OR (JAROWINKLER_SIMILARITY(x.TITLE_KEY, y.TITLE_KEY) >= 94
       AND x.TITLE_KEY NOT IN ('', 'untitled', 'sheet1', 'ad hoc') AND y.TITLE_KEY NOT IN ('', 'untitled', 'sheet1', 'ad hoc')
       AND ARRAY_SIZE(ARRAY_INTERSECTION(x.ENTITIES, y.ENTITIES)) >= 1)
   -- same entities AND the same named metrics AND a clearly related title:
   -- content alone is not enough, because every report in a subject area
   -- reads the same three tables.
   OR (ARRAY_SIZE(x.SIGNATURE) >= 3
       AND ARRAY_SIZE(ARRAY_INTERSECTION(x.SIGNATURE, y.SIGNATURE))
           / NULLIF(ARRAY_SIZE(x.SIGNATURE) + ARRAY_SIZE(y.SIGNATURE) - ARRAY_SIZE(ARRAY_INTERSECTION(x.SIGNATURE, y.SIGNATURE)), 0) >= 0.85
       AND JAROWINKLER_SIMILARITY(x.TITLE_KEY, y.TITLE_KEY) >= 86);

-- Label propagation to connected components.
CREATE OR REPLACE TABLE DUPLICATE_CLUSTER_MEMBER (
    ASSET_ID TEXT, CLUSTER_LABEL TEXT
);
INSERT INTO DUPLICATE_CLUSTER_MEMBER SELECT ASSET_ID, ASSET_ID FROM ASSET;

CREATE OR REPLACE PROCEDURE CONFORMED.SP_PROPAGATE_CLUSTERS()
RETURNS TEXT
LANGUAGE SQL
AS
$$
DECLARE
    changed NUMBER := 1;
    iter NUMBER := 0;
BEGIN
    WHILE (changed > 0 AND iter < 30) DO
        CREATE OR REPLACE TEMPORARY TABLE CONFORMED._NEXT AS
        SELECT m.ASSET_ID, LEAST(m.CLUSTER_LABEL, COALESCE(MIN(n.CLUSTER_LABEL), m.CLUSTER_LABEL)) AS CLUSTER_LABEL
        FROM DUPLICATE_CLUSTER_MEMBER m
        LEFT JOIN (
            SELECT p.ASSET_ID_A AS ASSET_ID, mb.CLUSTER_LABEL FROM DUPLICATE_PAIR p JOIN DUPLICATE_CLUSTER_MEMBER mb ON mb.ASSET_ID = p.ASSET_ID_B
            UNION ALL
            SELECT p.ASSET_ID_B, ma.CLUSTER_LABEL FROM DUPLICATE_PAIR p JOIN DUPLICATE_CLUSTER_MEMBER ma ON ma.ASSET_ID = p.ASSET_ID_A
        ) n ON n.ASSET_ID = m.ASSET_ID
        GROUP BY m.ASSET_ID, m.CLUSTER_LABEL;
        SELECT COUNT(*) INTO :changed
        FROM CONFORMED._NEXT x JOIN DUPLICATE_CLUSTER_MEMBER m ON m.ASSET_ID = x.ASSET_ID
        WHERE x.CLUSTER_LABEL <> m.CLUSTER_LABEL;
        DELETE FROM DUPLICATE_CLUSTER_MEMBER;
        INSERT INTO DUPLICATE_CLUSTER_MEMBER SELECT * FROM CONFORMED._NEXT;
        iter := iter + 1;
    END WHILE;
    RETURN 'converged after ' || iter || ' iterations';
END;
$$;
CALL CONFORMED.SP_PROPAGATE_CLUSTERS();

-- Clusters with a canonical member. Singletons are not clusters.
CREATE OR REPLACE TABLE DUPLICATE_CLUSTER AS
WITH ranked AS (
    SELECT m.CLUSTER_LABEL, m.ASSET_ID, a.TITLE, a.PLATFORM,
           COUNT(*) OVER (PARTITION BY m.CLUSTER_LABEL) AS CLUSTER_SIZE,
           ROW_NUMBER() OVER (PARTITION BY m.CLUSTER_LABEL
                              ORDER BY a.IS_CERTIFIED DESC, a.IS_PERSONAL_SPACE ASC, a.IS_SANDBOX ASC,
                                       us.VIEWS_365 DESC, us.VIEWERS_365 DESC, a.MODIFIED_AT DESC) AS RN
    FROM DUPLICATE_CLUSTER_MEMBER m
    JOIN ASSET a ON a.ASSET_ID = m.ASSET_ID
    JOIN USAGE_SUMMARY us ON us.ASSET_ID = m.ASSET_ID
)
SELECT 'DUP-' || LPAD(DENSE_RANK() OVER (ORDER BY CLUSTER_LABEL), 4, '0') AS CLUSTER_ID,
       CLUSTER_LABEL, ASSET_ID, TITLE, PLATFORM, CLUSTER_SIZE,
       RN = 1 AS IS_CANONICAL,
       FIRST_VALUE(ASSET_ID) OVER (PARTITION BY CLUSTER_LABEL ORDER BY RN) AS CANONICAL_ASSET_ID,
       FIRST_VALUE(TITLE)    OVER (PARTITION BY CLUSTER_LABEL ORDER BY RN) AS CANONICAL_TITLE
FROM ranked
WHERE CLUSTER_SIZE > 1;

-- PLATFORMS is sorted (WITHIN GROUP) so the string is identical run to run;
-- without it the same platforms came back in a different order each query.
CREATE OR REPLACE VIEW V_DUPLICATE_CLUSTER_SUMMARY COPY GRANTS AS
SELECT c.CLUSTER_ID, c.CANONICAL_TITLE, c.CANONICAL_ASSET_ID, c.CLUSTER_SIZE,
       COUNT(DISTINCT c.PLATFORM)                           AS PLATFORM_COUNT,
       LISTAGG(DISTINCT c.PLATFORM, ', ') WITHIN GROUP (ORDER BY c.PLATFORM) AS PLATFORMS,
       SUM(us.VIEWS_365)                                    AS CLUSTER_VIEWS_365,
       SUM(IFF(c.IS_CANONICAL, us.VIEWS_365, 0)) / NULLIF(SUM(us.VIEWS_365), 0) AS CANONICAL_VIEW_SHARE,
       COUNT_IF(us.DAYS_SINCE_LAST_VIEW > 365)              AS DEAD_MEMBERS,
       MODE(s.SUBJECT_AREA)                                 AS SUBJECT_AREA
FROM DUPLICATE_CLUSTER c
JOIN USAGE_SUMMARY us ON us.ASSET_ID = c.ASSET_ID
JOIN ASSET_SIGNATURE s ON s.ASSET_ID = c.ASSET_ID
GROUP BY 1, 2, 3, 4;

-- The demo database is readable by PUBLIC (phase 8); re-grant after a replace.
GRANT SELECT ON VIEW V_DUPLICATE_CLUSTER_SUMMARY TO ROLE PUBLIC;
