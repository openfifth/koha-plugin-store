use Modern::Perl;
use DBI;

my $dbh = DBI->connect( "dbi:SQLite:dbname=database.db", "", "" );

# Plugins schema
$dbh->do(q{DROP TABLE IF EXISTS plugins});
$dbh->do(
    q{
    CREATE TABLE plugins (
        id INTEGER PRIMARY KEY AUTOINCREMENT,   -- PK
        plugin_class TEXT UNIQUE,               -- Unique plugin class
        repo_url TEXT UNIQUE,                   -- Unique plugin repo url
        name TEXT UNIQUE,                       -- Unique plugin name
        description TEXT,                       -- Plugin description
        author TEXT,                            -- Author of the plugin
        thumbnail TEXT,                         -- Thumbnail image
        user_id TEXT,                           -- Uploader of the plugin
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY(user_id) REFERENCES users(id) ON DELETE CASCADE
    );
}
);

# Releases schema
$dbh->do(q{DROP TABLE IF EXISTS releases});
$dbh->do(
    q{
    CREATE TABLE releases (
        plugin_id INTEGER PRIMARY KEY AUTOINCREMENT, --id from the plugins table
        name TEXT,                                   -- release name
        version TEXT,                                -- release version
        koha_max_version TEXT,                       -- major Koha version (e.g. '24.05')
        date_released DATETIME,                      -- Date time this plugin version was released
        FOREIGN KEY(plugin_id) REFERENCES plugins(id) ON DELETE CASCADE
    );
}
);

# Users schema
$dbh->do(q{DROP TABLE IF EXISTS users});
$dbh->do(
    q{
    CREATE TABLE users (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        username TEXT UNIQUE NOT NULL,
        password TEXT NOT NULL,
        email TEXT UNIQUE NOT NULL
    );
}
);
