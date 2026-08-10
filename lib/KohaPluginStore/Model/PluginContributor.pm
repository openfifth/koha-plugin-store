package KohaPluginStore::Model::PluginContributor;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'plugin_contributors';
}

sub _columns {
    return [qw(id plugin_id github_username avatar_url contributions_count fetched_at)];
}

1;
