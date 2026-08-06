package KohaPluginStore::Model::Plugin;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

use KohaPluginStore::Model::PluginVersion;

sub _table {
    return 'plugins';
}

sub _columns {
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp)];
}

sub releases {
    my ($self) = @_;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => $self->pg )->search( { plugin_id => $self->id } );
    return \@versions;
}

1;
