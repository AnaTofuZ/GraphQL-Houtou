package GraphQL::Houtou::Runtime::Compiler;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Runtime::SchemaGraph ();
use GraphQL::Houtou::Runtime::Program ();
use GraphQL::Houtou::Runtime::Block ();
use GraphQL::Houtou::Runtime::Slot ();

sub compile_schema {
  my ($class, $schema, %opts) = @_;
  my $runtime_cache = $schema->prepare_runtime;

  my $type_index = _build_type_index($runtime_cache->{name2type} || {});
  my $dispatch_index = _build_dispatch_index($runtime_cache);
  my ($program, $root_types) = _build_program($schema, $runtime_cache);

  return GraphQL::Houtou::Runtime::SchemaGraph->new(
    version => 1,
    schema => $schema,
    runtime_cache => $runtime_cache,
    type_index => $type_index,
    dispatch_index => $dispatch_index,
    root_types => $root_types,
    program => $program,
  );
}

sub inflate_schema {
  my ($class, $schema, $struct) = @_;
  my $runtime_cache = $schema->prepare_runtime;
  my $program = _inflate_program($struct->{program} || {});
  _rebind_program_runtime_metadata($runtime_cache, $program);

  return GraphQL::Houtou::Runtime::SchemaGraph->new(
    version => $struct->{version} || 1,
    schema => $schema,
    runtime_cache => $runtime_cache,
    type_index => $struct->{type_index} || {},
    dispatch_index => $struct->{dispatch_index} || {},
    root_types => $struct->{root_types} || {},
    program => $program,
  );
}

sub _build_type_index {
  my ($name2type) = @_;
  my %index;

  for my $name (sort keys %{$name2type || {}}) {
    my $type = $name2type->{$name} or next;
    $index{$name} = {
      kind => _type_kind($type),
      completion_family => _completion_family_for_type($type),
      runtime_tag => ($type->can('runtime_tag') ? $type->runtime_tag : undef),
    };
  }

  return \%index;
}

sub _build_dispatch_index {
  my ($runtime_cache) = @_;
  my %dispatch;

  for my $name (sort keys %{ $runtime_cache->{resolve_type_map} || {} }) {
    $dispatch{$name}{dispatch_family} = 'RESOLVE_TYPE';
  }
  for my $name (sort keys %{ $runtime_cache->{tag_resolver_map} || {} }) {
    $dispatch{$name}{dispatch_family} = 'TAG';
  }
  for my $name (sort keys %{ $runtime_cache->{possible_types} || {} }) {
    $dispatch{$name}{dispatch_family} ||= 'POSSIBLE_TYPES';
  }

  return \%dispatch;
}

sub _build_program {
  my ($schema, $runtime_cache) = @_;
  my @blocks;
  my %root_blocks;
  my %root_types;
  my %blocks_by_type;

  for my $type_name (sort keys %{ $runtime_cache->{name2type} || {} }) {
    my $type = $runtime_cache->{name2type}{$type_name} or next;
    next if !$type->isa('GraphQL::Houtou::Type::Object');
    my $block = GraphQL::Houtou::Runtime::Block->new(
      name => uc($type_name),
      family => 'OBJECT',
      root_type_name => $type->name,
      slots => _build_slots_for_object($type),
    );
    push @blocks, $block;
    $blocks_by_type{ $type->name } = $block;
  }

  for my $root_name (qw(query mutation subscription)) {
    my $root_type = $runtime_cache->{root_types}{$root_name} or next;
    my $block = $blocks_by_type{ $root_type->name } or next;
    $root_blocks{$root_name} = $block;
    $root_types{$root_name} = $root_type->name;
  }

  my $program = GraphQL::Houtou::Runtime::Program->new(
    blocks => \@blocks,
    root_blocks => \%root_blocks,
  );

  return ($program, \%root_types);
}

sub _inflate_program {
  my ($struct) = @_;
  my @blocks = map { _inflate_block($_) } @{ $struct->{blocks} || [] };
  my %by_name = map { ($_->name => $_) } @blocks;
  my %root_blocks = map {
    ($_ => ($struct->{root_blocks}{$_} ? $by_name{ $struct->{root_blocks}{$_} } : undef));
  } keys %{ $struct->{root_blocks} || {} };

  return GraphQL::Houtou::Runtime::Program->new(
    blocks => \@blocks,
    root_blocks => \%root_blocks,
  );
}

sub _inflate_block {
  my ($struct) = @_;
  return GraphQL::Houtou::Runtime::Block->new(
    name => $struct->{name},
    family => $struct->{family},
    root_type_name => $struct->{root_type_name},
    slots => [ map { _inflate_slot($_) } @{ $struct->{slots} || [] } ],
  );
}

sub _inflate_slot {
  my ($struct) = @_;
  return GraphQL::Houtou::Runtime::Slot->new(
    field_name => $struct->{field_name},
    result_name => $struct->{result_name},
    return_type_name => $struct->{return_type_name},
    resolver_shape => $struct->{resolver_shape},
    completion_family => $struct->{completion_family},
    dispatch_family => $struct->{dispatch_family},
    arg_defs => $struct->{arg_defs} || {},
    has_args => $struct->{has_args},
    has_directives => $struct->{has_directives},
  );
}

sub _build_slots_for_object {
  my ($type) = @_;
  my $fields = $type->fields || {};
  my @slots;

  for my $field_name (sort keys %$fields) {
    my $field = $fields->{$field_name} || {};
    my $return_type = $field->{type};
    push @slots, GraphQL::Houtou::Runtime::Slot->new(
      field_name => $field_name,
      result_name => $field_name,
      return_type_name => _type_name($return_type),
      resolver_shape => ($field->{resolve} ? 'EXPLICIT' : 'DEFAULT'),
      completion_family => _completion_family_for_type($return_type),
      dispatch_family => _dispatch_family_for_type($return_type),
      arg_defs => _build_input_defs($field->{args} || {}),
      has_args => ($field->{args} && keys %{ $field->{args} }) ? 1 : 0,
      has_directives => ($field->{directives} && @{ $field->{directives} }) ? 1 : 0,
      resolve => $field->{resolve},
      return_type => $return_type,
    );
  }

  return \@slots;
}

sub _rebind_program_runtime_metadata {
  my ($runtime_cache, $program) = @_;

  for my $block (@{ $program->blocks || [] }) {
    my $type_name = $block->root_type_name;
    next if !defined $type_name;
    my $type = ($runtime_cache->{name2type} || {})->{$type_name} or next;
    next if !$type->isa('GraphQL::Houtou::Type::Object');
    my $fields = $type->fields || {};

    for my $slot (@{ $block->slots || [] }) {
      my $field = $fields->{ $slot->field_name } || {};
      $slot->{resolve} = $field->{resolve};
      $slot->{return_type} = $field->{type};
    }
  }

  return $program;
}

sub _type_name {
  my ($type) = @_;
  while ($type && $type->can('of')) {
    $type = $type->of;
  }
  return $type && $type->can('name') ? $type->name : undef;
}

sub _type_kind {
  my ($type) = @_;
  return 'NON_NULL' if $type && $type->isa('GraphQL::Houtou::Type::NonNull');
  return 'LIST' if $type && $type->isa('GraphQL::Houtou::Type::List');
  return 'OBJECT' if $type && $type->isa('GraphQL::Houtou::Type::Object');
  return 'INTERFACE' if $type && $type->isa('GraphQL::Houtou::Type::Interface');
  return 'UNION' if $type && $type->isa('GraphQL::Houtou::Type::Union');
  return 'SCALAR' if $type && $type->isa('GraphQL::Houtou::Type::Scalar');
  return 'ENUM' if $type && $type->isa('GraphQL::Houtou::Type::Enum');
  return 'INPUT_OBJECT' if $type && $type->isa('GraphQL::Houtou::Type::InputObject');
  return 'UNKNOWN';
}

sub _completion_family_for_type {
  my ($type) = @_;
  return 'GENERIC' if !$type;
  return 'LIST' if _contains_list($type);

  $type = $type->of while $type && $type->can('of');
  return 'ABSTRACT'
    if $type && (
      $type->isa('GraphQL::Houtou::Type::Interface')
      || $type->isa('GraphQL::Houtou::Type::Union')
    );
  return 'OBJECT' if $type && $type->isa('GraphQL::Houtou::Type::Object');
  return 'GENERIC';
}

sub _dispatch_family_for_type {
  my ($type) = @_;
  return 'ABSTRACT' if _completion_family_for_type($type) eq 'ABSTRACT';
  return 'OBJECT' if _completion_family_for_type($type) eq 'OBJECT';
  return 'LIST' if _completion_family_for_type($type) eq 'LIST';
  return 'GENERIC';
}

sub _contains_list {
  my ($type) = @_;
  while ($type && $type->can('of')) {
    return 1 if $type->isa('GraphQL::Houtou::Type::List');
    $type = $type->of;
  }
  return 0;
}

sub _build_input_defs {
  my ($fields) = @_;
  my %defs;

  for my $name (sort keys %{ $fields || {} }) {
    my $field = $fields->{$name} || {};
    $defs{$name} = {
      type => { type => _lower_type_shape($field->{type}) },
      has_default => exists $field->{default_value} ? 1 : 0,
      default_value => exists $field->{default_value}
        ? _clone_value($field->{default_value})
        : undef,
    };
  }

  return \%defs;
}

sub _clone_value {
  my ($value) = @_;
  my $ref = ref($value);
  return $value if !$ref;
  return [ map { _clone_value($_) } @$value ] if $ref eq 'ARRAY';
  return { map { $_ => _clone_value($value->{$_}) } keys %$value } if $ref eq 'HASH';
  return $value;
}

sub _lower_type_shape {
  my ($type) = @_;
  return $type if !ref($type);
  return ['list', { type => _lower_type_shape($type->of) }]
    if $type->isa('GraphQL::Houtou::Type::List');
  return ['non_null', { type => _lower_type_shape($type->of) }]
    if $type->isa('GraphQL::Houtou::Type::NonNull');
  return $type->name if $type->can('name');
  die "Cannot lower runtime input type shape.\n";
}

1;
