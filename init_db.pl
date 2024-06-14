use Modern::Perl;
use Text::CSV::Encoded;
use File::Slurp qw( read_file );
use JSON        qw(from_json);
use DBI;

my $dbh = DBI->connect( "dbi:SQLite:dbname=database.db", "", "" );
$dbh->do(q{DROP TABLE IF EXISTS plugins});
$dbh->do(
    q{
    CREATE TABLE plugins (
        id INTEGER PRIMARY KEY,   -- PK
        name TEXT UNIQUE,         -- Plugin name
        description TEXT,         -- Plugin description
        author TEXT,              -- Author of the plugin
        thumbnail TEXT,           -- Thumbnail image
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
    );
}
);

$dbh->do(q{DROP TABLE IF EXISTS versions});
$dbh->do(
    q{
    CREATE TABLE versions (
        plugin_id INTEGER,        -- id from the plugins table
        plugin_version TEXT,      -- version of the plugin
        koha_version TEXT,        -- major Koha version (e.g. '24.05')
        date_released DATETIME,   -- Date time this plugin version was released
        FOREIGN KEY(plugin_id) REFERENCES plugins(id) ON DELETE CASCADE
    );
}
);

$dbh->do( q{INSERT INTO plugins ( name, description, author, thumbnail ) values ( 'Acquisitions 2.0', 'Replaces the built-in Acquisitions module with a newer, more user-friendly, version.', 'PTFS-Europe', 'acq2.png') });
$dbh->do( q{INSERT INTO plugins ( name, description, author, thumbnail ) values ( 'Coverflow', 'Provides the option of showing a coverflow carousel in the OPAC through a pre-configured report.', 'Bywater Solutions', 'coverflow.png' ) });
$dbh->do( q{INSERT INTO plugins ( name, description, author, thumbnail ) values ( 'Event Management', 'This plugin makes it easy for you to create, manage and advertise events to your target audiences.', 'LMS Cloud', NULL ) });

$dbh->do( q{INSERT INTO versions( plugin_id, plugin_version, koha_version ) values( 1, 'v3.1.1', '24.05' ) });