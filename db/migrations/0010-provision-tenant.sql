-- provision: tenant_uuid on accounts and DDIs, so every CDR says whose call it
-- was (see 0009-cdr-billing.sql).
--
--   DDIs      the incoming extension sets CDR(tenant_id) and, for an agent,
--             CDR(agent_id) before the Dial.
--   accounts  the endpoint gets set_var __TENANT_ID / __AGENT_ID; the dialplan
--             (from-phones) copies them to CDR(tenant_id) / CDR(agent_id).
--             The leading __ keeps them on the channels the call creates.

USE `{{provision_db}}`;

ALTER TABLE accounts ADD COLUMN tenant_uuid CHAR(36) NULL COMMENT 'tenant billed for calls from this account' AFTER agent_uuid;
ALTER TABLE ddis ADD COLUMN tenant_uuid CHAR(36) NULL COMMENT 'tenant billed for calls to this number' AFTER agent_uuid;

DELIMITER //

-- Lower-case and validate an optional UUID column.
CREATE PROCEDURE prepare_uuid(INOUT p_uuid CHAR(36), IN p_column VARCHAR(20))
BEGIN
  DECLARE v_message VARCHAR(128);
  SET p_uuid = LOWER(NULLIF(TRIM(p_uuid), ''));
  IF p_uuid IS NOT NULL AND NOT REGEXP_LIKE(p_uuid, '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
    SET v_message = CONCAT('provision: ', p_column, ' is not a UUID');
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = v_message;
  END IF;
END//

-- Channel variables of the account's endpoints (after apply_account).
CREATE PROCEDURE apply_account_tags(IN p_name VARCHAR(40))
BEGIN
  DECLARE v_tenant, v_agent CHAR(36);
  DECLARE v_vars VARCHAR(255);
  SELECT tenant_uuid, agent_uuid INTO v_tenant, v_agent FROM accounts WHERE name = p_name;
  SET v_vars = CONCAT_WS(';', CONCAT('__TENANT_ID=', v_tenant), CONCAT('__AGENT_ID=', v_agent));
  IF v_vars <> '' THEN
    UPDATE `{{asterisk_db}}`.ps_endpoints SET set_var = v_vars WHERE id IN (p_name, CONCAT(p_name, '-webrtc'));
  END IF;
END//

DROP TRIGGER accounts_before_insert//

CREATE TRIGGER accounts_before_insert BEFORE INSERT ON accounts FOR EACH ROW
BEGIN
  CALL prepare_account(NEW.name, NEW.type, NEW.username, NEW.password, NEW.host, NEW.port, NEW.register,
                       NEW.match_ips, NEW.transports, NEW.transport, NEW.context, NEW.codecs,
                       NEW.from_user, NEW.from_domain, NEW.max_contacts, NEW.agent_uuid);
  CALL prepare_uuid(NEW.tenant_uuid, 'tenant_uuid');
  -- Refuse to take over objects created outside provision (pjsip.conf seeds, manual rows).
  IF EXISTS (SELECT 1 FROM `{{asterisk_db}}`.ps_endpoints WHERE id IN (NEW.name, CONCAT(NEW.name, '-webrtc')))
     OR EXISTS (SELECT 1 FROM `{{asterisk_db}}`.ps_registrations WHERE id = CONCAT(NEW.name, '-reg')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: an endpoint or registration with this name already exists in asterisk';
  END IF;
  IF NEW.agent_uuid IS NOT NULL AND EXISTS (SELECT 1 FROM `{{asterisk_db}}`.extensions WHERE context = 'internal' AND exten = NEW.username) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: internal already has an extension with this username';
  END IF;
END//

DROP TRIGGER accounts_before_update//

CREATE TRIGGER accounts_before_update BEFORE UPDATE ON accounts FOR EACH ROW
BEGIN
  IF NEW.name <> OLD.name OR NEW.type <> OLD.type THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: name and type cannot change; delete the account and create it again';
  END IF;
  CALL prepare_account(NEW.name, NEW.type, NEW.username, NEW.password, NEW.host, NEW.port, NEW.register,
                       NEW.match_ips, NEW.transports, NEW.transport, NEW.context, NEW.codecs,
                       NEW.from_user, NEW.from_domain, NEW.max_contacts, NEW.agent_uuid);
  CALL prepare_uuid(NEW.tenant_uuid, 'tenant_uuid');
END//

DROP TRIGGER accounts_after_insert//

CREATE TRIGGER accounts_after_insert AFTER INSERT ON accounts FOR EACH ROW
BEGIN
  CALL apply_account(NEW.name);
  CALL apply_account_tags(NEW.name);
  IF NEW.enabled = 1 AND NEW.register = 1 THEN
    INSERT INTO registration_queue (registration_id, account, action) VALUES (CONCAT(NEW.name, '-reg'), NEW.name, 'register');
  END IF;
END//

DROP TRIGGER accounts_after_update//

CREATE TRIGGER accounts_after_update AFTER UPDATE ON accounts FOR EACH ROW
BEGIN
  CALL remove_account(OLD.name, OLD.username, OLD.agent_uuid, NEW.enabled = 0);
  CALL apply_account(NEW.name);
  CALL apply_account_tags(NEW.name);
  IF OLD.enabled = 1 AND OLD.register = 1 THEN
    INSERT INTO registration_queue (registration_id, account, action) VALUES (CONCAT(OLD.name, '-reg'), OLD.name, 'unregister');
  END IF;
  IF NEW.enabled = 1 AND NEW.register = 1 THEN
    INSERT INTO registration_queue (registration_id, account, action) VALUES (CONCAT(NEW.name, '-reg'), NEW.name, 'register');
  END IF;
END//

-- The incoming extension: CDR variables first, then the Dial.
DROP PROCEDURE apply_ddi//

CREATE PROCEDURE apply_ddi(IN p_ddi VARCHAR(32), IN p_account VARCHAR(40), IN p_agent CHAR(36),
                           IN p_tenant CHAR(36), IN p_timeout INT, IN p_record TINYINT)
BEGIN
  DECLARE v_priority INT DEFAULT 1;
  IF p_tenant IS NOT NULL THEN
    INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
      VALUES ('incoming', p_ddi, v_priority, 'Set', CONCAT('CDR(tenant_id)=', p_tenant));
    SET v_priority = v_priority + 1;
  END IF;
  IF p_account IS NOT NULL THEN
    INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
      VALUES ('incoming', p_ddi, v_priority, 'Dial',
              CONCAT('PJSIP/', p_account, ',', p_timeout, IF(p_record = 1, ',U(start-recording-on-answer^${UUID})', '')));
  ELSE
    INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
      VALUES ('incoming', p_ddi, v_priority, 'Set', CONCAT('CDR(agent_id)=', p_agent));
    INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
      VALUES ('incoming', p_ddi, v_priority + 1, 'Dial', CONCAT('local/', p_agent, '@internal,', p_timeout));
    -- The agent entry point in internal, unless it already exists.
    IF NOT EXISTS (SELECT 1 FROM `{{asterisk_db}}`.extensions WHERE context = 'internal' AND exten = p_agent) THEN
      INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
        VALUES ('internal', p_agent, 1, 'GoSub', CONCAT('avr,', p_agent, ',1(avr-core:5001)'));
    END IF;
  END IF;
END//

DROP TRIGGER ddis_before_insert//

CREATE TRIGGER ddis_before_insert BEFORE INSERT ON ddis FOR EACH ROW
BEGIN
  CALL prepare_ddi(NEW.ddi, NEW.account, NEW.agent_uuid);
  CALL prepare_uuid(NEW.tenant_uuid, 'tenant_uuid');
  IF EXISTS (SELECT 1 FROM `{{asterisk_db}}`.extensions WHERE context = 'incoming' AND exten = NEW.ddi) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: incoming already has an extension for this ddi';
  END IF;
END//

DROP TRIGGER ddis_before_update//

CREATE TRIGGER ddis_before_update BEFORE UPDATE ON ddis FOR EACH ROW
BEGIN
  CALL prepare_ddi(NEW.ddi, NEW.account, NEW.agent_uuid);
  CALL prepare_uuid(NEW.tenant_uuid, 'tenant_uuid');
END//

DROP TRIGGER ddis_after_insert//

CREATE TRIGGER ddis_after_insert AFTER INSERT ON ddis FOR EACH ROW
BEGIN
  CALL apply_ddi(NEW.ddi, NEW.account, NEW.agent_uuid, NEW.tenant_uuid, NEW.ring_timeout, NEW.record);
END//

DROP TRIGGER ddis_after_update//

CREATE TRIGGER ddis_after_update AFTER UPDATE ON ddis FOR EACH ROW
BEGIN
  DELETE FROM `{{asterisk_db}}`.extensions WHERE context = 'incoming' AND exten = OLD.ddi;
  CALL apply_ddi(NEW.ddi, NEW.account, NEW.agent_uuid, NEW.tenant_uuid, NEW.ring_timeout, NEW.record);
END//

DELIMITER ;
