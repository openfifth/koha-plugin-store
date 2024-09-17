use Modern::Perl;
use DBI;

my $dbh = DBI->connect( "dbi:SQLite:dbname=database.db", "", "" );

$dbh->do(q{DELETE FROM plugins});
$dbh->do(q{DELETE FROM sqlite_sequence WHERE name = 'plugins'});
$dbh->do(q{DELETE FROM users});
$dbh->do(q{DELETE FROM sqlite_sequence WHERE name = 'users'});
$dbh->do(q{DELETE FROM releases});
$dbh->do(q{DELETE FROM sqlite_sequence WHERE name = 'releases'});

# Users data:
# admin: admin
# John: Doe

$dbh->do(
q{INSERT OR IGNORE INTO users( username, password, email ) values( 'admin', '$2y$14$suGo48Hu5oujkBqBqzVueeZHjjkNsY1/SZCBtIMFkoDbX.2Vq92yy', 'admin@www.com' ) }
);

$dbh->do(
q{INSERT OR IGNORE INTO users( username, password, email ) values( 'John', '$2y$14$0s3kXSp4hBVi5ueaRr1sJez2XGgvV/OETt653a28GHWHCskqV5rRa', 'john@doe.com' ) }
);

# Plugins data
$dbh->do(
q{INSERT OR IGNORE INTO plugins (
    author,
    class_name,
    description,
    name,
    repo_url,
    thumbnail,
    timestamp,
    user_id
) values (
    'Kyle M Hall',
    'Koha::Plugin::Com::ByWaterSolutions::CoverFlow',
    'Convert a report into a coverflow style widget!',
    'CoverFlow plugin',
    'https://github.com/bywatersolutions/koha-plugin-coverflow',
    'coverflow.png',
    '2024-09-17 09:34:22',
    1
)});

$dbh->do(
q{INSERT OR IGNORE INTO plugins (
    author,
    class_name,
    description,
    name,
    repo_url,
    thumbnail,
    timestamp,
    user_id
) values (
    'PTFS-Europe',
    'Koha::Plugin::Com::PTFSEurope::IllActions',
    'ILL Actions',
    'IllActions',
    'https://github.com/PTFS-Europe/koha-plugin-ill-actions',
    'ill_actions.png',
    '2024-09-17 09:53:10',
    1
)});

$dbh->do(
q{INSERT OR IGNORE INTO plugins (
    author,
    class_name,
    description,
    name,
    repo_url,
    thumbnail,
    timestamp,
    user_id
) values (
    'Mehdi Hamidi, Bouzid Fergani, Arthur Bousquet, The Minh Luong, Matthias Le Gac',
    'Koha::Plugin::PDFtoCover',
    'Creates cover images for documents missing one',
    'PDFtoCover',
    'https://github.com/inLibro/koha-plugin-pdftocover',
    'pdftocover.png',
    '2024-09-17 10:12:51',
    1
)});

$dbh->do(
q{INSERT OR IGNORE INTO plugins (
    author,
    class_name,
    description,
    name,
    repo_url,
    thumbnail,
    timestamp,
    user_id
) values (
    'LMSCloud GmbH',
    'Koha::Plugin::Com::LMSCloud::EventManagement',
    'This plugin makes managing events with koha a breeze!',
    'LMSEventManagement',
    'https://github.com/LMSCloud/LMSEventManagement',
    'lmscloudevent.png',
    '2024-09-17 11:29:28',
    1
)});

# Releases data

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
    '2024-07-01T15:34:06Z',
    '19.05',
    'https://github.com/bywatersolutions/koha-plugin-coverflow/releases/download/v2.5.7/koha-plugin-coverflow-2.5.7.kpz',
    'v2.5.7',
    1,
    'v2.5.7',
    '2.5.7'
)}
);

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
    '2024-03-27T15:56:15Z',
    '23.11.00.000',
    'https://github.com/PTFS-Europe/koha-plugin-ill-actions/releases/download/1.3.1/koha-ill-actions-plugin-1.3.1.kpz',
    'v1.3.1',
    2,
    '1.3.1',
    '1.3.1'
)}
);

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
    '2024-07-30T19:18:58Z',
    '23.05.08',
    'https://github.com/inLibro/koha-plugin-pdftocover/releases/download/v2.1/koha-plugin-pdftocover-2.1.kpz',
    'v2.1',
    3,
    'v2.1',
    '2.1'
)}
);

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
    '2024-03-04T12:32:26Z',
    '18.05',
    'https://github.com/LMSCloud/LMSEventManagement/releases/download/v1.6.12-beta.14/lms-event-management-v1.6.12.kpz',
    'Carnival',
    4,
    'v1.6.12-beta.14',
    '1.6.12'
)}
);