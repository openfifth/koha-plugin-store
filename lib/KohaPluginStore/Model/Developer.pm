package KohaPluginStore::Model::Developer;

use Modern::Perl;
use Mojo::Date;
use Mojo::JSON qw(decode_json encode_json);
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

sub _table {
    return 'developers';
}

sub _columns {
    return [
        qw(id oauth_provider_key provider_user_id username avatar_url created_at
            cached_repos cached_repos_fetched_at)
    ];
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

# Stored as jsonb; rows fetched without ->expand() come back with the raw JSON
# text, so this decodes it lazily rather than via Base's generic AUTOLOAD.
sub cached_repos {
    my $self = shift;

    return unless defined $self->data->{cached_repos};
    return decode_json( $self->data->{cached_repos} );
}

# Base::update's generic {column => value} form can't express the -json
# wrapper jsonb columns need, so this bypasses it with a targeted UPDATE.
sub refresh_cached_repos {
    my ( $self, $repos ) = @_;

    my $fetched_at = Mojo::Date->new(time)->to_datetime;

    $self->pg->db->update(
        $self->_table,
        { cached_repos => { -json => $repos }, cached_repos_fetched_at => $fetched_at },
        { id => $self->id }
    );

    $self->data->{cached_repos}            = encode_json($repos);
    $self->data->{cached_repos_fetched_at} = $fetched_at;

    return $self;
}

1;
