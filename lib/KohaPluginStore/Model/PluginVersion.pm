package KohaPluginStore::Model::PluginVersion;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'plugin_versions';
}

sub _columns {
    return [qw(id plugin_id name tag_name version koha_min_version kpz_url date_released status error_message content_digest author_username author_avatar_url certification_tier signed_manifest signature)];
}

1;
