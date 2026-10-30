-- Recordings partitioned by day, archived by month, purged after a retention
-- period. Same design as 0006 (CDRs), with two differences:
--   * recordings hold the audio (recording_blob), so they are archived every
--     month: recordings keeps the current month and the previous
--     hot_months; older months move to recordings_archives;
--   * created_at is a TIMESTAMP, so partitions are RANGE on
--     UNIX_TIMESTAMP(created_at). Day boundaries follow the MySQL server time
--     zone when the partitions are created: do not change it afterwards.
--
-- Partitioning requires every unique key to contain created_at, so the
-- unique key is (uuid, created_at). Writers must give a recording a fixed
-- created_at (save_recording.php uses the call start) so a retry for the same
-- call hits that key and ON DUPLICATE KEY UPDATE still applies.
--
-- pmin stays empty: MySQL adds the first partition to range queries.
--
-- Events (event scheduler on):
--   recordings_create_partitions  15 December 03:00, yearly: next year.
--   recordings_archive            daily 03:00: days before the first day of
--                                 (current month - hot_months) move to
--                                 recordings_archives (EXCHANGE PARTITION).
--   recordings_purge              daily 03:30: drops archive days before the
--                                 first day of (current month - retention_months).

USE `{{recordings_db}}`;

CREATE TABLE recordings_settings (
  id               TINYINT UNSIGNED NOT NULL DEFAULT 1,
  hot_months       INT UNSIGNED NOT NULL DEFAULT 1  COMMENT 'past months kept in recordings besides the current one',
  retention_months INT UNSIGNED NOT NULL DEFAULT 12 COMMENT 'months (before the current one) kept in recordings_archives',
  PRIMARY KEY (id)
) ENGINE=InnoDB;
INSERT INTO recordings_settings (id) VALUES (1);

-- Same columns as 0003; keys with created_at for partition pruning.
CREATE TABLE recordings_partitioned (
  `id` bigint(20) unsigned NOT NULL AUTO_INCREMENT,
  `uuid` char(36) NOT NULL,
  `caller` varchar(80) DEFAULT NULL,
  `destination` varchar(80) DEFAULT NULL,
  `duration` int unsigned DEFAULT NULL,
  `billsec` int unsigned DEFAULT NULL,
  `recording_path` varchar(512) NOT NULL,
  `recording_blob` longblob NOT NULL,
  `recording_size` bigint(20) unsigned NOT NULL,
  `audio_sha256` char(64) DEFAULT NULL,
  `audio_hmac_sha256` char(64) DEFAULT NULL,
  `transcription_status` enum('pending','processing','done','error','skipped') NOT NULL DEFAULT 'pending',
  `transcription_text` longtext DEFAULT NULL,
  `transcription_sha256` char(64) DEFAULT NULL,
  `transcription_hmac_sha256` char(64) DEFAULT NULL,
  `transcription_model` varchar(80) DEFAULT NULL,
  `transcription_language` varchar(16) DEFAULT NULL,
  `transcribed_at` timestamp NULL DEFAULT NULL,
  `summary_status` enum('pending','processing','done','error','skipped') NOT NULL DEFAULT 'pending',
  `summary_text` longtext DEFAULT NULL,
  `summary_sha256` char(64) DEFAULT NULL,
  `summary_hmac_sha256` char(64) DEFAULT NULL,
  `analysis_status` enum('pending','processing','done','error','skipped') NOT NULL DEFAULT 'pending',
  `analysis_json` json DEFAULT NULL,
  `analysis_sha256` char(64) DEFAULT NULL,
  `analysis_hmac_sha256` char(64) DEFAULT NULL,
  `processing_error` text DEFAULT NULL,
  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  PRIMARY KEY (`created_at`, `id`),
  KEY `id` (`id`),
  UNIQUE KEY `uuid_created_at` (`uuid`, `created_at`),
  KEY `caller_created_at` (`caller`, `created_at`),
  KEY `destination_created_at` (`destination`, `created_at`),
  KEY `audio_sha256` (`audio_sha256`),
  KEY `transcription_status_created_at` (`transcription_status`, `created_at`),
  KEY `summary_status_created_at` (`summary_status`, `created_at`),
  KEY `analysis_status_created_at` (`analysis_status`, `created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
PARTITION BY RANGE (UNIX_TIMESTAMP(`created_at`)) (PARTITION pmin VALUES LESS THAN (1),
                                                   PARTITION pmax VALUES LESS THAN MAXVALUE);

CREATE TABLE recordings_archives LIKE recordings_partitioned;

-- Staging table for EXCHANGE PARTITION: same structure, not partitioned.
CREATE TABLE recordings_swap LIKE recordings_partitioned;
ALTER TABLE recordings_swap REMOVE PARTITIONING;

DELIMITER //

CREATE FUNCTION day_partition(d DATE) RETURNS VARCHAR(9) DETERMINISTIC NO SQL
  RETURN CONCAT('p', DATE_FORMAT(d, '%Y%m%d'))//

CREATE FUNCTION has_partition(p_table VARCHAR(64), p_partition VARCHAR(64)) RETURNS TINYINT READS SQL DATA
  RETURN EXISTS (SELECT 1 FROM information_schema.partitions
                  WHERE table_schema = '{{recordings_db}}' AND table_name = p_table AND partition_name = p_partition)//

CREATE PROCEDURE run_sql(IN p_sql LONGTEXT)
BEGIN
  SET @recordings_sql = p_sql;
  PREPARE stmt FROM @recordings_sql;
  EXECUTE stmt;
  DEALLOCATE PREPARE stmt;
END//

-- Add day partitions [p_from, p_to) by splitting pmax. Partitions are only
-- appended after the last day partition: days before it are either present or
-- intentionally gone (archived or purged), never recreated.
CREATE PROCEDURE ensure_days(IN p_table VARCHAR(64), IN p_from DATE, IN p_to DATE)
BEGIN
  DECLARE d DATE DEFAULT p_from;
  DECLARE parts LONGTEXT DEFAULT '';
  DECLARE last_bound BIGINT;

  SELECT MAX(CAST(partition_description AS UNSIGNED)) INTO last_bound
    FROM information_schema.partitions
   WHERE table_schema = '{{recordings_db}}' AND table_name = p_table AND partition_name NOT IN ('pmin', 'pmax');
  WHILE d < p_to DO
    IF last_bound IS NULL OR UNIX_TIMESTAMP(d + INTERVAL 1 DAY) > last_bound THEN
      SET parts = CONCAT(parts, 'PARTITION ', day_partition(d), ' VALUES LESS THAN (',
                         UNIX_TIMESTAMP(d + INTERVAL 1 DAY), '), ');
    END IF;
    SET d = d + INTERVAL 1 DAY;
  END WHILE;

  IF parts <> '' THEN
    CALL run_sql(CONCAT('ALTER TABLE `', p_table, '` REORGANIZE PARTITION pmax INTO (', parts,
                        'PARTITION pmax VALUES LESS THAN MAXVALUE)'));
  END IF;
END//

CREATE PROCEDURE ensure_year(IN p_table VARCHAR(64), IN p_year INT)
  CALL ensure_days(p_table, MAKEDATE(p_year, 1), MAKEDATE(p_year + 1, 1))//

-- Move one day from recordings to recordings_archives (see 0006 archive_year),
-- leaving its partition empty; archive_at drops them all at once. The archive
-- must already have that day's partition (archive_at ensures it).
CREATE PROCEDURE archive_day(IN d DATE)
BEGIN
  DECLARE p VARCHAR(9) DEFAULT day_partition(d);
  IF has_partition('recordings', p) THEN
    -- Rows older than this day (late ones of an archived day) go by value.
    CALL run_sql(CONCAT('INSERT INTO recordings_archives SELECT * FROM recordings PARTITION (', p,
                        ') WHERE created_at < ''', d, ''''));
    CALL run_sql(CONCAT('DELETE FROM recordings PARTITION (', p, ') WHERE created_at < ''', d, ''''));
    CALL run_sql(CONCAT('SELECT COUNT(*) INTO @recordings_archived FROM recordings_archives PARTITION (', p, ')'));
    IF @recordings_archived = 0 THEN
      CALL run_sql(CONCAT('ALTER TABLE recordings EXCHANGE PARTITION ', p, ' WITH TABLE recordings_swap WITHOUT VALIDATION'));
      CALL run_sql(CONCAT('ALTER TABLE recordings_archives EXCHANGE PARTITION ', p, ' WITH TABLE recordings_swap WITHOUT VALIDATION'));
    ELSE
      CALL run_sql(CONCAT('INSERT INTO recordings_archives SELECT * FROM recordings PARTITION (', p, ')'));
      CALL run_sql(CONCAT('ALTER TABLE recordings TRUNCATE PARTITION ', p));
    END IF;
  END IF;
END//

-- First day of the month n months before p_today's.
CREATE FUNCTION month_start(p_today DATE, n INT) RETURNS DATE DETERMINISTIC NO SQL
  RETURN (p_today - INTERVAL (DAYOFMONTH(p_today) - 1) DAY) - INTERVAL n MONTH//

-- The three events call these with CURDATE(); tests pass other dates.

CREATE PROCEDURE create_partitions_at(IN p_today DATE)
BEGIN
  CALL ensure_year('recordings', YEAR(p_today));
  CALL ensure_year('recordings', YEAR(p_today) + 1);
END//

CREATE PROCEDURE archive_at(IN p_today DATE)
BEGIN
  DECLARE cutoff, d DATE;
  DECLARE hot, y INT;
  DECLARE emptied LONGTEXT DEFAULT '';
  SELECT hot_months INTO hot FROM recordings_settings WHERE id = 1;
  SET cutoff = month_start(p_today, hot);
  IF (SELECT COUNT(*) FROM recordings_swap) > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'recordings: recordings_swap is not empty; check it before archiving';
  END IF;
  SELECT MIN(STR_TO_DATE(SUBSTRING(partition_name, 2), '%Y%m%d')) INTO d
    FROM information_schema.partitions
   WHERE table_schema = '{{recordings_db}}' AND table_name = 'recordings' AND partition_name REGEXP '^p[0-9]{8}$';
  IF d IS NOT NULL AND d < cutoff THEN
    SET y = YEAR(d);
    WHILE y <= YEAR(cutoff - INTERVAL 1 DAY) DO
      CALL ensure_year('recordings_archives', y);
      SET y = y + 1;
    END WHILE;
  END IF;
  WHILE d IS NOT NULL AND d < cutoff DO
    IF has_partition('recordings', day_partition(d)) THEN
      CALL archive_day(d);
      SET emptied = CONCAT(emptied, IF(emptied = '', '', ', '), day_partition(d));
    END IF;
    SET d = d + INTERVAL 1 DAY;
  END WHILE;
  -- The emptied partitions go in one statement.
  IF emptied <> '' THEN
    CALL run_sql(CONCAT('ALTER TABLE recordings DROP PARTITION ', emptied));
  END IF;
END//

CREATE PROCEDURE purge_at(IN p_today DATE)
BEGIN
  DECLARE keep INT;
  DECLARE parts LONGTEXT;
  SELECT retention_months INTO keep FROM recordings_settings WHERE id = 1;
  SET SESSION group_concat_max_len = 1048576;
  SELECT GROUP_CONCAT(partition_name ORDER BY partition_ordinal_position SEPARATOR ', ') INTO parts
    FROM information_schema.partitions
   WHERE table_schema = '{{recordings_db}}' AND table_name = 'recordings_archives'
     AND partition_name REGEXP '^p[0-9]{8}$'
     AND STR_TO_DATE(SUBSTRING(partition_name, 2), '%Y%m%d') < month_start(p_today, keep);
  IF parts IS NOT NULL THEN
    CALL run_sql(CONCAT('ALTER TABLE recordings_archives DROP PARTITION ', parts));
  END IF;
END//

-- Move 0003's rows to their final place in one pass: the hot months to
-- recordings, older months within retention straight to recordings_archives
-- (no EXCHANGE loop at startup), older ones are not kept.
CREATE PROCEDURE migrate_unpartitioned()
BEGIN
  DECLARE hot, keep, y INT;
  DECLARE cutoff, keep_from DATE;
  DECLARE oldest TIMESTAMP;

  SELECT hot_months, retention_months INTO hot, keep FROM recordings_settings WHERE id = 1;
  SET cutoff = month_start(CURDATE(), hot), keep_from = month_start(CURDATE(), keep);
  SELECT MIN(created_at) INTO oldest FROM recordings WHERE created_at >= keep_from AND created_at < cutoff;
  SET y = YEAR(oldest);
  WHILE y IS NOT NULL AND y <= YEAR(cutoff - INTERVAL 1 DAY) DO
    CALL ensure_year('recordings_archives', y);
    SET y = y + 1;
  END WHILE;
  CALL ensure_days('recordings_partitioned', cutoff, MAKEDATE(YEAR(CURDATE()) + 1, 1));

  INSERT INTO recordings_archives
  SELECT id, uuid, caller, destination, duration, billsec, recording_path, recording_blob, recording_size, audio_sha256, audio_hmac_sha256, transcription_status, transcription_text, transcription_sha256, transcription_hmac_sha256, transcription_model, transcription_language, transcribed_at, summary_status, summary_text, summary_sha256, summary_hmac_sha256, analysis_status, analysis_json, analysis_sha256, analysis_hmac_sha256, processing_error, created_at, updated_at
    FROM recordings WHERE created_at >= keep_from AND created_at < cutoff;
  INSERT INTO recordings_partitioned
  SELECT id, uuid, caller, destination, duration, billsec, recording_path, recording_blob, recording_size, audio_sha256, audio_hmac_sha256, transcription_status, transcription_text, transcription_sha256, transcription_hmac_sha256, transcription_model, transcription_language, transcribed_at, summary_status, summary_text, summary_sha256, summary_hmac_sha256, analysis_status, analysis_json, analysis_sha256, analysis_hmac_sha256, processing_error, created_at, updated_at
    FROM recordings WHERE created_at >= cutoff;
END//

DELIMITER ;

CALL migrate_unpartitioned();
DROP PROCEDURE migrate_unpartitioned;
RENAME TABLE recordings TO recordings_unpartitioned, recordings_partitioned TO recordings;
DROP TABLE recordings_unpartitioned;

CALL ensure_year('recordings', YEAR(CURDATE()));
CALL ensure_year('recordings', IF(CURDATE() >= STR_TO_DATE(CONCAT(YEAR(CURDATE()), '-12-15'), '%Y-%m-%d'), YEAR(CURDATE()) + 1, YEAR(CURDATE())));
CALL archive_at(CURDATE());
CALL purge_at(CURDATE());

CREATE EVENT recordings_create_partitions
  ON SCHEDULE EVERY 1 YEAR
  STARTS IF(NOW() < TIMESTAMP(CONCAT(YEAR(CURDATE()), '-12-15 03:00:00')),
            TIMESTAMP(CONCAT(YEAR(CURDATE()), '-12-15 03:00:00')),
            TIMESTAMP(CONCAT(YEAR(CURDATE()) + 1, '-12-15 03:00:00')))
  COMMENT 'Next year''s day partitions of recordings (0007-recordings-partitions.sql)'
  DO CALL create_partitions_at(CURDATE());

CREATE EVENT recordings_archive
  ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 3 HOUR)
  COMMENT 'Months before the hot ones to recordings_archives (0007-recordings-partitions.sql)'
  DO CALL archive_at(CURDATE());

CREATE EVENT recordings_purge
  ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 3 HOUR + INTERVAL 30 MINUTE)
  COMMENT 'Drops recordings_archives days beyond retention_months (0007-recordings-partitions.sql)'
  DO CALL purge_at(CURDATE());
