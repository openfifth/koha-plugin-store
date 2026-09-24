package KohaPluginStore::Command::sync_plugin_releases;
use Mojo::Base 'Mojolicious::Command', -signatures;

use KohaPluginStore::Model::Plugin;

has description => 'Enqueue a release-sync job for every auto_sync_releases-enabled plugin';
has usage       => sub { shift->extract_usage };

sub run ($self, @args) {
    my $plugins = KohaPluginStore::Model::Plugin->new( pg => $self->app->pg )->auto_sync_enabled;

    $self->app->minion->enqueue( sync_plugin_release => [ $_->id ] ) for @$plugins;

    say 'Enqueued release sync for ' . scalar(@$plugins) . ' opted-in plugin(s).';
}

1;

=encoding utf8

=head1 NAME

KohaPluginStore::Command::sync_plugin_releases - Enqueue release-sync jobs for opted-in plugins

=head1 SYNOPSIS

  Usage: APPLICATION sync_plugin_releases

  Enqueues one sync_plugin_release job per plugin with auto_sync_releases enabled. Makes no
  GitHub calls and touches no plugin_versions rows itself -- each plugin's actual check and
  submission happens in its own Minion job, so one plugin's failure can't affect any other.

=cut
