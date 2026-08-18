package KohaPluginStore::Version;

use Modern::Perl;
use Exporter 'import';

our @EXPORT_OK = qw(normalize);

=head1 NAME

KohaPluginStore::Version

=head1 API

=head2 Functions

=head3 normalize

    my $canonical = normalize('23.11');
    # '23.11.00.000'

Parses a Koha version string the same way Koha core's own
C<Koha::Plugins::Base::_version_compare> does (split on C<. + : ~ ->, zero-pad missing
trailing segments), then renders it as a fixed-width C<MM.mm.pp.bbb> string safe for a
plain C<TEXT> comparison in SQL. Returns C<undef> -- never dies -- if C<$string> isn't a
dotted-numeric version: empty/undef, a non-numeric segment, or more than 4 segments.

=cut

sub normalize {
    my ($string) = @_;
    return unless defined $string && length $string;

    my @parts = split /[.+:~-]/, $string;
    return unless @parts;
    return if @parts > 4;
    return if grep { !/^\d+$/ } @parts;

    push @parts, 0 while @parts < 4;

    return sprintf( '%02d.%02d.%02d.%03d', @parts );
}

1;
