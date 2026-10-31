-- provision: local accounts default to max_contacts = 5 (several devices per
-- account; with remove_existing a sixth replaces the oldest), and existing
-- local accounts still at 1 move to 5.
--
-- Also: an UPDATE of an account no longer deletes its registered contacts.
-- The triggers regenerate the realtime rows on every UPDATE; deleting the
-- contacts too meant that changing a caller ID unregistered the phones until
-- their next refresh. Contacts are now deleted only on DELETE or enabled=0.

USE `{{provision_db}}`;

ALTER TABLE accounts MODIFY max_contacts INT UNSIGNED NULL COMMENT 'local: devices registered at once, default 5';

DELIMITER //

DROP PROCEDURE prepare_account//

CREATE PROCEDURE prepare_account(INOUT p_name VARCHAR(40), IN p_type VARCHAR(10),
                                 INOUT p_username VARCHAR(40), INOUT p_password VARCHAR(80),
                                 INOUT p_host VARCHAR(255), INOUT p_port SMALLINT UNSIGNED,
                                 INOUT p_register TINYINT, INOUT p_match VARCHAR(255),
                                 INOUT p_transports VARCHAR(20), INOUT p_transport VARCHAR(10),
                                 INOUT p_context VARCHAR(40), INOUT p_codecs VARCHAR(100),
                                 INOUT p_from_user VARCHAR(40), INOUT p_from_domain VARCHAR(255),
                                 INOUT p_max_contacts INT UNSIGNED, INOUT p_agent CHAR(36))
BEGIN
  SET p_name = TRIM(p_name);
  IF p_name IS NULL OR NOT REGEXP_LIKE(p_name, '^[A-Za-z0-9][A-Za-z0-9_.+-]*$', 'c') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: name must be letters, digits, _ . + - (starting with a letter or digit)';
  END IF;
  SET p_username = NULLIF(TRIM(p_username), ''), p_password = NULLIF(p_password, ''),
      p_host = NULLIF(TRIM(p_host), ''), p_agent = LOWER(NULLIF(TRIM(p_agent), ''));
  IF p_agent IS NOT NULL AND NOT REGEXP_LIKE(p_agent, '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: agent_uuid is not a UUID';
  END IF;

  IF p_type = 'local' THEN
    SET p_username = COALESCE(p_username, p_name),
        p_password = COALESCE(p_password, random_password(16)),
        p_host = NULL, p_port = NULL, p_register = NULL, p_match = NULL, p_transport = NULL,
        p_context = COALESCE(p_context, 'from-phones'),
        p_codecs = COALESCE(p_codecs, 'alaw,ulaw,g722'),
        p_max_contacts = COALESCE(p_max_contacts, 5);
    IF p_transports IS NULL OR p_transports = '' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: local account needs at least one transport';
    END IF;
  ELSE
    IF p_type = 'whatsapp' THEN
      SET p_host = COALESCE(p_host, 'wa.meta.vc'), p_transport = COALESCE(p_transport, 'tls'),
          p_register = 0, p_match = NULL,
          p_context = COALESCE(p_context, 'from-whatsapp'), p_codecs = COALESCE(p_codecs, 'opus');
      IF p_username IS NULL OR p_password IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: whatsapp account needs username (phone number) and password';
      END IF;
    ELSE
      IF p_host IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: external and trunk accounts need host';
      END IF;
      SET p_transport = COALESCE(p_transport, 'udp'), p_codecs = COALESCE(p_codecs, 'alaw,ulaw');
      IF p_type = 'external' THEN
        SET p_register = 1, p_match = NULL, p_context = COALESCE(p_context, 'internal');
      ELSE
        SET p_register = COALESCE(p_register, 0), p_context = COALESCE(p_context, 'from-trunk');
        SET p_match = IF(p_register = 1, NULL, COALESCE(NULLIF(TRIM(p_match), ''), p_host));
      END IF;
      IF p_register = 1 AND (p_username IS NULL OR p_password IS NULL) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: registering accounts need username and password';
      END IF;
    END IF;
    IF p_transport = 'wss' THEN
      SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: wss is only for local accounts';
    END IF;
    SET p_port = COALESCE(p_port, IF(p_transport = 'tls', 5061, 5060)),
        p_transports = p_transport, p_max_contacts = NULL,
        p_from_user = COALESCE(NULLIF(p_from_user, ''), p_username),
        p_from_domain = COALESCE(NULLIF(p_from_domain, ''), IF(p_type = 'whatsapp', NULL, p_host));
  END IF;
END//

DROP PROCEDURE remove_account//

CREATE PROCEDURE remove_account(IN p_name VARCHAR(40), IN p_username VARCHAR(40), IN p_agent CHAR(36),
                                IN p_drop_contacts TINYINT)
BEGIN
  DELETE FROM `{{asterisk_db}}`.ps_endpoints       WHERE id IN (p_name, CONCAT(p_name, '-webrtc'));
  DELETE FROM `{{asterisk_db}}`.ps_aors            WHERE id IN (p_name, CONCAT(p_name, '-webrtc'));
  DELETE FROM `{{asterisk_db}}`.ps_auths           WHERE id IN (p_name, CONCAT(p_name, '-auth'), CONCAT(p_name, '-webrtc'));
  DELETE FROM `{{asterisk_db}}`.ps_registrations   WHERE id = CONCAT(p_name, '-reg');
  DELETE FROM `{{asterisk_db}}`.ps_endpoint_id_ips WHERE id = CONCAT(p_name, '-identify');
  -- Registered devices survive an UPDATE (the AOR is recreated with the same id).
  IF p_drop_contacts THEN
    DELETE FROM `{{asterisk_db}}`.ps_contacts WHERE endpoint IN (p_name, CONCAT(p_name, '-webrtc'));
  END IF;
  IF p_agent IS NOT NULL THEN
    DELETE FROM `{{asterisk_db}}`.extensions
     WHERE context = 'internal' AND exten = p_username AND app = 'GoSub'
       AND appdata = CONCAT('avr,', p_agent, ',1(avr-core:5001)');
  END IF;
END//

DROP TRIGGER accounts_after_update//

CREATE TRIGGER accounts_after_update AFTER UPDATE ON accounts FOR EACH ROW
BEGIN
  CALL remove_account(OLD.name, OLD.username, OLD.agent_uuid, NEW.enabled = 0);
  CALL apply_account(NEW.name);
  IF OLD.enabled = 1 AND OLD.register = 1 THEN
    INSERT INTO registration_queue (registration_id, account, action) VALUES (CONCAT(OLD.name, '-reg'), OLD.name, 'unregister');
  END IF;
  IF NEW.enabled = 1 AND NEW.register = 1 THEN
    INSERT INTO registration_queue (registration_id, account, action) VALUES (CONCAT(NEW.name, '-reg'), NEW.name, 'register');
  END IF;
END//

DROP TRIGGER accounts_after_delete//

CREATE TRIGGER accounts_after_delete AFTER DELETE ON accounts FOR EACH ROW
BEGIN
  CALL remove_account(OLD.name, OLD.username, OLD.agent_uuid, 1);
  IF OLD.enabled = 1 AND OLD.register = 1 THEN
    INSERT INTO registration_queue (registration_id, account, action) VALUES (CONCAT(OLD.name, '-reg'), OLD.name, 'unregister');
  END IF;
END//

DELIMITER ;

UPDATE accounts SET max_contacts = 5 WHERE type = 'local' AND max_contacts = 1;
