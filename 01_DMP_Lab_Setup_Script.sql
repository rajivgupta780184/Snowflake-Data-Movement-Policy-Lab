-- =====================================================================
-- Snowflake Data Movement Policies: Hands-On Lab Script
-- Author: Rajiv Gupta | Snowflake User Group Seminar | October 2026
-- Companion to Snowflake_DMP_Hands_On_Lab_Guide.docx
--
-- Run in a NON-PRODUCTION account. Execute one step at a time.
-- Programmatic fetch and baseline tests (Steps 9 and 11) must run from the
-- Snowflake CLI, SnowSQL or Python; see the lab guide for those commands.
-- =====================================================================

-- =====================================================================
-- STEP 1.1  Warehouse, database and schemas
-- =====================================================================
USE ROLE SYSADMIN;

CREATE WAREHOUSE IF NOT EXISTS DMP_LAB_WH
  WAREHOUSE_SIZE      = 'LARGE'
  AUTO_SUSPEND        = 60
  AUTO_RESUME         = TRUE
  INITIALLY_SUSPENDED = TRUE
  COMMENT = 'Data Movement Policy seminar lab';

CREATE DATABASE IF NOT EXISTS DMP_LAB_DB
  COMMENT = 'Data Movement Policy seminar lab';
CREATE SCHEMA IF NOT EXISTS DMP_LAB_DB.PAYMENTS
  COMMENT = 'Lab data';
CREATE SCHEMA IF NOT EXISTS DMP_LAB_DB.GOVERNANCE
  COMMENT = 'Tags, data movement rules and policies';

USE WAREHOUSE DMP_LAB_WH;

SHOW WAREHOUSES LIKE 'DMP_LAB_WH';
SHOW SCHEMAS IN DATABASE DMP_LAB_DB;

-- =====================================================================
-- STEP 1.2  Sample data and export stage
-- =====================================================================
USE ROLE SYSADMIN;
USE SCHEMA DMP_LAB_DB.PAYMENTS;

CREATE OR REPLACE TABLE CUSTOMER_PAYMENTS (
  PAYMENT_ID     NUMBER(10,0),
  CUSTOMER_ID    NUMBER(10,0),
  CUSTOMER_NAME  VARCHAR(100),
  EMAIL          VARCHAR(200),
  IBAN           VARCHAR(34),
  COUNTRY_CODE   VARCHAR(2),
  PAYMENT_DATE   DATE,
  AMOUNT         NUMBER(12,2),
  CHANNEL        VARCHAR(20)
) COMMENT = 'Synthetic payment records for the DMP lab';

INSERT INTO CUSTOMER_PAYMENTS
SELECT
  ROW_NUMBER() OVER (ORDER BY SEQ4()),
  UNIFORM(10000, 99999, RANDOM()),
  ARRAY_CONSTRUCT('Aarav','Maya','Liam','Sofia','Noah',
                  'Priya','Ethan','Chloe','Omar','Hana')
      [UNIFORM(0, 9, RANDOM())]::VARCHAR
    || ' ' ||
  ARRAY_CONSTRUCT('Sharma','Patel','Jones','Garcia','Smith',
                  'Khan','Fischer','Rossi','Tanaka','Brown')
      [UNIFORM(0, 9, RANDOM())]::VARCHAR,
  'customer' || LPAD(ROW_NUMBER() OVER (ORDER BY SEQ4())::VARCHAR, 5, '0')
             || '@example.com',
  'GB' || LPAD(UNIFORM(10, 99, RANDOM())::VARCHAR, 2, '0') || 'LABX'
       || LPAD(UNIFORM(0, 99999999, RANDOM())::VARCHAR, 14, '0'),
  ARRAY_CONSTRUCT('GB','DE','FR','IN','US')[UNIFORM(0, 4, RANDOM())]::VARCHAR,
  DATEADD(DAY, -UNIFORM(0, 365, RANDOM()), CURRENT_DATE()),
  ROUND(UNIFORM(500, 500000, RANDOM()) / 100, 2),
  ARRAY_CONSTRUCT('CARD','BANK_TRANSFER','WALLET')[UNIFORM(0, 2, RANDOM())]::VARCHAR
FROM TABLE(GENERATOR(ROWCOUNT => 1000));

CREATE OR REPLACE TABLE WEB_EVENTS (
  EVENT_ID    NUMBER(10,0),
  SESSION_ID  VARCHAR(36),
  PAGE_PATH   VARCHAR(100),
  EVENT_TS    TIMESTAMP_NTZ
) COMMENT = 'Untagged table for the account-level baseline test';

INSERT INTO WEB_EVENTS
SELECT
  ROW_NUMBER() OVER (ORDER BY SEQ4()),
  UUID_STRING(),
  ARRAY_CONSTRUCT('/home','/pricing','/docs','/blog','/contact')
      [UNIFORM(0, 4, RANDOM())]::VARCHAR,
  DATEADD(SECOND, -UNIFORM(0, 2592000, RANDOM()), CURRENT_TIMESTAMP())::TIMESTAMP_NTZ
FROM TABLE(GENERATOR(ROWCOUNT => 2000));

CREATE OR REPLACE STAGE EXPORT_STAGE
  FILE_FORMAT = (TYPE = CSV FIELD_OPTIONALLY_ENCLOSED_BY = '"')
  COMMENT = 'Internal stage for COPY INTO export tests';

SELECT 'CUSTOMER_PAYMENTS' AS TABLE_NAME, COUNT(*) AS ROW_COUNT
FROM DMP_LAB_DB.PAYMENTS.CUSTOMER_PAYMENTS
UNION ALL
SELECT 'WEB_EVENTS', COUNT(*) FROM DMP_LAB_DB.PAYMENTS.WEB_EVENTS;

SELECT * FROM DMP_LAB_DB.PAYMENTS.CUSTOMER_PAYMENTS LIMIT 5;

-- =====================================================================
-- STEP 1.3  Roles and permissions
-- =====================================================================
USE ROLE USERADMIN;
CREATE ROLE IF NOT EXISTS DMP_LAB_ANALYST
  COMMENT = 'Lab analyst: limited on every movement channel';
CREATE ROLE IF NOT EXISTS DMP_LAB_STEWARD
  COMMENT = 'Lab steward: approved for unlimited programmatic fetch';

USE ROLE SECURITYADMIN;
GRANT ROLE DMP_LAB_ANALYST TO ROLE SYSADMIN;
GRANT ROLE DMP_LAB_STEWARD TO ROLE SYSADMIN;

-- Grant both roles to the current user (a single statement, so it also
-- works in tools that run each statement in its own session)
EXECUTE IMMEDIATE $$
BEGIN
  EXECUTE IMMEDIATE 'GRANT ROLE DMP_LAB_ANALYST TO USER "' || CURRENT_USER() || '"';
  EXECUTE IMMEDIATE 'GRANT ROLE DMP_LAB_STEWARD TO USER "' || CURRENT_USER() || '"';
  RETURN 'Roles granted to ' || CURRENT_USER();
END;
$$;

GRANT USAGE ON WAREHOUSE DMP_LAB_WH            TO ROLE DMP_LAB_ANALYST;
GRANT USAGE ON DATABASE  DMP_LAB_DB            TO ROLE DMP_LAB_ANALYST;
GRANT USAGE ON SCHEMA    DMP_LAB_DB.PAYMENTS   TO ROLE DMP_LAB_ANALYST;
GRANT SELECT ON ALL TABLES IN SCHEMA DMP_LAB_DB.PAYMENTS TO ROLE DMP_LAB_ANALYST;
GRANT READ, WRITE ON STAGE DMP_LAB_DB.PAYMENTS.EXPORT_STAGE TO ROLE DMP_LAB_ANALYST;

GRANT USAGE ON WAREHOUSE DMP_LAB_WH            TO ROLE DMP_LAB_STEWARD;
GRANT USAGE ON DATABASE  DMP_LAB_DB            TO ROLE DMP_LAB_STEWARD;
GRANT USAGE ON SCHEMA    DMP_LAB_DB.PAYMENTS   TO ROLE DMP_LAB_STEWARD;
GRANT SELECT ON ALL TABLES IN SCHEMA DMP_LAB_DB.PAYMENTS TO ROLE DMP_LAB_STEWARD;
GRANT READ, WRITE ON STAGE DMP_LAB_DB.PAYMENTS.EXPORT_STAGE TO ROLE DMP_LAB_STEWARD;

SHOW GRANTS TO ROLE DMP_LAB_ANALYST;
SHOW GRANTS TO ROLE DMP_LAB_STEWARD;





-- =====================================================================
-- STEP 2  Baseline: no data movement policy yet (TC01)
-- Run in Snowsight as DMP_LAB_ANALYST
-- =====================================================================
USE ROLE DMP_LAB_ANALYST;
USE SECONDARY ROLES NONE;
USE WAREHOUSE DMP_LAB_WH;

SELECT PAYMENT_ID, CUSTOMER_ID, CUSTOMER_NAME, COUNTRY_CODE,
       PAYMENT_DATE, AMOUNT, CHANNEL
FROM DMP_LAB_DB.PAYMENTS.CUSTOMER_PAYMENTS
LIMIT 260;





-- =====================================================================
-- STEP 3  Governance tags
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE WAREHOUSE DMP_LAB_WH;
USE SCHEMA DMP_LAB_DB.GOVERNANCE;

CREATE OR REPLACE TAG MOVEMENT_TIER
  ALLOWED_VALUES 'RESTRICTED', 'INTERNAL'
  PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT
  COMMENT = 'Sensitivity tier that carries the table-level data movement policy';

CREATE OR REPLACE TAG PII_CRITICAL
  ALLOWED_VALUES 'TRUE'
  PROPAGATE = ON_DEPENDENCY_AND_DATA_MOVEMENT
  COMMENT = 'Critical personal data that carries the column-level data movement policy';

ALTER TABLE DMP_LAB_DB.PAYMENTS.CUSTOMER_PAYMENTS
  SET TAG DMP_LAB_DB.GOVERNANCE.MOVEMENT_TIER = 'RESTRICTED';

ALTER TABLE DMP_LAB_DB.PAYMENTS.CUSTOMER_PAYMENTS
  MODIFY COLUMN IBAN SET TAG DMP_LAB_DB.GOVERNANCE.PII_CRITICAL = 'TRUE';

SELECT TAG_NAME, TAG_VALUE, LEVEL, COLUMN_NAME
FROM TABLE(DMP_LAB_DB.INFORMATION_SCHEMA.TAG_REFERENCES_ALL_COLUMNS(
       'DMP_LAB_DB.PAYMENTS.CUSTOMER_PAYMENTS', 'table'))
ORDER BY TAG_NAME, COLUMN_NAME;

SHOW TAGS IN SCHEMA DMP_LAB_DB.GOVERNANCE;

-- =====================================================================
-- STEP 4.1  Rules for the table-level policy
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE SCHEMA DMP_LAB_DB.GOVERNANCE;

-- Snowsight results grid
CREATE OR REPLACE DATA MOVEMENT RULE R_UI_VIEW_ENFORCE
  TYPE = 'SNOWSIGHT_UI'
  MAX_ROWS AS () RETURNS INTEGER -> (250);

CREATE OR REPLACE DATA MOVEMENT RULE R_UI_VIEW_ALERT
  TYPE = 'SNOWSIGHT_UI'
  MAX_ROWS AS () RETURNS INTEGER -> (150);

-- Snowsight download (enforce only: not captured in the violations view)
CREATE OR REPLACE DATA MOVEMENT RULE R_UI_DOWNLOAD_ENFORCE
  TYPE = 'UI_DOWNLOAD'
  MAX_ROWS AS () RETURNS INTEGER -> (50);

-- COPY INTO an internal stage
CREATE OR REPLACE DATA MOVEMENT RULE R_STAGE_ENFORCE
  TYPE = 'COPY_INTO_INTERNAL_STAGE'
  MAX_ROWS AS () RETURNS INTEGER -> (100);

CREATE OR REPLACE DATA MOVEMENT RULE R_STAGE_ALERT
  TYPE = 'COPY_INTO_INTERNAL_STAGE'
  MAX_ROWS AS () RETURNS INTEGER -> (60);

-- Programmatic clients: the steward role is exempt (NULL = no limit)
CREATE OR REPLACE DATA MOVEMENT RULE R_FETCH_ENFORCE
  TYPE = 'PROGRAMMATIC_FETCH'
  MAX_ROWS AS () RETURNS INTEGER -> (
    CASE WHEN SYS_CONTEXT('SNOWFLAKE$SESSION', 'ROLE') = 'DMP_LAB_STEWARD'
         THEN NULL
         ELSE 400
    END);

CREATE OR REPLACE DATA MOVEMENT RULE R_FETCH_ALERT
  TYPE = 'PROGRAMMATIC_FETCH'
  MAX_ROWS AS () RETURNS INTEGER -> (
    CASE WHEN SYS_CONTEXT('SNOWFLAKE$SESSION', 'ROLE') = 'DMP_LAB_STEWARD'
         THEN NULL
         ELSE 250
    END);

-- AI agents
CREATE OR REPLACE DATA MOVEMENT RULE R_AGENT_ENFORCE
  TYPE = 'AGENT_ACCESS'
  MAX_ROWS AS () RETURNS INTEGER -> (200);

CREATE OR REPLACE DATA MOVEMENT RULE R_AGENT_ALERT
  TYPE = 'AGENT_ACCESS'
  MAX_ROWS AS () RETURNS INTEGER -> (120);

-- =====================================================================
-- STEP 4.2  Rules for the IBAN column policy (every channel covered)
-- =====================================================================
CREATE OR REPLACE DATA MOVEMENT RULE C_UI_VIEW_ENFORCE
  TYPE = 'SNOWSIGHT_UI'
  MAX_ROWS AS () RETURNS INTEGER -> (25);

CREATE OR REPLACE DATA MOVEMENT RULE C_UI_DOWNLOAD_ENFORCE
  TYPE = 'UI_DOWNLOAD'
  MAX_ROWS AS () RETURNS INTEGER -> (10);

CREATE OR REPLACE DATA MOVEMENT RULE C_STAGE_ENFORCE
  TYPE = 'COPY_INTO_INTERNAL_STAGE'
  MAX_ROWS AS () RETURNS INTEGER -> (10);

CREATE OR REPLACE DATA MOVEMENT RULE C_FETCH_ENFORCE
  TYPE = 'PROGRAMMATIC_FETCH'
  MAX_ROWS AS () RETURNS INTEGER -> (
    CASE WHEN SYS_CONTEXT('SNOWFLAKE$SESSION', 'ROLE') = 'DMP_LAB_STEWARD'
         THEN NULL
         ELSE 25
    END);

CREATE OR REPLACE DATA MOVEMENT RULE C_AGENT_ENFORCE
  TYPE = 'AGENT_ACCESS'
  MAX_ROWS AS () RETURNS INTEGER -> (25);

-- =====================================================================
-- STEP 4.3  Rule for the account-level baseline
-- Scoped to the lab analyst so the lab cannot affect other workloads.
-- In production, invert this: limit everyone and exempt service roles.
-- =====================================================================
CREATE OR REPLACE DATA MOVEMENT RULE A_FETCH_BASELINE
  TYPE = 'PROGRAMMATIC_FETCH'
  MAX_ROWS AS () RETURNS INTEGER -> (
    CASE WHEN SYS_CONTEXT('SNOWFLAKE$SESSION', 'ROLE') = 'DMP_LAB_ANALYST'
         THEN 600
         ELSE NULL
    END);

SHOW DATA MOVEMENT RULES IN SCHEMA DMP_LAB_DB.GOVERNANCE;
DESCRIBE DATA MOVEMENT RULE R_FETCH_ENFORCE;

-- =====================================================================
-- STEP 5.1  Table-level policy on the MOVEMENT_TIER tag
-- =====================================================================
USE ROLE ACCOUNTADMIN;
USE SCHEMA DMP_LAB_DB.GOVERNANCE;

CREATE OR REPLACE DATA MOVEMENT POLICY P_RESTRICTED_TABLE
  ENFORCE_RULES = (R_UI_VIEW_ENFORCE, R_UI_DOWNLOAD_ENFORCE, R_STAGE_ENFORCE,
                   R_FETCH_ENFORCE, R_AGENT_ENFORCE)
  ALERT_RULES   = (R_UI_VIEW_ALERT, R_STAGE_ALERT, R_FETCH_ALERT, R_AGENT_ALERT)
  COMMENT = 'Movement guardrails for tables tagged MOVEMENT_TIER';

ALTER TAG DMP_LAB_DB.GOVERNANCE.MOVEMENT_TIER
  SET DATA MOVEMENT POLICY P_RESTRICTED_TABLE;

-- =====================================================================
-- STEP 5.2  Column-level policy on the PII_CRITICAL tag
-- =====================================================================
CREATE OR REPLACE DATA MOVEMENT POLICY P_PII_CRITICAL_COLUMN
  ENFORCE_RULES = (C_UI_VIEW_ENFORCE, C_UI_DOWNLOAD_ENFORCE, C_STAGE_ENFORCE,
                   C_FETCH_ENFORCE, C_AGENT_ENFORCE)
  COMMENT = 'Stricter limits whenever a PII_CRITICAL column is in the query';

ALTER TAG DMP_LAB_DB.GOVERNANCE.PII_CRITICAL
  SET DATA MOVEMENT POLICY P_PII_CRITICAL_COLUMN;

-- =====================================================================
-- STEP 5.3  Account-level baseline (skip if one is already set)
-- =====================================================================
CREATE OR REPLACE DATA MOVEMENT POLICY P_ACCOUNT_BASELINE
  ENFORCE_RULES = (A_FETCH_BASELINE)
  COMMENT = 'Baseline for data with no tag-based data movement policy';

ALTER ACCOUNT SET DATA MOVEMENT POLICY DMP_LAB_DB.GOVERNANCE.P_ACCOUNT_BASELINE;

SHOW DATA MOVEMENT POLICIES IN SCHEMA DMP_LAB_DB.GOVERNANCE;
SHOW DATA MOVEMENT POLICIES IN ACCOUNT;
DESCRIBE DATA MOVEMENT POLICY P_RESTRICTED_TABLE;
DESCRIBE DATA MOVEMENT POLICY P_PII_CRITICAL_COLUMN;
SHOW TAGS IN SCHEMA DMP_LAB_DB.GOVERNANCE;