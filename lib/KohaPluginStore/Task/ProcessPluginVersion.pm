package KohaPluginStore::Task::ProcessPluginVersion;

use Modern::Perl;
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use File::Find;
use File::Slurp;
use String::Util 'trim';
use Archive::Zip;
use PPI::Document;

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::PluginContributor;
use KohaPluginStore::GitHub;
use KohaPluginStore::Checks;
use KohaPluginStore::Model::ReviewCheck;

use KohaPluginStore::Signing;
use KohaPluginStore::Version qw(normalize);

sub register {
    my ($app) = @_;
    $app->minion->add_task( process_plugin_version => \&run );
}

sub run {
    my ( $job, $plugin_version_id ) = @_;

    my $app = $job->app;
    my $version = KohaPluginStore::Model::PluginVersion->new( pg => $app->pg )->find( { id => $plugin_version_id } );
    die "plugin_version $plugin_version_id not found\n" unless $version;

    $version->update( { status => 'checks_running' } );

    my $plugin = KohaPluginStore::Model::Plugin->new( pg => $app->pg )->find( { id => $version->plugin_id } );

    my $config = $app->config;
    my $token  = $config->{github_app_token};

    # A plain ephemeral tempdir is enough here: perl_syntax's sandboxed
    # compile-check now runs in the separate syntax-sandbox broker service
    # (see sandbox_broker/), reached over HTTP with file *contents*, not a
    # shared bind-mount path -- so unlike before that split, nothing here
    # needs this directory to be visible to the host's Docker daemon.
    my $tmp_dir  = tempdir( CLEANUP => 1 );
    my $kpz_path = "$tmp_dir/plugin.kpz";

    my $downloaded = KohaPluginStore::GitHub::download_kpz( $token, $version->kpz_url, $kpz_path );
    unless ($downloaded) {
        $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Could not download the .kpz asset from GitHub -- it may not be publicly accessible.',
            }
        );
        return;
    }

    my $extract_dir = "$tmp_dir/extracted";
    my $zip         = Archive::Zip->new($kpz_path);
    unless ($zip) {
        $version->update(
            { status => 'changes_requested', error_message => 'The downloaded .kpz file is not a valid zip archive.' }
        );
        return;
    }
    for my $member ( $zip->members ) {
        my $name = $member->fileName;

        # Zip Slip guard: reject any entry whose path would land outside
        # $extract_dir. Nothing under $extract_dir exists yet for a
        # symlink-based trick to hide behind, so checking the raw name for a
        # leading '/' (absolute) or a literal '..' segment is sufficient --
        # no need to resolve against the filesystem.
        ( my $normalized = $name ) =~ s{\\}{/}g;
        if ( $normalized =~ m{^/} || $normalized =~ m{(?:^|/)\.\.(?:/|$)} ) {
            $version->update(
                {
                    status        => 'changes_requested',
                    error_message => "The .kpz archive contains an unsafe path ('$name').",
                }
            );
            return;
        }

        $member->extractToFileNamed("$extract_dir/$name");
    }

    my ( $plugin_class_file, $plugin_class_name ) = _find_plugin_class($extract_dir);
    unless ($plugin_class_file) {
        $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Plugin class file not found. Make sure the plugin has a class containing \'use base qw(Koha::Plugins::Base)\'.',
            }
        );
        return;
    }
    unless ($plugin_class_name) {
        $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Plugin class name not found. Make sure the plugin class file contains \'package Name;\'.',
            }
        );
        return;
    }

    my $metadata = _parse_metadata($plugin_class_file);
    unless ($metadata) {
        $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Plugin metadata not found. Make sure the plugin class contains \'our $metadata = { ... }\'.',
            }
        );
        return;
    }
    unless ( $metadata->{minimum_version} ) {
        $version->update(
            { status => 'changes_requested', error_message => 'Plugin metadata is missing \'minimum_version\'.' }
        );
        return;
    }

    my $koha_min_version = normalize( $metadata->{minimum_version} );
    unless ($koha_min_version) {
        $version->update(
            {
                status        => 'changes_requested',
                error_message => "Plugin metadata's minimum_version ('$metadata->{minimum_version}') is not a valid Koha version string.",
            }
        );
        return;
    }

    my $koha_max_version;
    if ( $metadata->{maximum_version} ) {
        $koha_max_version = normalize( $metadata->{maximum_version} );
        unless ($koha_max_version) {
            $version->update(
                {
                    status        => 'changes_requested',
                    error_message => "Plugin metadata's maximum_version ('$metadata->{maximum_version}') is not a valid Koha version string.",
                }
            );
            return;
        }
    }

    my $digest = do {
        open my $fh, '<:raw', $kpz_path or die "Could not open $kpz_path: $!";
        local $/;
        sha256_hex(<$fh>);
    };

    my $readme_html = eval { KohaPluginStore::GitHub::fetch_readme_html( $token, $plugin->repo_url ) };

    $plugin->update(
        {
            name        => $metadata->{name},
            description => $metadata->{description},
            author      => $metadata->{author},
            class_name  => $plugin_class_name,
            ( defined $readme_html ? ( readme_html => $readme_html ) : () ),
        }
    );

    my $contributors = eval { KohaPluginStore::GitHub::fetch_contributors( $token, $plugin->repo_url ) } || [];
    for my $contributor (@$contributors) {
        my $existing = KohaPluginStore::Model::PluginContributor->new( pg => $app->pg )->find(
            { plugin_id => $plugin->id, github_username => $contributor->{github_username} }
        );
        if ($existing) {
            $existing->update( { contributions_count => $contributor->{contributions_count}, fetched_at => \'now()' } );
        }
        else {
            KohaPluginStore::Model::PluginContributor->new( pg => $app->pg )->create(
                { plugin_id => $plugin->id, %$contributor }
            );
        }
    }

    my $check_context = {
        repo_url     => $plugin->repo_url,
        tag_name     => $version->tag_name,
        github_token => $token,
    };

    my $review_check_model = KohaPluginStore::Model::ReviewCheck->new( pg => $app->pg );
    my $required_failed;
    my $gating_failed;

    for my $check_class (@KohaPluginStore::Checks::ALL) {
        my $check  = $check_class->new;
        my $result = eval { $check->run( $extract_dir, $metadata, $check_context ) };
        if ($@) {
            if ( $@ =~ /^check_infrastructure_error/ ) {
                $version->update( { status => 'check_error', error_message => "$check_class: $@" } );
                return;
            }
            die $@;
        }

        $review_check_model->record(
            {
                plugin_version_id => $version->id,
                check_name        => $check->check_name,
                required          => $check->required,
                passed            => $result->{passed},
                message           => $result->{message},
            }
        );

        if ( !$result->{passed} ) {
            $required_failed = 1 if $check->required;
            $gating_failed   = 1 if $check->gates_certification;
        }
    }

    if ($required_failed) {
        $version->update(
            {
                status             => 'changes_requested',
                certification_tier => 'INCOMPLETE',
                error_message      => 'One or more required checks failed.',
            }
        );
        return;
    }

    # Update the in-memory object first (no DB write yet) so build_manifest reads the
    # values this call is about to persist, rather than stale pre-publish data.
    $version->content_digest($digest);
    $version->version( $metadata->{version} );

    my $manifest = KohaPluginStore::Signing::build_manifest( $plugin, $version );
    my $json     = KohaPluginStore::Signing::canonical_json($manifest);

    my $key_path = $app->config->{signing_key_path};
    open my $key_fh, '<', $key_path or die "Could not read signing key at $key_path: $!\n";
    my $private_key_pem = do { local $/; <$key_fh> };
    close $key_fh;

    my $signature = KohaPluginStore::Signing::sign( $json, $private_key_pem );

    $version->update(
        {
            status             => 'published',
            content_digest     => $digest,
            version            => $metadata->{version},
            koha_min_version   => $koha_min_version,
            koha_max_version   => $koha_max_version,
            certification_tier => $gating_failed ? 'STRUCTURAL' : 'CERTIFIED',
            signed_manifest    => $json,
            signature          => $signature,
        }
    );

    return;
}

sub _find_plugin_class {
    my ($plugin_dir) = @_;

    return unless -d $plugin_dir;

    my $plugin_class_file;
    my $plugin_class_name;

    find(
        {
            wanted => sub {
                return unless -f $_ && -T _;
                open my $fh, '<', $_ or die "Could not open file: $!";
                while ( my $line = <$fh> ) {
                    $line = trim($line);
                    if ( $line =~ /use (?:base|parent)/ && $line =~ /Koha::Plugins::Base/ ) {
                        $plugin_class_file = $File::Find::name;

                        open my $class_fh, '<', $plugin_class_file or die "Could not open file: $plugin_class_file";
                        while ( my $class_line = <$class_fh> ) {
                            if ( $class_line =~ /^package/ ) {
                                $plugin_class_name = $class_line;
                                $plugin_class_name =~ s/^package\s+//;
                                $plugin_class_name =~ s/;$//;
                                $plugin_class_name =~ s/\s+//g;
                            }
                        }
                        close $class_fh;
                        last;
                    }
                }
                close $fh;
            },
            no_chdir => 1,
        },
        $plugin_dir
    );

    return ( $plugin_class_file, $plugin_class_name );
}

sub _parse_metadata {
    my ($plugin_class_file) = @_;

    return unless $plugin_class_file;

    # PPI is a pure lexer/parser -- it never executes the code it reads (and
    # doesn't even need the modules it references to be installed), unlike
    # the string eval() this used to run on regex-extracted text. It also
    # correctly understands Perl's actual grammar (comments, heredocs,
    # nested structures, ...), so a stray quote character inside a comment
    # can't desync a parse the way a from-scratch text scanner's quote
    # tracking could.
    my $doc = PPI::Document->new($plugin_class_file);
    return unless $doc;

    my $constructor = _find_metadata_constructor($doc);
    return unless $constructor;

    my %metadata;
    _extract_hash_pairs( $constructor, $doc, \%metadata );

    return unless %metadata;
    return \%metadata;
}

# Finds the `{ ... }` hash-literal constructor on the right-hand side of
# `our $metadata = { ... };` anywhere in the document.
sub _find_metadata_constructor {
    my ($doc) = @_;

    my $variables = $doc->find('PPI::Statement::Variable') || [];
    for my $stmt (@$variables) {
        next unless $stmt->type eq 'our';
        my @vars = $stmt->variables;
        next unless @vars == 1 && $vars[0] eq '$metadata';

        my ($constructor) = grep { $_->isa('PPI::Structure::Constructor') } $stmt->schildren;
        return $constructor if $constructor && $constructor->start->content eq '{';
    }
    return;
}

# Splits the constructor's contents into key => value groups on top-level
# commas and resolves each value that's safe to resolve -- see
# _resolve_value_tokens for what "safe" means here. Anything else (a
# do{} block, a method call, string concatenation, a ternary, ...) is
# silently skipped rather than executed, the same fail-safe behaviour as
# any other malformed/missing metadata field run() already validates for
# below.
sub _extract_hash_pairs {
    my ( $constructor, $doc, $metadata ) = @_;

    my @kids = $constructor->schildren;
    return unless @kids;

    my @tokens = $kids[0]->isa('PPI::Statement') ? $kids[0]->children : @kids;

    my @groups = ( [] );
    for my $tok (@tokens) {
        next if $tok->isa('PPI::Token::Whitespace') || $tok->isa('PPI::Token::Comment');
        if ( $tok->isa('PPI::Token::Operator') && $tok->content eq ',' ) {
            push @groups, [];
            next;
        }
        push @{ $groups[-1] }, $tok;
    }

    for my $group (@groups) {
        next unless @$group;
        my ( $key_tok, $fat_comma, @value_toks ) = @$group;
        next unless $fat_comma && $fat_comma->isa('PPI::Token::Operator') && $fat_comma->content eq '=>';

        my $key = _bareword_or_string($key_tok);
        next unless defined $key;

        my $value = _resolve_value_tokens( \@value_toks, $doc );
        next unless defined $value;

        $metadata->{$key} = $value;
    }
}

sub _bareword_or_string {
    my ($tok) = @_;
    return unless $tok;
    return $tok->content if $tok->isa('PPI::Token::Word');
    return $tok->string  if $tok->isa('PPI::Token::Quote');
    return;
}

# Resolves a value that's exactly one recognised token: a quoted string, a
# number, or a bare scalar variable (resolved against its own plain literal
# assignment elsewhere in the document, one level deep). Anything spanning
# more than one token, or a token type not listed here, is deliberately
# left unresolved.
sub _resolve_value_tokens {
    my ( $value_toks, $doc ) = @_;
    return unless @$value_toks == 1;

    my ($tok) = @$value_toks;

    return $tok->string  if $tok->isa('PPI::Token::Quote');
    return $tok->literal if $tok->isa('PPI::Token::Number');

    if ( $tok->isa('PPI::Token::Symbol') ) {
        return _resolve_symbol( $tok->content, $doc );
    }

    return;
}

sub _resolve_symbol {
    my ( $symbol, $doc ) = @_;

    my $variables = $doc->find('PPI::Statement::Variable') || [];
    for my $stmt (@$variables) {
        my @vars = $stmt->variables;
        next unless @vars == 1 && $vars[0] eq $symbol;

        my @kids = grep { !$_->isa('PPI::Token::Whitespace') && !$_->isa('PPI::Token::Structure') } $stmt->schildren;
        my $rhs = $kids[-1];
        return $rhs->string  if $rhs && $rhs->isa('PPI::Token::Quote');
        return $rhs->literal if $rhs && $rhs->isa('PPI::Token::Number');
    }
    return;
}

1;
