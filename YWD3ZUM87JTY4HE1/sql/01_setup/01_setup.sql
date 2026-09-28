-- =============================================================================
-- BI Rationalization & Migration Workbench — setup
-- -----------------------------------------------------------------------------
-- One database, the data plane for the whole migration. The layers are the
-- argument of the accelerator:
--
--   INVENTORY       what each BI platform hands back, landed as-is
--   CONFORMED       one tool-agnostic model of the estate (the hard part)
--   RATIONALIZATION scoring policy, rule engine, dispositions, review, waves
--   TARGET_MODEL    the future-state model DERIVED from what survives
--   CONVERSION      expression translation, workbook specs, reconciliation
--   TARGET          a small certified mart so converted assets can really run
--   AI              corpora, search services, semantic view
--   GOVERNANCE      decisions, copilot log, agent registry
--   APP             the workbench
-- =============================================================================

CREATE DATABASE IF NOT EXISTS BI_MODERNIZATION
    COMMENT = 'BI Rationalization & Migration Workbench — fictional Ridgeline Health, all data synthetic';

CREATE WAREHOUSE IF NOT EXISTS BI_MOD_WH
    WAREHOUSE_SIZE = 'SMALL'
    AUTO_SUSPEND = 300
    AUTO_RESUME = TRUE
    INITIALLY_SUSPENDED = TRUE
    COMMENT = 'BI Modernization demo';

USE DATABASE BI_MODERNIZATION;
USE WAREHOUSE BI_MOD_WH;

CREATE SCHEMA IF NOT EXISTS INVENTORY       COMMENT = 'Tool-native metadata and usage extracts, landed as delivered';
CREATE SCHEMA IF NOT EXISTS CONFORMED       COMMENT = 'The tool-agnostic BI asset model';
CREATE SCHEMA IF NOT EXISTS RATIONALIZATION COMMENT = 'Scoring policy, rule engine, dispositions, human review, wave plan';
CREATE SCHEMA IF NOT EXISTS TARGET_MODEL    COMMENT = 'Future-state data model derived from the surviving estate';
CREATE SCHEMA IF NOT EXISTS CONVERSION      COMMENT = 'Expression translation, workbook specs, reconciliation tests';
CREATE SCHEMA IF NOT EXISTS TARGET          COMMENT = 'Certified mart the converted assets run against (synthetic)';
CREATE SCHEMA IF NOT EXISTS AI              COMMENT = 'Grounding corpora, Cortex Search, semantic view';
CREATE SCHEMA IF NOT EXISTS GOVERNANCE      COMMENT = 'Decisions, copilot log, agent registry';
CREATE SCHEMA IF NOT EXISTS APP             COMMENT = 'Workbench objects';

CREATE STAGE IF NOT EXISTS INVENTORY.LANDING
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Raw extract files from each BI platform';

CREATE FILE FORMAT IF NOT EXISTS INVENTORY.CSV_EXTRACT
    TYPE = CSV
    SKIP_HEADER = 1
    FIELD_OPTIONALLY_ENCLOSED_BY = '"'
    EMPTY_FIELD_AS_NULL = TRUE
    NULL_IF = ('', 'NULL')
    ESCAPE_UNENCLOSED_FIELD = NONE;

CREATE STAGE IF NOT EXISTS APP.WORKBENCH_STAGE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Workbench files and the semantic model';

-- Agent skills (SKILL.md folders) for the Migration Copilot; build_all.py
-- uploads demo/skills/<name>/ to @AI.SKILLS_STAGE/skills/<name>/.
CREATE STAGE IF NOT EXISTS AI.SKILLS_STAGE
    DIRECTORY = (ENABLE = TRUE)
    COMMENT = 'Agent skills for the BI Migration Copilot';

-- The extract date. Everything time-relative (days since last view, decay)
-- is computed against this, never against CURRENT_DATE, so the demo reads the
-- same on any day it is shown.
CREATE OR REPLACE TABLE INVENTORY.EXTRACT_RUN (
    RUN_ID          NUMBER IDENTITY,
    EXTRACT_DATE    DATE,
    PLATFORMS       ARRAY,
    NOTE            TEXT,
    LOADED_AT       TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
INSERT INTO INVENTORY.EXTRACT_RUN (EXTRACT_DATE, PLATFORMS, NOTE)
SELECT DATE '2026-08-15', ARRAY_CONSTRUCT('TABLEAU', 'POWER_BI', 'SAP_BO'),
       'Ridgeline Health — full-estate extract (synthetic)';

CREATE OR REPLACE FUNCTION INVENTORY.AS_OF_DATE()
RETURNS DATE
AS $$ SELECT MAX(EXTRACT_DATE) FROM INVENTORY.EXTRACT_RUN $$;
