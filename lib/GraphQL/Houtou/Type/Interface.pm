package GraphQL::Houtou::Type::Interface;

use 5.014;
use strict;
use warnings;

use Moo;
use GraphQL::Houtou::Type::Library -all;
use Types::Standard -all;

extends 'GraphQL::Houtou::Type';
with qw(
  GraphQL::Role::Output
  GraphQL::Role::Composite
  GraphQL::Role::Abstract
  GraphQL::Role::Named
  GraphQL::Role::FieldsOutput
  GraphQL::Role::FieldsEither
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

has resolve_type => (is => 'ro', isa => CodeRef);

has to_doc => (
  is => 'lazy',
  builder => sub {
    my ($self) = @_;
    my @fieldlines = map {
      my ($main, @description) = @$_;
      (@description, $main);
    } $self->_make_fieldtuples($self->fields);
    return join '', map "$_\n",
      $self->_description_doc_lines($self->description),
      "interface @{[$self->name]} {",
      (map length() ? "  $_" : "", @fieldlines),
      "}";
  },
);

sub _ensure_valid_runtime_type {
  my ($self, $runtime_type_or_name, $context, $nodes, $info, $result) = @_;
  my $runtime_type = ref($runtime_type_or_name)
    ? $runtime_type_or_name
    : $context->{schema}->name2type->{$runtime_type_or_name};

  die GraphQL::Error->new(
    message => "Abstract type @{[$self->name]} must resolve to an " .
      "Object type at runtime for field @{[$info->{parent_type}->name]}." .
      "@{[$info->{field_name}]} with value $result, received '@{[$runtime_type->name]}'.",
    nodes => [ $nodes ],
  ) if !$runtime_type
      || !($runtime_type->isa('GraphQL::Type::Object') || $runtime_type->isa('GraphQL::Houtou::Type::Object'));

  die GraphQL::Error->new(
    message => "Runtime Object type '@{[$runtime_type->name]}' is not a possible type for " .
      "'@{[$self->name]}'.",
    nodes => [ $nodes ],
  ) if !$context->{schema}->is_possible_type($self, $runtime_type);

  return $runtime_type;
}

1;
