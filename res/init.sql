DROP TABLE IF EXISTS `session`;
-- DROP your project's tables here

CREATE TABLE `session` (
	`id`         VARCHAR(255) NOT NULL,
	`userId`     VARCHAR(255) NOT NULL,
	PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci ;

-- Create your project's database here
