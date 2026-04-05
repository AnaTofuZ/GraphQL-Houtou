package GraphQL::Houtou::Role::Abstract;

use 5.014;
use strict;
use warnings;

use Moo::Role;

use GraphQL::Error ();

# Runtime completion helpers for interfaces and unions.

sub _complete_value {
  my ($self, $context, $nodes, $info, $path, $result) = @_;
  my $resolve_type = $self->resolve_type || \&_default_resolve_type;
  my $runtime_type = $resolve_type->(
    $result, $context->{context_value}, $info, $self
  );

  return $self->_ensure_valid_runtime_type(
    $runtime_type,
    $context,
    $nodes,
    $info,
    $result,
  )->_complete_value(@_);
}

sub _ensure_valid_runtime_type {
  my ($self, $runtime_type_or_name, $context, $nodes, $info, $result) = @_;
  my $runtime_type = ref($runtime_type_or_name)
    ? $runtime_type_or_name
    : $context->{schema}->name2type->{$runtime_type_or_name};

  die GraphQL::Error->new(
    message => "Abstract type @{[$self->name]} must resolve to an " .
      "Object type at runtime for field @{[$info->{parent_type}->name]}." .
      "@{[$info->{field_name}]} with value $result, received '" .
      ($runtime_type ? $runtime_type->name : 'undef') . "'.",
    nodes => [ $nodes ],
  ) if !$runtime_type
      || !($runtime_type->isa('GraphQL::Houtou::Type::Object')
        || $runtime_type->isa('GraphQL::Type::Object'));

  die GraphQL::Error->new(
    message => "Runtime Object type '@{[$runtime_type->name]}' is not a possible type for " .
      "'@{[$self->name]}'.",
    nodes => [ $nodes ],
  ) if !$context->{schema}->is_possible_type($self, $runtime_type);

  return $runtime_type;
}

sub _default_resolve_type {
  my ($value, $context, $info, $abstract_type) = @_;
  my @possibles = @{ $info->{schema}->get_possible_types($abstract_type) };
  return (grep { $_->is_type_of->($value, $context, $info) } grep { $_->is_type_of } @possibles)[0];
}

1;
