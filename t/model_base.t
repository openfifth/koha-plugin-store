use Mojo::Base -strict;
use Test::More;

use lib 't/lib';
use TestDB qw(reset_db test_pg);

use KohaPluginStore::Model::Base;

package TestPlugin {
    use Modern::Perl;
    use parent -norequire, 'KohaPluginStore::Model::Base';
    sub _table   { return 'plugins' }
    sub _columns { return [qw(id repo_url name class_name description author thumbnail developer_id timestamp)] }
}

reset_db();

subtest 'create returns a populated object' => sub {
    my $plugin = TestPlugin->new( pg => test_pg() )->create( { name => 'Widget', description => 'A widget' } );
    ok( $plugin->id, 'id was assigned' );
    is( $plugin->name, 'Widget', 'name accessor reads back' );
};

subtest 'find locates by column' => sub {
    TestPlugin->new( pg => test_pg() )->create( { name => 'Findable' } );
    my $found = TestPlugin->new( pg => test_pg() )->find( { name => 'Findable' } );
    is( $found->name, 'Findable', 'found the right row' );
    ok( !TestPlugin->new( pg => test_pg() )->find( { name => 'NoSuchThing' } ), 'find returns undef for no match' );
};

subtest 'search returns all matches' => sub {
    reset_db();
    TestPlugin->new( pg => test_pg() )->create( { name => 'A', author => 'Same Author' } );
    TestPlugin->new( pg => test_pg() )->create( { name => 'B', author => 'Same Author' } );
    my @found = TestPlugin->new( pg => test_pg() )->search( { author => 'Same Author' } );
    is( scalar @found, 2, 'both rows found' );
};

subtest 'accessor can set as well as get' => sub {
    my $plugin = TestPlugin->new( pg => test_pg() )->create( { name => 'Settable' } );
    $plugin->description('Updated');
    is( $plugin->description, 'Updated', 'in-memory set works' );
};

subtest 'unblessed returns a plain hashref' => sub {
    my $plugin = TestPlugin->new( pg => test_pg() )->create( { name => 'Unblessable' } );
    my $hash = $plugin->unblessed;
    is( ref($hash), 'HASH', 'is a plain hashref' );
    is( $hash->{name}, 'Unblessable', 'has the right data' );
};

subtest 'unknown column dies' => sub {
    my $plugin = TestPlugin->new( pg => test_pg() )->create( { name => 'Strict' } );
    eval { $plugin->not_a_real_column };
    like( $@, qr/not a column/, 'raises on unknown accessor' );
};

subtest 'update modifies the row and the in-memory object' => sub {
    my $plugin = TestPlugin->new( pg => test_pg() )->create( { name => 'Updatable', description => 'Before' } );
    my $result = $plugin->update( { description => 'After' } );
    is( $result, $plugin, 'update returns the same object' );
    is( $plugin->description, 'After', 'in-memory value updated' );
    my $reloaded = TestPlugin->new( pg => test_pg() )->find( { name => 'Updatable' } );
    is( $reloaded->description, 'After', 'persisted value updated' );
};

done_testing();
