-- =============================================================================
-- CONVERSION — the residual pass (Claude via Cortex)
-- -----------------------------------------------------------------------------
-- The model is asked only about fields the rules could not finish, and it is
-- given the rules' attempt, the unresolved tokens and the Sigma function list.
-- Its answer is recorded NEXT TO the rules' answer, with its own confidence
-- and an explicit "requires_human" flag. A formula the model is unsure of is
-- routed to a person, not shipped.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA CONVERSION;

CREATE OR REPLACE PROCEDURE CONVERSION.SP_AI_TRANSLATE(MAX_ROWS NUMBER DEFAULT NULL)
RETURNS TEXT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    lim NUMBER;
    model TEXT;
    fn_list TEXT;
    schema_json TEXT;
    stmt TEXT;
    n NUMBER := 0;
BEGIN
    lim := COALESCE(:MAX_ROWS, GOVERNANCE.AI_CFG('TRANSLATION_BATCH_LIMIT')::NUMBER);
    model := GOVERNANCE.AI_CFG('TRANSLATION_MODEL');
    SELECT LISTAGG(FUNCTION_NAME, ', ') WITHIN GROUP (ORDER BY FUNCTION_NAME) INTO :fn_list FROM CONVERSION.SIGMA_FUNCTION;
    schema_json := '{"type":"object","properties":{"sigma_formula":{"type":"string"},"approach":{"type":"string"},'
        || '"confidence":{"type":"number"},"requires_human":{"type":"boolean"},"human_reason":{"type":"string"}},'
        || '"required":["sigma_formula","approach","confidence","requires_human","human_reason"]}';

    CREATE OR REPLACE TEMPORARY TABLE CONVERSION._AI_PROMPT AS
    SELECT FIELD_ID,
           'You translate BI calculated-field expressions into Sigma Computing formula syntax for a workbook built on a Snowflake certified dataset.\n\n'
           || 'Source language: ' || SOURCE_LANGUAGE || '\n'
           || 'Source expression: ' || SOURCE_EXPRESSION || '\n'
           || 'Rule-based attempt: ' || COALESCE(TARGET_EXPRESSION, '(none)') || '\n'
           || 'Unresolved tokens: ' || COALESCE(ARRAY_TO_STRING(UNRESOLVED_TOKENS, ', '), '(none)') || '\n'
           || 'Rule notes: ' || COALESCE(NOTES, '(none)') || '\n'
           || 'Construct class: ' || COALESCE(COMPLEXITY_TAG, 'SIMPLE') || '\n\n'
           || 'Sigma functions you may use: ' || :fn_list
           || '. Column references are [Column Name]. Controls are [Name-Control]. Grouping-level aggregates are referenced as [Grouping/Column]. '
           || 'Level-of-detail, filter-context and time-intelligence constructs usually do NOT have a one-line Sigma equivalent: they become a grouped child table, a SumIf against a date expression, or a dataset-level column. '
           || 'When that is the case, give the best single-element formula AND set requires_human to true with a one-sentence reason that names the modeling pattern. Never invent a function. Never drop a filter or a condition silently. Keep the formula as close to the source semantics as possible.' AS PROMPT
    FROM CONVERSION.FIELD_CONVERSION
    WHERE STATUS IN ('NEEDS_REVIEW', 'NEEDS_HUMAN') AND AI_FORMULA IS NULL
    ORDER BY CONFIDENCE ASC, FIELD_ID
    LIMIT :lim;

    -- Set-based first (one round trip for the whole batch); if the batch fails
    -- because one answer was malformed, fall back to one call per field so the
    -- good answers are kept and the bad one is recorded.
    CREATE OR REPLACE TEMPORARY TABLE CONVERSION._AI_ANSWER (FIELD_ID TEXT, RESP VARIANT, ERROR_TEXT TEXT);
    stmt := 'INSERT INTO CONVERSION._AI_ANSWER (FIELD_ID, RESP) SELECT FIELD_ID, TO_VARIANT(SNOWFLAKE.CORTEX.COMPLETE('''
         || model || ''', ARRAY_CONSTRUCT(OBJECT_CONSTRUCT(''role'', ''user'', ''content'', PROMPT)), '
         || 'OBJECT_CONSTRUCT(''temperature'', 0, ''max_tokens'', 4000, ''response_format'', OBJECT_CONSTRUCT(''type'', ''json'', ''schema'', PARSE_JSON('''
         || schema_json || '''))))) FROM CONVERSION._AI_PROMPT';
    BEGIN
        EXECUTE IMMEDIATE :stmt;
    EXCEPTION
        WHEN OTHER THEN
            DELETE FROM CONVERSION._AI_ANSWER;
            LET pc CURSOR FOR SELECT FIELD_ID FROM CONVERSION._AI_PROMPT;
            FOR r IN pc DO
                LET fid TEXT := r.FIELD_ID;
                LET one TEXT := :stmt || ' WHERE FIELD_ID = ''' || fid || '''';
                BEGIN
                    EXECUTE IMMEDIATE :one;
                EXCEPTION
                    WHEN OTHER THEN
                        LET err TEXT := SQLERRM;
                        INSERT INTO CONVERSION._AI_ANSWER (FIELD_ID, ERROR_TEXT) VALUES (:fid, :err);
                END;
            END FOR;
    END;

    UPDATE CONVERSION.FIELD_CONVERSION f
       SET AI_FORMULA        = b.RESP:structured_output[0]:raw_message:sigma_formula::TEXT,
           AI_CONFIDENCE     = b.RESP:structured_output[0]:raw_message:confidence::NUMBER(4,2),
           AI_RATIONALE      = b.RESP:structured_output[0]:raw_message:approach::TEXT
                               || IFF(b.RESP:structured_output[0]:raw_message:requires_human::BOOLEAN,
                                      ' HUMAN: ' || b.RESP:structured_output[0]:raw_message:human_reason::TEXT, ''),
           AI_REQUIRES_HUMAN = b.RESP:structured_output[0]:raw_message:requires_human::BOOLEAN,
           MODEL_USED        = :model,
           METHOD            = 'RULES+AI',
           STATUS            = CASE WHEN b.RESP:structured_output[0]:raw_message:requires_human::BOOLEAN THEN 'NEEDS_HUMAN'
                                    WHEN b.RESP:structured_output[0]:raw_message:confidence::NUMBER(4,2) >= 0.85 THEN 'AUTO'
                                    ELSE 'NEEDS_REVIEW' END
      FROM CONVERSION._AI_ANSWER b
     WHERE b.FIELD_ID = f.FIELD_ID AND b.RESP:structured_output IS NOT NULL;
    n := SQLROWCOUNT;
    LET failed NUMBER := (SELECT COUNT(*) FROM CONVERSION._AI_ANSWER WHERE ERROR_TEXT IS NOT NULL);
    RETURN n || ' fields translated by ' || model || ' (batch limit ' || lim || '); ' || failed || ' calls failed';
END;
$$;

-- The effective formula: a human edit beats the model, the model beats the rules.
CREATE OR REPLACE VIEW V_FIELD_CONVERSION AS
SELECT fc.*,
       COALESCE(fc.FINAL_EXPRESSION, IFF(fc.METHOD = 'RULES+AI' AND fc.AI_CONFIDENCE >= fc.CONFIDENCE, fc.AI_FORMULA, fc.TARGET_EXPRESSION)) AS EFFECTIVE_EXPRESSION,
       CASE WHEN fc.FINAL_EXPRESSION IS NOT NULL THEN 'HUMAN'
            WHEN fc.METHOD = 'RULES+AI' AND fc.AI_CONFIDENCE >= fc.CONFIDENCE THEN 'AI'
            ELSE 'RULES' END AS EFFECTIVE_SOURCE,
       a.TITLE AS ASSET_TITLE, a.PLATFORM
FROM FIELD_CONVERSION fc
JOIN CONFORMED.ASSET a ON a.ASSET_ID = fc.ASSET_ID;
