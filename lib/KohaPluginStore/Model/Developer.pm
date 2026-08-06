package KohaPluginStore::Model::Developer;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'developers';
}

sub _columns {
    return [qw(id oauth_provider_key provider_user_id username avatar_url created_at)];
}

sub find_or_create_from_oauth {
    my ( $self, $attrs ) = @_;

    my $developer = $self->find(
        {
            oauth_provider_key => $attrs->{oauth_provider_key},
            provider_user_id   => $attrs->{provider_user_id},
        }
    );

    return $developer->update(
        { username => $attrs->{username}, avatar_url => $attrs->{avatar_url} }
    ) if $developer;

    return $self->create($attrs);
}

1;
