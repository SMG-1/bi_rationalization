-- =============================================================================
-- AI — the definitions plane as a search corpus
-- -----------------------------------------------------------------------------
-- "What does survival rate mean", "how is a duplicate found", "which questions
-- are certified", "why did R055 move" — answered from GOVERNANCE, not from
-- memory. Ids are prepended into the text so exact lookups (KPI-003, MTH-02,
-- Q-ME-01, CHG-0001) hit. Definitions change rarely: target lag 24 hours; after
-- editing a row, re-run this file so the change is searchable now.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE WAREHOUSE BI_MOD_WH;
USE SCHEMA AI;

CREATE OR REPLACE VIEW AI.DEFINITION_DOCS AS
SELECT KPI_ID AS DOC_ID, 'KPI definition' AS DOC_KIND, KPI_ID || ' ' || KPI_NAME AS TITLE, TEAM,
       KPI_ID || ' — ' || KPI_NAME || ' (' || STATUS || ', version ' || VERSION || ', effective ' || EFFECTIVE_FROM || ', owner ' || OWNER_ROLE || ', team ' || TEAM || ')'
       || '\nDefinition: ' || DEFINITION
       || '\nFormula: ' || FORMULA
       || '\nGrain: ' || GRAIN || '. Numerator: ' || NUMERATOR || '. Denominator: ' || DENOMINATOR || '.'
       || '\nImplemented in: ' || SOURCE_OBJECT || ' using method ' || METHOD_ID || '.'
       || '\nCaveats: ' || CAVEATS AS DOC_TEXT
FROM GOVERNANCE.KPI_DEFINITION
UNION ALL
SELECT METHOD_ID, 'Method', METHOD_ID || ' ' || METHOD_NAME, TEAM,
       METHOD_ID || ' — ' || METHOD_NAME || ' (' || STATUS || ', version ' || VERSION || ', effective ' || EFFECTIVE_FROM || ', owner ' || OWNER_ROLE || ')'
       || '\nPurpose: ' || PURPOSE
       || '\nSteps: ' || STEPS
       || '\nThresholds: ' || THRESHOLDS
       || '\nImplemented in: ' || IMPLEMENTED_IN
       || '\nLimitations: ' || LIMITATIONS
FROM GOVERNANCE.METHOD_REGISTRY
UNION ALL
SELECT QUESTION_ID, 'Certified question', QUESTION_ID || ' ' || QUESTION, TEAM,
       QUESTION_ID || ' — certified question for the ' || TEAM || ' team: "' || QUESTION || '"'
       || '\nDepends on: ' || KPI_IDS || ' via ' || METHOD_ID || '. Answered from ' || SEMANTIC_VIEW || '.'
       || '\nStatus: ' || STATUS || ', verified by ' || VERIFIED_BY || ' on ' || VERIFIED_AT || '.'
       || IFF(IS_ONBOARDING, ' Offered as an onboarding question.', '')
       || '\nCertified SQL: ' || CERTIFIED_SQL
FROM GOVERNANCE.QUESTION_CATALOG
UNION ALL
SELECT CHANGE_ID, 'Definition change', CHANGE_ID || ' ' || OBJECT_ID, 'Shared',
       CHANGE_ID || ' — change to ' || OBJECT_ID || ' on ' || CHANGED_AT::DATE || ' (version ' || FROM_VERSION || ' to ' || TO_VERSION || '), signed by ' || SIGNED_BY || '.'
       || '\nChange: ' || CHANGE
       || '\nReason: ' || REASON
       || '\nQuestions re-opened for certification: ' || REOPENED_QUESTIONS
FROM GOVERNANCE.DEFINITION_CHANGE_LOG;

CREATE OR REPLACE CORTEX SEARCH SERVICE AI.DEFINITION_SEARCH
    ON DOC_TEXT
    ATTRIBUTES DOC_ID, DOC_KIND, TITLE, TEAM
    WAREHOUSE = BI_MOD_WH
    TARGET_LAG = '24 hours'
    COMMENT = 'The trusted-definitions plane as documents: every KPI definition with formula, grain, owner, version and caveats; every codified method with steps and thresholds; every certified question with the SQL a steward signed; every definition change with its reason.'
AS SELECT DOC_TEXT, DOC_ID, DOC_KIND, TITLE, TEAM FROM AI.DEFINITION_DOCS;

GRANT SELECT ON VIEW AI.DEFINITION_DOCS TO ROLE PUBLIC;
GRANT USAGE ON CORTEX SEARCH SERVICE AI.DEFINITION_SEARCH TO ROLE PUBLIC;

SELECT 'definition docs: ' || (SELECT COUNT(*) FROM AI.DEFINITION_DOCS) AS STATUS;
