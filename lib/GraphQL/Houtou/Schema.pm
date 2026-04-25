package GraphQL::Houtou::Schema;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use Moo;
use Types::Standard qw(HashRef Object ArrayRef);

use GraphQL::Houtou::Directive ();
use GraphQL::Houtou::Runtime ();
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

sub prepare_runtime {
  my ($self) = @_;
  return $self->_runtime_cache;
}

sub compile_runtime {
  my ($self, %opts) = @_;
  return GraphQL::Houtou::Runtime::compile_schema($self, %opts);
}

sub compile_runtime_graph {
  my ($self, %opts) = @_;
  return $self->compile_runtime(%opts);
}

sub compile_runtime_descriptor {
  my ($self, %opts) = @_;
  return $self->compile_runtime(%opts)->to_struct;
}

sub inflate_runtime {
  my ($self, $descriptor) = @_;
  return GraphQL::Houtou::Runtime::inflate_schema($self, $descriptor);
}

sub runtime_cache {
  my ($self) = @_;
  return $self->{_runtime_cache};
}

sub clear_runtime_cache {
  my ($self) = @_;
  delete $self->{_runtime_cache};
  return $self;
}

sub _runtime_cache {
  my ($self) = @_;
  return $self->{_runtime_cache} if $self->{_runtime_cache};

  my $name2type = $self->name2type || {};
  my $interface2types = $self->_interface2types || {};
  my $possible_type_map = { %{ $self->_possible_type_map || {} } };
  my %possible_types;
  my %field_maps;
  my %resolve_type_map;
  my %is_type_of_map;
  my %tag_resolver_map;
  my %runtime_tag_map;

  for my $type (values %$name2type) {
    next if !$type;

    if (_does_any_role($type, qw(
      GraphQL::Houtou::Role::FieldsOutput
      GraphQL::Role::FieldsOutput
    ))) {
      $field_maps{ $type->name } = $type->fields || {};
    }

    if ($type->isa('GraphQL::Type::Object') || $type->isa('GraphQL::Houtou::Type::Object')) {
      my $is_type_of = $type->is_type_of;
      $is_type_of_map{ $type->name } = $is_type_of if $is_type_of;
    }

    if ($type->isa('GraphQL::Type::Union') || $type->isa('GraphQL::Houtou::Type::Union')) {
      my $types = $type->{types} || $type->types || [];
      my $resolve_type = $type->resolve_type;
      my $tag_resolver = $type->can('tag_resolver') ? $type->tag_resolver : undef;
      $resolve_type_map{ $type->name } = $resolve_type if $resolve_type;
      $tag_resolver_map{ $type->name } = $tag_resolver if $tag_resolver;
      $possible_types{ $type->name } = [ @$types ];
      $possible_type_map->{ $type->name } ||= { map { ($_->name => 1) } @$types };
      if (my $tag_map = _build_runtime_tag_map($type, $types, $name2type)) {
        $runtime_tag_map{ $type->name } = $tag_map;
      }
      next;
    }

    if ($type->isa('GraphQL::Type::Interface') || $type->isa('GraphQL::Houtou::Type::Interface')) {
      my $types = [ @{ $interface2types->{ $type->name } || [] } ];
      my $resolve_type = $type->resolve_type;
      my $tag_resolver = $type->can('tag_resolver') ? $type->tag_resolver : undef;
      $resolve_type_map{ $type->name } = $resolve_type if $resolve_type;
      $tag_resolver_map{ $type->name } = $tag_resolver if $tag_resolver;
      $possible_types{ $type->name } = $types;
      $possible_type_map->{ $type->name } ||= { map { ($_->name => 1) } @$types };
      if (my $tag_map = _build_runtime_tag_map($type, $types, $name2type)) {
        $runtime_tag_map{ $type->name } = $tag_map;
      }
      next;
    }
  }

  return $self->{_runtime_cache} = {
    root_types => {
      query => $self->{query},
      mutation => $self->{mutation},
      subscription => $self->{subscription},
    },
    name2type => $name2type,
    interface2types => $interface2types,
    possible_type_map => $possible_type_map,
    possible_types => \%possible_types,
    field_maps => \%field_maps,
    resolve_type_map => \%resolve_type_map,
    is_type_of_map => \%is_type_of_map,
    tag_resolver_map => \%tag_resolver_map,
    runtime_tag_map => \%runtime_tag_map,
  };
}

sub _build_runtime_tag_map {
  my ($abstract_type, $possible_types, $name2type) = @_;
  my %tag_map;
  my $declared = $abstract_type->can('tag_map') ? $abstract_type->tag_map : undef;

  if ($declared) {
    for my $tag (keys %$declared) {
      my $target = $declared->{$tag};
      my $type = ref($target) ? $target : $name2type->{$target};
      next if !$type;
      next if !($type->isa('GraphQL::Type::Object') || $type->isa('GraphQL::Houtou::Type::Object'));
      $tag_map{$tag} = $type;
    }
  }

  for my $type (@{ $possible_types || [] }) {
    next if !$type || !$type->can('runtime_tag');
    my $tag = $type->runtime_tag;
    next if !defined $tag || ref($tag);
    $tag_map{$tag} ||= $type;
  }

  return keys(%tag_map) ? \%tag_map : undef;
}

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
  if ($self->{_runtime_cache}) {
    $self->{_runtime_cache}{possible_type_map} = $map;
  }
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
