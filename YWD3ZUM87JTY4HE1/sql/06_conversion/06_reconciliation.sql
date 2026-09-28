-- =============================================================================
-- CONVERSION — reconciliation harness
-- -----------------------------------------------------------------------------
-- A converted report is accepted when its numbers match the source within a
-- declared materiality, for a declared period, signed off by a business
-- owner. The harness holds the certified definition of each metric (the
-- TARGET SQL), a snapshot of what the SOURCE report showed for the same
-- period, and runs the comparison.
--
-- The interesting failures are not bugs. They are the cases where the source
-- report defined the metric differently from the certified definition — LOS
-- in hours/24 instead of days, net revenue before bad debt. The harness
-- surfaces those as DEFINITION_VARIANCE so the owner decides which number is
-- right, instead of the engineer quietly "fixing" the conversion to match.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA CONVERSION;

-- One test per (surviving asset, metric it computes) where the harness has a
-- certified definition. The SOURCE snapshot is what the legacy report showed:
-- in this synthetic estate it is simulated from the certified value — exact
-- (within rounding) when the report used the certified definition, and
-- shifted by a definition-specific factor when it used a variant.
CREATE OR REPLACE TABLE TEST_CASE (
    TEST_ID             TEXT,
    ASSET_ID            TEXT,
    FIELD_ID            TEXT,
    FIELD_NAME_KEY      TEXT,
    METRIC_LABEL        TEXT,
    SOURCE_EXPRESSION   TEXT,
    SOURCE_LANGUAGE     TEXT,
    USES_CERTIFIED_DEFINITION BOOLEAN,
    TARGET_SQL          TEXT,
    MATERIALITY_PCT     NUMBER(5,2),
    SOURCE_SNAPSHOT_VALUE NUMBER(20,6),
    SNAPSHOT_NOTE       TEXT,
    PERIOD_LABEL        TEXT
);

CREATE TABLE IF NOT EXISTS TEST_RESULT (
    RUN_ID              NUMBER,
    TEST_ID             TEXT,
    TARGET_VALUE        NUMBER(20,6),
    SOURCE_VALUE        NUMBER(20,6),
    VARIANCE_PCT        NUMBER(10,4),
    MATERIALITY_PCT     NUMBER(5,2),
    OUTCOME             TEXT,       -- PASS | FAIL | DEFINITION_VARIANCE | ERROR
    ERROR_MESSAGE       TEXT,
    RAN_AT              TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE CONVERSION.SP_BUILD_TEST_CASES()
RETURNS TEXT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    c CURSOR FOR SELECT FIELD_NAME_KEY, TARGET_SQL FROM CONVERSION.METRIC_TEST_TEMPLATE;
    v_key TEXT; v_sql TEXT; v_val NUMBER(20,6);
BEGIN
    CREATE OR REPLACE TEMPORARY TABLE CONVERSION._CERT_VALUE (FIELD_NAME_KEY TEXT, CERT_VALUE NUMBER(20,6));
    FOR r IN c DO
        v_key := r.FIELD_NAME_KEY; v_sql := r.TARGET_SQL;
        LET rs RESULTSET := (EXECUTE IMMEDIATE :v_sql);
        LET cur CURSOR FOR rs;
        OPEN cur;
        FETCH cur INTO v_val;
        CLOSE cur;
        INSERT INTO CONVERSION._CERT_VALUE VALUES (:v_key, :v_val);
    END FOR;

    DELETE FROM CONVERSION.TEST_CASE;
    INSERT INTO CONVERSION.TEST_CASE
    SELECT 'TC-' || LPAD(ROW_NUMBER() OVER (ORDER BY f.ASSET_ID, t.FIELD_NAME_KEY), 4, '0'),
           f.ASSET_ID, f.FIELD_ID, t.FIELD_NAME_KEY, t.METRIC_LABEL, f.EXPRESSION, f.EXPRESSION_LANGUAGE,
           x.IS_CERT, t.TARGET_SQL, t.MATERIALITY_PCT,
           -- the simulated source snapshot
           CASE WHEN x.IS_CERT
                THEN ROUND(cv.CERT_VALUE * (1 + (MOD(ABS(HASH(f.FIELD_ID, 'noise')), 61) - 30) / 10000.0
                                            * IFF(MOD(ABS(HASH(f.FIELD_ID, 'bad')), 11) = 0, 4, 1)), 6)      -- within ±0.3%, a few drift to ±1.2% (a real conversion defect)
                ELSE ROUND(cv.CERT_VALUE * (1 + IFF(MOD(ABS(HASH(f.EXPRESSION)), 2) = 0, 1, -1) * (3 + MOD(ABS(HASH(f.EXPRESSION, 'shift')), 9)) / 100.0), 6) END,   -- ±3-11%
           IFF(x.IS_CERT, 'Source report uses the certified definition; any variance beyond rounding is a conversion defect to fix.',
                          'Source report uses a VARIANT definition; its number is expected to differ. The owner decides which is right.'),
           t.PERIOD_LABEL
    FROM CONFORMED.ASSET_FIELD f
    JOIN CONVERSION.METRIC_TEST_TEMPLATE t ON t.FIELD_NAME_KEY = f.FIELD_NAME_KEY
    JOIN CONVERSION._CERT_VALUE cv ON cv.FIELD_NAME_KEY = t.FIELD_NAME_KEY
    JOIN RATIONALIZATION.V_FINAL_DISPOSITION d ON d.ASSET_ID = f.ASSET_ID AND d.FINAL_DISPOSITION IN ('MIGRATE', 'REBUILD')
    JOIN LATERAL (SELECT f.EXPRESSION = CASE f.EXPRESSION_LANGUAGE WHEN 'TABLEAU_CALC' THEN t.CERTIFIED_TABLEAU
                                                                  WHEN 'DAX' THEN t.CERTIFIED_DAX ELSE t.CERTIFIED_BO END AS IS_CERT) x
    WHERE f.FIELD_KIND = 'CALCULATED'
    QUALIFY ROW_NUMBER() OVER (PARTITION BY f.ASSET_ID, t.FIELD_NAME_KEY ORDER BY f.FIELD_ID) = 1;
    RETURN (SELECT COUNT(*) FROM CONVERSION.TEST_CASE) || ' test cases built';
END;
$$;

CREATE OR REPLACE PROCEDURE CONVERSION.SP_RUN_RECONCILIATION(MAX_TESTS NUMBER DEFAULT 400)
RETURNS TEXT
LANGUAGE SQL
EXECUTE AS CALLER
AS
$$
DECLARE
    run_id NUMBER;
    c CURSOR FOR SELECT TEST_ID, TARGET_SQL, SOURCE_SNAPSHOT_VALUE, MATERIALITY_PCT, USES_CERTIFIED_DEFINITION
                 FROM CONVERSION.TEST_CASE ORDER BY TEST_ID LIMIT 400;
    tc CURSOR FOR SELECT DISTINCT TARGET_SQL FROM CONVERSION.TEST_CASE;
    v_id TEXT; v_sql TEXT; v_src NUMBER(20,6); v_mat NUMBER(5,2); v_cert BOOLEAN; v_tgt NUMBER(20,6); v_var NUMBER(10,4); v_out TEXT;
    n NUMBER := 0;
BEGIN
    SELECT COALESCE(MAX(RUN_ID), 0) + 1 INTO :run_id FROM CONVERSION.TEST_RESULT;
    -- The certified SQL is the same for every test of a metric; evaluate each once.
    CREATE OR REPLACE TEMPORARY TABLE CONVERSION._TGT (TARGET_SQL TEXT, V NUMBER(20,6));
    FOR t IN tc DO
        v_sql := t.TARGET_SQL;
        LET rs RESULTSET := (EXECUTE IMMEDIATE :v_sql);
        LET cur CURSOR FOR rs;
        OPEN cur; FETCH cur INTO v_tgt; CLOSE cur;
        INSERT INTO CONVERSION._TGT VALUES (:v_sql, :v_tgt);
    END FOR;
    FOR r IN c DO
        v_id := r.TEST_ID; v_sql := r.TARGET_SQL; v_src := r.SOURCE_SNAPSHOT_VALUE; v_mat := r.MATERIALITY_PCT; v_cert := r.USES_CERTIFIED_DEFINITION;
        SELECT V INTO :v_tgt FROM CONVERSION._TGT WHERE TARGET_SQL = :v_sql;
        v_var := IFF(v_src = 0, NULL, ABS(v_tgt - v_src) / ABS(v_src) * 100);
        v_out := CASE WHEN v_var IS NULL THEN 'ERROR'
                      WHEN v_var <= v_mat THEN 'PASS'
                      WHEN NOT v_cert THEN 'DEFINITION_VARIANCE'
                      ELSE 'FAIL' END;
        INSERT INTO CONVERSION.TEST_RESULT (RUN_ID, TEST_ID, TARGET_VALUE, SOURCE_VALUE, VARIANCE_PCT, MATERIALITY_PCT, OUTCOME)
        VALUES (:run_id, :v_id, :v_tgt, :v_src, :v_var, :v_mat, :v_out);
        n := n + 1;
        IF (n >= MAX_TESTS) THEN BREAK; END IF;
    END FOR;
    RETURN 'run ' || run_id || ': ' || n || ' tests executed';
END;
$$;

CALL CONVERSION.SP_BUILD_TEST_CASES();
CALL CONVERSION.SP_RUN_RECONCILIATION(400);

CREATE OR REPLACE VIEW V_TEST_RESULT AS
SELECT r.RUN_ID, r.TEST_ID, c.ASSET_ID, a.TITLE, a.PLATFORM, c.METRIC_LABEL, c.PERIOD_LABEL,
       c.SOURCE_LANGUAGE, c.SOURCE_EXPRESSION, c.USES_CERTIFIED_DEFINITION,
       r.TARGET_VALUE, r.SOURCE_VALUE, r.VARIANCE_PCT, r.MATERIALITY_PCT, r.OUTCOME, c.SNAPSHOT_NOTE, r.RAN_AT
FROM TEST_RESULT r
JOIN TEST_CASE c ON c.TEST_ID = r.TEST_ID
JOIN CONFORMED.ASSET a ON a.ASSET_ID = c.ASSET_ID
WHERE r.RUN_ID = (SELECT MAX(RUN_ID) FROM TEST_RESULT);

CREATE OR REPLACE VIEW V_TEST_SUMMARY AS
SELECT METRIC_LABEL, COUNT(*) AS TESTS, COUNT_IF(OUTCOME = 'PASS') AS PASSED, COUNT_IF(OUTCOME = 'FAIL') AS FAILED,
       COUNT_IF(OUTCOME = 'DEFINITION_VARIANCE') AS DEFINITION_VARIANCES, COUNT_IF(OUTCOME = 'ERROR') AS ERRORS,
       ROUND(AVG(IFF(OUTCOME = 'PASS', VARIANCE_PCT, NULL)), 3) AS AVG_PASS_VARIANCE_PCT,
       MAX(MATERIALITY_PCT) AS MATERIALITY_PCT
FROM V_TEST_RESULT GROUP BY 1 ORDER BY 2 DESC;

-- Business sign-off is a decision with a name on it; the harness does not sign.
CREATE TABLE IF NOT EXISTS ACCEPTANCE_SIGNOFF (
    SIGNOFF_ID NUMBER IDENTITY, ASSET_ID TEXT, SIGNED_BY TEXT DEFAULT CURRENT_USER(), SIGNER_ROLE TEXT,
    DECISION TEXT, NOTE TEXT, SIGNED_AT TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);
