-- =============================================================================
-- CONVERSION — the translator (Snowpark Python)
-- -----------------------------------------------------------------------------
-- Reads the rule catalog and every calculated field, and writes one row per
-- field to FIELD_CONVERSION: the Sigma formula the rules produced, which rules
-- fired, what is still unresolved, a confidence, and a status.
--
-- Three constructs are handled in code because a regex cannot: branching
-- (IF/THEN/ELSEIF/ELSE/END, CASE/WHEN, SWITCH(TRUE(), ...), If/Then/ElseIf),
-- DAX CALCULATE with simple filters (→ SumIf / CountIf), and DAX DIVIDE with
-- nested parentheses. Everything else is a rule, so the catalog is where the
-- engagement adds knowledge.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA CONVERSION;

CREATE TABLE IF NOT EXISTS FIELD_CONVERSION (
    FIELD_ID            TEXT,
    ASSET_ID            TEXT,
    FIELD_NAME          TEXT,
    SOURCE_LANGUAGE     TEXT,
    SOURCE_EXPRESSION   TEXT,
    COMPLEXITY_TAG      TEXT,
    TARGET_EXPRESSION   TEXT,
    METHOD              TEXT,          -- RULES | RULES+AI
    APPLIED_RULES       ARRAY,
    UNRESOLVED_TOKENS   ARRAY,
    CONFIDENCE          NUMBER(4,2),
    STATUS              TEXT,          -- AUTO | NEEDS_REVIEW | NEEDS_HUMAN
    NOTES               TEXT,
    AI_FORMULA          TEXT,
    AI_CONFIDENCE       NUMBER(4,2),
    AI_RATIONALE        TEXT,
    AI_REQUIRES_HUMAN   BOOLEAN,
    MODEL_USED          TEXT,
    REVIEWED_BY         TEXT,
    REVIEW_DECISION     TEXT,          -- ACCEPT | EDIT | REJECT
    FINAL_EXPRESSION    TEXT,
    CONVERTED_AT        TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE PROCEDURE CONVERSION.SP_TRANSLATE_FIELDS(SCOPE TEXT DEFAULT 'SURVIVING')
RETURNS TEXT
LANGUAGE PYTHON
RUNTIME_VERSION = '3.11'
PACKAGES = ('snowflake-snowpark-python', 'pandas')
HANDLER = 'run'
EXECUTE AS CALLER
AS
$$
import re
import json
import pandas as pd
from snowflake.snowpark.functions import col


def run(session, scope):
    rules = session.sql("""
        SELECT RULE_ID, SOURCE_LANGUAGE, PRIORITY, PATTERN, REPLACEMENT, CONFIDENCE, NEEDS_HUMAN, CASE_INSENSITIVE, NOTE
        FROM CONVERSION.CONVERSION_RULE WHERE IS_ENABLED ORDER BY SOURCE_LANGUAGE, PRIORITY""").to_pandas()
    sigma_fns = {r[0].lower(): r[0] for r in session.sql("SELECT FUNCTION_NAME FROM CONVERSION.SIGMA_FUNCTION").collect()}

    where = ""
    if scope == 'SURVIVING':
        where = """AND f.ASSET_ID IN (SELECT ASSET_ID FROM RATIONALIZATION.V_FINAL_DISPOSITION
                                       WHERE FINAL_DISPOSITION IN ('MIGRATE','REBUILD','INVESTIGATE'))"""
    fields = session.sql(f"""
        SELECT f.FIELD_ID, f.ASSET_ID, f.FIELD_NAME, f.EXPRESSION_LANGUAGE, f.EXPRESSION, f.COMPLEXITY_TAG
        FROM CONFORMED.ASSET_FIELD f
        WHERE f.FIELD_KIND = 'CALCULATED' AND f.EXPRESSION IS NOT NULL {where}""").to_pandas()

    compiled = {}
    for lang, grp in rules.groupby("SOURCE_LANGUAGE"):
        compiled[lang] = [(r.RULE_ID, re.compile(r.PATTERN, re.I if r.CASE_INSENSITIVE else 0),
                           r.REPLACEMENT, float(r.CONFIDENCE), bool(r.NEEDS_HUMAN), r.NOTE) for r in grp.itertuples()]

    # ---------------------------------------------------------------- helpers
    def split_args(s):
        """Split a function argument list on top-level commas."""
        out, depth, buf, q = [], 0, [], None
        for ch in s:
            if q:
                buf.append(ch)
                if ch == q:
                    q = None
                continue
            if ch in "\"'":
                q = ch
                buf.append(ch)
                continue
            if ch in "([{":
                depth += 1
            elif ch in ")]}":
                depth -= 1
            if ch == "," and depth == 0:
                out.append("".join(buf).strip())
                buf = []
            else:
                buf.append(ch)
        if buf:
            out.append("".join(buf).strip())
        return out

    def find_call(s, name):
        """Locate NAME( ... ) with balanced parens; returns (start, end, inner) or None."""
        m = re.search(r"\b" + name + r"\s*\(", s, re.I)
        if not m:
            return None
        i, depth, q = m.end(), 1, None
        while i < len(s):
            ch = s[i]
            if q:
                if ch == q:
                    q = None
            elif ch in "\"'":
                q = ch
            elif ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    return (m.start(), i + 1, s[m.end():i])
            i += 1
        return None

    def rewrite_calls(s, name, fn, applied, rid):
        """Repeatedly rewrite NAME(...) calls via fn(args) -> replacement or None."""
        for _ in range(20):
            hit = find_call(s, name)
            if not hit:
                break
            start, end, inner = hit
            rep = fn(split_args(inner))
            if rep is None:
                # leave it, but mark so we do not loop forever
                s = s[:start] + "\u0000" + s[start + 1:]
                continue
            s = s[:start] + rep + s[end:]
            applied.append(rid)
        return s.replace("\u0000", name[0])

    def tableau_if(s, applied):
        # IF c1 THEN v1 [ELSEIF c2 THEN v2]* [ELSE v] END  -> If(c1, v1, c2, v2, v)
        pat = re.compile(r"\bIF\s+(.+?)\s+THEN\s+(.+?)((?:\s+ELSEIF\s+.+?\s+THEN\s+.+?)*)(?:\s+ELSE\s+(.+?))?\s+END\b", re.I | re.S)
        def rep(m):
            parts = [m.group(1).strip(), m.group(2).strip()]
            for em in re.finditer(r"\s+ELSEIF\s+(.+?)\s+THEN\s+(.+?)(?=\s+ELSEIF\s+|$)", m.group(3) or "", re.I | re.S):
                parts += [em.group(1).strip(), em.group(2).strip()]
            if m.group(4):
                parts.append(m.group(4).strip())
            applied.append("CODE-IF")
            return "If(" + ", ".join(parts) + ")"
        for _ in range(5):
            new = pat.sub(rep, s)
            if new == s:
                break
            s = new
        return s

    def tableau_case(s, applied):
        pat = re.compile(r"\bCASE\s+(.+?)\s+((?:WHEN\s+.+?\s+THEN\s+.+?\s+)+)(?:ELSE\s+(.+?)\s+)?END\b", re.I | re.S)
        def rep(m):
            parts = [m.group(1).strip()]
            for wm in re.finditer(r"WHEN\s+(.+?)\s+THEN\s+(.+?)(?=\s+WHEN\s+|\s*$)", m.group(2), re.I | re.S):
                parts += [wm.group(1).strip(), wm.group(2).strip()]
            if m.group(3):
                parts.append(m.group(3).strip())
            applied.append("CODE-CASE")
            return "Switch(" + ", ".join(parts) + ")"
        return pat.sub(rep, s)

    def bo_if(s, applied):
        pat = re.compile(r"\bIf\s+(.+?)\s+Then\s+(.+?)((?:\s+ElseIf\s+.+?\s+Then\s+.+?)*)(?:\s+Else\s+(.+?))?$", re.I | re.S)
        def rep(m):
            parts = [m.group(1).strip(), m.group(2).strip()]
            for em in re.finditer(r"\s+ElseIf\s+(.+?)\s+Then\s+(.+?)(?=\s+ElseIf\s+|$)", m.group(3) or "", re.I | re.S):
                parts += [em.group(1).strip(), em.group(2).strip()]
            if m.group(4):
                parts.append(m.group(4).strip())
            applied.append("CODE-IF")
            return "If(" + ", ".join(parts) + ")"
        return pat.sub(rep, s)

    def dax_switch_true(s, applied):
        def fn(args):
            if not args or not re.fullmatch(r"TRUE\s*\(\s*\)", args[0], re.I):
                return None
            applied.append("CODE-SWITCH-TRUE")
            return "If(" + ", ".join(args[1:]) + ")"
        return rewrite_calls(s, "SWITCH", fn, applied, "CODE-SWITCH-TRUE")

    def dax_divide(s, applied):
        def fn(args):
            if len(args) == 2:
                return f"({args[0]}) / ({args[1]})"
            if len(args) == 3:
                return f"If({args[1]} = 0, {args[2]}, ({args[0]}) / ({args[1]}))"
            return None
        return rewrite_calls(s, "DIVIDE", fn, applied, "CODE-DIVIDE")

    def dax_calculate(s, applied):
        # CALCULATE(SUM([x]), f1, f2) -> SumIf([x], f1 and f2); COUNTROWS -> CountIf
        def fn(args):
            if len(args) < 2:
                return None
            expr, filters = args[0], args[1:]
            for f in filters:
                if re.search(r"\b(ALL|ALLSELECTED|ALLEXCEPT|SAMEPERIODLASTYEAR|DATESINPERIOD|PREVIOUSMONTH|DATESYTD|FILTER|REMOVEFILTERS|KEEPFILTERS)\s*\(", f, re.I):
                    return None
            cond = " and ".join(f"({f})" for f in filters) if len(filters) > 1 else filters[0]
            m = re.fullmatch(r"\s*-?\s*SUM\s*\((.+)\)\s*", expr, re.I | re.S)
            if m:
                neg = "-" if expr.strip().startswith("-") else ""
                return f"{neg}SumIf({m.group(1).strip()}, {cond})"
            m = re.fullmatch(r"\s*COUNTROWS\s*\((.+)\)\s*", expr, re.I | re.S)
            if m:
                return f"CountIf({cond})"
            m = re.fullmatch(r"\s*DISTINCTCOUNT\s*\((.+)\)\s*", expr, re.I | re.S)
            if m:
                return f"CountDistinctIf({m.group(1).strip()}, {cond})"
            m = re.fullmatch(r"\s*AVERAGE\s*\((.+)\)\s*", expr, re.I | re.S)
            if m:
                return f"AvgIf({m.group(1).strip()}, {cond})"
            return None
        return rewrite_calls(s, "CALCULATE", fn, applied, "CODE-CALCULATE")

    def normalize(lang, s):
        s = s.strip()
        if lang == "BO_FORMULA":
            s = s[1:] if s.startswith("=") else s
            s = s.replace(";", ",")
        if lang == "DAX":
            s = re.sub(r"'[^']+'\[", "[", s)            # 'Date'[Date] -> [Date]
            s = re.sub(r"\b[A-Za-z_][A-Za-z0-9_]*\[", "[", s)  # Txn[Amount] -> [Amount]
        if lang in ("TABLEAU_CALC", "MEDE"):
            s = re.sub(r"'([^']*)'", r'"\1"', s)       # 'string' -> "string"
        return s

    def canonicalize(s):
        def rep(m):
            nm = m.group(1)
            return sigma_fns.get(nm.lower(), nm) + "("
        return re.sub(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", rep, s)

    def unresolved(s):
        toks = set()
        for m in re.finditer(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", s):
            nm = m.group(1)
            if nm.lower() not in sigma_fns:
                toks.add(nm)
        return sorted(toks)

    # ------------------------------------------------------------- translate
    rows = []
    for f in fields.itertuples():
        lang, src = f.EXPRESSION_LANGUAGE, f.EXPRESSION
        applied, notes = [], []
        s = normalize(lang, src)
        conf = 1.0
        needs_human = False
        if lang == "TABLEAU_CALC":
            s = tableau_case(s, applied)
            s = tableau_if(s, applied)
        elif lang == "DAX":
            s = dax_switch_true(s, applied)
            s = dax_calculate(s, applied)
            s = dax_divide(s, applied)
        elif lang == "BO_FORMULA":
            s = bo_if(s, applied)
        for rid, rx, rep, rconf, rhuman, note in compiled.get(lang, []):
            new, n = rx.subn(rep, s)
            if n:
                s = new
                applied.append(rid)
                conf *= rconf
                if rhuman:
                    needs_human = True
                if note:
                    notes.append(f"{rid}: {note}")
        s = re.sub(r'DateDiff\("([A-Z]+)"', lambda m: f'DateDiff("{m.group(1).lower()}"', s)
        s = canonicalize(s)
        s = re.sub(r"\s+", " ", s).strip()
        unres = unresolved(s)
        conf *= (0.5 ** len(unres))
        if "/*" in s and not needs_human:
            conf *= 0.8
        conf = round(max(0.0, min(1.0, conf)), 2)
        if needs_human or conf < 0.6:
            status = "NEEDS_HUMAN"
        elif conf >= 0.85 and not unres:
            status = "AUTO"
        else:
            status = "NEEDS_REVIEW"
        rows.append({
            "FIELD_ID": f.FIELD_ID, "ASSET_ID": f.ASSET_ID, "FIELD_NAME": f.FIELD_NAME,
            "SOURCE_LANGUAGE": lang, "SOURCE_EXPRESSION": src, "COMPLEXITY_TAG": f.COMPLEXITY_TAG,
            "TARGET_EXPRESSION": s, "METHOD": "RULES",
            "APPLIED_RULES": json.dumps(applied), "UNRESOLVED_TOKENS": json.dumps(unres),
            "CONFIDENCE": conf, "STATUS": status, "NOTES": " | ".join(dict.fromkeys(notes)) or None,
        })

    out = pd.DataFrame(rows)
    # Human review decisions survive a re-run: stash by FIELD_ID, reload, re-apply.
    session.sql("""CREATE OR REPLACE TEMPORARY TABLE _FC_REVIEWS AS
                   SELECT FIELD_ID, REVIEWED_BY, REVIEW_DECISION, FINAL_EXPRESSION
                   FROM CONVERSION.FIELD_CONVERSION WHERE REVIEW_DECISION IS NOT NULL""").collect()
    session.sql("DELETE FROM CONVERSION.FIELD_CONVERSION").collect()
    if len(out):
        session.write_pandas(out, "FIELD_CONVERSION_STAGE", database="BI_MODERNIZATION", schema="CONVERSION",
                             auto_create_table=True, overwrite=True, quote_identifiers=False)
        session.sql("""
            INSERT INTO CONVERSION.FIELD_CONVERSION
                (FIELD_ID, ASSET_ID, FIELD_NAME, SOURCE_LANGUAGE, SOURCE_EXPRESSION, COMPLEXITY_TAG, TARGET_EXPRESSION,
                 METHOD, APPLIED_RULES, UNRESOLVED_TOKENS, CONFIDENCE, STATUS, NOTES)
            SELECT FIELD_ID, ASSET_ID, FIELD_NAME, SOURCE_LANGUAGE, SOURCE_EXPRESSION, COMPLEXITY_TAG, TARGET_EXPRESSION,
                   METHOD, PARSE_JSON(APPLIED_RULES), PARSE_JSON(UNRESOLVED_TOKENS), CONFIDENCE, STATUS, NOTES
            FROM CONVERSION.FIELD_CONVERSION_STAGE""").collect()
        session.sql("DROP TABLE IF EXISTS CONVERSION.FIELD_CONVERSION_STAGE").collect()
        session.sql("""UPDATE CONVERSION.FIELD_CONVERSION f
                       SET REVIEWED_BY = r.REVIEWED_BY, REVIEW_DECISION = r.REVIEW_DECISION, FINAL_EXPRESSION = r.FINAL_EXPRESSION
                       FROM _FC_REVIEWS r WHERE r.FIELD_ID = f.FIELD_ID""").collect()
    counts = out["STATUS"].value_counts().to_dict() if len(out) else {}
    return f"{len(out)} fields translated: {counts}"
$$;

CALL CONVERSION.SP_TRANSLATE_FIELDS('SURVIVING');

CREATE OR REPLACE VIEW V_CONVERSION_SUMMARY AS
SELECT SOURCE_LANGUAGE, STATUS, COUNT(*) AS FIELDS, ROUND(AVG(CONFIDENCE), 2) AS AVG_CONFIDENCE,
       COUNT_IF(METHOD = 'RULES+AI') AS AI_ASSISTED, COUNT_IF(REVIEW_DECISION IS NOT NULL) AS REVIEWED
FROM FIELD_CONVERSION GROUP BY 1, 2 ORDER BY 1, 2;

CREATE OR REPLACE VIEW V_RULE_USAGE AS
SELECT r.RULE_ID, r.SOURCE_LANGUAGE, r.SIGMA_CONSTRUCT, r.CONFIDENCE, r.NEEDS_HUMAN,
       COUNT(fc.FIELD_ID) AS FIELDS_HIT
FROM CONVERSION_RULE r
LEFT JOIN FIELD_CONVERSION fc ON ARRAY_CONTAINS(r.RULE_ID::VARIANT, fc.APPLIED_RULES)
GROUP BY 1, 2, 3, 4, 5 ORDER BY FIELDS_HIT DESC;

CREATE OR REPLACE VIEW V_UNRESOLVED_TOKENS AS
SELECT t.VALUE::TEXT AS TOKEN, fc.SOURCE_LANGUAGE, COUNT(*) AS OCCURRENCES, MIN(fc.SOURCE_EXPRESSION) AS SAMPLE_EXPRESSION
FROM FIELD_CONVERSION fc, LATERAL FLATTEN(INPUT => fc.UNRESOLVED_TOKENS) t
GROUP BY 1, 2 ORDER BY 3 DESC;
