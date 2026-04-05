package GraphQL::Houtou::Schema;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use Moo;
use Types::Standard qw(HashRef Object ArrayRef);

use GraphQL::Houtou::Directive ();
use GraphQL::Houtou::Type::Library qw(StrNameValid);
use GraphQL::Houtou::Type::Scalar qw($Int $Float $String $Boolean $ID);
use GraphQL::Houtou::Introspection qw($SCHEMA_META_TYPE);

our @EXPORT_OK = qw(lookup_type);

has query => (
  is => 'ro',
  isa => Object,
  required => 1,
);

has mutation => (
  is => 'ro',
  isa => Object,
);

has subscription => (
  is => 'ro',
  isa => Object,
);

has types => (
  is => 'ro',
  isa => ArrayRef,
  default => sub { [ $Int, $Float, $String, $Boolean, $ID ] },
);

has directives => (
  is => 'ro',
  isa => ArrayRef,
  default => sub { \@GraphQL::Houtou::Directive::SPECIFIED_DIRECTIVES },
);

has name2type => (
  is => 'lazy',
  isa => HashRef,
);

has name2directive => (
  is => 'lazy',
  isa => HashRef,
  builder => '_build_name2directive',
);

has _interface2types => (
  is => 'lazy',
  isa => HashRef,
  builder => '_build__interface2types',
);

has _possible_type_map => (
  is => 'rw',
  isa => HashRef,
);

sub _build_name2type {
  my ($self) = @_;
  my @types = grep $_, (map $self->$_, qw(query mutation subscription)), $SCHEMA_META_TYPE;
  push @types, @{ $self->types || [] };

  my %name2type;
  _expand_type_houtou(\%name2type, $_) for @types;
  return \%name2type;
}

sub _does_any_role {
  my ($type, @roles) = @_;
  return if !$type || !$type->can('DOES');
  return !!grep { $type->DOES($_) } @roles;
}

sub _build_name2directive {
  my ($self) = @_;
  return +{ map { ($_->name => $_) } @{ $self->directives || [] } };
}

sub _build__interface2types {
  my ($self) = @_;
  my $name2type = $self->name2type || {};
  my %interface2types;

  for my $type (values %$name2type) {
    next if !($type->isa('GraphQL::Type::Object') || $type->isa('GraphQL::Houtou::Type::Object'));
    push @{ $interface2types{ $_->name } }, $type for @{ $type->interfaces || [] };
  }

  return \%interface2types;
}

sub get_possible_types {
  my ($self, $abstract_type) = @_;
  return $abstract_type->get_types
    if $abstract_type->isa('GraphQL::Type::Union') || $abstract_type->isa('GraphQL::Houtou::Type::Union');
  return $self->_interface2types->{ $abstract_type->name } || [];
}

sub is_possible_type {
  my ($self, $abstract_type, $possible_type) = @_;
  my $map = $self->_possible_type_map || {};
  my @possibles;

  return $map->{$abstract_type->name}{$possible_type->name}
    if $map->{$abstract_type->name};

  @possibles = @{ $self->get_possible_types($abstract_type) || [] };
  die <<"EOF" if !@possibles;
Could not find possible implementing types for @{[$abstract_type->name]}
in schema. Check that schema.types is defined and is an array of
all possible types in the schema.
EOF
  $map->{$abstract_type->name} = { map { ($_->name => 1) } @possibles };
  $self->_possible_type_map($map);
  return $map->{$abstract_type->name}{$possible_type->name};
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
    if $type->isa('GraphQL::Type::Object') || $type->isa('GraphQL::Houtou::Type::Object');
  push @types, ($type, map @{ _expand_type_houtou($map, $_) }, @{ $type->get_types })
    if $type->isa('GraphQL::Type::Union') || $type->isa('GraphQL::Houtou::Type::Union');
  if (_does_any_role($type, qw(
    GraphQL::Houtou::Role::FieldsInput
    GraphQL::Houtou::Role::FieldsOutput
    GraphQL::Role::FieldsInput
    GraphQL::Role::FieldsOutput
  ))) {
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
  return 0 if !(
    ($left->isa('GraphQL::Type::Scalar') || $left->isa('GraphQL::Houtou::Type::Scalar'))
    && ($right->isa('GraphQL::Type::Scalar') || $right->isa('GraphQL::Houtou::Type::Scalar'))
  );
  return 0 if !(grep { $_ eq $left->name } qw(Int Float String Boolean ID));
  return $left->name eq $right->name ? 1 : 0;
}

sub lookup_type {
  my ($typedef, $name2type) = @_;
  my ($type, $wrapper_type, $wrapped);

  die "lookup_type expects a type definition hash reference\n"
    if ref($typedef) ne 'HASH';
  die "lookup_type expects a name2type hash reference\n"
    if ref($name2type) ne 'HASH';

  $type = $typedef->{type};
  die "Undefined type given\n" if !defined $type;

  if (!ref($type)) {
    return $name2type->{$type} // die "Unknown type '$type'.\n";
  }

  if (ref($type) ne 'ARRAY') {
    die "Unknown wrapped type representation\n";
  }

  ($wrapper_type, $wrapped) = @$type;
  return lookup_type($wrapped, $name2type)->$wrapper_type;
}

1;
