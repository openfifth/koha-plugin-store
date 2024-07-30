use utf8;
package KohaPluginStore::Schema::Result::Release;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

KohaPluginStore::Schema::Result::Release

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<releases>

=cut

__PACKAGE__->table("releases");

=head1 ACCESSORS

=head2 plugin_id

  data_type: 'integer'
  is_auto_increment: 1
  is_foreign_key: 1
  is_nullable: 0

=head2 name

  data_type: 'text'
  is_nullable: 1

=head2 version

  data_type: 'text'
  is_nullable: 1

=head2 koha_max_version

  data_type: 'text'
  is_nullable: 1

=head2 date_released

  data_type: 'datetime'
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "plugin_id",
  {
    data_type         => "integer",
    is_auto_increment => 1,
    is_foreign_key    => 1,
    is_nullable       => 0,
  },
  "name",
  { data_type => "text", is_nullable => 1 },
  "version",
  { data_type => "text", is_nullable => 1 },
  "koha_max_version",
  { data_type => "text", is_nullable => 1 },
  "date_released",
  { data_type => "datetime", is_nullable => 1 },
);

=head1 PRIMARY KEY

=over 4

=item * L</plugin_id>

=back

=cut

__PACKAGE__->set_primary_key("plugin_id");

=head1 RELATIONS

=head2 plugin

Type: belongs_to

Related object: L<KohaPluginStore::Schema::Result::Plugin>

=cut

__PACKAGE__->belongs_to(
  "plugin",
  "KohaPluginStore::Schema::Result::Plugin",
  { id => "plugin_id" },
  { is_deferrable => 0, on_delete => "CASCADE", on_update => "NO ACTION" },
);


# Created by DBIx::Class::Schema::Loader v0.07051 @ 2024-07-30 12:58:38
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:B70AXbpFC7aGmRm/1CBpoQ


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
