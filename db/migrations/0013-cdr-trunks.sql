-- cdr: source_trunk and destination_trunk replace trunk.
--
--   source_trunk       provision account of the carrier the call came in on
--                      (from-trunk / from-whatsapp: ${CHANNEL(endpoint)})
--   destination_trunk  provision account of the carrier the call went out on
--                      (outgoing: the trunk it dials)
--
-- An agent's transfer to an outside number keeps both on its out leg: it came
-- in on one trunk and went out on another. avr-rate takes the carrier cost of
-- an in leg from source_trunk, of an out leg from destination_trunk.
-- Existing values of trunk move to source_trunk (in) or destination_trunk (out).
--
-- cdr, cdr_archives and cdr_swap keep the same columns in the same order.

USE `{{cdr_db}}`;

ALTER TABLE cdr
  ADD COLUMN `source_trunk` VARCHAR(40) NULL DEFAULT NULL AFTER `trunk`,
  ADD COLUMN `destination_trunk` VARCHAR(40) NULL DEFAULT NULL AFTER `source_trunk`;
ALTER TABLE cdr_archives
  ADD COLUMN `source_trunk` VARCHAR(40) NULL DEFAULT NULL AFTER `trunk`,
  ADD COLUMN `destination_trunk` VARCHAR(40) NULL DEFAULT NULL AFTER `source_trunk`;
ALTER TABLE cdr_swap
  ADD COLUMN `source_trunk` VARCHAR(40) NULL DEFAULT NULL AFTER `trunk`,
  ADD COLUMN `destination_trunk` VARCHAR(40) NULL DEFAULT NULL AFTER `source_trunk`;

UPDATE cdr SET source_trunk = trunk WHERE direction = 'in' AND trunk IS NOT NULL;
UPDATE cdr SET destination_trunk = trunk WHERE direction = 'out' AND trunk IS NOT NULL;
UPDATE cdr_archives SET source_trunk = trunk WHERE direction = 'in' AND trunk IS NOT NULL;
UPDATE cdr_archives SET destination_trunk = trunk WHERE direction = 'out' AND trunk IS NOT NULL;

ALTER TABLE cdr DROP COLUMN `trunk`;
ALTER TABLE cdr_archives DROP COLUMN `trunk`;
ALTER TABLE cdr_swap DROP COLUMN `trunk`;

USE `{{billing_db}}`;

CREATE OR REPLACE SQL SECURITY DEFINER VIEW cdr_report AS
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
       c.source_trunk,
       c.destination_trunk,
       c.disposition,
       c.rating_status,
       c.uniqueid,
       c.linkedid
  FROM `{{cdr_db}}`.cdr c
  LEFT JOIN billing_zones z ON z.id = c.billing_zone_id
 WHERE c.direction IS NOT NULL;
