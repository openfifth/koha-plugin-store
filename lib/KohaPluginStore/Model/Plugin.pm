package KohaPluginStore::Model::Plugin;

use Modern::Perl;
use KohaPluginStore::Model::Base;
use parent -norequire, 'KohaPluginStore::Model::Base';

use KohaPluginStore::Model::PluginVersion;

sub _table {
    return 'plugins';
}

sub _columns {
    return [qw(id repo_url name class_name description author thumbnail developer_id timestamp slug documentation_url)];
}

sub releases {
    my ($self) = @_;

    my @versions = KohaPluginStore::Model::PluginVersion->new( pg => $self->pg )->search( { plugin_id => $self->id } );
    return \@versions;
}

sub create_with_unique_slug {
    my ( $self, $slug_source, $attrs ) = @_;

    my $base = lc($slug_source);
    $base =~ s/[^a-z0-9]+/-/g;
    $base =~ s/^-+|-+$//g;

    for my $attempt ( 1 .. 10 ) {
        my $candidate = $attempt == 1 ? $base : "$base-$attempt";
        my $plugin = eval { $self->create( { %$attrs, slug => $candidate } ) };
        return $plugin if $plugin;
        die $@ unless $@ =~ /plugins_slug_key/;
    }

    die "Could not generate a unique slug for '$slug_source' after 10 attempts";
}

1;
