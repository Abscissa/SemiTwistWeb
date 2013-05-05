DROP TABLE IF EXISTS `session`;
DROP TABLE IF EXISTS `token`;
-- DROP your project's tables here

CREATE TABLE `session` (
	`id`         VARCHAR(255) NOT NULL,
	`userId`     VARCHAR(255) NOT NULL,
	PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci ;

CREATE TABLE `token` (
	`type`        VARCHAR(255) NOT NULL,
	`code`        VARCHAR(255) NOT NULL,
	`expiration`  DATETIME NOT NULL,
	`email`       VARCHAR(255),
	`linkedId`    BIGINT UNSIGNED NOT NULL,
	PRIMARY KEY (`type`, `code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci ;

-- Create your project's database here
