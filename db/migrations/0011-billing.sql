-- billing: price lists, who pays what, and the balances avr-rate keeps.
--
-- A billing profile is a price list: zones (destination names) and fees
-- (a regular expression on the E.164 number, without +). The fee whose
-- expression is the longest wins (^2132.*$ before ^213.*$). One price:
-- init_rate for the first init_interval seconds, then follow_rate per
-- follow_interval seconds; rates are per minute.
--
-- Every call is rated twice (see avr-rate), so the margin is known:
--   billing_tenants   what the tenant pays: one profile for incoming and one
--                     for outgoing calls
--   billing_carriers  what the carrier charges us, by trunk (the provision
--                     account the call used)
--
-- The price lists themselves are not shipped here: load them with your own
-- data (elokia-infra: make billing-seed).

CREATE DATABASE IF NOT EXISTS `{{billing_db}}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE `{{billing_db}}`;

CREATE TABLE billing_profiles (
  id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
  handle      VARCHAR(64)  NULL,
  name        VARCHAR(128) NULL,
  created_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at  TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id)
) ENGINE=InnoDB;

CREATE TABLE billing_zones (
  id                  INT UNSIGNED NOT NULL AUTO_INCREMENT,
  billing_profile_id  INT UNSIGNED NOT NULL,
  zone                VARCHAR(127) NOT NULL COMMENT 'e.g. Africa',
  detail              VARCHAR(127) NULL COMMENT 'destination name, e.g. Algeria / Algiers',
  created_at          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at          TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (id),
  UNIQUE KEY profile_zone_detail (billing_profile_id, zone, detail),
  CONSTRAINT billing_zones_profile FOREIGN KEY (billing_profile_id) REFERENCES billing_profiles (id)
    ON DELETE CASCADE ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE TABLE billing_fees (
  id                  INT UNSIGNED NOT NULL AUTO_INCREMENT,
  billing_profile_id  INT UNSIGNED NOT NULL,
  billing_zone_id     INT UNSIGNED NULL,
  destination         VARCHAR(255) NOT NULL COMMENT 'regular expression on the E.164 number without +, e.g. ^34[67].*$',
  type                ENUM('call','sms') NOT NULL DEFAULT 'call',
  init_rate           DECIMAL(14,6) NOT NULL DEFAULT 0 COMMENT 'per minute, first init_interval seconds',
  init_interval       INT UNSIGNED  NOT NULL DEFAULT 1 COMMENT 'seconds',
  follow_rate         DECIMAL(14,6) NOT NULL DEFAULT 0 COMMENT 'per minute, after init_interval',
  follow_interval     INT UNSIGNED  NOT NULL DEFAULT 1 COMMENT 'seconds',
  PRIMARY KEY (id),
  UNIQUE KEY profile_destination_type (billing_profile_id, destination, type),
  KEY zone (billing_zone_id),
  CONSTRAINT billing_fees_profile FOREIGN KEY (billing_profile_id) REFERENCES billing_profiles (id)
    ON DELETE CASCADE ON UPDATE CASCADE,
  CONSTRAINT billing_fees_zone FOREIGN KEY (billing_zone_id) REFERENCES billing_zones (id)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE TABLE billing_tenants (
  tenant_id               CHAR(36)     NOT NULL COMMENT 'provision tenant_uuid (elokia-core tenant id)',
  name                    VARCHAR(255) NULL,
  in_billing_profile_id   INT UNSIGNED NULL COMMENT 'price of incoming calls',
  out_billing_profile_id  INT UNSIGNED NULL COMMENT 'price of outgoing calls',
  created_at              TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at              TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (tenant_id),
  CONSTRAINT billing_tenants_in FOREIGN KEY (in_billing_profile_id) REFERENCES billing_profiles (id)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT billing_tenants_out FOREIGN KEY (out_billing_profile_id) REFERENCES billing_profiles (id)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

CREATE TABLE billing_carriers (
  trunk                   VARCHAR(40)  NOT NULL COMMENT 'provision account of the trunk, e.g. sipgw1',
  name                    VARCHAR(255) NULL,
  in_billing_profile_id   INT UNSIGNED NULL COMMENT 'cost of incoming calls',
  out_billing_profile_id  INT UNSIGNED NULL COMMENT 'cost of outgoing calls',
  created_at              TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at              TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (trunk),
  CONSTRAINT billing_carriers_in FOREIGN KEY (in_billing_profile_id) REFERENCES billing_profiles (id)
    ON DELETE RESTRICT ON UPDATE CASCADE,
  CONSTRAINT billing_carriers_out FOREIGN KEY (out_billing_profile_id) REFERENCES billing_profiles (id)
    ON DELETE RESTRICT ON UPDATE CASCADE
) ENGINE=InnoDB;

-- Totals of the rated calls (rating_status ok), rebuilt by avr-rate for every
-- day and month it rates.
CREATE TABLE tenant_balances (
  tenant_id     CHAR(36)      NOT NULL,
  period        ENUM('daily','monthly') NOT NULL,
  start         DATE          NOT NULL COMMENT 'the day, or the first day of the month',
  direction     ENUM('in','out') NOT NULL,
  calls         INT UNSIGNED  NOT NULL DEFAULT 0,
  billsec       BIGINT UNSIGNED NOT NULL DEFAULT 0,
  cost          DECIMAL(14,4) NOT NULL DEFAULT 0,
  carrier_cost  DECIMAL(14,4) NOT NULL DEFAULT 0,
  updated_at    TIMESTAMP     NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (tenant_id, period, start, direction)
) ENGINE=InnoDB;

-- One line per call leg, for people: agent, number, time, duration, direction,
-- destination name and price.
CREATE SQL SECURITY DEFINER VIEW cdr_report AS
SELECT c.calldate,
       c.tenant_id,
       c.agent_id,
       c.direction,
       c.dst AS destination,
       c.billsec AS duration,
       TIME_FORMAT(SEC_TO_TIME(c.billsec), '%Hh %im %ss') AS duration_human,
       COALESCE(z.detail, z.zone) AS destination_name,
       c.cost,
       c.carrier_cost,
       c.cost - c.carrier_cost AS margin,
       c.disposition,
       c.rating_status,
       c.uniqueid,
       c.linkedid
  FROM `{{cdr_db}}`.cdr c
  LEFT JOIN billing_zones z ON z.id = c.billing_zone_id
 WHERE c.direction IS NOT NULL;

GRANT SELECT, INSERT, UPDATE, DELETE ON `{{billing_db}}`.* TO '{{app_user}}'@'%';
