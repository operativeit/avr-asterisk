-- cdr: who the call belongs to, and what it costs.
--
-- Written at call time by the dialplan through cdr_adaptive_odbc, which fills
-- every column named like a CDR variable:
--   tenant_id, agent_id  Set(CDR(tenant_id)=...) from provision (the DDI for
--                        incoming calls, the calling account for outgoing ones)
--   direction            in, out or internal
--   trunk                provision account of the carrier the call used
--   linkedid             groups the legs of one call (transfers)
-- Written later by avr-rate, with the tenant's price and the carrier's cost
-- of the leg (billsec), so the margin is cost - carrier_cost:
--   cost, billing_*_id, carrier_cost, carrier_billing_*_id, rating_status, rated_at
-- export_status / exported_at are for the export to the invoicing system.
--
-- cdr, cdr_archives and cdr_swap must keep the same columns in the same order
-- (EXCHANGE PARTITION and INSERT ... SELECT * in archive_year).

USE `{{cdr_db}}`;

ALTER TABLE cdr
  ADD COLUMN `linkedid` VARCHAR(64) NULL DEFAULT NULL,
  ADD COLUMN `tenant_id` CHAR(36) NULL DEFAULT NULL,
  ADD COLUMN `agent_id` CHAR(36) NULL DEFAULT NULL,
  ADD COLUMN `direction` ENUM('in','out','internal') NULL DEFAULT NULL,
  ADD COLUMN `trunk` VARCHAR(40) NULL DEFAULT NULL,
  ADD COLUMN `cost` DECIMAL(12,4) NULL DEFAULT NULL,
  ADD COLUMN `billing_profile_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `billing_zone_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `billing_fee_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `carrier_cost` DECIMAL(12,4) NULL DEFAULT NULL,
  ADD COLUMN `carrier_billing_profile_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `carrier_billing_zone_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `carrier_billing_fee_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `rating_status` ENUM('unrated','ok','ignored','failed_no_tenant','failed_no_fee',
                                  'failed_no_carrier','failed_no_carrier_fee') NOT NULL DEFAULT 'unrated',
  ADD COLUMN `rated_at` TIMESTAMP NULL DEFAULT NULL,
  ADD COLUMN `export_status` ENUM('unexported','ok','failed') NOT NULL DEFAULT 'unexported',
  ADD COLUMN `exported_at` TIMESTAMP NULL DEFAULT NULL,
  ADD KEY `rating_status_calldate` (`rating_status`, `calldate`),
  ADD KEY `export_status_calldate` (`export_status`, `calldate`),
  ADD KEY `tenant_calldate` (`tenant_id`, `calldate`),
  ADD KEY `linkedid` (`linkedid`);

-- Rows written before this migration: nothing to rate.
UPDATE cdr SET rating_status = 'ignored';

ALTER TABLE cdr_archives
  ADD COLUMN `linkedid` VARCHAR(64) NULL DEFAULT NULL,
  ADD COLUMN `tenant_id` CHAR(36) NULL DEFAULT NULL,
  ADD COLUMN `agent_id` CHAR(36) NULL DEFAULT NULL,
  ADD COLUMN `direction` ENUM('in','out','internal') NULL DEFAULT NULL,
  ADD COLUMN `trunk` VARCHAR(40) NULL DEFAULT NULL,
  ADD COLUMN `cost` DECIMAL(12,4) NULL DEFAULT NULL,
  ADD COLUMN `billing_profile_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `billing_zone_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `billing_fee_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `carrier_cost` DECIMAL(12,4) NULL DEFAULT NULL,
  ADD COLUMN `carrier_billing_profile_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `carrier_billing_zone_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `carrier_billing_fee_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `rating_status` ENUM('unrated','ok','ignored','failed_no_tenant','failed_no_fee',
                                  'failed_no_carrier','failed_no_carrier_fee') NOT NULL DEFAULT 'ignored',
  ADD COLUMN `rated_at` TIMESTAMP NULL DEFAULT NULL,
  ADD COLUMN `export_status` ENUM('unexported','ok','failed') NOT NULL DEFAULT 'unexported',
  ADD COLUMN `exported_at` TIMESTAMP NULL DEFAULT NULL,
  ADD KEY `rating_status_calldate` (`rating_status`, `calldate`),
  ADD KEY `export_status_calldate` (`export_status`, `calldate`),
  ADD KEY `tenant_calldate` (`tenant_id`, `calldate`),
  ADD KEY `linkedid` (`linkedid`);

-- EXCHANGE PARTITION needs identical definitions, defaults included.
ALTER TABLE cdr_archives ALTER COLUMN `rating_status` SET DEFAULT 'unrated';

ALTER TABLE cdr_swap
  ADD COLUMN `linkedid` VARCHAR(64) NULL DEFAULT NULL,
  ADD COLUMN `tenant_id` CHAR(36) NULL DEFAULT NULL,
  ADD COLUMN `agent_id` CHAR(36) NULL DEFAULT NULL,
  ADD COLUMN `direction` ENUM('in','out','internal') NULL DEFAULT NULL,
  ADD COLUMN `trunk` VARCHAR(40) NULL DEFAULT NULL,
  ADD COLUMN `cost` DECIMAL(12,4) NULL DEFAULT NULL,
  ADD COLUMN `billing_profile_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `billing_zone_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `billing_fee_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `carrier_cost` DECIMAL(12,4) NULL DEFAULT NULL,
  ADD COLUMN `carrier_billing_profile_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `carrier_billing_zone_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `carrier_billing_fee_id` INT UNSIGNED NULL DEFAULT NULL,
  ADD COLUMN `rating_status` ENUM('unrated','ok','ignored','failed_no_tenant','failed_no_fee',
                                  'failed_no_carrier','failed_no_carrier_fee') NOT NULL DEFAULT 'unrated',
  ADD COLUMN `rated_at` TIMESTAMP NULL DEFAULT NULL,
  ADD COLUMN `export_status` ENUM('unexported','ok','failed') NOT NULL DEFAULT 'unexported',
  ADD COLUMN `exported_at` TIMESTAMP NULL DEFAULT NULL,
  ADD KEY `rating_status_calldate` (`rating_status`, `calldate`),
  ADD KEY `export_status_calldate` (`export_status`, `calldate`),
  ADD KEY `tenant_calldate` (`tenant_id`, `calldate`),
  ADD KEY `linkedid` (`linkedid`);
