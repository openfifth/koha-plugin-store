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
# Sanitizes GitHub-rendered README/changelog HTML before it's stored --
# see KohaPluginStore::Sanitize.
requires 'HTML::Scrubber';
# Used directly by ProcessPluginVersion's metadata parser and the
# DependencyAllowlist/HardcodedCredentials checks to safely inspect
# submitted plugin source without executing it. It's also a transitive
# dependency of Perl::Critic below (installed into the project-local
# 'local/' lib, see its comment), but that's an implementation detail of
# how Perl::Critic happens to be installed here -- code that depends on PPI
# directly should declare it directly, not rely on riding along with
# another package's install path.
requires 'PPI';
# Koha::QA's own Makefile.PL needs Module::CPANfile to run at all, but its
# META.json doesn't declare that as a configure-time dependency -- cpanm has
# no way to know to install this first unless we say so ourselves. Without
# it: "Can't locate Module/CPANfile.pm ... at Makefile.PL line 3."
requires 'Module::CPANfile';
# The exact-version pin the old "install from git into a project-local
# local/" approach used to need is back: Koha::QA's own cpanfile requires
# Perl::Tidy == 20250105 exactly, but cpanm resolves the newest Perl::Tidy
# release first when nothing else constrains it -- once that newer version
# is already installed, Koha::QA's own configure step refuses to proceed
# ("Installed version (...) of Perl::Tidy is not in range '== 20250105'").
# Declaring the pin directly here forces cpanm to satisfy it before it ever
# gets to Koha::QA.
requires 'Perl::Tidy', '== 20250105';
# Provides Koha::QA::PerlCritic, used by the perl_critic check. A normal CPAN
# distribution (not installed from git), but -- see the two requires above --
# not one `cpanm --installdeps .` can resolve unassisted.
requires 'Koha::QA';
