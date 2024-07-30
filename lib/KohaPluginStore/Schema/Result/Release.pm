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

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 plugin_id

  data_type: 'integer'
  is_foreign_key: 1
  is_nullable: 1

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
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "plugin_id",
  { data_type => "integer", is_foreign_key => 1, is_nullable => 1 },
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

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 RELATIONS

=head2 plugin

Type: belongs_to

Related object: L<KohaPluginStore::Schema::Result::Plugin>

=cut

__PACKAGE__->belongs_to(
  "plugin",
  "KohaPluginStore::Schema::Result::Plugin",
  { id => "plugin_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "CASCADE",
    on_update     => "NO ACTION",
  },
);


# Created by DBIx::Class::Schema::Loader v0.07051 @ 2024-07-30 15:44:37
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:2MRRl9aM6+2gpUgZh/yUlA

sub object_class {
    'KohaPluginStore::Model::Release';
}

1;
