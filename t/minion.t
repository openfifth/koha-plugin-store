use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app test_pg);

use KohaPluginStore::Model::Developer;

reset_db();

my $t = test_app();
$t->app->plugin( Minion => { Pg => test_pg() } );

subtest 'the minion helper is registered and can run a trivial job' => sub {
    $t->app->minion->add_task(
        test_task => sub {
            my $job = shift;
            KohaPluginStore::Model::Developer->new( pg => $job->app->pg )->create(
                { oauth_provider_key => 'test', provider_user_id => 'minion-smoke-test', username => 'minion-smoke-test' }
            );
        }
    );
    $t->app->minion->enqueue('test_task');
    $t->app->minion->perform_jobs;

    my $created = KohaPluginStore::Model::Developer->new( pg => test_pg() )->find(
        { provider_user_id => 'minion-smoke-test' }
    );
    ok( $created, 'the enqueued job actually ran and wrote to the database' );
};

done_testing();
