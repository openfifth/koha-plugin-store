use Modern::Perl;
use DBI;

my $dbh = DBI->connect( "dbi:SQLite:dbname=database.db", "", "" );

# THESE QUERIES ARE FOR TESTING ONLY AND ASSUME BYWATER COVERFLOW PLUGIN IS plugin_id

# Add latest release requiring mininum 19.05
$dbh->do(
q{INSERT OR IGNORE INTO main.releases( plugin_id, name, tag_name, version, koha_min_version, date_released, kpz_url ) values( 1, 'v2.7', 'v2.7', '2.7', '19.05', '2024-12-25T15:34:06Z', "https://github.com/bywatersolutions/koha-plugin-coverflow/releases/download/v2.5.7/koha-plugin-coverflow-2.5.7.kpz" ) }
);

#Add latest release beyond requiring mininum 26.05
$dbh->do(
q{INSERT OR IGNORE INTO main.releases( plugin_id, name, tag_name, version, koha_min_version, date_released, kpz_url ) values( 1, 'v2.9', 'v2.9', '2.9', '26.05', '2024-12-27T15:34:06Z', "https://github.com/bywatersolutions/koha-plugin-coverflow/releases/download/v2.5.7/koha-plugin-coverflow-2.5.7.kpz" ) }
);

#Delete all releases for a plugin
$dbh->do(
q{DELETE from releases where plugin_id = 3 }
);