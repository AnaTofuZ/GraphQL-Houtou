package GraphQL::Houtou::Type::Object;

use 5.014;
use strict;
use warnings;

use Moo;
use GraphQL::Houtou::Type::Library -all;
use Types::Standard -all;

extends 'GraphQL::Houtou::Type';
with qw(
  GraphQL::Houtou::Role::Output
  GraphQL::Houtou::Role::Composite
  GraphQL::Houtou::Role::Named
  GraphQL::Houtou::Role::FieldsOutput
  GraphQL::Houtou::Role::HashMappable
);

sub list {
  require GraphQL::Houtou::Type::List;
  $_[0]->{_houtou_list} ||= GraphQL::Houtou::Type::List->new(of => $_[0]);
}

sub non_null {
  require GraphQL::Houtou::Type::NonNull;
  $_[0]->{_houtou_non_null} ||= GraphQL::Houtou::Type::NonNull->new(of => $_[0]);
}

use constant DEBUG => $ENV{GRAPHQL_DEBUG};

has interfaces => (is => 'ro', isa => ArrayRef[Object], default => sub { [] });
has is_type_of => (is => 'ro', isa => CodeRef);

sub graphql_to_perl {
  my ($self, $item) = @_;
  my $fields = $self->fields;

  return $item if !defined $item;
  $item = $self->uplift($item);
  return $self->hashmap($item, $fields, sub {
    my ($key, $value) = @_;
    return $fields->{$key}{type}->graphql_to_perl($value // $fields->{$key}{default_value});
  });
}

has to_doc => (
  is => 'lazy',
  builder => sub {
    my ($self) = @_;
    my @fieldlines = map {
      my ($main, @description) = @$_;
      (@description, $main);
    } $self->_make_fieldtuples($self->fields);
    my $implements = join ' & ', map $_->name, @{ $self->interfaces || [] };
    $implements &&= 'implements ' . $implements . ' ';
    return join '', map "$_\n",
      $self->_description_doc_lines($self->description),
      "type @{[$self->name]} $implements\{",
      (map length() ? "  $_" : "", @fieldlines),
      "}";
  },
);

1;
