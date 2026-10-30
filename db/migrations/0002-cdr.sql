-- CDRs in their own database, written by cdr_adaptive_odbc through the "cdr"
-- ODBC connection (see entrypoint.sh).

CREATE DATABASE IF NOT EXISTS `{{cdr_db}}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE `{{cdr_db}}`;

CREATE TABLE IF NOT EXISTS `cdr` (
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

  PRIMARY KEY (`id`),
  KEY `idx_calldate` (`calldate`),
  KEY `idx_src` (`src`),
  KEY `idx_dst` (`dst`),
  KEY `idx_uniqueid` (`uniqueid`)
)
ENGINE=InnoDB
DEFAULT CHARSET=utf8mb4
COLLATE=utf8mb4_unicode_ci;

GRANT SELECT, INSERT, UPDATE, DELETE ON `{{cdr_db}}`.* TO '{{app_user}}'@'%';
