-- provision: DDIs to a local account ring every endpoint it has.
--
-- A local account gets <name> for udp/tcp/tls and <name>-webrtc for wss
-- (see apply_account in 0004-provision.sql), so a DDI dials
-- PJSIP/<name>&PJSIP/<name>-webrtc, or only the one that exists: a
-- wss-only account has no <name> endpoint. Other account types keep
-- PJSIP/<name>.
--
-- When an account's transports change, its DDIs are rewritten by an extra
-- trigger, so the account triggers of 0010-provision-tenant.sql stay as they are.

USE `{{provision_db}}`;

DELIMITER //

-- The incoming extension: CDR variables first, then the Dial.
DROP PROCEDURE apply_ddi//

CREATE PROCEDURE apply_ddi(IN p_ddi VARCHAR(32), IN p_account VARCHAR(40), IN p_agent CHAR(36),
                           IN p_tenant CHAR(36), IN p_timeout INT, IN p_record TINYINT)
BEGIN
  DECLARE v_priority INT DEFAULT 1;
  DECLARE v_type VARCHAR(10);
  DECLARE v_transports VARCHAR(20);
  DECLARE v_dial VARCHAR(100);
  IF p_tenant IS NOT NULL THEN
    INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
      VALUES ('incoming', p_ddi, v_priority, 'Set', CONCAT('CDR(tenant_id)=', p_tenant));
    SET v_priority = v_priority + 1;
  END IF;
  IF p_account IS NOT NULL THEN
    SELECT type, transports INTO v_type, v_transports FROM accounts WHERE name = p_account;
    SET v_dial = CONCAT('PJSIP/', p_account);
    IF v_type = 'local' THEN
      SET v_dial = CONCAT_WS('&',
        IF(FIND_IN_SET('udp', v_transports) OR FIND_IN_SET('tcp', v_transports) OR FIND_IN_SET('tls', v_transports),
           CONCAT('PJSIP/', p_account), NULL),
        IF(FIND_IN_SET('wss', v_transports), CONCAT('PJSIP/', p_account, '-webrtc'), NULL));
    END IF;
    INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
      VALUES ('incoming', p_ddi, v_priority, 'Dial',
              CONCAT(v_dial, ',', p_timeout, IF(p_record = 1, ',U(start-recording-on-answer^${UUID})', '')));
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

-- Rewrite the incoming extensions of the DDIs of an account (NULL: of every account).
CREATE PROCEDURE refresh_account_ddis(IN p_account VARCHAR(40))
BEGIN
  DECLARE v_done TINYINT DEFAULT 0;
  DECLARE v_ddi VARCHAR(32);
  DECLARE v_account VARCHAR(40);
  DECLARE v_tenant CHAR(36);
  DECLARE v_timeout INT;
  DECLARE v_record TINYINT;
  DECLARE c CURSOR FOR
    SELECT ddi, account, tenant_uuid, ring_timeout, record FROM ddis
     WHERE account IS NOT NULL AND (p_account IS NULL OR account = p_account);
  DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_done = 1;
  OPEN c;
  ddis: LOOP
    FETCH c INTO v_ddi, v_account, v_tenant, v_timeout, v_record;
    IF v_done THEN
      LEAVE ddis;
    END IF;
    DELETE FROM `{{asterisk_db}}`.extensions WHERE context = 'incoming' AND exten = v_ddi;
    CALL apply_ddi(v_ddi, v_account, NULL, v_tenant, v_timeout, v_record);
  END LOOP;
  CLOSE c;
END//

CREATE TRIGGER accounts_after_update_ddis AFTER UPDATE ON accounts FOR EACH ROW FOLLOWS accounts_after_update
BEGIN
  IF NOT (NEW.transports <=> OLD.transports) THEN
    CALL refresh_account_ddis(NEW.name);
  END IF;
END//

DELIMITER ;

-- DDIs created before this migration.
CALL refresh_account_ddis(NULL);
