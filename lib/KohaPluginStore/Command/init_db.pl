use Modern::Perl;
use Text::CSV::Encoded;
use File::Slurp qw( read_file );
use JSON        qw(from_json);
use DBI;

my $dbh = DBI->connect( "dbi:SQLite:dbname=database.db", "", "" );

# Plugins schema
$dbh->do(q{DROP TABLE IF EXISTS plugins});
$dbh->do(
    q{
    CREATE TABLE plugins (
        id INTEGER PRIMARY KEY AUTOINCREMENT,   -- PK
        plugin_class TEXT UNIQUE,               -- Unique plugin class
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

# Versions schema
$dbh->do(q{DROP TABLE IF EXISTS versions});
$dbh->do(
    q{
    CREATE TABLE versions (
        plugin_id INTEGER PRIMARY KEY AUTOINCREMENT, --id from the plugins table
        plugin_version TEXT,                         -- version of the plugin
        koha_version TEXT,                           -- major Koha version (e.g. '24.05')
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
        username TEXT NOT NULL,
        password TEXT NOT NULL,
        email TEXT NOT NULL
    );
}
);

# Plugins data
$dbh->do(
q{INSERT INTO plugins ( name, plugin_class, description, author, thumbnail, user_id ) values ( 'Acquisitions 2.0', 'Koha::Plugin::Acquire', 'Replaces the built-in Acquisitions module with a newer, more user-friendly, version.', 'PTFS-Europe', 'acq2.png', 1) }
);
$dbh->do(
q{INSERT INTO plugins ( name, plugin_class, description, author, thumbnail, user_id ) values ( 'Coverflow', 'Koha::Plugin::Com::ByWaterSolutions::CoverFlow', 'Provides the option of showing a coverflow carousel in the OPAC through a pre-configured report.', 'Bywater Solutions', 'coverflow.png', 2) }
);
$dbh->do(
q{INSERT INTO plugins ( name, plugin_class, description, author, thumbnail, user_id ) values ( 'Event Management', 'Koha::Plugin::Com::LMSCloud::EventManagement', 'This plugin makes it easy for you to create, manage and advertise events to your target audiences.', 'LMS Cloud', NULL, 1 ) }
);

# Versions data
$dbh->do(
q{INSERT INTO versions( plugin_id, plugin_version, koha_version ) values( 1, 'v3.1.1', '24.05' ) }
);

# Users data:
# admin: admin
# John: Doe

$dbh->do(
q{INSERT INTO users( username, password, email ) values( 'admin', '$2y$14$suGo48Hu5oujkBqBqzVueeZHjjkNsY1/SZCBtIMFkoDbX.2Vq92yy', 'admin@www.com' ) }
);

$dbh->do(
q{INSERT INTO users( username, password, email ) values( 'John', '$2y$14$0s3kXSp4hBVi5ueaRr1sJez2XGgvV/OETt653a28GHWHCskqV5rRa', 'john@doe.com' ) }
);

