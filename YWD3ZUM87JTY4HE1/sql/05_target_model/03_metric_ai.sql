-- =============================================================================
-- TARGET_MODEL — metric reconciliation proposals (Claude via Cortex)
-- -----------------------------------------------------------------------------
-- For each metric with more than one definition, ask the model to do what a
-- senior analyst does in a workshop: sort the variants into "these mean the
-- same thing" and "these are genuinely different", propose ONE canonical SQL
-- definition over the target entity, and list the decisions a human has to
-- make. The output is a PROPOSAL row. Certification is a named person's act.
--
-- Structured output (response_format) so the result is data, not prose.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;

CREATE TABLE IF NOT EXISTS GOVERNANCE.AI_CONFIG (
    CONFIG_KEY TEXT PRIMARY KEY, CONFIG_VALUE TEXT, DESCRIPTION TEXT
);
MERGE INTO GOVERNANCE.AI_CONFIG t USING (
    SELECT 'METRIC_MODEL' K, 'claude-sonnet-5' V, 'Model for metric reconciliation proposals (few calls, judgment-heavy)' D
    UNION ALL SELECT 'TRANSLATION_MODEL', 'claude-haiku-4-5', 'Model for residual expression translation (many calls, pattern-heavy)'
    UNION ALL SELECT 'TRANSLATION_BATCH_LIMIT', '200', 'Maximum fields sent to the model per SP_AI_TRANSLATE call'
) s ON t.CONFIG_KEY = s.K
WHEN NOT MATCHED THEN INSERT (CONFIG_KEY, CONFIG_VALUE, DESCRIPTION) VALUES (s.K, s.V, s.D);

CREATE OR REPLACE FUNCTION GOVERNANCE.AI_CFG(K TEXT) RETURNS TEXT
AS $$ SELECT CONFIG_VALUE FROM GOVERNANCE.AI_CONFIG WHERE CONFIG_KEY = K $$;

USE SCHEMA TARGET_MODEL;

CREATE OR REPLACE VIEW V_METRIC_VARIANT_PROMPT AS
SELECT m.METRIC_ID, m.METRIC_NAME, m.PRIMARY_ENTITY, m.DEFINITION_STATUS,
       (SELECT LISTAGG('- [' || v.EXPRESSION_LANGUAGE || ', used by ' || v.ASSET_COUNT || ' assets] ' || v.EXPRESSION, '\n')
               WITHIN GROUP (ORDER BY v.ASSET_COUNT DESC)
          FROM METRIC_VARIANT v WHERE v.FIELD_NAME_KEY = m.FIELD_NAME_KEY) AS VARIANTS_TEXT,
       (SELECT LISTAGG(a.ATTRIBUTE_NAME || ' ' || TARGET_MODEL.ATTRIBUTE_TYPE(a.ATTRIBUTE_CLASS), ', ')
               WITHIN GROUP (ORDER BY a.ATTRIBUTE_NAME)
          FROM ENTITY_ATTRIBUTE a WHERE a.ENTITY_NAME = m.PRIMARY_ENTITY) AS ENTITY_COLUMNS
FROM METRIC m;

CREATE OR REPLACE PROCEDURE TARGET_MODEL.SP_PROPOSE_METRIC_DEFINITIONS(MAX_METRICS NUMBER DEFAULT 12)
RETURNS TEXT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    model TEXT;
    schema_json TEXT;
    stmt TEXT;
    n NUMBER := 0;
BEGIN
    model := GOVERNANCE.AI_CFG('METRIC_MODEL');
    -- The structured-output contract. The model returns data in this shape or the call fails.
    schema_json := '{"type":"object","properties":{'
        || '"canonical_name":{"type":"string"},"definition_sql":{"type":"string"},"definition_text":{"type":"string"},'
        || '"equivalent_variants":{"type":"array","items":{"type":"string"}},'
        || '"divergent_variants":{"type":"array","items":{"type":"object","properties":{"expression":{"type":"string"},"why_different":{"type":"string"},"decision_needed":{"type":"string"}},"required":["expression","why_different","decision_needed"]}},'
        || '"rationale":{"type":"string"},"confidence":{"type":"number"}},'
        || '"required":["canonical_name","definition_sql","definition_text","equivalent_variants","divergent_variants","rationale","confidence"]}';

    -- 1. the prompts, as rows
    CREATE OR REPLACE TEMPORARY TABLE TARGET_MODEL._METRIC_PROMPT AS
    SELECT p.METRIC_ID,
           'You are a senior healthcare analytics data modeler reconciling metric definitions found across Tableau, Power BI and SAP BusinessObjects into ONE canonical definition for a Snowflake target model.\n\n'
           || 'Metric name as it appears in reports: ' || p.METRIC_NAME || '\n'
           || 'Target entity: ANALYTICS.' || COALESCE(p.PRIMARY_ENTITY, 'UNKNOWN') || '\n'
           || 'Columns available on the target entity: ' || COALESCE(p.ENTITY_COLUMNS, '(none derived yet)') || '\n\n'
           || 'Definitions found in the estate:\n' || p.VARIANTS_TEXT || '\n\n'
           || 'Do four things. (1) Propose one canonical name and one Snowflake SQL expression over the target entity columns only - never invent a column; if the right column is missing, say so in the rationale and write the expression against the column that SHOULD exist, clearly marked. (2) Sort the variants: which are notationally different but mean the same thing (equivalent), and which compute something genuinely different (divergent) - for each divergent one say WHY it differs (numerator, denominator, population, time basis, sign) and what decision a human owner must make. (3) Write a one-sentence business definition. (4) Give a confidence 0-1 that the canonical definition is what the business means. Healthcare context matters: net revenue with or without bad debt, LOS in days versus hours, readmission denominators, and PMPM with member months versus distinct members are real differences, not notation.' AS PROMPT
    FROM TARGET_MODEL.V_METRIC_VARIANT_PROMPT p
    WHERE p.DEFINITION_STATUS <> 'SINGLE_DEFINITION'
      AND NOT EXISTS (SELECT 1 FROM TARGET_MODEL.METRIC_RESOLUTION r WHERE r.METRIC_ID = p.METRIC_ID)
    ORDER BY p.DEFINITION_STATUS = 'CONFLICTING' DESC, p.METRIC_ID
    LIMIT :MAX_METRICS;

    -- 2. the model call. COMPLETE needs the model name as a literal, hence dynamic
    --    SQL. One call per metric, each in its own exception scope, so a single
    --    malformed answer is recorded as a failure and the batch continues.
    --    max_tokens is generous on purpose: Claude Sonnet 5 reasons before it
    --    answers and the reasoning bills against the same budget.
    CREATE OR REPLACE TEMPORARY TABLE TARGET_MODEL._METRIC_ANSWER (METRIC_ID TEXT, RESP VARIANT, ERROR_TEXT TEXT);
    LET pc CURSOR FOR SELECT METRIC_ID FROM TARGET_MODEL._METRIC_PROMPT;
    FOR r IN pc DO
        LET mid TEXT := r.METRIC_ID;
        stmt := 'INSERT INTO TARGET_MODEL._METRIC_ANSWER (METRIC_ID, RESP) SELECT METRIC_ID, TO_VARIANT(SNOWFLAKE.CORTEX.COMPLETE('''
             || model || ''', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(''role'', ''user'', ''content'', PROMPT)), '
             || 'OBJECT_CONSTRUCT(''temperature'', 0.1, ''max_tokens'', 12000, ''response_format'', OBJECT_CONSTRUCT(''type'', ''json'', ''schema'', PARSE_JSON('''
             || schema_json || '''))))) FROM TARGET_MODEL._METRIC_PROMPT WHERE METRIC_ID = ''' || mid || '''';
        BEGIN
            EXECUTE IMMEDIATE :stmt;
        EXCEPTION
            WHEN OTHER THEN
                LET err TEXT := SQLERRM;
                INSERT INTO TARGET_MODEL._METRIC_ANSWER (METRIC_ID, ERROR_TEXT) VALUES (:mid, :err);
        END;
    END FOR;

    -- 3. proposals, labeled as such
    INSERT INTO TARGET_MODEL.METRIC_RESOLUTION
        (METRIC_ID, CANONICAL_NAME, DEFINITION_SQL, DEFINITION_TEXT, EQUIVALENT_VARIANTS, DIVERGENT_VARIANTS,
         PROPOSED_BY, MODEL_USED, RATIONALE, STATUS)
    SELECT a.METRIC_ID,
           a.RESP:structured_output[0]:raw_message:canonical_name::TEXT,
           a.RESP:structured_output[0]:raw_message:definition_sql::TEXT,
           a.RESP:structured_output[0]:raw_message:definition_text::TEXT,
           a.RESP:structured_output[0]:raw_message:equivalent_variants::ARRAY,
           a.RESP:structured_output[0]:raw_message:divergent_variants::ARRAY,
           'AI_PROPOSER', :model,
           a.RESP:structured_output[0]:raw_message:rationale::TEXT
             || ' [model confidence ' || a.RESP:structured_output[0]:raw_message:confidence::TEXT || ']',
           'PROPOSED'
    FROM TARGET_MODEL._METRIC_ANSWER a
    WHERE a.RESP:structured_output IS NOT NULL;
    n := SQLROWCOUNT;
    LET failed NUMBER := (SELECT COUNT(*) FROM TARGET_MODEL._METRIC_ANSWER WHERE ERROR_TEXT IS NOT NULL);
    RETURN n || ' metric definition proposals written by ' || model || ' (status PROPOSED; a named owner certifies); ' || failed || ' calls failed';
END;
$$;

CREATE OR REPLACE VIEW V_METRIC_RECONCILIATION AS
SELECT m.METRIC_ID, m.METRIC_NAME, m.PRIMARY_ENTITY, m.DEFINITION_STATUS, m.VARIANT_COUNT, m.LANGUAGES,
       m.ASSET_COUNT, m.VIEWS_365, m.DOMINANT_EXPRESSION, m.DOMINANT_LANGUAGE, ROUND(m.DOMINANT_SHARE * 100) AS DOMINANT_SHARE_PCT,
       r.CANONICAL_NAME, r.DEFINITION_SQL, r.DEFINITION_TEXT,
       ARRAY_SIZE(r.EQUIVALENT_VARIANTS) AS EQUIVALENT_COUNT, ARRAY_SIZE(r.DIVERGENT_VARIANTS) AS DIVERGENT_COUNT,
       r.DIVERGENT_VARIANTS, r.RATIONALE, r.STATUS AS RESOLUTION_STATUS, r.PROPOSED_BY, r.MODEL_USED, r.CERTIFIED_BY
FROM METRIC m
LEFT JOIN METRIC_RESOLUTION r ON r.METRIC_ID = m.METRIC_ID
   AND r.RESOLUTION_ID = (SELECT MAX(RESOLUTION_ID) FROM METRIC_RESOLUTION x WHERE x.METRIC_ID = m.METRIC_ID);
