-- provision: local accounts can be called from the other phones.
--
-- A local account without agent_uuid gets internal/<username> →
-- Dial(<its endpoints>,30): PJSIP/<name>&PJSIP/<name>-webrtc, or only the one
-- its transports create, so the phone and the browser ring at once (the same
-- rule as DDIs, see 0012-provision-ddi-webrtc.sql). An account with
-- agent_uuid keeps its GoSub to the agent (apply_account).
--
-- Extra triggers keep the row up to date, so the account triggers of
-- 0010-provision-tenant.sql stay as they are.

USE `{{provision_db}}`;

DELIMITER //

-- Dial target of a local account: the endpoints its transports create.
CREATE FUNCTION account_dial(p_name VARCHAR(40)) RETURNS VARCHAR(100) READS SQL DATA
BEGIN
  DECLARE v_transports VARCHAR(20);
  SELECT transports INTO v_transports FROM accounts WHERE name = p_name;
  RETURN CONCAT_WS('&',
    IF(FIND_IN_SET('udp', v_transports) OR FIND_IN_SET('tcp', v_transports) OR FIND_IN_SET('tls', v_transports),
       CONCAT('PJSIP/', p_name), NULL),
    IF(FIND_IN_SET('wss', v_transports), CONCAT('PJSIP/', p_name, '-webrtc'), NULL));
END//

-- Remove the internal row apply_account_internal wrote for an account.
CREATE PROCEDURE remove_account_internal(IN p_name VARCHAR(40), IN p_username VARCHAR(40))
BEGIN
  DELETE FROM `{{asterisk_db}}`.extensions
   WHERE context = 'internal' AND exten = p_username AND app = 'Dial'
     AND appdata IN (CONCAT('PJSIP/', p_name, ',30'), CONCAT('PJSIP/', p_name, '-webrtc,30'),
                     CONCAT('PJSIP/', p_name, '&PJSIP/', p_name, '-webrtc,30'));
END//

-- internal/<username> for an enabled local account without agent, unless taken.
CREATE PROCEDURE apply_account_internal(IN p_name VARCHAR(40))
BEGIN
  INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
    SELECT 'internal', a.username, 1, 'Dial', CONCAT(account_dial(a.name), ',30')
      FROM accounts a
     WHERE a.name = p_name AND a.type = 'local' AND a.enabled = 1 AND a.agent_uuid IS NULL
       AND NOT EXISTS (SELECT 1 FROM `{{asterisk_db}}`.extensions e WHERE e.context = 'internal' AND e.exten = a.username);
END//

CREATE TRIGGER accounts_before_insert_internal BEFORE INSERT ON accounts FOR EACH ROW FOLLOWS accounts_before_insert
BEGIN
  IF NEW.type = 'local' AND NEW.agent_uuid IS NULL
     AND EXISTS (SELECT 1 FROM `{{asterisk_db}}`.extensions WHERE context = 'internal' AND exten = NEW.username) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: internal already has an extension with this username';
  END IF;
END//

CREATE TRIGGER accounts_after_insert_internal AFTER INSERT ON accounts FOR EACH ROW FOLLOWS accounts_after_insert
BEGIN
  CALL apply_account_internal(NEW.name);
END//

-- Removed before accounts_after_update, which may write the agent GoSub in its place.
CREATE TRIGGER accounts_before_update_internal BEFORE UPDATE ON accounts FOR EACH ROW FOLLOWS accounts_before_update
BEGIN
  CALL remove_account_internal(OLD.name, OLD.username);
END//

CREATE TRIGGER accounts_after_update_internal AFTER UPDATE ON accounts FOR EACH ROW FOLLOWS accounts_after_update_ddis
BEGIN
  CALL apply_account_internal(NEW.name);
END//

CREATE TRIGGER accounts_after_delete_internal AFTER DELETE ON accounts FOR EACH ROW FOLLOWS accounts_after_delete
BEGIN
  CALL remove_account_internal(OLD.name, OLD.username);
END//

DELIMITER ;

-- Accounts created before this migration.
INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
  SELECT 'internal', a.username, 1, 'Dial', CONCAT(account_dial(a.name), ',30')
    FROM accounts a
   WHERE a.type = 'local' AND a.enabled = 1 AND a.agent_uuid IS NULL
     AND NOT EXISTS (SELECT 1 FROM `{{asterisk_db}}`.extensions e WHERE e.context = 'internal' AND e.exten = a.username);
