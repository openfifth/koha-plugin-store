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
        author TEXT,              -- Author of the plugin
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

$dbh->do( q{INSERT INTO plugins ( id, name, author ) values ( 1, 'Acquisitions 2.0', 'PTFS-Europe') });
$dbh->do( q{INSERT INTO plugins ( id, name, author ) values ( 2, 'Coverflow', 'Bywater Solutions' ) });
$dbh->do( q{INSERT INTO versions( plugin_id, plugin_version, koha_version ) values( 1, 'v3.1.1', '24.05' ) });