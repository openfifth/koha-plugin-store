package KohaPluginStore::Check::HardcodedCredentials;

use Mojo::Base 'KohaPluginStore::Check::Base', -signatures;
use File::Slurp qw(read_file);
use PPI::Document;

# Matched against a real hash key or variable *name* in the parsed source,
# not against arbitrary file text -- so a string or comment that merely
# describes something shaped like `password => "..."` (e.g. in a docstring
# or an error message) is never mistaken for an actual assignment.
my $CREDENTIAL_NAME_RE = qr/^(?:api[_-]?key|secret|token|password|passwd)$/i;

# These two are shape-based, not name-based, so a plain content scan is
# appropriate regardless of where they appear -- a real PEM block or
# AWS-key-shaped string is vanishingly unlikely to show up innocently in a
# comment or string.
my @CONTENT_PATTERNS = (
    qr/-----BEGIN (?:RSA|OPENSSH|EC|DSA) PRIVATE KEY-----/,
    qr/\bAKIA[0-9A-Z]{16}\b/,
);

sub check_name         { 'hardcoded_credentials' }
sub required            { 0 }
sub gates_certification { 1 }

sub run ($self, $extract_dir, $metadata, $context) {
    my @hits;

    for my $file ( $self->find_files( $extract_dir, qr/\.(pm|pl|tt)$/ ) ) {
        my $relative = $file;
        $relative =~ s{^\Q$extract_dir\E/?}{};

        my $content = read_file($file);
        my $hit     = _content_hit($content);

        if ( !$hit && $file =~ /\.(?:pm|pl)$/ ) {
            my $doc = PPI::Document->new( \$content );
            $hit = $doc && _credential_assignment($doc);
        }

        push @hits, $relative if $hit;
    }

    return { passed => 1, message => undef } unless @hits;
    return { passed => 0, message => 'Possible hardcoded credential(s) found in: ' . join( ', ', @hits ) };
}

sub _content_hit {
    my ($content) = @_;
    for my $pattern (@CONTENT_PATTERNS) {
        return 1 if $content =~ $pattern;
    }
    return 0;
}

# Looks for `<credential-name> => 'literal'` (a hash pair) or `$<credential-
# name> = 'literal'` (a scalar assignment) as real syntax -- comments, POD,
# and string literals that just happen to contain similar-looking text are
# never Word/Symbol tokens in the parse tree, so they're not examined here.
sub _credential_assignment {
    my ($doc) = @_;

    my $candidates = $doc->find( sub { $_[1]->isa('PPI::Token::Word') || $_[1]->isa('PPI::Token::Symbol') } ) || [];
    for my $tok (@$candidates) {
        my $name = $tok->isa('PPI::Token::Symbol') ? substr( $tok->content, 1 ) : $tok->content;
        next unless $name =~ $CREDENTIAL_NAME_RE;

        my $op = $tok->snext_sibling or next;
        next unless $op->isa('PPI::Token::Operator') && ( $op->content eq '=>' || $op->content eq '=' );

        my $value = $op->snext_sibling;
        return 1 if $value && $value->isa('PPI::Token::Quote') && length( $value->string ) >= 6;
    }
    return 0;
}

1;
