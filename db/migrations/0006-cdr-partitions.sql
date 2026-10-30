-- CDRs partitioned by day, archived by calendar year, purged after a
-- retention period.
--
-- cdr and cdr_archives have one RANGE partition per day (pYYYYMMDD) on
-- TO_DAYS(calldate), plus pmax so an insert never fails if partitions are
-- missing, and an always-empty pmin: MySQL adds the first partition to every
-- range query on TO_DAYS(), so that extra read costs nothing. Queries on a day read one partition, on a month ~30. The primary
-- key (calldate, id) clusters the rows by date.
--
-- Three events (the event scheduler must be on: --event-scheduler=ON):
--   cdr_create_partitions  15 December 03:00, yearly: next year's partitions.
--   cdr_archive            daily 03:00: day partitions of past years (on
--                          1 January, all of the year that just ended) move
--                          from cdr to cdr_archives with EXCHANGE PARTITION.
--   cdr_purge              daily 03:30: drops cdr_archives years older than
--                          cdr_settings.retention_years.
-- The current year is never archived.

USE `{{cdr_db}}`;

CREATE TABLE cdr_settings (
  id              TINYINT UNSIGNED NOT NULL DEFAULT 1,
  retention_years INT UNSIGNED NOT NULL DEFAULT 4 COMMENT 'past calendar years kept in cdr_archives',
  PRIMARY KEY (id)
) ENGINE=InnoDB;
INSERT INTO cdr_settings (id) VALUES (1);

-- Same columns as 0002; new keys. id needs its own index for AUTO_INCREMENT.
CREATE TABLE cdr_partitioned (
  `id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
  `calldate` DATETIME NOT NULL,
  `clid` VARCHAR(80) NOT NULL DEFAULT '',
  `src` VARCHAR(80) NOT NULL DEFAULT '',
  `dst` VARCHAR(80) NOT NULL DEFAULT '',
  `dcontext` VARCHAR(80) NOT NULL DEFAULT '',
  `channel` VARCHAR(100) NULL DEFAULT NULL,
  `dstchannel` VARCHAR(100) NULL DEFAULT NULL,
  `lastapp` VARCHAR(200) NULL DEFAULT NULL,
  `lastdata` VARCHAR(255) NULL DEFAULT NULL,
  `duration` INT UNSIGNED NULL DEFAULT NULL,
  `billsec` INT UNSIGNED NULL DEFAULT NULL,
  `disposition` VARCHAR(45) NULL DEFAULT NULL,
  `amaflags` VARCHAR(50) NULL DEFAULT NULL,
  `accountcode` VARCHAR(80) NULL DEFAULT NULL,
  `uniqueid` VARCHAR(64) NOT NULL DEFAULT '',
  `userfield` VARCHAR(255) NULL DEFAULT NULL,
  PRIMARY KEY (`calldate`, `id`),
  KEY `id` (`id`),
  KEY `src_calldate` (`src`, `calldate`),
  KEY `dst_calldate` (`dst`, `calldate`),
  KEY `accountcode_calldate` (`accountcode`, `calldate`),
  KEY `uniqueid` (`uniqueid`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
PARTITION BY RANGE (TO_DAYS(`calldate`)) (PARTITION pmin VALUES LESS THAN (1),
                                         PARTITION pmax VALUES LESS THAN MAXVALUE);

CREATE TABLE cdr_archives LIKE cdr_partitioned;

-- Staging table for EXCHANGE PARTITION: same structure, not partitioned.
CREATE TABLE cdr_swap LIKE cdr_partitioned;
ALTER TABLE cdr_swap REMOVE PARTITIONING;

DELIMITER //

CREATE FUNCTION day_partition(d DATE) RETURNS VARCHAR(9) DETERMINISTIC NO SQL
  RETURN CONCAT('p', DATE_FORMAT(d, '%Y%m%d'))//

CREATE FUNCTION has_partition(p_table VARCHAR(64), p_partition VARCHAR(64)) RETURNS TINYINT READS SQL DATA
  RETURN EXISTS (SELECT 1 FROM information_schema.partitions
                  WHERE table_schema = '{{cdr_db}}' AND table_name = p_table AND partition_name = p_partition)//

CREATE PROCEDURE run_sql(IN p_sql LONGTEXT)
BEGIN
  SET @cdr_sql = p_sql;
  PREPARE stmt FROM @cdr_sql;
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
   WHERE table_schema = '{{cdr_db}}' AND table_name = p_table AND partition_name NOT IN ('pmin', 'pmax');
  WHILE d < p_to DO
    IF last_bound IS NULL OR TO_DAYS(d + INTERVAL 1 DAY) > last_bound THEN
      SET parts = CONCAT(parts, 'PARTITION ', day_partition(d), ' VALUES LESS THAN (',
                         TO_DAYS(d + INTERVAL 1 DAY), '), ');
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

-- Move every day of a past year from cdr to cdr_archives. An empty archive
-- partition is swapped in (metadata only); one that already holds rows (a
-- re-run) gets them merged with INSERT ... SELECT.
CREATE PROCEDURE archive_year(IN p_year INT)
BEGIN
  DECLARE d DATE DEFAULT MAKEDATE(p_year, 1);
  DECLARE p VARCHAR(9);
  DECLARE emptied LONGTEXT DEFAULT '';

  IF (SELECT COUNT(*) FROM cdr_swap) > 0 THEN
    SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'cdr: cdr_swap is not empty; check it before archiving';
  END IF;
  CALL ensure_year('cdr_archives', p_year);

  WHILE d < MAKEDATE(p_year + 1, 1) DO
    SET p = day_partition(d);
    IF has_partition('cdr', p) THEN
      -- The first partition also holds CDRs older than its day (late ones of
      -- an archived year). Route those by value so EXCHANGE ... WITHOUT
      -- VALIDATION never carries a row into the wrong day.
      CALL run_sql(CONCAT('INSERT INTO cdr_archives SELECT * FROM cdr PARTITION (', p, ') WHERE calldate < ''', d, ''''));
      CALL run_sql(CONCAT('DELETE FROM cdr PARTITION (', p, ') WHERE calldate < ''', d, ''''));
      CALL run_sql(CONCAT('SELECT COUNT(*) INTO @cdr_archived FROM cdr_archives PARTITION (', p, ')'));
      IF @cdr_archived = 0 THEN
        CALL run_sql(CONCAT('ALTER TABLE cdr EXCHANGE PARTITION ', p, ' WITH TABLE cdr_swap WITHOUT VALIDATION'));
        CALL run_sql(CONCAT('ALTER TABLE cdr_archives EXCHANGE PARTITION ', p, ' WITH TABLE cdr_swap WITHOUT VALIDATION'));
      ELSE
        CALL run_sql(CONCAT('INSERT INTO cdr_archives SELECT * FROM cdr PARTITION (', p, ')'));
        CALL run_sql(CONCAT('ALTER TABLE cdr TRUNCATE PARTITION ', p));
      END IF;
      SET emptied = CONCAT(emptied, IF(emptied = '', '', ', '), p);
    END IF;
    SET d = d + INTERVAL 1 DAY;
  END WHILE;
  -- The emptied partitions go in one statement (one ALTER instead of 365).
  IF emptied <> '' THEN
    CALL run_sql(CONCAT('ALTER TABLE cdr DROP PARTITION ', emptied));
  END IF;
END//

-- Drop archive partitions of years before p_first_kept_year.
CREATE PROCEDURE purge_archives(IN p_first_kept_year INT)
BEGIN
  DECLARE parts LONGTEXT;
  SET SESSION group_concat_max_len = 1048576;   -- default 1024 cuts a year of names
  SELECT GROUP_CONCAT(partition_name ORDER BY partition_ordinal_position SEPARATOR ', ') INTO parts
    FROM information_schema.partitions
   WHERE table_schema = '{{cdr_db}}' AND table_name = 'cdr_archives'
     AND partition_name REGEXP '^p[0-9]{8}$' AND CAST(SUBSTRING(partition_name, 2, 4) AS UNSIGNED) < p_first_kept_year;
  IF parts IS NOT NULL THEN
    CALL run_sql(CONCAT('ALTER TABLE cdr_archives DROP PARTITION ', parts));
  END IF;
END//

-- The three events call these with CURDATE(); tests pass other dates.

-- cdr_create_partitions: the current year (if missing) and the next one.
CREATE PROCEDURE create_partitions_at(IN p_today DATE)
BEGIN
  CALL ensure_year('cdr', YEAR(p_today));
  CALL ensure_year('cdr', YEAR(p_today) + 1);
END//

-- cdr_archive: every year before p_today's still in cdr, oldest first.
CREATE PROCEDURE archive_at(IN p_today DATE)
BEGIN
  DECLARE y INT;
  SELECT MIN(CAST(SUBSTRING(partition_name, 2, 4) AS UNSIGNED)) INTO y
    FROM information_schema.partitions
   WHERE table_schema = '{{cdr_db}}' AND table_name = 'cdr' AND partition_name REGEXP '^p[0-9]{8}$';
  WHILE y IS NOT NULL AND y < YEAR(p_today) DO
    CALL archive_year(y);
    SET y = y + 1;
  END WHILE;
END//

-- cdr_purge: keep retention_years calendar years before p_today's.
CREATE PROCEDURE purge_at(IN p_today DATE)
BEGIN
  DECLARE keep_years INT;
  SELECT retention_years INTO keep_years FROM cdr_settings WHERE id = 1;
  CALL purge_archives(YEAR(p_today) - keep_years);
END//

-- Move the CDRs of 0002's table to their final place in one pass: the current
-- year to cdr, past years within retention straight to cdr_archives (no
-- EXCHANGE loop at startup), older ones are not kept.
CREATE PROCEDURE migrate_unpartitioned()
BEGIN
  DECLARE y, first_kept INT;
  DECLARE this_year DATE DEFAULT MAKEDATE(YEAR(CURDATE()), 1);

  SELECT YEAR(CURDATE()) - retention_years INTO first_kept FROM cdr_settings WHERE id = 1;
  SELECT YEAR(MIN(calldate)) INTO y FROM cdr WHERE calldate >= MAKEDATE(first_kept, 1) AND calldate < this_year;
  WHILE y IS NOT NULL AND y < YEAR(CURDATE()) DO
    CALL ensure_year('cdr_archives', y);
    SET y = y + 1;
  END WHILE;
  CALL ensure_year('cdr_partitioned', YEAR(CURDATE()));

  INSERT INTO cdr_archives (id, calldate, clid, src, dst, dcontext, channel, dstchannel, lastapp, lastdata, duration, billsec, disposition, amaflags, accountcode, uniqueid, userfield)
  SELECT id, calldate, clid, src, dst, dcontext, channel, dstchannel, lastapp, lastdata, duration, billsec, disposition, amaflags, accountcode, uniqueid, userfield FROM cdr WHERE calldate >= MAKEDATE(first_kept, 1) AND calldate < this_year;
  INSERT INTO cdr_partitioned (id, calldate, clid, src, dst, dcontext, channel, dstchannel, lastapp, lastdata, duration, billsec, disposition, amaflags, accountcode, uniqueid, userfield)
  SELECT id, calldate, clid, src, dst, dcontext, channel, dstchannel, lastapp, lastdata, duration, billsec, disposition, amaflags, accountcode, uniqueid, userfield FROM cdr WHERE calldate >= this_year;
END//

DELIMITER ;

CALL migrate_unpartitioned();
DROP PROCEDURE migrate_unpartitioned;
RENAME TABLE cdr TO cdr_unpartitioned, cdr_partitioned TO cdr;
DROP TABLE cdr_unpartitioned;

-- Current year, next year if 15 December has passed, and past years brought
-- over from 0002's table go to the archive.
CALL ensure_year('cdr', YEAR(CURDATE()));
CALL ensure_year('cdr', IF(CURDATE() >= STR_TO_DATE(CONCAT(YEAR(CURDATE()), '-12-15'), '%Y-%m-%d'), YEAR(CURDATE()) + 1, YEAR(CURDATE())));
CALL archive_at(CURDATE());
CALL purge_at(CURDATE());

CREATE EVENT cdr_create_partitions
  ON SCHEDULE EVERY 1 YEAR
  STARTS IF(NOW() < TIMESTAMP(CONCAT(YEAR(CURDATE()), '-12-15 03:00:00')),
            TIMESTAMP(CONCAT(YEAR(CURDATE()), '-12-15 03:00:00')),
            TIMESTAMP(CONCAT(YEAR(CURDATE()) + 1, '-12-15 03:00:00')))
  COMMENT 'Next year''s day partitions of cdr (0006-cdr-partitions.sql)'
  DO CALL create_partitions_at(CURDATE());

CREATE EVENT cdr_archive
  ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 3 HOUR)
  COMMENT 'Past years of cdr to cdr_archives (0006-cdr-partitions.sql)'
  DO CALL archive_at(CURDATE());

CREATE EVENT cdr_purge
  ON SCHEDULE EVERY 1 DAY STARTS (CURRENT_DATE + INTERVAL 1 DAY + INTERVAL 3 HOUR + INTERVAL 30 MINUTE)
  COMMENT 'Drops cdr_archives years beyond retention_years (0006-cdr-partitions.sql)'
  DO CALL purge_at(CURDATE());
