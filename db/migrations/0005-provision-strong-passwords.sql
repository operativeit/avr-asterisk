-- Generated passwords for local accounts: 16 characters from a
-- cryptographically secure source (RANDOM_BYTES), with at least one lowercase
-- letter, uppercase letter, digit and symbol. Symbols are limited to
-- ! % * + - . ^ _ ~ so the password survives phone configs, .env files, URLs
-- and shells without quoting. Replaces the 24-hex-digit password of 0004.

USE `{{provision_db}}`;

DELIMITER //

-- Uniform random integer in [0, n) from RANDOM_BYTES (32 bits; bias < 1e-7).
CREATE FUNCTION random_index(n INT) RETURNS INT NOT DETERMINISTIC NO SQL
BEGIN
  RETURN CONV(HEX(RANDOM_BYTES(4)), 16, 10) MOD n;
END//

CREATE FUNCTION random_password(p_length INT) RETURNS VARCHAR(64) NOT DETERMINISTIC NO SQL
BEGIN
  DECLARE lower_set  VARCHAR(26) DEFAULT 'abcdefghijklmnopqrstuvwxyz';
  DECLARE upper_set  VARCHAR(26) DEFAULT 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  DECLARE digit_set  VARCHAR(10) DEFAULT '0123456789';
  DECLARE symbol_set VARCHAR(9)  DEFAULT '!%*+-.^_~';
  DECLARE all_set    VARCHAR(80);
  DECLARE pwd        VARCHAR(64);
  DECLARE i, j INT;
  DECLARE c CHAR(1);

  IF p_length < 4 OR p_length > 64 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'provision: password length must be 4-64';
  END IF;
  SET all_set = CONCAT(lower_set, upper_set, digit_set, symbol_set);

  -- One character of each class, the rest from all of them...
  SET pwd = CONCAT(SUBSTRING(lower_set,  random_index(26) + 1, 1),
                   SUBSTRING(upper_set,  random_index(26) + 1, 1),
                   SUBSTRING(digit_set,  random_index(10) + 1, 1),
                   SUBSTRING(symbol_set, random_index(9) + 1, 1));
  SET i = 4;
  WHILE i < p_length DO
    SET pwd = CONCAT(pwd, SUBSTRING(all_set, random_index(CHAR_LENGTH(all_set)) + 1, 1));
    SET i = i + 1;
  END WHILE;

  -- ...then shuffled (Fisher-Yates), so the classes are not in fixed positions.
  SET i = p_length;
  WHILE i > 1 DO
    SET j = random_index(i) + 1;
    SET c = SUBSTRING(pwd, i, 1);
    SET pwd = INSERT(INSERT(pwd, i, 1, SUBSTRING(pwd, j, 1)), j, 1, c);
    SET i = i - 1;
  END WHILE;
  RETURN pwd;
END//

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

DELIMITER ;
