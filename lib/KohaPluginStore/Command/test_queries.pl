use Modern::Perl;
use DBI;

my $dbh = DBI->connect( "dbi:SQLite:dbname=database.db", "", "" );

$dbh->do(
q{INSERT OR IGNORE INTO releases (
    date_released,
    koha_min_version,
    kpz_url,
    name,
    plugin_id,
    tag_name,
    version
) values (
    '2024-07-31T15:18:53Z',
    '19.05',
    'https://github.com/bywatersolutions/koha-plugin-coverflow/releases/download/v2.5.8/koha-plugin-coverflow-2.5.8.kpz',
    'v2.5.8',
    1,
    'v2.5.8',
    '2.5.8'
)}
);