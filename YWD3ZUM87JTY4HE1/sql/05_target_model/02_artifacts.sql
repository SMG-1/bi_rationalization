-- =============================================================================
-- TARGET_MODEL — generated build artifacts
-- -----------------------------------------------------------------------------
-- The data team does not receive a diagram. They receive, per entity: a DDL
-- statement, a dbt model with every attribute mapped to its source column (or
-- marked as needing a decision), and a schema.yml with the tests the grain
-- implies. All generated from the derived model, so a change to the model
-- regenerates the artifacts and nothing is hand-maintained.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA TARGET_MODEL;

-- primary source per entity: the live table most attributes come from
CREATE OR REPLACE VIEW V_ATTRIBUTE_SOURCE_COLUMN AS
WITH x AS (
    SELECT ea.ENTITY_NAME, ea.ATTRIBUTE_NAME, ea.ATTRIBUTE_CLASS, ea.REFERENCING_ASSETS,
           s.VALUE::TEXT AS SOURCE_COLUMN,
           SPLIT_PART(s.VALUE::TEXT, '.', 1) AS SOURCE_DATABASE, SPLIT_PART(s.VALUE::TEXT, '.', 2) AS SOURCE_SCHEMA,
           SPLIT_PART(s.VALUE::TEXT, '.', 3) AS SOURCE_TABLE, SPLIT_PART(s.VALUE::TEXT, '.', 4) AS COLUMN_NAME
    FROM ENTITY_ATTRIBUTE ea, LATERAL FLATTEN(INPUT => ea.SOURCE_COLUMNS) s
)
SELECT x.*, COALESCE(c.IS_DECOMMISSIONED, FALSE) AS IS_DECOMMISSIONED,
       NOT COALESCE(c.IS_DECOMMISSIONED, FALSE) AND x.SOURCE_DATABASE <> 'SHAREPOINT' AND NOT COALESCE(c.SYSTEM_FAMILY ILIKE '%(hosted)%', FALSE) AS IS_LIVE
FROM x
LEFT JOIN INVENTORY.SOURCE_SYSTEM_CATALOG c ON c.SOURCE_DATABASE = x.SOURCE_DATABASE AND UPPER(c.SOURCE_TABLE) = UPPER(x.SOURCE_TABLE);

CREATE OR REPLACE VIEW V_ENTITY_PRIMARY_SOURCE AS
SELECT ENTITY_NAME,
       MAX_BY(SOURCE_DATABASE || '.' || SOURCE_SCHEMA || '.' || SOURCE_TABLE, N) AS PRIMARY_SOURCE,
       MAX_BY(SOURCE_DATABASE, N) AS PRIMARY_DATABASE,
       MAX_BY(SOURCE_SCHEMA, N)   AS PRIMARY_SCHEMA,
       MAX_BY(SOURCE_TABLE, N)    AS PRIMARY_TABLE
FROM (SELECT ENTITY_NAME, SOURCE_DATABASE, SOURCE_SCHEMA, SOURCE_TABLE, COUNT(*) N
      FROM V_ATTRIBUTE_SOURCE_COLUMN WHERE IS_LIVE GROUP BY 1, 2, 3, 4)
GROUP BY 1;

CREATE OR REPLACE VIEW V_ATTRIBUTE_SOURCE_EXPR AS
-- the source column on the primary source, if the attribute has one there
SELECT x.ENTITY_NAME, x.ATTRIBUTE_NAME, x.ATTRIBUTE_CLASS, x.REFERENCING_ASSETS,
       MAX(IFF(x.SOURCE_DATABASE || '.' || x.SOURCE_SCHEMA || '.' || x.SOURCE_TABLE = ps.PRIMARY_SOURCE, x.COLUMN_NAME, NULL)) AS PRIMARY_SOURCE_COLUMN,
       MAX(IFF(x.IS_LIVE, x.SOURCE_COLUMN, NULL)) AS ANY_LIVE_SOURCE_COLUMN,
       MAX(x.SOURCE_COLUMN) AS ANY_SOURCE_COLUMN
FROM V_ATTRIBUTE_SOURCE_COLUMN x
LEFT JOIN V_ENTITY_PRIMARY_SOURCE ps ON ps.ENTITY_NAME = x.ENTITY_NAME
GROUP BY 1, 2, 3, 4;

-- Pre-aggregated per entity: Snowflake will not evaluate a correlated LISTAGG
-- inside a string concatenation, so each body is built once here and joined.
CREATE OR REPLACE VIEW V_ARTIFACT_BODY AS
WITH ddl AS (
    SELECT a.ENTITY_NAME,
           LISTAGG('    ' || RPAD(a.ATTRIBUTE_NAME, 34) || TARGET_MODEL.ATTRIBUTE_TYPE(a.ATTRIBUTE_CLASS)
                   || IFF(a.SURVIVING_ASSETS = 0, '   -- referenced only by INVESTIGATE assets', ''), ',\n')
             WITHIN GROUP (ORDER BY a.ATTRIBUTE_CLASS = 'KEY' DESC, a.REFERENCING_ASSETS DESC, a.ATTRIBUTE_NAME) AS DDL_COLUMNS
    FROM ENTITY_ATTRIBUTE a GROUP BY 1
), dbt AS (
    SELECT x.ENTITY_NAME,
           LISTAGG('    ' ||
               CASE WHEN x.PRIMARY_SOURCE_COLUMN IS NOT NULL THEN x.PRIMARY_SOURCE_COLUMN
                    WHEN x.ANY_LIVE_SOURCE_COLUMN IS NOT NULL THEN 'null /* TODO join: ' || x.ANY_LIVE_SOURCE_COLUMN || ' */'
                    ELSE 'null /* DECISION: only source is ' || x.ANY_SOURCE_COLUMN || ' */' END
               || ' as ' || LOWER(x.ATTRIBUTE_NAME), ',\n')
             WITHIN GROUP (ORDER BY x.ATTRIBUTE_CLASS = 'KEY' DESC, x.REFERENCING_ASSETS DESC, x.ATTRIBUTE_NAME) AS DBT_COLUMNS
    FROM V_ATTRIBUTE_SOURCE_EXPR x GROUP BY 1
), pk AS (
    SELECT k.ENTITY_NAME, MIN(k.ATTRIBUTE_NAME) AS PK_ATTRIBUTE
    FROM ENTITY_ATTRIBUTE k JOIN ENTITY e ON e.ENTITY_NAME = k.ENTITY_NAME
    WHERE k.ATTRIBUTE_CLASS = 'KEY' AND k.ATTRIBUTE_NAME LIKE REPLACE(REPLACE(e.ENTITY_NAME, 'FACT_', ''), 'DIM_', '') || '%'
    GROUP BY 1
), yml AS (
    SELECT a.ENTITY_NAME,
           LISTAGG('      - name: ' || LOWER(a.ATTRIBUTE_NAME) || '\n'
                   || '        description: "referenced by ' || a.REFERENCING_ASSETS || ' assets"\n'
                   || IFF(a.ATTRIBUTE_NAME = pk.PK_ATTRIBUTE,
                          '        tests: [not_null' || IFF(e.ENTITY_ROLE = 'DIM', ', unique', '') || ']\n', ''), '')
             WITHIN GROUP (ORDER BY a.ATTRIBUTE_CLASS = 'KEY' DESC, a.REFERENCING_ASSETS DESC, a.ATTRIBUTE_NAME) AS YML_COLUMNS
    FROM ENTITY_ATTRIBUTE a
    JOIN ENTITY e ON e.ENTITY_NAME = a.ENTITY_NAME
    LEFT JOIN pk ON pk.ENTITY_NAME = a.ENTITY_NAME
    GROUP BY 1
)
SELECT e.ENTITY_NAME, ddl.DDL_COLUMNS, dbt.DBT_COLUMNS, yml.YML_COLUMNS
FROM ENTITY e
LEFT JOIN ddl ON ddl.ENTITY_NAME = e.ENTITY_NAME
LEFT JOIN dbt ON dbt.ENTITY_NAME = e.ENTITY_NAME
LEFT JOIN yml ON yml.ENTITY_NAME = e.ENTITY_NAME;

CREATE OR REPLACE TABLE GENERATED_ARTIFACT AS
-- DDL
SELECT e.ENTITY_NAME, 'DDL' AS ARTIFACT_KIND, LOWER(e.ENTITY_NAME) || '.sql' AS FILE_NAME,
       '-- ' || e.ENTITY_NAME || ' (' || e.ENTITY_ROLE || ', ' || e.SUBJECT_AREA || ')\n'
       || '-- Grain: ' || COALESCE(e.GRAIN, 'to be declared') || '\n'
       || '-- Unblocks ' || e.SURVIVING_ASSETS || ' surviving assets; first needed in wave ' || e.FIRST_WAVE_NEEDED || '\n'
       || 'CREATE TABLE IF NOT EXISTS ANALYTICS.' || e.ENTITY_NAME || ' (\n'
       || b.DDL_COLUMNS
       || ',\n    _LOADED_AT                        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()\n);' AS CONTENT
FROM ENTITY e JOIN V_ARTIFACT_BODY b ON b.ENTITY_NAME = e.ENTITY_NAME
UNION ALL
-- dbt model
SELECT e.ENTITY_NAME, 'DBT_MODEL', LOWER(e.ENTITY_NAME) || '.sql',
       '{{ config(materialized=''' || IFF(e.ENTITY_ROLE = 'FACT', 'incremental', 'table') || ''') }}\n'
       || '-- ' || e.ENTITY_NAME || ': ' || COALESCE(e.GRAIN, 'grain to be declared') || '\n'
       || '-- Source status: ' || e.SOURCE_STATUS || '\n'
       || 'select\n' || b.DBT_COLUMNS
       || '\nfrom {{ source(''' || LOWER(COALESCE(ps.PRIMARY_DATABASE, 'TBD')) || ''', ''' || LOWER(COALESCE(ps.PRIMARY_TABLE, 'tbd')) || ''') }}\n'
       || IFF(e.ENTITY_ROLE = 'FACT', '{% if is_incremental() %}\nwhere _loaded_at > (select max(_loaded_at) from {{ this }})\n{% endif %}\n', '')
FROM ENTITY e JOIN V_ARTIFACT_BODY b ON b.ENTITY_NAME = e.ENTITY_NAME
LEFT JOIN V_ENTITY_PRIMARY_SOURCE ps ON ps.ENTITY_NAME = e.ENTITY_NAME
UNION ALL
-- dbt schema.yml
SELECT e.ENTITY_NAME, 'DBT_SCHEMA', LOWER(e.ENTITY_NAME) || '.yml',
       'version: 2\nmodels:\n  - name: ' || LOWER(e.ENTITY_NAME) || '\n'
       || '    description: "' || COALESCE(e.GRAIN, '') || '. Derived from ' || e.SURVIVING_ASSETS || ' surviving BI assets in ' || e.SUBJECT_AREA || '."\n'
       || '    columns:\n' || b.YML_COLUMNS
FROM ENTITY e JOIN V_ARTIFACT_BODY b ON b.ENTITY_NAME = e.ENTITY_NAME;

CREATE OR REPLACE VIEW V_ARTIFACT_SUMMARY AS
SELECT ARTIFACT_KIND, COUNT(*) AS FILES, SUM(LENGTH(CONTENT)) AS BYTES,
       COUNT_IF(CONTENT LIKE '%DECISION:%') AS FILES_WITH_DECISIONS, COUNT_IF(CONTENT LIKE '%TODO join%') AS FILES_WITH_TODOS
FROM GENERATED_ARTIFACT GROUP BY 1;
