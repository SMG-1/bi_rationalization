-- =============================================================================
-- TARGET — a small certified mart, so converted assets can actually run
-- -----------------------------------------------------------------------------
-- Two subject areas (Inpatient Census / Encounters and Revenue Cycle / Denials)
-- built to the derived target model's entity names, with enough synthetic
-- rows that a reconciliation test produces a real number. This is what the
-- data team's first wave delivers; here it exists so the harness has
-- something to reconcile against.
-- =============================================================================
USE DATABASE BI_MODERNIZATION;
USE SCHEMA TARGET;

CREATE OR REPLACE TABLE DIM_DATE AS
SELECT DATEADD(day, SEQ4(), DATE '2025-01-01') AS CALENDAR_DATE,
       TO_NUMBER(TO_CHAR(DATEADD(day, SEQ4(), DATE '2025-01-01'), 'YYYYMMDD')) AS DATE_KEY,
       IFF(MONTH(DATEADD(day, SEQ4(), DATE '2025-01-01')) >= 7, YEAR(DATEADD(day, SEQ4(), DATE '2025-01-01')) + 1, YEAR(DATEADD(day, SEQ4(), DATE '2025-01-01'))) AS FISCAL_YEAR,
       MOD(MONTH(DATEADD(day, SEQ4(), DATE '2025-01-01')) + 5, 12) + 1 AS FISCAL_PERIOD,
       DAYOFWEEKISO(DATEADD(day, SEQ4(), DATE '2025-01-01')) AS DAY_OF_WEEK,
       DAYOFWEEKISO(DATEADD(day, SEQ4(), DATE '2025-01-01')) >= 6 AS IS_WEEKEND
FROM TABLE(GENERATOR(ROWCOUNT => 592));

CREATE OR REPLACE TABLE DIM_DEPARTMENT AS
SELECT 'DEP' || LPAD(SEQ4() + 1, 3, '0') AS DEPARTMENT_ID,
       ARRAY_CONSTRUCT('4 North Med/Surg','4 South Med/Surg','5 North Telemetry','5 South Ortho','6 North Oncology','6 South Neuro',
                       'MICU','SICU','CVICU','NICU','PICU','Mother Baby','L&D','Peds Med/Surg','Behavioral Health','Rehab',
                       'Observation Unit','Emergency Department','Main OR','Ambulatory Surgery','Cath Lab','Endoscopy',
                       'Cardiology Clinic','Primary Care East','Primary Care West','Orthopedics Clinic','Oncology Clinic',
                       'Pediatrics Clinic','Women''s Health Clinic','Urgent Care North','Urgent Care South','Dialysis',
                       'Infusion Center','Wound Care','Sleep Lab','Imaging','Lab','Pharmacy','Respiratory','Physical Therapy')[SEQ4()]::TEXT AS DEPARTMENT_NAME,
       SEQ4() < 17 AS IS_INPATIENT, SEQ4() = 17 AS IS_ED,
       IFF(SEQ4() < 17, 12 + MOD(ABS(HASH(SEQ4(), 'beds')), 24), NULL) AS BED_COUNT,
       IFF(SEQ4() < 17, 'Inpatient', IFF(SEQ4() < 22, 'Procedural', 'Ambulatory')) AS SERVICE_AREA,
       'CC' || LPAD(7000 + SEQ4(), 4, '0') AS COST_CENTER
FROM TABLE(GENERATOR(ROWCOUNT => 40));

CREATE OR REPLACE TABLE DIM_PAYER AS
SELECT 'PAY' || LPAD(SEQ4() + 1, 2, '0') AS PAYER_ID,
       ARRAY_CONSTRUCT('Medicare','Medicare Advantage - Aetna','Medicare Advantage - Humana','Medicaid','Medicaid MCO - Molina',
                       'BCBS PPO','BCBS HMO','UnitedHealthcare','Cigna','Aetna Commercial','Self Pay','Workers Comp')[SEQ4()]::TEXT AS PAYER_NAME,
       ARRAY_CONSTRUCT('MCR','MCR','MCR','MCD','MCD','COM','COM','COM','COM','COM','SELF','WC')[SEQ4()]::TEXT AS FINANCIAL_CLASS,
       SEQ4() < 5 AS IS_GOVERNMENT
FROM TABLE(GENERATOR(ROWCOUNT => 12));

CREATE OR REPLACE TABLE DIM_PROVIDER AS
SELECT 'PRV' || LPAD(SEQ4() + 1, 4, '0') AS PROVIDER_ID,
       'Provider ' || (SEQ4() + 1) AS PROVIDER_NAME,
       ARRAY_CONSTRUCT('Hospital Medicine','Cardiology','Orthopedics','General Surgery','Emergency Medicine','Oncology','Neurology','Pediatrics','Family Medicine','Internal Medicine')[MOD(SEQ4(), 10)]::TEXT AS SPECIALTY,
       MOD(ABS(HASH(SEQ4(), 'emp')), 10) < 7 AS IS_EMPLOYED
FROM TABLE(GENERATOR(ROWCOUNT => 300));

CREATE OR REPLACE TABLE FACT_HOSPITAL_ENCOUNTER AS
WITH g AS (
    SELECT SEQ4() AS N,
           DATEADD(day, MOD(ABS(HASH(SEQ4(), 'adm')), 560), DATE '2025-01-01') AS ADMIT_DATE,
           -- LOS skewed: mostly 1-5 days, tail to 30
           GREATEST(1, LEAST(30, ROUND(-LN(1 - (MOD(ABS(HASH(SEQ4(), 'los')), 10000) / 10000.0) * 0.999) * 3.4))) AS LOS_DAYS,
           MOD(ABS(HASH(SEQ4(), 'hrs')), 24) AS ADMIT_HOUR, MOD(ABS(HASH(SEQ4(), 'dhrs')), 24) AS DISCH_HOUR
    FROM TABLE(GENERATOR(ROWCOUNT => 120000))
)
SELECT 'HE' || LPAD(N + 1, 7, '0') AS HOSPITAL_ENCOUNTER_ID,
       'PT' || LPAD(MOD(ABS(HASH(N, 'pt')), 60000), 6, '0') AS PATIENT_ID,
       TIMESTAMPADD(hour, ADMIT_HOUR, ADMIT_DATE::TIMESTAMP_NTZ) AS ADMIT_DATETIME,
       TIMESTAMPADD(hour, DISCH_HOUR, DATEADD(day, LOS_DAYS, ADMIT_DATE)::TIMESTAMP_NTZ) AS DISCHARGE_DATETIME,
       ADMIT_DATE, DATEADD(day, LOS_DAYS, ADMIT_DATE) AS DISCHARGE_DATE,
       'DEP' || LPAD(1 + MOD(ABS(HASH(N, 'dep')), 17), 3, '0') AS DISCHARGE_DEPARTMENT_ID,
       'PRV' || LPAD(1 + MOD(ABS(HASH(N, 'prv')), 300), 4, '0') AS ATTENDING_PROVIDER_ID,
       'PAY' || LPAD(1 + MOD(ABS(HASH(N, 'pay')), 12), 2, '0') AS PRIMARY_PAYER_ID,
       IFF(MOD(ABS(HASH(N, 'cls')), 100) < 82, 'Inpatient', 'Observation') AS PATIENT_CLASS,
       LOS_DAYS,
       LOS_DAYS AS PATIENT_DAYS,
       MOD(ABS(HASH(N, 'readm')), 1000) < 118 AS READMIT_30D_FLAG,
       ARRAY_CONSTRUCT('Home','Home Health','SNF','Rehab','Expired','AMA','Hospice')[LEAST(6, FLOOR(MOD(ABS(HASH(N, 'disp')), 100) / 18))]::TEXT AS DISCHARGE_DISPOSITION,
       ROUND(LOS_DAYS * (0.85 + MOD(ABS(HASH(N, 'elos')), 40) / 100.0), 2) AS EXPECTED_LOS
FROM g;

CREATE OR REPLACE TABLE FACT_DAILY_CENSUS AS
SELECT d.CALENDAR_DATE AS CENSUS_DATE, e.DISCHARGE_DEPARTMENT_ID AS DEPARTMENT_ID,
       COUNT(*) AS MIDNIGHT_CENSUS,
       COUNT_IF(e.ADMIT_DATE = d.CALENDAR_DATE) AS ADMISSIONS,
       COUNT_IF(e.DISCHARGE_DATE = DATEADD(day, 1, d.CALENDAR_DATE)) AS DISCHARGES_NEXT_DAY
FROM DIM_DATE d
JOIN FACT_HOSPITAL_ENCOUNTER e ON e.ADMIT_DATE <= d.CALENDAR_DATE AND e.DISCHARGE_DATE > d.CALENDAR_DATE
WHERE d.CALENDAR_DATE <= DATE '2026-08-15'
GROUP BY 1, 2;

CREATE OR REPLACE TABLE FACT_BILLING_TRANSACTION AS
WITH g AS (SELECT SEQ4() AS N FROM TABLE(GENERATOR(ROWCOUNT => 600000)))
SELECT 'TX' || LPAD(N + 1, 8, '0') AS TRANSACTION_ID,
       'HE' || LPAD(1 + MOD(ABS(HASH(N, 'he')), 120000), 7, '0') AS HOSPITAL_ACCOUNT_ID,
       DATEADD(day, MOD(ABS(HASH(N, 'svc')), 560), DATE '2025-01-01') AS SERVICE_DATE,
       DATEADD(day, MOD(ABS(HASH(N, 'svc')), 560) + MOD(ABS(HASH(N, 'lag')), 9), DATE '2025-01-01') AS POST_DATE,
       CASE WHEN MOD(ABS(HASH(N, 'typ')), 100) < 55 THEN 'Charge'
            WHEN MOD(ABS(HASH(N, 'typ')), 100) < 80 THEN 'Payment'
            WHEN MOD(ABS(HASH(N, 'typ')), 100) < 96 THEN 'Contractual Adjustment'
            ELSE 'Bad Debt' END AS TRANSACTION_TYPE,
       CASE WHEN MOD(ABS(HASH(N, 'typ')), 100) < 55 THEN ROUND(50 + MOD(ABS(HASH(N, 'amt')), 12000) * 0.73, 2)
            WHEN MOD(ABS(HASH(N, 'typ')), 100) < 80 THEN -ROUND(40 + MOD(ABS(HASH(N, 'amt')), 6000) * 0.61, 2)
            WHEN MOD(ABS(HASH(N, 'typ')), 100) < 96 THEN -ROUND(30 + MOD(ABS(HASH(N, 'amt')), 5000) * 0.57, 2)
            ELSE -ROUND(20 + MOD(ABS(HASH(N, 'amt')), 1500) * 0.5, 2) END AS AMOUNT,
       'DEP' || LPAD(1 + MOD(ABS(HASH(N, 'dep')), 40), 3, '0') AS DEPARTMENT_ID,
       'PAY' || LPAD(1 + MOD(ABS(HASH(N, 'pay')), 12), 2, '0') AS PAYER_ID,
       'PRV' || LPAD(1 + MOD(ABS(HASH(N, 'prv')), 300), 4, '0') AS PROVIDER_ID
FROM g;

CREATE OR REPLACE TABLE FACT_DENIAL AS
WITH g AS (SELECT SEQ4() AS N FROM TABLE(GENERATOR(ROWCOUNT => 60000)))
SELECT 'DN' || LPAD(N + 1, 7, '0') AS DENIAL_ID,
       'HE' || LPAD(1 + MOD(ABS(HASH(N, 'he')), 120000), 7, '0') AS HOSPITAL_ACCOUNT_ID,
       'PAY' || LPAD(1 + MOD(ABS(HASH(N, 'pay')), 12), 2, '0') AS PAYER_ID,
       DATEADD(day, MOD(ABS(HASH(N, 'dd')), 560), DATE '2025-01-01') AS DENIAL_DATE,
       ARRAY_CONSTRUCT('Authorization','Medical Necessity','Eligibility','Coding','Timely Filing','Duplicate','Bundling','Other')[MOD(ABS(HASH(N, 'cat')), 8)]::TEXT AS DENIAL_CATEGORY,
       ARRAY_CONSTRUCT('CO-197','CO-50','CO-27','CO-4','CO-29','CO-18','CO-97','CO-16')[MOD(ABS(HASH(N, 'cat')), 8)]::TEXT AS CARC_CODE,
       ROUND(100 + MOD(ABS(HASH(N, 'amt')), 25000) * 0.8, 2) AS DENIED_AMOUNT,
       MOD(ABS(HASH(N, 'app')), 100) < 42 AS APPEAL_FLAG,
       IFF(MOD(ABS(HASH(N, 'app')), 100) < 42, IFF(MOD(ABS(HASH(N, 'out')), 100) < 55, 'Overturned', 'Upheld'), NULL) AS APPEAL_OUTCOME,
       IFF(MOD(ABS(HASH(N, 'app')), 100) < 42 AND MOD(ABS(HASH(N, 'out')), 100) < 55, ROUND((100 + MOD(ABS(HASH(N, 'amt')), 25000) * 0.8) * 0.9, 2), 0) AS RECOVERED_AMOUNT,
       MOD(ABS(HASH(N, 'cat')), 8) IN (0, 2, 3, 4) AS PREVENTABLE_FLAG,
       'DEP' || LPAD(1 + MOD(ABS(HASH(N, 'dep')), 40), 3, '0') AS ROOT_CAUSE_DEPARTMENT_ID
FROM g;

-- Claim volume denominator for the denial rate: accounts billed per month.
CREATE OR REPLACE VIEW V_CLAIMS_BILLED AS
SELECT HOSPITAL_ENCOUNTER_ID AS CLAIM_ID, PRIMARY_PAYER_ID AS PAYER_ID, DISCHARGE_DATE AS BILLED_DATE,
       EXISTS (SELECT 1 FROM FACT_DENIAL d WHERE d.HOSPITAL_ACCOUNT_ID = e.HOSPITAL_ENCOUNTER_ID) AS DENIED_FLAG
FROM FACT_HOSPITAL_ENCOUNTER e;

CREATE OR REPLACE TABLE FACT_ED_EVENT AS
WITH g AS (SELECT SEQ4() AS N FROM TABLE(GENERATOR(ROWCOUNT => 150000)))
SELECT 'ED' || LPAD(N + 1, 7, '0') AS ED_VISIT_ID,
       'PT' || LPAD(MOD(ABS(HASH(N, 'pt')), 60000), 6, '0') AS PATIENT_ID,
       TIMESTAMPADD(minute, MOD(ABS(HASH(N, 'min')), 1440), DATEADD(day, MOD(ABS(HASH(N, 'arr')), 560), DATE '2025-01-01')::TIMESTAMP_NTZ) AS ARRIVAL_DATETIME,
       1 + MOD(ABS(HASH(N, 'esi')), 5) AS ESI_LEVEL,
       MOD(ABS(HASH(N, 'lwbs')), 1000) < 27 AS LWBS_FLAG,
       IFF(MOD(ABS(HASH(N, 'lwbs')), 1000) < 27, 'LWBS', IFF(MOD(ABS(HASH(N, 'adm')), 100) < 22, 'Admit', 'Discharge')) AS DISPOSITION,
       IFF(MOD(ABS(HASH(N, 'adm')), 100) < 22, MOD(ABS(HASH(N, 'board')), 720), 0) AS BOARDING_MINUTES,
       15 + MOD(ABS(HASH(N, 'd2p')), 120) AS DOOR_TO_PROVIDER_MINUTES
FROM g;
