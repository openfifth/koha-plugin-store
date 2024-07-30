use Modern::Perl;
use DBI;

my $dbh = DBI->connect( "dbi:SQLite:dbname=database.db", "", "" );

# Plugins data
$dbh->do(
q{INSERT OR IGNORE INTO plugins ( name, repo_url, plugin_class, description, author, thumbnail, user_id ) values ( 'Acquisitions 2.0', 'https://github.com/PTFS-Europe/koha-plugin-acq2.0', 'Koha::Plugin::Acquire', 'Replaces the built-in Acquisitions module with a newer, more user-friendly, version.', 'PTFS-Europe', 'acq2.png', 1) }
);
$dbh->do(
q{INSERT OR IGNORE INTO plugins ( name, repo_url, plugin_class, description, author, thumbnail, user_id ) values ( 'Coverflow', 'https://github.com/bywatersolutions/koha-plugin-coverflow', 'Koha::Plugin::Com::ByWaterSolutions::CoverFlow', 'Provides the option of showing a coverflow carousel in the OPAC through a pre-configured report.', 'Bywater Solutions', 'coverflow.png', 2) }
);
$dbh->do(
q{INSERT OR IGNORE INTO plugins ( name, repo_url, plugin_class, description, author, thumbnail, user_id ) values ( 'Event Management', 'https://github.com/LMSCloud/LMSEventManagement', 'Koha::Plugin::Com::LMSCloud::EventManagement', 'This plugin makes it easy for you to create, manage and advertise events to your target audiences.', 'LMS Cloud', NULL, 1 ) }
);

# Releases data
$dbh->do(
q{INSERT OR IGNORE INTO releases( plugin_id, name, version, koha_max_version ) values( 1, 'v3.1.1','3.1.1', '24.05' ) }
);

# Users data:
# admin: admin
# John: Doe

$dbh->do(
q{INSERT OR IGNORE INTO users( username, password, email ) values( 'admin', '$2y$14$suGo48Hu5oujkBqBqzVueeZHjjkNsY1/SZCBtIMFkoDbX.2Vq92yy', 'admin@www.com' ) }
);

$dbh->do(
q{INSERT OR IGNORE INTO users( username, password, email ) values( 'John', '$2y$14$0s3kXSp4hBVi5ueaRr1sJez2XGgvV/OETt653a28GHWHCskqV5rRa', 'john@doe.com' ) }
);
