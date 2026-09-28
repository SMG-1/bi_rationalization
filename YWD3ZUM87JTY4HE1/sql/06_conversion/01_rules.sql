-- =============================================================================
-- CONVERSION — the expression rule catalog
-- -----------------------------------------------------------------------------
-- BI-to-BI rewriting is mostly mechanical and partly judgment. The mechanical
-- part is a rule: a pattern in the source language, a replacement in Sigma's
-- formula language, a confidence, and a note. The judgment part is marked
-- NEEDS_HUMAN with the pattern that usually replaces it. The translator
-- applies these in priority order and reports which rules fired; the model
-- is only asked about what the rules could not finish.
--
-- Patterns are Python regular expressions, stored in dollar-quoted strings so
-- backslashes survive. Sigma function names follow Sigma's documentation and
-- should be verified against the client's Sigma release (TO CONFIRM per
-- engagement; the catalog is the thing you edit).
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA CONVERSION;

CREATE OR REPLACE TABLE CONVERSION_RULE (
    RULE_ID          TEXT PRIMARY KEY,
    SOURCE_LANGUAGE  TEXT,            -- TABLEAU_CALC | DAX | BO_FORMULA
    PRIORITY         NUMBER,
    PATTERN          TEXT,            -- python regex
    REPLACEMENT      TEXT,            -- python replacement
    SIGMA_CONSTRUCT  TEXT,
    CONFIDENCE       NUMBER(4,2),
    NEEDS_HUMAN      BOOLEAN DEFAULT FALSE,
    CASE_INSENSITIVE BOOLEAN DEFAULT TRUE,
    NOTE             TEXT,
    IS_ENABLED       BOOLEAN DEFAULT TRUE
);

INSERT INTO CONVERSION_RULE (RULE_ID, SOURCE_LANGUAGE, PRIORITY, PATTERN, REPLACEMENT, SIGMA_CONSTRUCT, CONFIDENCE, NEEDS_HUMAN, CASE_INSENSITIVE, NOTE)
SELECT * FROM VALUES
-- ------------------------------------------------------------ Tableau -------
('TAB-010', 'TABLEAU_CALC', 10, $$\{\s*FIXED\s+([^:}]+?)\s*:\s*(.+?)\s*\}$$, $$/* FIXED @ \1 */ \2$$, 'grouping level / SumIf', 0.50, TRUE, TRUE,
 'A FIXED level-of-detail expression recomputes at a declared grain regardless of the visual. In Sigma, build a child table grouped at that grain, or use SumIf/CountDistinctIf when the grain is a filter. The aggregate is kept; the grain is a modeling decision.'),
('TAB-011', 'TABLEAU_CALC', 11, $$\{\s*INCLUDE\s+([^:}]+?)\s*:\s*(.+?)\s*\}$$, $$/* INCLUDE \1 */ \2$$, 'grouping level', 0.40, TRUE, TRUE,
 'INCLUDE adds a dimension to the visual grain. In Sigma, add it to the grouping and aggregate up.'),
('TAB-012', 'TABLEAU_CALC', 12, $$\{\s*EXCLUDE\s+([^:}]+?)\s*:\s*(.+?)\s*\}$$, $$/* EXCLUDE \1 */ \2$$, 'parent grouping level', 0.40, TRUE, TRUE,
 'EXCLUDE removes a dimension from the grain — the parent grouping total in Sigma.'),
('TAB-020', 'TABLEAU_CALC', 20, $$\bSCRIPT_(REAL|STR|INT|BOOL)\s*\($$, $$/* EXTERNAL SCRIPT */ ($$, 'Snowpark', 0.10, TRUE, TRUE,
 'TabPy / Rserve call. Move the model to Snowpark or a Cortex function and expose the score as a column.'),
('TAB-030', 'TABLEAU_CALC', 30, $$\bCOUNTD\s*\($$, $$CountDistinct($$, 'CountDistinct', 1.00, FALSE, TRUE, NULL),
('TAB-031', 'TABLEAU_CALC', 31, $$\bSUM\s*\($$, $$Sum($$, 'Sum', 1.00, FALSE, TRUE, NULL),
('TAB-032', 'TABLEAU_CALC', 32, $$\bAVG\s*\($$, $$Avg($$, 'Avg', 1.00, FALSE, TRUE, NULL),
('TAB-033', 'TABLEAU_CALC', 33, $$\bCOUNT\s*\($$, $$Count($$, 'Count', 1.00, FALSE, TRUE, NULL),
('TAB-034', 'TABLEAU_CALC', 34, $$\bMEDIAN\s*\($$, $$Median($$, 'Median', 1.00, FALSE, TRUE, NULL),
('TAB-035', 'TABLEAU_CALC', 35, $$\b(MIN|MAX)\s*\($$, $$\1($$, 'Min/Max', 1.00, FALSE, FALSE, NULL),
('TAB-036', 'TABLEAU_CALC', 36, $$\bMIN\s*\($$, $$Min($$, 'Min', 1.00, FALSE, TRUE, NULL),
('TAB-037', 'TABLEAU_CALC', 37, $$\bMAX\s*\($$, $$Max($$, 'Max', 1.00, FALSE, TRUE, NULL),
('TAB-040', 'TABLEAU_CALC', 40, $$\bATTR\s*\(\s*(\[[^\]]+\])\s*\)$$, $$\1$$, 'column at grouping', 0.90, FALSE, TRUE, 'ATTR returns the single value at the visual grain; in a grouped Sigma table the column itself does that.'),
('TAB-041', 'TABLEAU_CALC', 41, $$\bZN\s*\(\s*(.+?)\s*\)$$, $$Coalesce(\1, 0)$$, 'Coalesce', 0.95, FALSE, TRUE, NULL),
('TAB-042', 'TABLEAU_CALC', 42, $$\bIFNULL\s*\($$, $$Coalesce($$, 'Coalesce', 1.00, FALSE, TRUE, NULL),
('TAB-043', 'TABLEAU_CALC', 43, $$\bISNULL\s*\($$, $$IsNull($$, 'IsNull', 1.00, FALSE, TRUE, NULL),
('TAB-044', 'TABLEAU_CALC', 44, $$\bIIF\s*\($$, $$If($$, 'If', 0.95, FALSE, TRUE, 'IIF has an optional fourth argument for unknown; If does not.'),
('TAB-050', 'TABLEAU_CALC', 50, $$\bDATEDIFF\s*\(\s*"(\w+)"\s*,$$, $$DateDiff("\1",$$, 'DateDiff', 0.95, FALSE, TRUE, 'Same argument order (part, start, end).'),
('TAB-051', 'TABLEAU_CALC', 51, $$\bDATETRUNC\s*\(\s*"(\w+)"\s*,$$, $$DateTrunc("\1",$$, 'DateTrunc', 0.95, FALSE, TRUE, NULL),
('TAB-052', 'TABLEAU_CALC', 52, $$\bDATEPART\s*\(\s*"(\w+)"\s*,\s*(.+?)\s*\)$$, $$DatePart("\1", \2)$$, 'DatePart', 0.85, FALSE, TRUE, 'Weekday numbering differs (Tableau Sunday=1); confirm.'),
('TAB-053', 'TABLEAU_CALC', 53, $$\bDATENAME\s*\(\s*"month"\s*,\s*(.+?)\s*\)$$, $$DateFormat(\1, "%B")$$, 'DateFormat', 0.80, FALSE, TRUE, NULL),
('TAB-054', 'TABLEAU_CALC', 54, $$\bDATEADD\s*\(\s*"(\w+)"\s*,$$, $$DateAdd("\1",$$, 'DateAdd', 0.95, FALSE, TRUE, NULL),
('TAB-055', 'TABLEAU_CALC', 55, $$\bTODAY\s*\(\s*\)$$, $$Today()$$, 'Today', 1.00, FALSE, TRUE, NULL),
('TAB-056', 'TABLEAU_CALC', 56, $$\bNOW\s*\(\s*\)$$, $$Now()$$, 'Now', 1.00, FALSE, TRUE, NULL),
('TAB-057', 'TABLEAU_CALC', 57, $$\b(YEAR|MONTH|DAY)\s*\(\s*(\[[^\]]+\])\s*\)$$, $$\1(\2)$$, 'Year/Month/Day', 0.95, FALSE, TRUE, NULL),
('TAB-060', 'TABLEAU_CALC', 60, $$\bCONTAINS\s*\($$, $$Contains($$, 'Contains', 1.00, FALSE, TRUE, NULL),
('TAB-061', 'TABLEAU_CALC', 61, $$\b(UPPER|LOWER|TRIM|LEN|LEFT|RIGHT|ROUND|ABS|FLOOR|CEILING)\s*\($$, $$\1($$, 'string/math', 0.95, FALSE, TRUE, NULL),
('TAB-062', 'TABLEAU_CALC', 62, $$\bMID\s*\($$, $$Mid($$, 'Mid', 0.95, FALSE, TRUE, NULL),
('TAB-063', 'TABLEAU_CALC', 63, $$\bSPLIT\s*\($$, $$SplitPart($$, 'SplitPart', 0.90, FALSE, TRUE, NULL),
('TAB-064', 'TABLEAU_CALC', 64, $$\bREGEXP_EXTRACT\s*\($$, $$RegexpExtract($$, 'RegexpExtract', 0.85, FALSE, TRUE, 'Regex dialect differences are possible; test the pattern.'),
('TAB-065', 'TABLEAU_CALC', 65, $$\bSTR\s*\($$, $$Text($$, 'Text', 0.95, FALSE, TRUE, NULL),
('TAB-066', 'TABLEAU_CALC', 66, $$\bFLOAT\s*\($$, $$Number($$, 'Number', 0.90, FALSE, TRUE, NULL),
('TAB-067', 'TABLEAU_CALC', 67, $$\bINT\s*\($$, $$Int($$, 'Int', 0.90, FALSE, TRUE, NULL),
('TAB-070', 'TABLEAU_CALC', 70, $$\bRUNNING_SUM\s*\($$, $$CumulativeSum($$, 'CumulativeSum', 0.80, FALSE, TRUE, 'Table calc ordering must be reproduced by the table sort.'),
('TAB-071', 'TABLEAU_CALC', 71, $$\bRUNNING_AVG\s*\($$, $$CumulativeAvg($$, 'CumulativeAvg', 0.80, FALSE, TRUE, NULL),
('TAB-072', 'TABLEAU_CALC', 72, $$\bWINDOW_SUM\s*\(\s*(.+?)\s*,\s*-?(\d+)\s*,\s*(\d+)\s*\)$$, $$MovingSum(\1, \2, \3)$$, 'MovingSum', 0.75, FALSE, TRUE, 'Window bounds are relative offsets in both tools; confirm inclusive/exclusive.'),
('TAB-073', 'TABLEAU_CALC', 73, $$\bWINDOW_AVG\s*\(\s*(.+?)\s*,\s*-?(\d+)\s*,\s*(\d+)\s*\)$$, $$MovingAvg(\1, \2, \3)$$, 'MovingAvg', 0.75, FALSE, TRUE, NULL),
('TAB-074', 'TABLEAU_CALC', 74, $$\bLOOKUP\s*\(\s*(.+?)\s*,\s*-(\d+)\s*\)$$, $$Lag(\1, \2)$$, 'Lag', 0.85, FALSE, TRUE, NULL),
('TAB-075', 'TABLEAU_CALC', 75, $$\bLOOKUP\s*\(\s*(.+?)\s*,\s*(\d+)\s*\)$$, $$Lead(\1, \2)$$, 'Lead', 0.85, FALSE, TRUE, NULL),
('TAB-076', 'TABLEAU_CALC', 76, $$\bTOTAL\s*\(\s*(.+?)\s*\)$$, $$/* parent grouping total */ \1$$, 'parent grouping total', 0.50, TRUE, TRUE, 'TOTAL() is the aggregate at the parent level. In Sigma reference the grouping-level column, e.g. [Grouping/Total Amount].'),
('TAB-077', 'TABLEAU_CALC', 77, $$\bRANK\s*\(\s*(.+?)\s*,\s*"(asc|desc)"\s*\)$$, $$Rank(\1, "\2")$$, 'Rank', 0.80, FALSE, TRUE, NULL),
('TAB-078', 'TABLEAU_CALC', 78, $$\bINDEX\s*\(\s*\)$$, $$RowNumber()$$, 'RowNumber', 0.85, FALSE, TRUE, NULL),
('TAB-079', 'TABLEAU_CALC', 79, $$\b(FIRST|LAST|SIZE)\s*\(\s*\)$$, $$/* \1() table calc */ 0$$, 'window', 0.30, TRUE, TRUE, 'Positional table calcs depend on the pane; restate against the grouped table.'),
('TAB-080', 'TABLEAU_CALC', 80, $$\[([^\]]*?)\s+Parameter\]$$, $$[\1-Control]$$, 'control', 0.70, FALSE, TRUE, 'Tableau parameter → Sigma control of the same type; create the control on the workbook.'),
('TAB-081', 'TABLEAU_CALC', 81, $$\[Measure Selector\]$$, $$[Measure-Selector-Control]$$, 'control', 0.70, FALSE, TRUE, 'Measure-swap parameter → Sigma list control feeding a Switch.'),
('TAB-090', 'TABLEAU_CALC', 90, $$\s+AND\s+$$, $$ and $$, 'and', 0.95, FALSE, FALSE, NULL),
('TAB-091', 'TABLEAU_CALC', 91, $$\s+OR\s+$$, $$ or $$, 'or', 0.95, FALSE, FALSE, NULL),
('TAB-092', 'TABLEAU_CALC', 92, $$\bNOT\s+$$, $$not $$, 'not', 0.95, FALSE, FALSE, NULL),
('TAB-093', 'TABLEAU_CALC', 93, $$<>$$, $$!=$$, '!=', 1.00, FALSE, TRUE, NULL),
('TAB-094', 'TABLEAU_CALC', 94, $$(\[[^\]]+\])\s+IN\s*\(([^)]*)\)$$, $$In(\1, \2)$$, 'In', 0.85, FALSE, TRUE, NULL),
-- ------------------------------------------------------------ DAX -----------
('DAX-010', 'DAX', 10, $$\bTOTALYTD\s*\(\s*(.+?)\s*,\s*(\[[^\]]+\])\s*(?:,\s*"[^"]*")?\s*\)$$, $$/* YTD of \1 by \2 (fiscal year end as declared) */ CumulativeSum(\1)$$, 'CumulativeSum at year grouping', 0.45, TRUE, FALSE,
 'Time intelligence has no single Sigma function. Build the period on the date dimension (fiscal year, month) and use CumulativeSum within the year grouping, or a SumIf against DateTrunc.'),
('DAX-011', 'DAX', 11, $$\bTOTALMTD\s*\(\s*(.+?)\s*,\s*(\[[^\]]+\])\s*\)$$, $$/* MTD of \1 */ CumulativeSum(\1)$$, 'CumulativeSum at month grouping', 0.45, TRUE, FALSE, NULL),
('DAX-012', 'DAX', 12, $$\bCALCULATE\s*\(\s*(.+?)\s*,\s*SAMEPERIODLASTYEAR\s*\(\s*(\[[^\]]+\])\s*\)\s*\)$$, $$/* prior-year \1 */ Lag(\1, 12)$$, 'Lag at month grouping', 0.50, TRUE, FALSE,
 'Prior-period comparison: Lag(x, 12) on a month-grouped table, or a prior-year join in the dataset. Confirm the grouping grain.'),
('DAX-013', 'DAX', 13, $$\bCALCULATE\s*\(\s*(.+?)\s*,\s*DATESINPERIOD\s*\([^)]*-\s*(\d+)\s*,\s*MONTH\s*\)\s*\)$$, $$MovingSum(\1, \2, 0)$$, 'MovingSum', 0.55, TRUE, FALSE, 'Rolling window of \2 months; requires a month-grouped table.'),
('DAX-014', 'DAX', 14, $$\bCALCULATE\s*\(\s*(.+?)\s*,\s*PREVIOUSMONTH\s*\([^)]*\)\s*\)$$, $$Lag(\1, 1)$$, 'Lag', 0.60, FALSE, FALSE, 'Requires a month-grouped table sorted ascending.'),
('DAX-020', 'DAX', 20, $$\bVAR\b.*\bRETURN\b$$, $$/* VAR/RETURN inlined by hand */$$, 'inline', 0.30, TRUE, FALSE, 'Variable blocks have to be inlined; usually simple once the measures they reference exist as columns.'),
('DAX-021', 'DAX', 21, $$\bUSERPRINCIPALNAME\s*\(\s*\)$$, $$CurrentUserEmail()$$, 'CurrentUserEmail', 0.70, TRUE, FALSE, 'Row-level security belongs in Sigma user attributes / Snowflake row access policies, not a formula.'),
('DAX-022', 'DAX', 22, $$\b(ALLSELECTED|ALLEXCEPT|REMOVEFILTERS|KEEPFILTERS)\s*\(([^)]*)\)$$, $$/* \1(\2) → grouping-level total */$$, 'grouping level', 0.40, TRUE, FALSE, 'Filter-context modifiers map to Sigma grouping levels, not functions.'),
('DAX-023', 'DAX', 23, $$\bCALCULATE\s*\(\s*(.+?)\s*,\s*ALL\s*\(([^)]*)\)\s*\)$$, $$/* \1 at grand-total grouping (ALL \2) */ \1$$, 'grand total', 0.45, TRUE, FALSE, 'Percent-of-total pattern: divide by the grouping-level aggregate.'),
('DAX-030', 'DAX', 30, $$\bDISTINCTCOUNT\s*\($$, $$CountDistinct($$, 'CountDistinct', 1.00, FALSE, FALSE, NULL),
('DAX-031', 'DAX', 31, $$\bCOUNTROWS\s*\(\s*[A-Za-z_']+\s*\)$$, $$Count()$$, 'Count', 0.80, FALSE, FALSE, 'Row count at the grouping level; Sigma Count() with no argument counts rows.'),
('DAX-032', 'DAX', 32, $$\bAVERAGE\s*\($$, $$Avg($$, 'Avg', 1.00, FALSE, FALSE, NULL),
('DAX-033', 'DAX', 33, $$\bSUM\s*\($$, $$Sum($$, 'Sum', 1.00, FALSE, FALSE, NULL),
('DAX-034', 'DAX', 34, $$\bCOUNT\s*\($$, $$Count($$, 'Count', 1.00, FALSE, FALSE, NULL),
('DAX-035', 'DAX', 35, $$\bMIN\s*\($$, $$Min($$, 'Min', 1.00, FALSE, FALSE, NULL),
('DAX-036', 'DAX', 36, $$\bMAX\s*\($$, $$Max($$, 'Max', 1.00, FALSE, FALSE, NULL),
('DAX-040', 'DAX', 40, $$\bRANKX\s*\(\s*ALL\s*\([^)]*\)\s*,\s*(.+?)\s*\)$$, $$Rank(\1, "desc")$$, 'Rank', 0.70, FALSE, FALSE, 'RANKX default order is descending.'),
('DAX-041', 'DAX', 41, $$\bCONCATENATEX\s*\(\s*VALUES\s*\(\s*(\[[^\]]+\])\s*\)\s*,\s*\[[^\]]+\]\s*,\s*("[^"]*")\s*\)$$, $$ListAgg(\1, \2)$$, 'ListAgg', 0.70, FALSE, FALSE, NULL),
('DAX-042', 'DAX', 42, $$\bSUMX\s*\(\s*FILTER\s*\(\s*[A-Za-z_']+\s*,\s*(.+?)\s*\)\s*,\s*(.+?)\s*\)$$, $$SumIf(\2, \1)$$, 'SumIf', 0.80, FALSE, FALSE, NULL),
('DAX-043', 'DAX', 43, $$\bSUMX\s*\(\s*[A-Za-z_']+\s*,\s*(.+?)\s*\)$$, $$Sum(\1)$$, 'Sum of row expression', 0.80, FALSE, FALSE, 'Row-level arithmetic then aggregate — Sigma evaluates the expression per row inside Sum.'),
('DAX-044', 'DAX', 44, $$\bAVERAGEX\s*\(\s*VALUES\s*\(\s*(\[[^\]]+\])\s*\)\s*,\s*(.+?)\s*\)$$, $$/* average of \2 per \1 */ Avg(\2)$$, 'grouped average', 0.40, TRUE, FALSE, 'Average of a measure over distinct keys needs a child table grouped by the key.'),
('DAX-045', 'DAX', 45, $$\bAVERAGEX\s*\(\s*[A-Za-z_']+\s*,\s*(.+?)\s*\)$$, $$Avg(\1)$$, 'Avg of row expression', 0.80, FALSE, FALSE, NULL),
('DAX-050', 'DAX', 50, $$\bRELATED\s*\(\s*(\[[^\]]+\])\s*\)$$, $$\1$$, 'lookup column', 0.85, FALSE, FALSE, 'The related column is joined into the dataset.'),
('DAX-051', 'DAX', 51, $$\bSELECTEDVALUE\s*\(\s*\[([^\]]+)\]\s*\)$$, $$[\1-Control]$$, 'control', 0.70, FALSE, FALSE, 'Slicer selection → Sigma control.'),
('DAX-052', 'DAX', 52, $$\bISBLANK\s*\($$, $$IsNull($$, 'IsNull', 0.95, FALSE, FALSE, NULL),
('DAX-053', 'DAX', 53, $$\bBLANK\s*\(\s*\)$$, $$Null$$, 'Null', 0.95, FALSE, FALSE, NULL),
('DAX-054', 'DAX', 54, $$\bIF\s*\($$, $$If($$, 'If', 1.00, FALSE, FALSE, NULL),
('DAX-055', 'DAX', 55, $$\bTRUE\s*\(\s*\)$$, $$True$$, 'True', 1.00, FALSE, FALSE, NULL),
('DAX-056', 'DAX', 56, $$\bFALSE\s*\(\s*\)$$, $$False$$, 'False', 1.00, FALSE, FALSE, NULL),
('DAX-057', 'DAX', 57, $$\bDATEDIFF\s*\(\s*(.+?)\s*,\s*(.+?)\s*,\s*(DAY|MONTH|YEAR|HOUR|MINUTE)\s*\)$$, $$DateDiff("\3", \1, \2)$$, 'DateDiff', 0.90, FALSE, FALSE, 'Argument order changes: part first in Sigma.'),
('DAX-058', 'DAX', 58, $$\b(YEAR|MONTH|DAY)\s*\(\s*(\[[^\]]+\])\s*\)$$, $$\1(\2)$$, 'Year/Month/Day', 0.95, FALSE, TRUE, NULL),
('DAX-059', 'DAX', 59, $$\bDIVIDE\s*\(\s*([^(),]+?)\s*,\s*([^(),]+?)\s*,\s*([^(),]+?)\s*\)$$, $$If(\2 = 0, \3, \1 / \2)$$, 'safe divide', 0.90, FALSE, FALSE, NULL),
('DAX-060', 'DAX', 60, $$\bDIVIDE\s*\(\s*([^(),]+?)\s*,\s*([^(),]+?)\s*\)$$, $$(\1) / (\2)$$, 'divide', 0.90, FALSE, FALSE, 'DIVIDE returns blank on zero; Sigma returns null on division by zero as well.'),
('DAX-070', 'DAX', 70, $$\s*&&\s*$$, $$ and $$, 'and', 0.95, FALSE, FALSE, NULL),
('DAX-071', 'DAX', 71, $$\s*\|\|\s*$$, $$ or $$, 'or', 0.95, FALSE, FALSE, NULL),
('DAX-072', 'DAX', 72, $$<>$$, $$!=$$, '!=', 1.00, FALSE, FALSE, NULL),
('DAX-073', 'DAX', 73, $$(\[[^\]]+\])\s+IN\s*\{([^}]*)\}$$, $$In(\1, \2)$$, 'In', 0.85, FALSE, FALSE, NULL),
-- ------------------------------------------------------------ BO ------------
('BO-010', 'BO_FORMULA', 10, $$\bIn\s+Report\b$$, $$/* report-level total → grand-total grouping */$$, 'grand total', 0.45, TRUE, TRUE, 'Calculation context "In Report" is the grand total; reference the top grouping level in Sigma.'),
('BO-011', 'BO_FORMULA', 11, $$\bIn\s*\(\s*(\[[^\]]+\])\s*\)$$, $$/* In \1 → grouping level */$$, 'grouping level', 0.45, TRUE, TRUE, 'Input context: recompute at the named dimension grain — a grouped child table in Sigma.'),
('BO-012', 'BO_FORMULA', 12, $$\bForEach\s*\(\s*(\[[^\]]+\])\s*\)$$, $$/* ForEach \1 → add \1 to grouping */$$, 'grouping level', 0.45, TRUE, TRUE, NULL),
('BO-013', 'BO_FORMULA', 13, $$\bForAll\s*\(\s*(\[[^\]]+\])\s*\)$$, $$/* ForAll \1 → remove \1 from grouping */$$, 'parent grouping', 0.45, TRUE, TRUE, NULL),
('BO-014', 'BO_FORMULA', 14, $$\bNoFilter\s*\(\s*(.+?)\s*\)$$, $$/* NoFilter: unfiltered \1 */ \1$$, 'unfiltered aggregate', 0.40, TRUE, TRUE, 'Sigma filters apply to the whole element; an unfiltered comparison needs a second, unfiltered element or a dataset-level aggregate.'),
('BO-015', 'BO_FORMULA', 15, $$\bDrillFilters\s*\(\s*\)$$, $$/* DrillFilters → breadcrumb of active controls */ ""$$, 'controls', 0.30, TRUE, TRUE, NULL),
('BO-016', 'BO_FORMULA', 16, $$\[Merged\s+([^\]]+)\]$$, $$[\1]$$, 'dataset join', 0.40, TRUE, TRUE, 'Merged dimensions across queries become a join in the dataset, not a formula.'),
('BO-017', 'BO_FORMULA', 17, $$\bUserResponse\s*\(\s*"([^"]+)"\s*\)$$, $$[\1-Control]$$, 'control', 0.60, FALSE, TRUE, 'Prompt → Sigma control.'),
('BO-020', 'BO_FORMULA', 20, $$\bSum\s*\(\s*(\[[^\]]+\])\s*\)\s*Where\s*\((.+?)\)$$, $$SumIf(\1, \2)$$, 'SumIf', 0.90, FALSE, TRUE, NULL),
('BO-021', 'BO_FORMULA', 21, $$\bCount\s*\(\s*(\[[^\]]+\])\s*\)\s*Where\s*\((.+?)\)$$, $$CountDistinctIf(\1, \2)$$, 'CountDistinctIf', 0.85, FALSE, TRUE, 'BO Count() is distinct by default.'),
('BO-022', 'BO_FORMULA', 22, $$\bCount\s*\($$, $$CountDistinct($$, 'CountDistinct', 0.90, FALSE, TRUE, 'BO Count() is distinct by default; use Count(x; All) semantics only if the report did.'),
('BO-023', 'BO_FORMULA', 23, $$\bAverage\s*\($$, $$Avg($$, 'Avg', 1.00, FALSE, TRUE, NULL),
('BO-024', 'BO_FORMULA', 24, $$\bSum\s*\($$, $$Sum($$, 'Sum', 1.00, FALSE, TRUE, NULL),
('BO-025', 'BO_FORMULA', 25, $$\b(Min|Max)\s*\($$, $$\1($$, 'Min/Max', 1.00, FALSE, FALSE, NULL),
('BO-030', 'BO_FORMULA', 30, $$\bDaysBetween\s*\(\s*(.+?)\s*,\s*(.+?)\s*\)$$, $$DateDiff("day", \1, \2)$$, 'DateDiff', 0.95, FALSE, TRUE, NULL),
('BO-031', 'BO_FORMULA', 31, $$\bRelativeDate\s*\(\s*(.+?)\s*,\s*(-?\d+)\s*\)$$, $$DateAdd("day", \2, \1)$$, 'DateAdd', 0.95, FALSE, TRUE, NULL),
('BO-032', 'BO_FORMULA', 32, $$\bCurrentDate\s*\(\s*\)$$, $$Today()$$, 'Today', 1.00, FALSE, TRUE, NULL),
('BO-033', 'BO_FORMULA', 33, $$\bFormatDate\s*\(\s*(.+?)\s*,\s*"MM/yyyy"\s*\)$$, $$DateFormat(\1, "%m/%Y")$$, 'DateFormat', 0.70, FALSE, TRUE, 'Format tokens differ; translate the mask.'),
('BO-034', 'BO_FORMULA', 34, $$\b(Year|Month)\s*\($$, $$\1($$, 'Year/Month', 0.95, FALSE, FALSE, NULL),
('BO-040', 'BO_FORMULA', 40, $$\bRunningSum\s*\($$, $$CumulativeSum($$, 'CumulativeSum', 0.80, FALSE, TRUE, NULL),
('BO-041', 'BO_FORMULA', 41, $$\bRank\s*\(\s*(.+?)\s*,\s*\[[^\]]+\]\s*\)$$, $$Rank(\1, "desc")$$, 'Rank', 0.70, FALSE, TRUE, 'Rank partitioned by a dimension → rank within the grouping.'),
('BO-042', 'BO_FORMULA', 42, $$\bPrevious\s*\(\s*(.+?)\s*\)$$, $$Lag(\1, 1)$$, 'Lag', 0.85, FALSE, TRUE, NULL),
('BO-050', 'BO_FORMULA', 50, $$\bIsNull\s*\($$, $$IsNull($$, 'IsNull', 1.00, FALSE, TRUE, NULL),
('BO-051', 'BO_FORMULA', 51, $$"\s*\+\s*$$, $$" & $$, 'string concat', 0.80, FALSE, TRUE, 'String + becomes &.'),
('BO-052', 'BO_FORMULA', 52, $$\)\s*\+\s*"$$, $$) & "$$, 'string concat', 0.80, FALSE, TRUE, NULL),
('BO-053', 'BO_FORMULA', 53, $$\]\s*\+\s*"$$, $$] & "$$, 'string concat', 0.80, FALSE, TRUE, NULL),
('BO-060', 'BO_FORMULA', 60, $$\s+And\s+$$, $$ and $$, 'and', 0.95, FALSE, TRUE, NULL),
('BO-061', 'BO_FORMULA', 61, $$\s+Or\s+$$, $$ or $$, 'or', 0.95, FALSE, TRUE, NULL),
('BO-062', 'BO_FORMULA', 62, $$<>$$, $$!=$$, '!=', 1.00, FALSE, TRUE, NULL),
-- ------------------------------------------------------------ MedeAnalytics --
('MEDE-010', 'MEDE', 10, $$^\[Mede standard measure\]\s*(.+?)\s+—.*$$, $$/* VENDOR-DEFINED: \1 — redefine on the certified dataset */$$, 'redefine', 0.10, TRUE, TRUE,
 'The definition lives in the vendor measure dictionary and is not exported. Obtain the dictionary entry, certify a definition on the target model, then write the Sigma formula against it.'),
('MEDE-020', 'MEDE', 20, $$\bCOUNT DISTINCT\s*\($$, $$CountDistinct($$, 'CountDistinct', 1.00, FALSE, TRUE, NULL),
('MEDE-021', 'MEDE', 21, $$\bSUM\s*\($$, $$Sum($$, 'Sum', 1.00, FALSE, TRUE, NULL),
('MEDE-022', 'MEDE', 22, $$\bCOUNT\s*\($$, $$Count($$, 'Count', 1.00, FALSE, TRUE, NULL),
('MEDE-023', 'MEDE', 23, $$\bAVG\s*\($$, $$Avg($$, 'Avg', 1.00, FALSE, TRUE, NULL),
('MEDE-024', 'MEDE', 24, $$\bIF\s*\($$, $$If($$, 'If', 0.95, FALSE, TRUE, NULL),
('MEDE-025', 'MEDE', 25, $$\bDAYS\s*\(\s*(.+?)\s*,\s*(.+?)\s*\)$$, $$DateDiff("day", \1, \2)$$, 'DateDiff', 0.90, FALSE, TRUE, NULL),
('MEDE-026', 'MEDE', 26, $$\b(YEAR|MONTH|TODAY)\s*\($$, $$\1($$, 'date', 0.95, FALSE, TRUE, NULL),
('MEDE-027', 'MEDE', 27, $$\[Prompt:\s*([^\]]+)\]$$, $$[\1-Control]$$, 'control', 0.70, FALSE, TRUE, 'Report prompt → Sigma control.'),
('MEDE-028', 'MEDE', 28, $$\s+WHERE\s*\((.+?)\)$$, $$ /* filter: \1 */$$, 'SumIf', 0.60, FALSE, TRUE, 'Mede WHERE on a measure → SumIf/CountIf.')
AS v(RULE_ID, SOURCE_LANGUAGE, PRIORITY, PATTERN, REPLACEMENT, SIGMA_CONSTRUCT, CONFIDENCE, NEEDS_HUMAN, CASE_INSENSITIVE, NOTE);

-- Sigma functions the translator recognizes as resolved. Anything else that
-- still looks like a function call after the rules ran is an unresolved token.
CREATE OR REPLACE TABLE SIGMA_FUNCTION (FUNCTION_NAME TEXT PRIMARY KEY, CATEGORY TEXT);
INSERT INTO SIGMA_FUNCTION SELECT * FROM VALUES
 ('Sum','aggregate'),('Avg','aggregate'),('Count','aggregate'),('CountDistinct','aggregate'),('Min','aggregate'),('Max','aggregate'),
 ('Median','aggregate'),('Percentile','aggregate'),('Stddev','aggregate'),('Variance','aggregate'),('ListAgg','aggregate'),
 ('SumIf','conditional aggregate'),('CountIf','conditional aggregate'),('CountDistinctIf','conditional aggregate'),('AvgIf','conditional aggregate'),
 ('MinIf','conditional aggregate'),('MaxIf','conditional aggregate'),
 ('If','logical'),('Switch','logical'),('In','logical'),('IsNull','logical'),('Coalesce','logical'),('And','logical'),('Or','logical'),('Not','logical'),
 ('DateTrunc','date'),('DateDiff','date'),('DateAdd','date'),('DatePart','date'),('DateFormat','date'),('Year','date'),('Month','date'),('Day','date'),
 ('Weekday','date'),('Today','date'),('Now','date'),('Date','date'),
 ('Contains','text'),('Upper','text'),('Lower','text'),('Trim','text'),('Len','text'),('Left','text'),('Right','text'),('Mid','text'),
 ('SplitPart','text'),('RegexpExtract','text'),('Text','text'),('Concat','text'),('Replace','text'),
 ('Number','math'),('Int','math'),('Round','math'),('Abs','math'),('Floor','math'),('Ceiling','math'),('Greatest','math'),('Least','math'),
 ('Lag','window'),('Lead','window'),('Rank','window'),('RowNumber','window'),('CumulativeSum','window'),('CumulativeAvg','window'),
 ('CumulativeCount','window'),('MovingSum','window'),('MovingAvg','window'),
 ('CurrentUserEmail','context');
