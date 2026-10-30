-- provision: create SIP accounts, trunks and DDIs with a single INSERT.
--
-- Triggers on provision.accounts and provision.ddis write the matching rows
-- in `{{asterisk_db}}`.ps_* and `{{asterisk_db}}`.extensions (Asterisk realtime), so endpoints,
-- auths, AORs, identifies and dialplan work without any reload.
--
-- Outbound registrations (type external, and trunk with register=1) are the
-- exception: Asterisk only starts a new realtime registration once it loads
-- it ("pjsip show registration <id>"), and only stops a deleted one on
-- "pjsip send unregister <id>". The triggers queue those actions in
-- provision.registration_queue for an external worker (elokia-asterisk-api).
--
-- Applied by avr-db-migrate (entrypoint) as root; {{...}} are replaced with
-- the configured database names and application user.

CREATE DATABASE IF NOT EXISTS `{{provision_db}}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE `{{provision_db}}`;

CREATE TABLE accounts (
  name          VARCHAR(40)  NOT NULL,
  type          ENUM('local','external','trunk','whatsapp') NOT NULL,
  enabled       TINYINT(1)   NOT NULL DEFAULT 1,
  username      VARCHAR(40)  NULL COMMENT 'local: defaults to name; external/whatsapp: required; trunk: required with register=1',
  password      VARCHAR(80)  NULL COMMENT 'local: generated when empty',
  host          VARCHAR(255) NULL COMMENT 'remote PBX / provider; whatsapp: defaults to wa.meta.vc',
  port          SMALLINT UNSIGNED NULL COMMENT 'remote port, any value; defaults to 5060, or 5061 with tls',
  register      TINYINT(1)   NULL COMMENT 'trunk: 1 = register on the provider, 0 = authenticate by IP',
  match_ips     VARCHAR(255) NULL COMMENT 'trunk with register=0: provider IPs/CIDRs, comma separated; defaults to host',
  transports    SET('udp','tcp','tls','wss') NOT NULL DEFAULT 'udp,tcp,tls' COMMENT 'local: allowed transports; wss adds a <name>-webrtc endpoint',
  transport     ENUM('udp','tcp','tls','wss') NULL COMMENT 'transport of the remote side (external/trunk/whatsapp): udp (default), tcp or tls; whatsapp default tls',
  context       VARCHAR(40)  NULL COMMENT 'default: local from-phones, external internal, trunk from-trunk, whatsapp from-whatsapp',
  codecs        VARCHAR(100) NULL,
  callerid      VARCHAR(80)  NULL,
  from_user     VARCHAR(40)  NULL,
  from_domain   VARCHAR(255) NULL,
  max_contacts  INT UNSIGNED NULL COMMENT 'local: devices registered at once, default 1',
  agent_uuid    CHAR(36)     NULL COMMENT 'AVR agent answering calls to internal/<username>',
  created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (name)
) ENGINE=InnoDB;

CREATE TABLE ddis (
  ddi           VARCHAR(32)  NOT NULL,
  account       VARCHAR(40)  NULL COMMENT 'ring this account (Dial PJSIP/<account>)',
  agent_uuid    CHAR(36)     NULL COMMENT 'or send the call to this AVR agent',
  ring_timeout  INT UNSIGNED NOT NULL DEFAULT 30,
  record        TINYINT(1)   NOT NULL DEFAULT 1 COMMENT 'account calls: record on answer',
  created_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at    TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (ddi),
  KEY account (account),
  CONSTRAINT ddis_account FOREIGN KEY (account) REFERENCES accounts (name) ON UPDATE RESTRICT ON DELETE RESTRICT
) ENGINE=InnoDB;

CREATE TABLE registration_queue (
  id              BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  registration_id VARCHAR(64) NOT NULL COMMENT '`{{asterisk_db}}`.ps_registrations id: <account>-reg',
  account         VARCHAR(40) NOT NULL,
  action          ENUM('register','unregister') NOT NULL COMMENT 'register: pjsip show registration <id>; unregister: pjsip send unregister <id>',
  created_at      TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
  processed_at    TIMESTAMP   NULL,
  PRIMARY KEY (id),
  KEY pending (processed_at, id)
) ENGINE=InnoDB;

DELIMITER //

-- Remove everything provision created for an account.
CREATE PROCEDURE remove_account(IN p_name VARCHAR(40), IN p_username VARCHAR(40), IN p_agent CHAR(36))
BEGIN
  DELETE FROM `{{asterisk_db}}`.ps_endpoints       WHERE id IN (p_name, CONCAT(p_name, '-webrtc'));
  DELETE FROM `{{asterisk_db}}`.ps_aors            WHERE id IN (p_name, CONCAT(p_name, '-webrtc'));
  DELETE FROM `{{asterisk_db}}`.ps_auths           WHERE id IN (p_name, CONCAT(p_name, '-auth'), CONCAT(p_name, '-webrtc'));
  DELETE FROM `{{asterisk_db}}`.ps_registrations   WHERE id = CONCAT(p_name, '-reg');
  DELETE FROM `{{asterisk_db}}`.ps_endpoint_id_ips WHERE id = CONCAT(p_name, '-identify');
  DELETE FROM `{{asterisk_db}}`.ps_contacts        WHERE endpoint IN (p_name, CONCAT(p_name, '-webrtc'));
  IF p_agent IS NOT NULL THEN
    DELETE FROM `{{asterisk_db}}`.extensions
     WHERE context = 'internal' AND exten = p_username AND app = 'GoSub'
       AND appdata = CONCAT('avr,', p_agent, ',1(avr-core:5001)');
  END IF;
END//

-- Write the asterisk realtime rows for an account (values already defaulted).
CREATE PROCEDURE apply_account(IN p_name VARCHAR(40))
BEGIN
  DECLARE v_type, v_transport VARCHAR(10);
  DECLARE v_enabled, v_register TINYINT;
  DECLARE v_username, v_from_user VARCHAR(40);
  DECLARE v_password VARCHAR(80);
  DECLARE v_host, v_from_domain VARCHAR(255);
  DECLARE v_port INT;
  DECLARE v_match VARCHAR(255);
  DECLARE v_transports VARCHAR(20);
  DECLARE v_context VARCHAR(40);
  DECLARE v_codecs VARCHAR(100);
  DECLARE v_callerid VARCHAR(80);
  DECLARE v_max_contacts INT;
  DECLARE v_agent CHAR(36);
  DECLARE v_uri VARCHAR(300);

  SELECT type, enabled, username, password, host, port, register, match_ips, transports, transport,
         context, codecs, callerid, from_user, from_domain, max_contacts, agent_uuid
    INTO v_type, v_enabled, v_username, v_password, v_host, v_port, v_register, v_match, v_transports, v_transport,
         v_context, v_codecs, v_callerid, v_from_user, v_from_domain, v_max_contacts, v_agent
    FROM accounts WHERE name = p_name;

  IF v_enabled = 1 THEN
    IF v_type = 'local' THEN
      -- Phones register here over any allowed transport; Asterisk calls them back
      -- over the transport of their contact, so the endpoint has no fixed transport.
      IF FIND_IN_SET('udp', v_transports) OR FIND_IN_SET('tcp', v_transports) OR FIND_IN_SET('tls', v_transports) THEN
        INSERT INTO `{{asterisk_db}}`.ps_auths (id, auth_type, username, md5_cred, realm)
          VALUES (p_name, 'md5', v_username, MD5(CONCAT(v_username, ':asterisk:', v_password)), 'asterisk');
        INSERT INTO `{{asterisk_db}}`.ps_aors (id, max_contacts, remove_existing, qualify_frequency)
          VALUES (p_name, v_max_contacts, 'yes', 30);
        INSERT INTO `{{asterisk_db}}`.ps_endpoints (id, aors, auth, context, disallow, allow, callerid, direct_media,
                                           rewrite_contact, rtp_symmetric, force_rport, identify_by)
          VALUES (p_name, p_name, p_name, v_context, 'all', v_codecs, v_callerid, 'no',
                  'yes', 'yes', 'yes', 'username,auth_username');
      END IF;
      -- WebRTC needs DTLS/ICE settings that break plain SIP phones: separate endpoint.
      IF FIND_IN_SET('wss', v_transports) THEN
        INSERT INTO `{{asterisk_db}}`.ps_auths (id, auth_type, username, md5_cred, realm)
          VALUES (CONCAT(p_name, '-webrtc'), 'md5', CONCAT(v_username, '-webrtc'),
                  MD5(CONCAT(v_username, '-webrtc:asterisk:', v_password)), 'asterisk');
        INSERT INTO `{{asterisk_db}}`.ps_aors (id, max_contacts, remove_existing, qualify_frequency)
          VALUES (CONCAT(p_name, '-webrtc'), v_max_contacts, 'yes', 30);
        INSERT INTO `{{asterisk_db}}`.ps_endpoints (id, transport, aors, auth, context, disallow, allow, callerid, webrtc,
                                           message_context, subscribe_context, allow_subscribe, device_state_busy_at,
                                           direct_media, rewrite_contact, rtp_symmetric, force_rport,
                                           media_use_received_transport, identify_by)
          VALUES (CONCAT(p_name, '-webrtc'), 'transport-wss', CONCAT(p_name, '-webrtc'), CONCAT(p_name, '-webrtc'),
                  v_context, 'all', 'opus,alaw,ulaw', v_callerid, 'yes',
                  'avr-message-context', 'avr-subscribe-context', 'yes', 1,
                  'no', 'yes', 'yes', 'yes', 'yes', 'username,auth_username');
      END IF;

    ELSE
      -- Any port. The transport is set by the transport-<x> field, not in the URI:
      -- Asterisk rejects a registration server_uri carrying ;transport=.
      SET v_uri = CONCAT('sip:', v_host, ':', v_port);
      IF v_username IS NOT NULL THEN
        INSERT INTO `{{asterisk_db}}`.ps_auths (id, auth_type, username, password)
          VALUES (CONCAT(p_name, '-auth'), 'userpass', v_username, v_password);
      END IF;
      INSERT INTO `{{asterisk_db}}`.ps_aors (id, contact, max_contacts, qualify_frequency)
        VALUES (p_name, v_uri, 1, IF(v_type = 'whatsapp', 0, 60));

      IF v_type = 'whatsapp' THEN
        INSERT INTO `{{asterisk_db}}`.ps_endpoints (id, transport, aors, outbound_auth, context, disallow, allow, callerid,
                                           from_user, from_domain, direct_media, webrtc, ice_support, rtcp_mux,
                                           media_encryption, dtls_auto_generate_cert, dtls_verify, dtls_setup,
                                           rewrite_contact, rtp_symmetric, force_rport)
          VALUES (p_name, CONCAT('transport-', v_transport), p_name, CONCAT(p_name, '-auth'), v_context, 'all', v_codecs,
                  v_callerid, v_from_user, v_from_domain, 'no', 'yes', 'yes', 'yes',
                  'dtls', 'yes', 'fingerprint', 'actpass', 'yes', 'yes', 'yes');
        INSERT INTO `{{asterisk_db}}`.ps_endpoint_id_ips (id, endpoint, match_header)
          VALUES (CONCAT(p_name, '-identify'), p_name, 'X-FB-External-Domain: wa.meta.vc');
      ELSE
        INSERT INTO `{{asterisk_db}}`.ps_endpoints (id, transport, aors, outbound_auth, context, disallow, allow, callerid,
                                           from_user, from_domain, direct_media, rewrite_contact, rtp_symmetric, force_rport)
          VALUES (p_name, CONCAT('transport-', v_transport), p_name,
                  IF(v_username IS NULL, NULL, CONCAT(p_name, '-auth')), v_context, 'all', v_codecs, v_callerid,
                  v_from_user, v_from_domain, 'no', 'yes', 'yes', 'yes');
        IF v_register = 1 THEN
          -- line=yes ties incoming calls to this registration, so several
          -- extensions of the same remote PBX (same IP) stay apart.
          INSERT INTO `{{asterisk_db}}`.ps_registrations (id, server_uri, client_uri, contact_user, outbound_auth, transport,
                                                 retry_interval, forbidden_retry_interval, max_retries, expiration,
                                                 line, endpoint)
            VALUES (CONCAT(p_name, '-reg'), v_uri, CONCAT('sip:', v_username, '@', v_host), v_username,
                    CONCAT(p_name, '-auth'), CONCAT('transport-', v_transport), 60, 300, 10000, 300, 'yes', p_name);
        ELSE
          INSERT INTO `{{asterisk_db}}`.ps_endpoint_id_ips (id, endpoint, `match`)
            VALUES (CONCAT(p_name, '-identify'), p_name, v_match);
        END IF;
      END IF;
    END IF;

    IF v_agent IS NOT NULL THEN
      INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
        VALUES ('internal', v_username, 1, 'GoSub', CONCAT('avr,', v_agent, ',1(avr-core:5001)'));
    END IF;
  END IF;
END//

-- Defaults and validation shared by the BEFORE INSERT / BEFORE UPDATE triggers.
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
        p_password = COALESCE(p_password, LEFT(SHA2(CONCAT(RAND(), UUID(), NOW(6)), 256), 24)),
        p_host = NULL, p_port = NULL, p_register = NULL, p_match = NULL, p_transport = NULL,
        p_context = COALESCE(p_context, 'from-phones'),
        p_codecs = COALESCE(p_codecs, 'alaw,ulaw,g722'),
        p_max_contacts = COALESCE(p_max_contacts, 1);
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

CREATE TRIGGER accounts_before_insert BEFORE INSERT ON accounts FOR EACH ROW
BEGIN
  CALL prepare_account(NEW.name, NEW.type, NEW.username, NEW.password, NEW.host, NEW.port, NEW.register,
                       NEW.match_ips, NEW.transports, NEW.transport, NEW.context, NEW.codecs,
                       NEW.from_user, NEW.from_domain, NEW.max_contacts, NEW.agent_uuid);
  -- Refuse to take over objects created outside provision (pjsip.conf seeds, manual rows).
  IF EXISTS (SELECT 1 FROM `{{asterisk_db}}`.ps_endpoints WHERE id IN (NEW.name, CONCAT(NEW.name, '-webrtc')))
     OR EXISTS (SELECT 1 FROM `{{asterisk_db}}`.ps_registrations WHERE id = CONCAT(NEW.name, '-reg')) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: an endpoint or registration with this name already exists in asterisk';
  END IF;
  IF NEW.agent_uuid IS NOT NULL AND EXISTS (SELECT 1 FROM `{{asterisk_db}}`.extensions WHERE context = 'internal' AND exten = NEW.username) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: internal already has an extension with this username';
  END IF;
END//

CREATE TRIGGER accounts_before_update BEFORE UPDATE ON accounts FOR EACH ROW
BEGIN
  IF NEW.name <> OLD.name OR NEW.type <> OLD.type THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: name and type cannot change; delete the account and create it again';
  END IF;
  CALL prepare_account(NEW.name, NEW.type, NEW.username, NEW.password, NEW.host, NEW.port, NEW.register,
                       NEW.match_ips, NEW.transports, NEW.transport, NEW.context, NEW.codecs,
                       NEW.from_user, NEW.from_domain, NEW.max_contacts, NEW.agent_uuid);
END//

CREATE TRIGGER accounts_after_insert AFTER INSERT ON accounts FOR EACH ROW
BEGIN
  CALL apply_account(NEW.name);
  IF NEW.enabled = 1 AND NEW.register = 1 THEN
    INSERT INTO registration_queue (registration_id, account, action) VALUES (CONCAT(NEW.name, '-reg'), NEW.name, 'register');
  END IF;
END//

CREATE TRIGGER accounts_after_update AFTER UPDATE ON accounts FOR EACH ROW
BEGIN
  CALL remove_account(OLD.name, OLD.username, OLD.agent_uuid);
  CALL apply_account(NEW.name);
  IF OLD.enabled = 1 AND OLD.register = 1 THEN
    INSERT INTO registration_queue (registration_id, account, action) VALUES (CONCAT(OLD.name, '-reg'), OLD.name, 'unregister');
  END IF;
  IF NEW.enabled = 1 AND NEW.register = 1 THEN
    INSERT INTO registration_queue (registration_id, account, action) VALUES (CONCAT(NEW.name, '-reg'), NEW.name, 'register');
  END IF;
END//

CREATE TRIGGER accounts_after_delete AFTER DELETE ON accounts FOR EACH ROW
BEGIN
  CALL remove_account(OLD.name, OLD.username, OLD.agent_uuid);
  IF OLD.enabled = 1 AND OLD.register = 1 THEN
    INSERT INTO registration_queue (registration_id, account, action) VALUES (CONCAT(OLD.name, '-reg'), OLD.name, 'unregister');
  END IF;
END//

-- DDIs: one row per number in `{{asterisk_db}}`.extensions, context incoming (reached
-- from from-trunk and from-whatsapp).
CREATE PROCEDURE prepare_ddi(INOUT p_ddi VARCHAR(32), INOUT p_account VARCHAR(40), INOUT p_agent CHAR(36))
BEGIN
  SET p_ddi = TRIM(p_ddi), p_account = NULLIF(TRIM(p_account), ''), p_agent = LOWER(NULLIF(TRIM(p_agent), ''));
  IF p_ddi IS NULL OR NOT REGEXP_LIKE(p_ddi, '^[+]?[0-9]{3,20}$') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: ddi must be 3-20 digits, optionally starting with +';
  END IF;
  IF (p_account IS NULL) = (p_agent IS NULL) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: a ddi needs exactly one of account or agent_uuid';
  END IF;
  IF p_agent IS NOT NULL AND NOT REGEXP_LIKE(p_agent, '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: agent_uuid is not a UUID';
  END IF;
END//

CREATE PROCEDURE apply_ddi(IN p_ddi VARCHAR(32), IN p_account VARCHAR(40), IN p_agent CHAR(36),
                           IN p_timeout INT, IN p_record TINYINT)
BEGIN
  IF p_account IS NOT NULL THEN
    INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
      VALUES ('incoming', p_ddi, 1, 'Dial',
              CONCAT('PJSIP/', p_account, ',', p_timeout, IF(p_record = 1, ',U(start-recording-on-answer^${UUID})', '')));
  ELSE
    INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
      VALUES ('incoming', p_ddi, 1, 'Dial', CONCAT('local/', p_agent, '@internal,', p_timeout));
    -- The agent entry point in internal, unless it already exists.
    IF NOT EXISTS (SELECT 1 FROM `{{asterisk_db}}`.extensions WHERE context = 'internal' AND exten = p_agent) THEN
      INSERT INTO `{{asterisk_db}}`.extensions (context, exten, priority, app, appdata)
        VALUES ('internal', p_agent, 1, 'GoSub', CONCAT('avr,', p_agent, ',1(avr-core:5001)'));
    END IF;
  END IF;
END//

CREATE TRIGGER ddis_before_insert BEFORE INSERT ON ddis FOR EACH ROW
BEGIN
  CALL prepare_ddi(NEW.ddi, NEW.account, NEW.agent_uuid);
  IF EXISTS (SELECT 1 FROM `{{asterisk_db}}`.extensions WHERE context = 'incoming' AND exten = NEW.ddi) THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: incoming already has an extension for this ddi';
  END IF;
END//

CREATE TRIGGER ddis_before_update BEFORE UPDATE ON ddis FOR EACH ROW
BEGIN
  CALL prepare_ddi(NEW.ddi, NEW.account, NEW.agent_uuid);
END//

CREATE TRIGGER ddis_after_insert AFTER INSERT ON ddis FOR EACH ROW
BEGIN
  CALL apply_ddi(NEW.ddi, NEW.account, NEW.agent_uuid, NEW.ring_timeout, NEW.record);
END//

CREATE TRIGGER ddis_after_update AFTER UPDATE ON ddis FOR EACH ROW
BEGIN
  DELETE FROM `{{asterisk_db}}`.extensions WHERE context = 'incoming' AND exten = OLD.ddi;
  CALL apply_ddi(NEW.ddi, NEW.account, NEW.agent_uuid, NEW.ring_timeout, NEW.record);
END//

CREATE TRIGGER ddis_after_delete AFTER DELETE ON ddis FOR EACH ROW
BEGIN
  DELETE FROM `{{asterisk_db}}`.extensions WHERE context = 'incoming' AND exten = OLD.ddi;
END//

DELIMITER ;

-- The application user (MYSQL_USER) manages provision rows; the triggers
-- write the asterisk tables with their definer's (root) privileges.
GRANT SELECT, INSERT, UPDATE, DELETE ON `{{provision_db}}`.* TO '{{app_user}}'@'%';
