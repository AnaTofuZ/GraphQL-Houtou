package GraphQL::Houtou::Schema;

use 5.014;
use strict;
use warnings;

use Moo;

use GraphQL::Houtou::Directive ();
use GraphQL::Houtou::Type::Scalar qw($Int $Float $String $Boolean $ID);
use GraphQL::Introspection qw($SCHEMA_META_TYPE);

extends 'GraphQL::Schema';

has '+types' => (
  default => sub { [ $Int, $Float, $String, $Boolean, $ID ] },
);

has '+directives' => (
  default => sub { \@GraphQL::Houtou::Directive::SPECIFIED_DIRECTIVES },
);

has '+name2type' => (
  lazy => 1,
  builder => '_build_name2type',
);

sub _build_name2type {
  my ($self) = @_;
  my @types = grep $_, (map $self->$_, qw(query mutation subscription)), $SCHEMA_META_TYPE;
  push @types, @{ $self->types || [] };

  my %name2type;
  _expand_type_houtou(\%name2type, $_) for @types;
  return \%name2type;
}

sub _expand_type_houtou {
  my ($map, $type) = @_;
  my @types;
  my $name;

  if ($type->can('of')) {
    return _expand_type_houtou($map, $type->of);
  }

  $name = $type->name if $type->can('name');
  if ($name && $map->{$name}) {
    return []
      if $map->{$name} == $type;
    return []
      if _is_builtin_scalar_pair($map->{$name}, $type);
    die "Duplicate type $name";
  }

  $map->{$name} = $type if $name;

  push @types, ($type, map @{ _expand_type_houtou($map, $_) }, @{ $type->interfaces || [] })
    if $type->isa('GraphQL::Type::Object');
  push @types, ($type, map @{ _expand_type_houtou($map, $_) }, @{ $type->get_types })
    if $type->isa('GraphQL::Type::Union');
  if (grep $type->DOES($_), qw(GraphQL::Role::FieldsInput GraphQL::Role::FieldsOutput)) {
    my $fields = $type->fields || {};
    push @types, map {
      map @{ _expand_type_houtou($map, $_->{type}) }, $_, values %{ $_->{args} || {} }
    } values %$fields;
  }

  return \@types;
}

sub _is_builtin_scalar_pair {
  my ($left, $right) = @_;
  return 0 if !$left || !$right;
  return 0 if !$left->isa('GraphQL::Type::Scalar') || !$right->isa('GraphQL::Type::Scalar');
  return 0 if !(grep { $_ eq $left->name } qw(Int Float String Boolean ID));
  return $left->name eq $right->name ? 1 : 0;
}

1;
