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
# Used directly by ProcessPluginVersion's metadata parser and the
# DependencyAllowlist/HardcodedCredentials checks to safely inspect
# submitted plugin source without executing it. It's also a transitive
# dependency of Perl::Critic below (installed into the project-local
# 'local/' lib, see its comment), but that's an implementation detail of
# how Perl::Critic happens to be installed here -- code that depends on PPI
# directly should declare it directly, not rely on riding along with
# another package's install path.
requires 'PPI';
# Provides Koha::QA::PerlCritic, used by the perl_critic check. Formerly
# had to be installed from git into a project-local 'local/' lib (with a
# finicky Perl::Tidy version-pinning dance to avoid a dependency-resolution
# race -- see git history if that ever comes back), since it wasn't on CPAN
# at all. It's a normal CPAN distribution now: a plain `cpanm --installdeps
# .` resolves it, Perl::Critic, Perl::Tidy, and File::ShareDir together in
# one dependency graph, with no special PERL5LIB or install order needed.
requires 'Koha::QA';
