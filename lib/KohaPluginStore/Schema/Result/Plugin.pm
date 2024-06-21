use utf8;
package KohaPluginStore::Schema::Result::Plugin;

# Created by DBIx::Class::Schema::Loader
# DO NOT MODIFY THE FIRST PART OF THIS FILE

=head1 NAME

KohaPluginStore::Schema::Result::Plugin

=cut

use strict;
use warnings;

use base 'DBIx::Class::Core';

=head1 TABLE: C<plugins>

=cut

__PACKAGE__->table("plugins");

=head1 ACCESSORS

=head2 id

  data_type: 'integer'
  is_auto_increment: 1
  is_nullable: 0

=head2 plugin_class

  data_type: 'text'
  is_nullable: 1

=head2 name

  data_type: 'text'
  is_nullable: 1

=head2 description

  data_type: 'text'
  is_nullable: 1

=head2 author

  data_type: 'text'
  is_nullable: 1

=head2 thumbnail

  data_type: 'text'
  is_nullable: 1

=head2 user_id

  data_type: 'text'
  is_foreign_key: 1
  is_nullable: 1

=head2 timestamp

  data_type: 'datetime'
  default_value: current_timestamp
  is_nullable: 1

=cut

__PACKAGE__->add_columns(
  "id",
  { data_type => "integer", is_auto_increment => 1, is_nullable => 0 },
  "plugin_class",
  { data_type => "text", is_nullable => 1 },
  "name",
  { data_type => "text", is_nullable => 1 },
  "description",
  { data_type => "text", is_nullable => 1 },
  "author",
  { data_type => "text", is_nullable => 1 },
  "thumbnail",
  { data_type => "text", is_nullable => 1 },
  "user_id",
  { data_type => "text", is_foreign_key => 1, is_nullable => 1 },
  "timestamp",
  {
    data_type     => "datetime",
    default_value => \"current_timestamp",
    is_nullable   => 1,
  },
);

=head1 PRIMARY KEY

=over 4

=item * L</id>

=back

=cut

__PACKAGE__->set_primary_key("id");

=head1 UNIQUE CONSTRAINTS

=head2 C<name_unique>

=over 4

=item * L</name>

=back

=cut

__PACKAGE__->add_unique_constraint("name_unique", ["name"]);

=head2 C<plugin_class_unique>

=over 4

=item * L</plugin_class>

=back

=cut

__PACKAGE__->add_unique_constraint("plugin_class_unique", ["plugin_class"]);

=head1 RELATIONS

=head2 user

Type: belongs_to

Related object: L<KohaPluginStore::Schema::Result::User>

=cut

__PACKAGE__->belongs_to(
  "user",
  "KohaPluginStore::Schema::Result::User",
  { id => "user_id" },
  {
    is_deferrable => 0,
    join_type     => "LEFT",
    on_delete     => "CASCADE",
    on_update     => "NO ACTION",
  },
);

=head2 version

Type: might_have

Related object: L<KohaPluginStore::Schema::Result::Version>

=cut

__PACKAGE__->might_have(
  "version",
  "KohaPluginStore::Schema::Result::Version",
  { "foreign.plugin_id" => "self.id" },
  { cascade_copy => 0, cascade_delete => 0 },
);


# Created by DBIx::Class::Schema::Loader v0.07051 @ 2024-06-21 12:46:40
# DO NOT MODIFY THIS OR ANYTHING ABOVE! md5sum:Bx3XB6efUqe92Uc7KebpUw


# You can replace this text with custom code or comments, and it will be preserved on regeneration
1;
