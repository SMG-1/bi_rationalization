-- =============================================================================
-- CONVERSION — SEED: certified metric definitions for reconciliation. Run once at
-- deploy; edited by the engagement; never touched by the in-app pipeline.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA CONVERSION;

-- Certified definitions and the period every test uses.
CREATE OR REPLACE TABLE METRIC_TEST_TEMPLATE (
    FIELD_NAME_KEY     TEXT PRIMARY KEY,
    METRIC_LABEL       TEXT,
    TARGET_SQL         TEXT,
    MATERIALITY_PCT    NUMBER(5,2),
    CERTIFIED_TABLEAU  TEXT,
    CERTIFIED_DAX      TEXT,
    CERTIFIED_BO       TEXT,
    PERIOD_LABEL       TEXT DEFAULT 'FY2026 Q4 (Apr-Jun 2026)'
);
INSERT INTO METRIC_TEST_TEMPLATE (FIELD_NAME_KEY, METRIC_LABEL, TARGET_SQL, MATERIALITY_PCT, CERTIFIED_TABLEAU, CERTIFIED_DAX, CERTIFIED_BO) VALUES
('average length of stay', 'Average Length of Stay (days)',
 'SELECT AVG(LOS_DAYS) FROM TARGET.FACT_HOSPITAL_ENCOUNTER WHERE PATIENT_CLASS = ''Inpatient'' AND DISCHARGE_DATE BETWEEN ''2026-04-01'' AND ''2026-06-30''',
 1.0, 'AVG(DATEDIFF(''day'', [Admit Date], [Discharge Date]))', 'AVERAGEX(Admissions, DATEDIFF(Admissions[AdmitDate], Admissions[DischargeDate], DAY))', '=Average(DaysBetween([Admit Date];[Discharge Date]))'),
('30 day readmission rate', '30-Day Readmission Rate',
 'SELECT COUNT_IF(READMIT_30D_FLAG) / COUNT(*) FROM TARGET.FACT_HOSPITAL_ENCOUNTER WHERE PATIENT_CLASS = ''Inpatient'' AND DISCHARGE_DATE BETWEEN ''2026-04-01'' AND ''2026-06-30''',
 2.0, 'SUM(IF [Readmit 30d Flag] THEN 1 ELSE 0 END) / COUNTD([Encounter ID])', 'DIVIDE(CALCULATE(COUNTROWS(Admissions), Admissions[Readmit30] = 1), COUNTROWS(Admissions))', '=Count([Encounter ID]) Where([Readmit Flag] = 1) / Count([Encounter ID])'),
('midnight census', 'Average Midnight Census',
 'SELECT AVG(C) FROM (SELECT CENSUS_DATE, SUM(MIDNIGHT_CENSUS) C FROM TARGET.FACT_DAILY_CENSUS WHERE CENSUS_DATE BETWEEN ''2026-04-01'' AND ''2026-06-30'' GROUP BY 1)',
 1.0, 'COUNTD(IF [Patient Class] = ''Inpatient'' THEN [Encounter ID] END)', 'CALCULATE(DISTINCTCOUNT(Adt[EncounterId]), Adt[InHouseAtMidnight] = TRUE())', '=Count([Encounter ID]) Where([In House Flag] = "Y")'),
('initial denial rate', 'Initial Denial Rate',
 'SELECT COUNT_IF(DENIED_FLAG) / COUNT(*) FROM TARGET.V_CLAIMS_BILLED WHERE BILLED_DATE BETWEEN ''2026-04-01'' AND ''2026-06-30''',
 2.0, 'COUNTD([Denied Claim ID]) / COUNTD([Claim ID])', 'DIVIDE(DISTINCTCOUNT(Denials[DenialId]), DISTINCTCOUNT(Claims[ClaimId]))', '=Count([Denial ID]) / Count([Claim ID])'),
('net patient revenue', 'Net Patient Revenue',
 'SELECT SUM(IFF(TRANSACTION_TYPE = ''Charge'', AMOUNT, 0)) + SUM(IFF(TRANSACTION_TYPE = ''Contractual Adjustment'', AMOUNT, 0)) FROM TARGET.FACT_BILLING_TRANSACTION WHERE POST_DATE BETWEEN ''2026-04-01'' AND ''2026-06-30''',
 0.5, 'SUM([Charges]) - SUM([Contractual Adjustments])', 'SUM(Txn[Charges]) - SUM(Txn[ContractualAdj])', '=Sum([Charges]) - Sum([Contractual Adj])'),
('cash collections', 'Cash Collections',
 'SELECT -SUM(AMOUNT) FROM TARGET.FACT_BILLING_TRANSACTION WHERE TRANSACTION_TYPE = ''Payment'' AND POST_DATE BETWEEN ''2026-04-01'' AND ''2026-06-30''',
 0.5, 'SUM(IF [Transaction Type] = ''Payment'' THEN -[Amount] END)', 'CALCULATE(-SUM(Txn[Amount]), Txn[TxnType] = "Payment")', '=Sum([Payments])'),
('charge lag days', 'Charge Lag (days)',
 'SELECT AVG(DATEDIFF(day, SERVICE_DATE, POST_DATE)) FROM TARGET.FACT_BILLING_TRANSACTION WHERE TRANSACTION_TYPE = ''Charge'' AND POST_DATE BETWEEN ''2026-04-01'' AND ''2026-06-30''',
 2.0, 'AVG(DATEDIFF(''day'', [Service Date], [Post Date]))', 'AVERAGEX(Txn, DATEDIFF(Txn[ServiceDate], Txn[PostDate], DAY))', '=Average(DaysBetween([Service Date];[Post Date]))'),
('ed left without being seen rate', 'ED LWBS Rate',
 'SELECT COUNT_IF(LWBS_FLAG) / COUNT(*) FROM TARGET.FACT_ED_EVENT WHERE ARRIVAL_DATETIME::DATE BETWEEN ''2026-04-01'' AND ''2026-06-30''',
 2.0, 'SUM(IF [LWBS Flag] THEN 1 ELSE 0 END) / COUNT([ED Visit ID])', 'DIVIDE(CALCULATE(COUNTROWS(EdVisits), EdVisits[Lwbs] = TRUE()), COUNTROWS(EdVisits))', '=Count([ED Visit ID]) Where([LWBS Flag] = "Y") / Count([ED Visit ID])');

