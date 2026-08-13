package KohaPluginStore::Task::ProcessPluginVersion;

use Modern::Perl;
use Digest::SHA qw(sha256_hex);
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Find;
use File::Slurp;
use String::Util 'trim';
use Archive::Zip;

use KohaPluginStore::Model::Plugin;
use KohaPluginStore::Model::PluginVersion;
use KohaPluginStore::Model::PluginContributor;
use KohaPluginStore::GitHub;
use KohaPluginStore::Checks;
use KohaPluginStore::Model::ReviewCheck;

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

    # PerlSyntax's check bind-mounts $extract_dir into a sandbox container via
    # the HOST's Docker daemon (docker-compose mounts the host socket into
    # this worker, rather than running a nested dockerd) -- Docker resolves
    # bind-mount sources against the true host filesystem, not this
    # container's own private one, so a tempdir() under the default /tmp
    # (invisible outside this container) would silently bind-mount an empty
    # directory. /app/tmp is safe because docker-compose.yml already bind-
    # mounts the whole worktree at /app, so paths under it are identical on
    # the host and in here.
    my $sandbox_scratch_dir = '/app/tmp';
    make_path($sandbox_scratch_dir) unless -d $sandbox_scratch_dir;
    my $tmp_dir  = tempdir( DIR => $sandbox_scratch_dir, CLEANUP => 1 );
    my $kpz_path = "$tmp_dir/plugin.kpz";

    my $downloaded = KohaPluginStore::GitHub::download_kpz( $token, $version->kpz_url, $kpz_path );
    unless ($downloaded) {
        return $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Could not download the .kpz asset from GitHub -- it may not be publicly accessible.',
            }
        );
    }

    my $extract_dir = "$tmp_dir/extracted";
    my $zip         = Archive::Zip->new($kpz_path);
    unless ($zip) {
        return $version->update(
            { status => 'changes_requested', error_message => 'The downloaded .kpz file is not a valid zip archive.' }
        );
    }
    for my $member ( $zip->members ) {
        $member->extractToFileNamed( "$extract_dir/" . $member->fileName );
    }

    my ( $plugin_class_file, $plugin_class_name ) = _find_plugin_class($extract_dir);
    unless ($plugin_class_file) {
        return $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Plugin class file not found. Make sure the plugin has a class containing \'use base qw(Koha::Plugins::Base)\'.',
            }
        );
    }
    unless ($plugin_class_name) {
        return $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Plugin class name not found. Make sure the plugin class file contains \'package Name;\'.',
            }
        );
    }

    my $metadata = _parse_metadata($plugin_class_file);
    unless ($metadata) {
        return $version->update(
            {
                status        => 'changes_requested',
                error_message => 'Plugin metadata not found. Make sure the plugin class contains \'our $metadata = { ... }\'.',
            }
        );
    }
    unless ( $metadata->{minimum_version} ) {
        return $version->update(
            { status => 'changes_requested', error_message => 'Plugin metadata is missing \'minimum_version\'.' }
        );
    }

    my $digest = do {
        open my $fh, '<:raw', $kpz_path or die "Could not open $kpz_path: $!";
        local $/;
        sha256_hex(<$fh>);
    };

    $plugin->update(
        {
            name        => $metadata->{name},
            description => $metadata->{description},
            author      => $metadata->{author},
            class_name  => $plugin_class_name,
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
                return $version->update( { status => 'check_error', error_message => "$check_class: $@" } );
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
        return $version->update(
            {
                status             => 'changes_requested',
                certification_tier => 'INCOMPLETE',
                error_message      => 'One or more required checks failed.',
            }
        );
    }

    $version->update(
        {
            status             => 'published',
            content_digest     => $digest,
            version            => $metadata->{version},
            koha_min_version   => $metadata->{minimum_version},
            certification_tier => $gating_failed ? 'STRUCTURAL' : 'CERTIFIED',
        }
    );
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

    my $metadata_contents = read_file($plugin_class_file);
    my $plugin_metadata;

    if ( $metadata_contents =~ /our \$metadata = (\{.*?\});(?!\w)/si ) {
        my $extracted_metadata = $1;
        my $metadata_variables;
        while ( $extracted_metadata =~ /\$([a-zA-Z_]+)\b/g ) {
            my $variable = $1;
            if ( $metadata_contents =~ /(our \$$variable.*?= .*?;)/si ) {
                my $value = $1;
                $value =~ s/our \$$variable.*?= //;
                $value =~ s/;//;
                $value = trim($value);
                $metadata_variables->{ '$' . $variable } = $value;
            }
        }

        for my $key ( keys %$metadata_variables ) {
            $extracted_metadata =~ s/\Q$key\E/$metadata_variables->{$key}/;
        }

        eval( '$plugin_metadata = ' . $extracted_metadata . ';' );
        if ($@) {
            warn "Error evaluating metadata: $@";
        }
    }

    return unless ref($plugin_metadata) eq 'HASH' && scalar keys %$plugin_metadata > 0;
    return $plugin_metadata;
}

1;
