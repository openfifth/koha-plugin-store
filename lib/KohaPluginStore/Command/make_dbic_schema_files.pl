use DBIx::Class::Schema::Loader qw/ make_schema_at /;
make_schema_at(
    'KohaPluginStore::Schema',
    {
        debug          => 1,
        dump_directory => './lib',
    },
    [
        'dbi:SQLite:dbname=database.db', '', '', # This is dev only || TODO: add user:password here
    ],
);
