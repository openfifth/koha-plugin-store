use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use lib 't/lib';
use TestDB qw(reset_db test_app);

reset_db();

my $t = test_app();

subtest 'renders every check name, organized by tier' => sub {
    $t->get_ok('/developers/checks')
      ->status_is(200)
      ->content_like(qr/Required checks/)
      ->content_like(qr/Certification-gating checks/)
      ->content_like(qr/Informational checks/)
      ->content_like(qr/perl_syntax/)
      ->content_like(qr/manifest_completeness/)
      ->content_like(qr/dependency_allowlist/)
      ->content_like(qr/perl_critic/)
      ->content_like(qr/docs_presence/)
      ->content_like(qr/readme_presence/)
      ->content_like(qr/changelog_format/)
      ->content_like(qr/tests_presence/)
      ->content_like(qr/translatable_templates/)
      ->content_like(qr/plugin_template_wrapper/)
      ->content_like(qr/hardcoded_credentials/)
      ->content_like(qr/koha_max_version/)
      ->content_like(qr/gpg_signed_tag/)
      ->content_like(qr/keepachangelog\.com/)
      ->content_like(qr/common-changelog\.org/);
};

subtest 'linked from the developers pitch page and a plugin\'s technical report' => sub {
    $t->get_ok('/developers')->element_exists('a[href="/developers/checks"]');
};

done_testing();
