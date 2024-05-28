use Modern::Perl;
use Text::CSV::Encoded;
use File::Slurp qw( read_file );
use JSON qw(from_json);
use DBI;

my $dbh = DBI->connect("dbi:SQLite:dbname=database.db", "", "");
$dbh->do(q{DROP TABLE IF EXISTS plugins});
$dbh->do(q{
    CREATE TABLE plugins (
        id INTEGER PRIMARY KEY,
        name TEXT UNIQUE,
        author TEXT,
        timestamp DATETIME DEFAULT CURRENT_TIMESTAMP
    );
});

$dbh->do(
    q{
    INSERT INTO plugins ( name, author) values ( 'Mojolicious', 'Mojolicious');
    );
}
);
