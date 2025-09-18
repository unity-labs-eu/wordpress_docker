<?php
// Local DB credentials (override production)
define('DB_NAME',     getenv('WORDPRESS_DB_NAME')     ?: 'wordpress');
define('DB_USER',     getenv('WORDPRESS_DB_USER')     ?: 'wordpress');
define('DB_PASSWORD', getenv('WORDPRESS_DB_PASSWORD') ?: 'wordpress');
define('DB_HOST',     getenv('WORDPRESS_DB_HOST')     ?: 'db:3306');

// Local URLs (match compose)
if (getenv('WP_HOME'))    define('WP_HOME',    getenv('WP_HOME'));
if (getenv('WP_SITEURL')) define('WP_SITEURL', getenv('WP_SITEURL'));

// Local dev toggles
define('WP_DEBUG', true);
define('WP_DEBUG_LOG', true);
define('FS_METHOD', 'direct');
