package KohaPluginStore::Checks;

use Modern::Perl;

use KohaPluginStore::Check::PerlSyntax;
use KohaPluginStore::Check::ManifestCompleteness;
use KohaPluginStore::Check::DependencyAllowlist;
use KohaPluginStore::Check::PerlCritic;
use KohaPluginStore::Check::DocsPresence;
use KohaPluginStore::Check::ReadmePresence;
use KohaPluginStore::Check::ChangelogFormat;
use KohaPluginStore::Check::TestsPresence;
use KohaPluginStore::Check::TranslatableTemplates;
use KohaPluginStore::Check::PluginTemplateWrapper;
use KohaPluginStore::Check::HardcodedCredentials;
use KohaPluginStore::Check::KohaMaxVersion;
use KohaPluginStore::Check::GpgSignedTag;

our @ALL = qw(
    KohaPluginStore::Check::PerlSyntax
    KohaPluginStore::Check::ManifestCompleteness
    KohaPluginStore::Check::DependencyAllowlist
    KohaPluginStore::Check::PerlCritic
    KohaPluginStore::Check::DocsPresence
    KohaPluginStore::Check::ReadmePresence
    KohaPluginStore::Check::ChangelogFormat
    KohaPluginStore::Check::TestsPresence
    KohaPluginStore::Check::TranslatableTemplates
    KohaPluginStore::Check::PluginTemplateWrapper
    KohaPluginStore::Check::HardcodedCredentials
    KohaPluginStore::Check::KohaMaxVersion
    KohaPluginStore::Check::GpgSignedTag
);

1;
