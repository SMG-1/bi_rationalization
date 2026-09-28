-- =============================================================================
-- APP — Setup Wizard objects: drop the app into a client account, load their
-- extracts into INVENTORY from the app, build the catalog and register, and
-- run the pipeline from inside Snowflake. No local Python after deploy.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE WAREHOUSE BI_MOD_WH;
USE SCHEMA APP;

-- Header-driven CSV format so a client can upload columns in any order.
CREATE FILE FORMAT IF NOT EXISTS INVENTORY.CSV_HEADER
    TYPE = CSV PARSE_HEADER = TRUE FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    EMPTY_FIELD_AS_NULL = TRUE NULL_IF = ('', 'NULL') ESCAPE_UNENCLOSED_FIELD = NONE;

-- The common HCLS source tables, as a starting catalog for a new client. Seeded
-- from the demo catalog at deploy; the wizard lets the client accept, edit or add.
CREATE TABLE IF NOT EXISTS APP.SOURCE_CATALOG_SEED AS
SELECT SOURCE_DATABASE, SOURCE_SCHEMA, SOURCE_TABLE, SUBJECT_AREA, ENTITY_ROLE, CONFORMED_ENTITY, GRAIN, SYSTEM_FAMILY
FROM INVENTORY.SOURCE_SYSTEM_CATALOG;

-- Row counts per landing table — what has been loaded.
CREATE OR REPLACE VIEW APP.V_EXTRACT_STATUS AS
SELECT 'TABLEAU' PLATFORM, 'TABLEAU_WORKBOOKS' TABLE_NAME, 'Workbooks (REST API)' WHAT, COUNT(*) ROWS_LOADED FROM INVENTORY.TABLEAU_WORKBOOKS
UNION ALL SELECT 'TABLEAU', 'TABLEAU_VIEWS', 'Views / sheets', COUNT(*) FROM INVENTORY.TABLEAU_VIEWS
UNION ALL SELECT 'TABLEAU', 'TABLEAU_DATASOURCES', 'Data sources (Metadata API)', COUNT(*) FROM INVENTORY.TABLEAU_DATASOURCES
UNION ALL SELECT 'TABLEAU', 'TABLEAU_CALCULATED_FIELDS', 'Calculated fields', COUNT(*) FROM INVENTORY.TABLEAU_CALCULATED_FIELDS
UNION ALL SELECT 'TABLEAU', 'TABLEAU_FIELD_LINEAGE', 'Field lineage (Metadata API)', COUNT(*) FROM INVENTORY.TABLEAU_FIELD_LINEAGE
UNION ALL SELECT 'TABLEAU', 'TABLEAU_VIEWS_STATS', 'views_stats (usage)', COUNT(*) FROM INVENTORY.TABLEAU_VIEWS_STATS
UNION ALL SELECT 'TABLEAU', 'TABLEAU_SUBSCRIPTIONS', 'Subscriptions', COUNT(*) FROM INVENTORY.TABLEAU_SUBSCRIPTIONS
UNION ALL SELECT 'TABLEAU', 'TABLEAU_EXTRACT_REFRESHES', 'Extract refresh runs', COUNT(*) FROM INVENTORY.TABLEAU_EXTRACT_REFRESHES
UNION ALL SELECT 'POWER_BI', 'PBI_WORKSPACES', 'Workspaces (admin API)', COUNT(*) FROM INVENTORY.PBI_WORKSPACES
UNION ALL SELECT 'POWER_BI', 'PBI_REPORTS', 'Reports', COUNT(*) FROM INVENTORY.PBI_REPORTS
UNION ALL SELECT 'POWER_BI', 'PBI_REPORT_PAGES', 'Report pages / visuals', COUNT(*) FROM INVENTORY.PBI_REPORT_PAGES
UNION ALL SELECT 'POWER_BI', 'PBI_DATASETS', 'Datasets (scanner)', COUNT(*) FROM INVENTORY.PBI_DATASETS
UNION ALL SELECT 'POWER_BI', 'PBI_DATASET_TABLES', 'Dataset tables + M source', COUNT(*) FROM INVENTORY.PBI_DATASET_TABLES
UNION ALL SELECT 'POWER_BI', 'PBI_MEASURES', 'DAX measures', COUNT(*) FROM INVENTORY.PBI_MEASURES
UNION ALL SELECT 'POWER_BI', 'PBI_ACTIVITY_EVENTS', 'Activity events (usage)', COUNT(*) FROM INVENTORY.PBI_ACTIVITY_EVENTS
UNION ALL SELECT 'POWER_BI', 'PBI_REFRESH_HISTORY', 'Refresh history', COUNT(*) FROM INVENTORY.PBI_REFRESH_HISTORY
UNION ALL SELECT 'POWER_BI', 'PBI_SUBSCRIPTIONS', 'Subscriptions', COUNT(*) FROM INVENTORY.PBI_SUBSCRIPTIONS
UNION ALL SELECT 'SAP_BO', 'BO_UNIVERSES', 'Universes (CMS)', COUNT(*) FROM INVENTORY.BO_UNIVERSES
UNION ALL SELECT 'SAP_BO', 'BO_UNIVERSE_OBJECTS', 'Universe objects', COUNT(*) FROM INVENTORY.BO_UNIVERSE_OBJECTS
UNION ALL SELECT 'SAP_BO', 'BO_WEBI_DOCUMENTS', 'Webi / Crystal documents', COUNT(*) FROM INVENTORY.BO_WEBI_DOCUMENTS
UNION ALL SELECT 'SAP_BO', 'BO_WEBI_QUERIES', 'Document queries', COUNT(*) FROM INVENTORY.BO_WEBI_QUERIES
UNION ALL SELECT 'SAP_BO', 'BO_WEBI_VARIABLES', 'Variables (formulas)', COUNT(*) FROM INVENTORY.BO_WEBI_VARIABLES
UNION ALL SELECT 'SAP_BO', 'BO_REPORT_ELEMENTS', 'Report elements', COUNT(*) FROM INVENTORY.BO_REPORT_ELEMENTS
UNION ALL SELECT 'SAP_BO', 'BO_AUDIT_EVENTS', 'Audit events (usage)', COUNT(*) FROM INVENTORY.BO_AUDIT_EVENTS
UNION ALL SELECT 'SAP_BO', 'BO_SCHEDULES', 'Schedules', COUNT(*) FROM INVENTORY.BO_SCHEDULES
UNION ALL SELECT 'MEDEANALYTICS', 'MEDE_REPORTS', 'Report catalog (admin export)', COUNT(*) FROM INVENTORY.MEDE_REPORTS
UNION ALL SELECT 'MEDEANALYTICS', 'MEDE_REPORT_FIELDS', 'Report fields / measures', COUNT(*) FROM INVENTORY.MEDE_REPORT_FIELDS
UNION ALL SELECT 'MEDEANALYTICS', 'MEDE_REPORT_SECTIONS', 'Report sections', COUNT(*) FROM INVENTORY.MEDE_REPORT_SECTIONS
UNION ALL SELECT 'MEDEANALYTICS', 'MEDE_USER_ACTIVITY', 'User activity (usage)', COUNT(*) FROM INVENTORY.MEDE_USER_ACTIVITY
UNION ALL SELECT 'MEDEANALYTICS', 'MEDE_DELIVERIES', 'Scheduled deliveries', COUNT(*) FROM INVENTORY.MEDE_DELIVERIES
UNION ALL SELECT 'SHARED', 'USER_DIRECTORY', 'HR directory', COUNT(*) FROM INVENTORY.USER_DIRECTORY
UNION ALL SELECT 'SHARED', 'SOURCE_SYSTEM_CATALOG', 'Source system catalog', COUNT(*) FROM INVENTORY.SOURCE_SYSTEM_CATALOG;

-- Every physical table the extracts reference, and whether the catalog knows it.
CREATE OR REPLACE VIEW APP.V_REFERENCED_SOURCE_TABLES AS
WITH refs AS (
    SELECT UPPER(ds.DATABASE_NAME) DB_, UPPER(ds.SCHEMA_NAME) SCH, UPPER(t.VALUE::TEXT) TBL, 'TABLEAU' PLATFORM, ds.WORKBOOK_ID ASSET_ID
    FROM INVENTORY.TABLEAU_DATASOURCES ds, LATERAL FLATTEN(INPUT => PARSE_JSON(ds.TABLE_NAMES)) t
    UNION ALL
    SELECT UPPER(dt.SOURCE_DATABASE), UPPER(dt.SOURCE_SCHEMA), UPPER(dt.SOURCE_TABLE), 'POWER_BI', r.REPORT_ID
    FROM INVENTORY.PBI_DATASET_TABLES dt JOIN INVENTORY.PBI_REPORTS r ON r.DATASET_ID = dt.DATASET_ID
    UNION ALL
    SELECT UPPER(u.DATABASE_NAME), UPPER(SPLIT_PART(REGEXP_REPLACE(o.SELECT_SQL, '^sum\\(|\\)$', ''), '.', 1)),
           UPPER(SPLIT_PART(REGEXP_REPLACE(o.SELECT_SQL, '^sum\\(|\\)$', ''), '.', 2)), 'SAP_BO', d.DOC_KEY
    FROM INVENTORY.BO_WEBI_DOCUMENTS d
    JOIN INVENTORY.BO_WEBI_QUERIES q ON q.DOC_SI_ID = d.SI_ID
    JOIN INVENTORY.BO_UNIVERSES u ON u.SI_ID = q.UNIVERSE_SI_ID
    JOIN INVENTORY.BO_UNIVERSE_OBJECTS o ON o.UNIVERSE_SI_ID = u.SI_ID
    UNION ALL
    SELECT 'MEDE_PLATFORM', UPPER(SPLIT_PART(d.VALUE::TEXT, '.', 1)), UPPER(SPLIT_PART(d.VALUE::TEXT, '.', 2)), 'MEDEANALYTICS', r.REPORT_ID
    FROM INVENTORY.MEDE_REPORTS r, LATERAL FLATTEN(INPUT => PARSE_JSON(r.DATA_DOMAINS)) d
)
SELECT r.DB_ AS SOURCE_DATABASE, r.SCH AS SOURCE_SCHEMA, r.TBL AS SOURCE_TABLE,
       COUNT(DISTINCT r.ASSET_ID) AS ASSETS_REFERENCING, LISTAGG(DISTINCT r.PLATFORM, ', ') AS PLATFORMS,
       c.SOURCE_TABLE IS NOT NULL AS IS_CATALOGED,
       COALESCE(c.SUBJECT_AREA, s.SUBJECT_AREA) AS SUBJECT_AREA, COALESCE(c.ENTITY_ROLE, s.ENTITY_ROLE) AS ENTITY_ROLE,
       COALESCE(c.CONFORMED_ENTITY, s.CONFORMED_ENTITY) AS CONFORMED_ENTITY, COALESCE(c.GRAIN, s.GRAIN) AS GRAIN,
       COALESCE(c.IS_DECOMMISSIONED, FALSE) AS IS_DECOMMISSIONED, COALESCE(c.SYSTEM_FAMILY, s.SYSTEM_FAMILY) AS SYSTEM_FAMILY,
       s.SOURCE_TABLE IS NOT NULL AND c.SOURCE_TABLE IS NULL AS SUGGESTED_FROM_SEED
FROM refs r
LEFT JOIN INVENTORY.SOURCE_SYSTEM_CATALOG c ON UPPER(c.SOURCE_DATABASE) = r.DB_ AND UPPER(c.SOURCE_TABLE) = r.TBL
LEFT JOIN APP.SOURCE_CATALOG_SEED s ON UPPER(s.SOURCE_TABLE) = r.TBL AND UPPER(s.SOURCE_DATABASE) = r.DB_
WHERE r.TBL IS NOT NULL AND r.TBL <> ''
GROUP BY 1, 2, 3, 6, 7, 8, 9, 10, 11, 12, 13;

-- ----------------------------------------------------------- the runner ------
-- The pipeline as rows: which SQL file (on the stage) or CALL each step is, and
-- whether the in-app run includes it. Seed files are deploy-only, so a client's
-- edits to policy, rules, register and test templates survive every re-run.
-- Phases follow build_all.py: 6.8 is the trusted-definitions plane (shipped as
-- code — it is rebuilt from the staged SQL, so edit definitions in the repo, not
-- in the table), 7 the corpora, search and semantic views, 9 the copilot (skills
-- copied from @WORKBENCH_STAGE/skills/, where build_all.py stages them, then the
-- agent). Phases 1, 2 and 8 (setup, extract upload, app) stay deploy-time.
CREATE OR REPLACE TABLE APP.PIPELINE_STEP (
    SEQ NUMBER, PHASE NUMBER(4,1), LABEL TEXT, KIND TEXT, TARGET TEXT, IS_AI BOOLEAN DEFAULT FALSE, IN_APP BOOLEAN DEFAULT TRUE
);
INSERT INTO APP.PIPELINE_STEP (SEQ, PHASE, LABEL, KIND, TARGET, IS_AI) VALUES
 (10, 3,   'Conform: asset model, fields, lineage, usage',      'FILE', 'sql/03_conformed/01_asset_model.sql', FALSE),
 (20, 3,   'Conform: duplicate clusters',                         'FILE', 'sql/03_conformed/02_duplicates.sql', FALSE),
 (30, 4,   'Rationalize: scores and asset profile',               'FILE', 'sql/04_rationalization/01_scores.sql', FALSE),
 (40, 4,   'Rationalize: rule engine and final dispositions',     'FILE', 'sql/04_rationalization/02_rule_engine.sql', FALSE),
 (50, 4,   'Rationalize: wave plan',                              'FILE', 'sql/04_rationalization/03_wave_plan.sql', FALSE),
 (60, 5,   'Target model: entities, attributes, metrics, mapping','FILE', 'sql/05_target_model/01_derive_model.sql', FALSE),
 (70, 5,   'Target model: DDL, dbt, schema.yml',                  'FILE', 'sql/05_target_model/02_artifacts.sql', FALSE),
 (75, 5,   'Target model: metric proposer (define)',              'FILE', 'sql/05_target_model/03_metric_ai.sql', FALSE),
 (80, 5.5, 'Claude: metric reconciliation proposals',             'CALL', 'CALL TARGET_MODEL.SP_PROPOSE_METRIC_DEFINITIONS(12)', TRUE),
 (90, 6,   'Convert: rule-based translation',                     'FILE', 'sql/06_conversion/02_translator.sql', FALSE),
 (95, 6,   'Convert: residual translator (define)',               'FILE', 'sql/06_conversion/03_ai_residual.sql', FALSE),
 (100, 6,  'Convert: workbook specs and readiness',               'FILE', 'sql/06_conversion/04_workbook_spec.sql', FALSE),
 (110, 6,  'Reconcile: test cases and run',                       'FILE', 'sql/06_conversion/06_reconciliation.sql', FALSE),
 (120, 6.5,'Claude: residual expression translation',             'CALL', 'CALL CONVERSION.SP_AI_TRANSLATE(NULL)', TRUE),
 (125, 6.8,'Definitions: KPIs, methods, certified questions, change log', 'FILE', 'sql/06b_definitions/01_definitions.sql', FALSE),
 (130, 7,  'AI: estate record corpus',                            'FILE', 'sql/07_ai/01_estate_record.sql', FALSE),
 (140, 7,  'AI: search services and semantic views',              'FILE', 'sql/07_ai/03_search_and_semantic.sql', FALSE),
 (150, 7,  'AI: definitions corpus and DEFINITION_SEARCH',        'FILE', 'sql/07_ai/04_definition_search.sql', FALSE),
 (160, 9,  'Copilot: skills to @AI.SKILLS_STAGE',                 'CALL',
  'BEGIN CREATE STAGE IF NOT EXISTS BI_MODERNIZATION.AI.SKILLS_STAGE DIRECTORY = (ENABLE = TRUE); COPY FILES INTO @BI_MODERNIZATION.AI.SKILLS_STAGE/skills/ FROM @BI_MODERNIZATION.APP.WORKBENCH_STAGE/skills/; ALTER STAGE BI_MODERNIZATION.AI.SKILLS_STAGE REFRESH; RETURN ''skills copied''; END;', FALSE),
 (170, 9,  'Copilot: BI Migration Copilot agent (CoWork)',        'FILE', 'sql/09_agent/01_agent.sql', FALSE);

CREATE TABLE IF NOT EXISTS APP.PIPELINE_RUN (
    RUN_ID NUMBER, SEQ NUMBER, LABEL TEXT, STATUS TEXT, MESSAGE TEXT,
    STARTED_AT TIMESTAMP_NTZ, ENDED_AT TIMESTAMP_NTZ, RUN_BY TEXT DEFAULT CURRENT_USER()
);

-- Phases are FLOAT: a NUMBER argument has scale 0 and would round 6.8 to 7.
-- Drop the old NUMBER-argument signatures so calls are not ambiguous.
DROP PROCEDURE IF EXISTS APP.SP_RUN_PIPELINE(NUMBER, NUMBER, BOOLEAN);
DROP PROCEDURE IF EXISTS APP.SP_START_PIPELINE(NUMBER, NUMBER, BOOLEAN);
CREATE OR REPLACE PROCEDURE APP.SP_RUN_PIPELINE(FROM_PHASE FLOAT DEFAULT 3, TO_PHASE FLOAT DEFAULT 9, INCLUDE_AI BOOLEAN DEFAULT TRUE)
RETURNS TEXT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    run_id NUMBER;
    steps CURSOR FOR SELECT SEQ, PHASE, LABEL, KIND, TARGET, IS_AI FROM APP.PIPELINE_STEP WHERE IN_APP ORDER BY SEQ;
    v_seq NUMBER; v_phase NUMBER(4,1); v_label TEXT; v_kind TEXT; v_target TEXT; v_ai BOOLEAN; stmt TEXT; done NUMBER := 0;
BEGIN
    SELECT COALESCE(MAX(RUN_ID), 0) + 1 INTO :run_id FROM APP.PIPELINE_RUN;
    FOR r IN steps DO
        v_seq := r.SEQ; v_phase := r.PHASE; v_label := r.LABEL; v_kind := r.KIND; v_target := r.TARGET; v_ai := r.IS_AI;
        IF (v_phase < FROM_PHASE OR v_phase > TO_PHASE) THEN
            CONTINUE;
        END IF;
        IF (v_ai AND NOT INCLUDE_AI) THEN
            INSERT INTO APP.PIPELINE_RUN (RUN_ID, SEQ, LABEL, STATUS, MESSAGE, STARTED_AT, ENDED_AT)
            VALUES (:run_id, :v_seq, :v_label, 'SKIPPED', 'AI step skipped by request', CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP());
            CONTINUE;
        END IF;
        INSERT INTO APP.PIPELINE_RUN (RUN_ID, SEQ, LABEL, STATUS, STARTED_AT) VALUES (:run_id, :v_seq, :v_label, 'RUNNING', CURRENT_TIMESTAMP());
        stmt := IFF(v_kind = 'FILE', 'EXECUTE IMMEDIATE FROM ''@BI_MODERNIZATION.APP.WORKBENCH_STAGE/' || v_target || '''', v_target);
        BEGIN
            EXECUTE IMMEDIATE :stmt;
            UPDATE APP.PIPELINE_RUN SET STATUS = 'OK', ENDED_AT = CURRENT_TIMESTAMP() WHERE RUN_ID = :run_id AND SEQ = :v_seq;
            done := done + 1;
        EXCEPTION
            WHEN OTHER THEN
                LET err TEXT := SQLERRM;
                UPDATE APP.PIPELINE_RUN SET STATUS = 'FAILED', MESSAGE = :err, ENDED_AT = CURRENT_TIMESTAMP() WHERE RUN_ID = :run_id AND SEQ = :v_seq;
                RETURN 'run ' || run_id || ' FAILED at step ' || v_seq || ' (' || v_label || '): ' || err;
        END;
    END FOR;
    RETURN 'run ' || run_id || ': ' || done || ' steps completed';
END;
$$;

-- Load one uploaded extract file into its landing table (header-driven).
CREATE OR REPLACE PROCEDURE APP.SP_LOAD_EXTRACT(TABLE_NAME TEXT, FILE_NAME TEXT, REPLACE_ROWS BOOLEAN DEFAULT FALSE)
RETURNS TEXT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    stmt TEXT; n NUMBER;
BEGIN
    IF (NOT REGEXP_LIKE(TABLE_NAME, '^[A-Z0-9_]+$') OR NOT REGEXP_LIKE(FILE_NAME, '^[A-Za-z0-9_.-]+$')) THEN
        RETURN 'invalid table or file name';
    END IF;
    IF (REPLACE_ROWS) THEN
        stmt := 'TRUNCATE TABLE INVENTORY.' || TABLE_NAME;
        EXECUTE IMMEDIATE :stmt;
    END IF;
    stmt := 'COPY INTO INVENTORY.' || TABLE_NAME || ' FROM @INVENTORY.LANDING/' || FILE_NAME
         || ' FILE_FORMAT = (FORMAT_NAME = INVENTORY.CSV_HEADER) MATCH_BY_COLUMN_NAME = CASE_INSENSITIVE FORCE = TRUE ON_ERROR = ABORT_STATEMENT';
    EXECUTE IMMEDIATE :stmt;
    stmt := 'SELECT COUNT(*) FROM INVENTORY.' || TABLE_NAME;
    LET rs RESULTSET := (EXECUTE IMMEDIATE :stmt);
    LET c CURSOR FOR rs; OPEN c; FETCH c INTO n; CLOSE c;
    RETURN 'loaded ' || FILE_NAME || ' into INVENTORY.' || TABLE_NAME || ' (' || n || ' rows now)';
END;
$$;

-- Start from a clean estate (keeps catalog seed, policy, rules, register).
CREATE OR REPLACE PROCEDURE APP.SP_CLEAR_INVENTORY()
RETURNS TEXT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    tabs CURSOR FOR SELECT TABLE_NAME FROM APP.V_EXTRACT_STATUS WHERE TABLE_NAME <> 'SOURCE_SYSTEM_CATALOG';
    stmt TEXT;
BEGIN
    FOR t IN tabs DO
        LET nm TEXT := t.TABLE_NAME;
        stmt := 'TRUNCATE TABLE INVENTORY.' || nm;
        EXECUTE IMMEDIATE :stmt;
    END FOR;
    TRUNCATE TABLE INVENTORY._GENERATOR_TRUTH;
    RETURN 'inventory cleared; catalog, policy, rules and register kept';
END;
$$;

GRANT USAGE ON ALL PROCEDURES IN SCHEMA APP TO ROLE PUBLIC;
GRANT SELECT ON ALL VIEWS IN SCHEMA APP TO ROLE PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA APP TO ROLE PUBLIC;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA INVENTORY TO ROLE PUBLIC;
GRANT INSERT, UPDATE, DELETE ON TABLE RATIONALIZATION.REGULATORY_REGISTER TO ROLE PUBLIC;
GRANT INSERT, UPDATE, DELETE ON TABLE RATIONALIZATION.REGULATORY_ASSET TO ROLE PUBLIC;
GRANT INSERT, UPDATE, DELETE ON TABLE RATIONALIZATION.DISPOSITION_RULE TO ROLE PUBLIC;
GRANT INSERT, UPDATE, DELETE ON TABLE CONVERSION.METRIC_TEST_TEMPLATE TO ROLE PUBLIC;
GRANT READ, WRITE ON STAGE INVENTORY.LANDING TO ROLE PUBLIC;
GRANT READ ON STAGE APP.WORKBENCH_STAGE TO ROLE PUBLIC;

-- ----------------------------------------------------- async runner ---------
-- Fire the pipeline as a task so the page does not block. Serverless when the
-- role holds EXECUTE MANAGED TASK; otherwise a warehouse-backed task (still
-- asynchronous). The run log is the progress signal either way.
CREATE OR REPLACE PROCEDURE APP.SP_START_PIPELINE(FROM_PHASE FLOAT DEFAULT 3, TO_PHASE FLOAT DEFAULT 9, INCLUDE_AI BOOLEAN DEFAULT TRUE)
RETURNS TEXT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    body TEXT; mode TEXT;
    running NUMBER;
BEGIN
    SELECT COUNT(*) INTO :running FROM APP.PIPELINE_RUN
     WHERE STATUS = 'RUNNING' AND STARTED_AT > DATEADD(hour, -2, CURRENT_TIMESTAMP());
    IF (running > 0) THEN
        RETURN 'a pipeline step is still RUNNING (started within 2 hours); wait for it or check the task history';
    END IF;
    body := 'CALL BI_MODERNIZATION.APP.SP_RUN_PIPELINE(' || FROM_PHASE || ', ' || TO_PHASE || ', ' || IFF(INCLUDE_AI, 'TRUE', 'FALSE') || ')';
    BEGIN
        EXECUTE IMMEDIATE 'CREATE OR REPLACE TASK BI_MODERNIZATION.APP.PIPELINE_TASK '
            || 'USER_TASK_MANAGED_INITIAL_WAREHOUSE_SIZE = ''SMALL'' USER_TASK_TIMEOUT_MS = 7200000 '
            || 'COMMENT = ''One-shot pipeline run started from the Setup Wizard'' AS ' || body;
        mode := 'serverless';
    EXCEPTION
        WHEN OTHER THEN
            EXECUTE IMMEDIATE 'CREATE OR REPLACE TASK BI_MODERNIZATION.APP.PIPELINE_TASK '
                || 'WAREHOUSE = BI_MOD_WH USER_TASK_TIMEOUT_MS = 7200000 '
                || 'COMMENT = ''One-shot pipeline run started from the Setup Wizard'' AS ' || body;
            mode := 'warehouse BI_MOD_WH (serverless not permitted for this role)';
    END;
    EXECUTE IMMEDIATE 'EXECUTE TASK BI_MODERNIZATION.APP.PIPELINE_TASK';
    INSERT INTO APP.PIPELINE_RUN (RUN_ID, SEQ, LABEL, STATUS, MESSAGE, STARTED_AT, ENDED_AT)
    SELECT COALESCE(MAX(RUN_ID), 0) + 1, 0, 'Task submitted', 'SUBMITTED',
           'phases ' || :FROM_PHASE || '-' || :TO_PHASE || IFF(:INCLUDE_AI, ' with', ' without') || ' Claude steps; ' || :mode,
           CURRENT_TIMESTAMP(), CURRENT_TIMESTAMP()
    FROM APP.PIPELINE_RUN;
    RETURN 'pipeline task submitted (' || mode || '); watch the run log';
END;
$$;

-- Task history for the wizard (what the task itself reported).
CREATE OR REPLACE VIEW APP.V_PIPELINE_TASK_HISTORY AS
SELECT NAME, STATE, SCHEDULED_TIME, COMPLETED_TIME, ERROR_MESSAGE, QUERY_ID
FROM TABLE(BI_MODERNIZATION.INFORMATION_SCHEMA.TASK_HISTORY(TASK_NAME => 'PIPELINE_TASK', RESULT_LIMIT => 20))
ORDER BY SCHEDULED_TIME DESC;

GRANT USAGE ON ALL PROCEDURES IN SCHEMA APP TO ROLE PUBLIC;
GRANT SELECT ON ALL VIEWS IN SCHEMA APP TO ROLE PUBLIC;
