-- Demo-only: a handful of pre-recorded decisions so the gate is visibly a gate.
-- Never run from the in-app pipeline; never at a client.
USE DATABASE BI_MODERNIZATION;
USE SCHEMA RATIONALIZATION;

-- idempotent: the demo reviewers' rows are replaced, never duplicated
DELETE FROM DISPOSITION_REVIEW WHERE REVIEWER IN ('jordan.okafor@ridgelinehealth.org', 'riley.mensah@ridgelinehealth.org', 'casey.lindqvist@ridgelinehealth.org');

-- A handful of decisions are pre-recorded so the gate is visibly a gate: an
-- owner pushing back on a retirement, a subscription trap resolved both ways,
-- and a consolidation accepted.
INSERT INTO DISPOSITION_REVIEW (ASSET_ID, REVIEWER, REVIEWER_ROLE, DECISION, FINAL_DISPOSITION, NOTE)
SELECT d.ASSET_ID, 'jordan.okafor@ridgelinehealth.org', 'Director, Decision Support', 'OVERRIDE', 'MIGRATE',
       'Board package feed. The subscribers read the PDF; they never open the workbook. Confirmed with the CFO office.'
FROM ASSET_DISPOSITION d JOIN V_ASSET_PROFILE p ON p.ASSET_ID = d.ASSET_ID
WHERE d.RULE_ID = 'R055' AND p.EXEC_SUBSCRIBER_COUNT > 0
ORDER BY p.SUBSCRIPTION_COUNT DESC LIMIT 3;

INSERT INTO DISPOSITION_REVIEW (ASSET_ID, REVIEWER, REVIEWER_ROLE, DECISION, FINAL_DISPOSITION, NOTE)
SELECT d.ASSET_ID, 'riley.mensah@ridgelinehealth.org', 'BI Platform Lead', 'ACCEPT', 'RETIRE',
       'Recipients confirmed the subscription was set up for a project that closed in 2024. Unsubscribed.'
FROM ASSET_DISPOSITION d JOIN V_ASSET_PROFILE p ON p.ASSET_ID = d.ASSET_ID
WHERE d.RULE_ID = 'R055' AND p.EXEC_SUBSCRIBER_COUNT = 0
ORDER BY p.SUBSCRIPTION_COUNT ASC LIMIT 4;

INSERT INTO DISPOSITION_REVIEW (ASSET_ID, REVIEWER, REVIEWER_ROLE, DECISION, FINAL_DISPOSITION, NOTE)
SELECT d.ASSET_ID, 'casey.lindqvist@ridgelinehealth.org', 'Manager, Revenue Cycle Analytics', 'OVERRIDE', 'MIGRATE',
       'Used during month-end close only; 5 views a quarter is the correct number. Keep.'
FROM ASSET_DISPOSITION d JOIN V_ASSET_PROFILE p ON p.ASSET_ID = d.ASSET_ID
WHERE d.RULE_ID = 'R060' AND p.SUBJECT_AREA = 'Revenue Cycle' AND p.OWNER_IS_ACTIVE
ORDER BY p.VIEWS_365 DESC LIMIT 2;

INSERT INTO DISPOSITION_REVIEW (ASSET_ID, REVIEWER, REVIEWER_ROLE, DECISION, FINAL_DISPOSITION, NOTE)
SELECT d.ASSET_ID, 'riley.mensah@ridgelinehealth.org', 'BI Platform Lead', 'ACCEPT', 'CONSOLIDATE',
       'Agreed with owner; the payer filter they needed is being added to the canonical.'
FROM ASSET_DISPOSITION d JOIN V_ASSET_PROFILE p ON p.ASSET_ID = d.ASSET_ID
WHERE d.RULE_ID = 'R030' AND p.VIEWS_365 > 50
ORDER BY p.VIEWS_365 DESC LIMIT 6;

