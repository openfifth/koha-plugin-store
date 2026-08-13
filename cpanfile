requires 'Modern::Perl';
requires 'Mojolicious';
requires 'Mojolicious::Plugin::OpenAPI';
requires 'Mojo::Pg';
requires 'Mojolicious::Plugin::OAuth2';
requires 'Minion';
requires 'JSON';
requires 'Archive::Zip';
requires 'Digest::SHA';
requires 'CryptX';
requires 'String::Util';
requires 'IO::Socket::SSL';
requires 'Net::SSLeay';
requires 'File::Slurp';
# Koha::QA isn't on CPAN, and plain `cpanm --installdeps` ignores this line's
# git=>/ref=> meta entirely (it always does a bare CPAN name lookup, which
# fails) -- it must be installed explicitly, to a project-local 'local/'
# directory, via:
#   cpanm --notest Module::CPANfile File::ShareDir::Install       # its Makefile.PL needs these to configure
#   cpanm -L local --force Perl::Tidy@20250105 Perl::Critic       # pin *inside* -L local first, see below
#   cpanm -L local --force https://gitlab.com/joubu/koha-qa.git@c98c2cd6ac14756fd82edc59655b54e11c8c9f31
# Its Makefile.PL also needs `yarn` on PATH (builds share/ assets via a
# js-deps Makefile target) and pins an exact Perl::Tidy version -- installing
# Perl::Critic (also required below) *without* that pin already present
# inside the same -L local lib pulls whatever Perl::Tidy is newest and fails
# koha-qa's own version check. This raced in practice: pinning Perl::Tidy
# site-wide first was NOT reliably visible to the -L local install, so pin
# both Perl::Tidy and Perl::Critic inside -L local, immediately before the
# koha-qa install itself (see Dockerfile for the exact sequence, verified
# deterministic over repeated runs).
# All prove/app/minion-worker runs must be prefixed with: PERL5LIB="$(pwd)/local/lib/perl5:$PERL5LIB"
requires 'Koha::QA', git => 'https://gitlab.com/joubu/koha-qa.git', ref => 'c98c2cd6ac14756fd82edc59655b54e11c8c9f31';
requires 'Perl::Critic';
requires 'File::ShareDir';
