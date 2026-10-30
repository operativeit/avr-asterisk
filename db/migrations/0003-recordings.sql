-- Call recordings metadata in their own database (written by the
-- save_recording AGI, read by the transcription/summary workers).

CREATE DATABASE IF NOT EXISTS `{{recordings_db}}` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
USE `{{recordings_db}}`;

CREATE TABLE IF NOT EXISTS `recordings` (
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

  `transcription_status` enum(
    'pending',
    'processing',
    'done',
    'error',
    'skipped'
  ) NOT NULL DEFAULT 'pending',

  `transcription_text` longtext DEFAULT NULL,
  `transcription_sha256` char(64) DEFAULT NULL,
  `transcription_hmac_sha256` char(64) DEFAULT NULL,
  `transcription_model` varchar(80) DEFAULT NULL,
  `transcription_language` varchar(16) DEFAULT NULL,
  `transcribed_at` timestamp NULL DEFAULT NULL,

  `summary_status` enum(
    'pending',
    'processing',
    'done',
    'error',
    'skipped'
  ) NOT NULL DEFAULT 'pending',

  `summary_text` longtext DEFAULT NULL,
  `summary_sha256` char(64) DEFAULT NULL,
  `summary_hmac_sha256` char(64) DEFAULT NULL,

  `analysis_status` enum(
    'pending',
    'processing',
    'done',
    'error',
    'skipped'
  ) NOT NULL DEFAULT 'pending',

  `analysis_json` json DEFAULT NULL,
  `analysis_sha256` char(64) DEFAULT NULL,
  `analysis_hmac_sha256` char(64) DEFAULT NULL,

  `processing_error` text DEFAULT NULL,

  `created_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
  `updated_at` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,

  PRIMARY KEY (`id`),
  UNIQUE KEY `uniq_uuid` (`uuid`),

  KEY `idx_created_at` (`created_at`),
  KEY `idx_caller` (`caller`),
  KEY `idx_destination` (`destination`),
  KEY `idx_audio_sha256` (`audio_sha256`),
  KEY `idx_transcription_status_created_at` (`transcription_status`, `created_at`),
  KEY `idx_summary_status_created_at` (`summary_status`, `created_at`),
  KEY `idx_analysis_status_created_at` (`analysis_status`, `created_at`)
) ENGINE=InnoDB
  DEFAULT CHARSET=utf8mb4
  COLLATE=utf8mb4_unicode_ci;

GRANT SELECT, INSERT, UPDATE, DELETE ON `{{recordings_db}}`.* TO '{{app_user}}'@'%';
