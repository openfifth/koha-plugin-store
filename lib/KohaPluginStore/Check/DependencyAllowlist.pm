package KohaPluginStore::Check::DependencyAllowlist;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use PPI::Document;

# PPI parses real Perl structure rather than scanning raw text, so a mention
# of `system(` in a comment, POD, or a string literal no longer false-
# positives, and `$self->system()`/`sub system {...}`/`system => 1` are
# correctly told apart from an actual call to the system() builtin.
my @RISKY_MODULES = (
    [ qr/^IO::Socket(?:::|$)/,       'opens sockets (IO::Socket)' ],
    [ qr/^Net::/,                    'uses a Net:: networking module' ],
    [ qr/^(?:LWP|HTTP::Tiny)(?:::|$)/, 'makes HTTP requests' ],
);

my %RISKY_CALLS = (
    system => 'calls system()',
    exec   => 'calls exec()',
);

sub check_name         { 'dependency_allowlist' }
sub required            { 1 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @issues;

    for my $file ( $self->find_files( $extract_dir, qr/\.(pm|pl)$/ ) ) {
        my $relative = $file;
        $relative =~ s{^\Q$extract_dir\E/?}{};

        my $doc = PPI::Document->new($file);
        unless ($doc) {
            push @issues, "$relative: could not be parsed as Perl";
            next;
        }

        push @issues, "$relative: $_" for _find_issues($doc);
    }

    return { passed => 1, message => undef } unless @issues;
    return { passed => 0, message => join( '; ', @issues ) };
}

sub _find_issues {
    my ($doc) = @_;
    my @issues;

    for my $inc ( @{ $doc->find('PPI::Statement::Include') || [] } ) {
        my $module = $inc->module // next;
        for my $pattern (@RISKY_MODULES) {
            my ( $re, $description ) = @$pattern;
            push @issues, $description if $module =~ $re;
        }
    }

    for my $tok ( @{ $doc->find('PPI::Token::Word') || [] } ) {
        my $description = $RISKY_CALLS{ $tok->content } or next;
        next if _is_method_call($tok) || _is_sub_definition($tok) || _is_hash_key($tok);
        push @issues, $description;
    }

    push @issues, 'uses backticks' if @{ $doc->find('PPI::Token::QuoteLike::Backtick') || [] };
    push @issues, 'uses qx//'      if @{ $doc->find('PPI::Token::QuoteLike::Command') || [] };

    for my $tok ( @{ $doc->find('PPI::Token::Word') || [] } ) {
        next unless $tok->content eq 'open';
        next if _is_method_call($tok) || _is_hash_key($tok);
        push @issues, 'opens an absolute filesystem path' if _open_has_absolute_path($tok);
    }

    my $quote_like = $doc->find( sub { $_[1]->isa('PPI::Token::Quote') || $_[1]->isa('PPI::Token::QuoteLike::Words') } ) || [];
    for my $tok (@$quote_like) {
        if ( $tok->can('string') && $tok->string =~ m{\.\./} ) {
            push @issues, "references a path outside its own directory (../)";
            last;
        }
    }

    my %seen;
    return grep { !$seen{$_}++ } @issues;
}

sub _is_method_call {
    my ($tok) = @_;
    my $prev = $tok->sprevious_sibling;
    return $prev && $prev->isa('PPI::Token::Operator') && $prev->content eq '->';
}

sub _is_sub_definition {
    my ($tok) = @_;
    my $prev = $tok->sprevious_sibling;
    return $prev && $prev->isa('PPI::Token::Word') && $prev->content eq 'sub';
}

sub _is_hash_key {
    my ($tok) = @_;
    my $next = $tok->snext_sibling;
    return $next && $next->isa('PPI::Token::Operator') && $next->content eq '=>';
}

sub _open_has_absolute_path {
    my ($tok) = @_;
    my $next = $tok->snext_sibling;
    return 0 unless $next && $next->isa('PPI::Structure::List');
    for my $quote ( @{ $next->find('PPI::Token::Quote') || [] } ) {
        return 1 if $quote->string =~ m{^/};
    }
    return 0;
}

1;
