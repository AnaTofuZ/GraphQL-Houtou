package GraphQL::Houtou::Runtime::Executor;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Runtime::Cursor ();
use GraphQL::Houtou::Runtime::ExecState ();
use GraphQL::Houtou::Runtime::Outcome ();
use GraphQL::Houtou::Runtime::Writer ();

sub execute_operation {
  my ($class, $runtime_schema, $program, %opts) = @_;
  my $writer = GraphQL::Houtou::Runtime::Writer->new;
  my $variables = _prepare_variables($program, $opts{variables} || {});
  my $state = GraphQL::Houtou::Runtime::ExecState->new(
    runtime_schema => $runtime_schema,
    program => $program,
    cursor => GraphQL::Houtou::Runtime::Cursor->new(block => $program->root_block),
    writer => $writer,
    context => $opts{context},
    variables => $variables,
    root_value => $opts{root_value},
    promise_code => $opts{promise_code},
    empty_args => {},
  );

  my $data = _execute_block($state, $program->root_block, $opts{root_value});
  return {
    data => $data,
    errors => [ @{ $writer->errors || [] } ],
  };
}

sub _execute_block {
  my ($state, $block, $source) = @_;
  my %data;

  for my $instruction (@{ $block->instructions || [] }) {
    my $outcome = _execute_instruction($state, $block, $instruction, $source);
    _consume_outcome($state->writer, \%data, $instruction->result_name, $outcome);
  }

  return \%data;
}

sub _execute_instruction {
  my ($state, $block, $instruction, $source) = @_;
  my $value = _resolve_field_value($state, $block, $instruction, $source);
  my $op = $instruction->complete_op || 'COMPLETE_GENERIC';

  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if $op eq 'COMPLETE_GENERIC';

  return _complete_object($state, $instruction, $value)
    if $op eq 'COMPLETE_OBJECT';

  return _complete_list($state, $instruction, $value)
    if $op eq 'COMPLETE_LIST';

  return _complete_abstract($state, $instruction, $value)
    if $op eq 'COMPLETE_ABSTRACT';

  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'VALUE', value => $value);
}

sub _resolve_field_value {
  my ($state, $block, $instruction, $source) = @_;
  my $field_map = $state->runtime_schema->runtime_cache->{field_maps}{ $block->type_name } || {};
  my $field = $field_map->{ $instruction->field_name } || {};
  my $resolver = $field->{resolve};
  my $return_type = $field->{type}
    || $state->runtime_schema->runtime_cache->{name2type}{ $instruction->return_type_name };
  my $args = _resolve_instruction_args($state, $instruction);

  if ($resolver) {
    return $resolver->($source, $args, $state->context, $return_type);
  }

  return $source->{ $instruction->field_name } if ref($source) eq 'HASH';
  return;
}

sub _resolve_instruction_args {
  my ($state, $instruction) = @_;
  my $mode = $instruction->args_mode || 'NONE';
  return $state->empty_args if $mode eq 'NONE';
  return $instruction->args_payload if $mode eq 'STATIC';
  return _materialize_dynamic_args($instruction->args_payload, $state->variables || {});
}

sub _prepare_variables {
  my ($program, $provided) = @_;
  my %resolved = %{ $provided || {} };
  for my $name (keys %{ $program->variable_defs || {} }) {
    next if exists $resolved{$name};
    my $def = $program->variable_defs->{$name} || {};
    next if !$def->{has_default};
    $resolved{$name} = $def->{default_value};
  }
  return \%resolved;
}

sub _materialize_dynamic_args {
  my ($value, $variables) = @_;
  my $ref = ref($value);
  return $value if !$ref;
  return (exists $variables->{ $$value } ? $variables->{ $$value } : undef) if $ref eq 'SCALAR';
  return $$$value if $ref eq 'REF';
  return [ map { _materialize_dynamic_args($_, $variables) } @$value ] if $ref eq 'ARRAY';
  return { map { $_ => _materialize_dynamic_args($value->{$_}, $variables) } keys %$value } if $ref eq 'HASH';
  return $value;
}

sub _complete_object {
  my ($state, $instruction, $value) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;

  my $child = $state->program->block_by_name($instruction->child_block_name);
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$child;

  return GraphQL::Houtou::Runtime::Outcome->new(
    kind => 'OBJECT',
    object_value => _execute_block($state, $child, $value),
  );
}

sub _complete_list {
  my ($state, $instruction, $value) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;

  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if ref($value) ne 'ARRAY';

  my $child = $state->program->block_by_name($instruction->child_block_name);
  my @items = map {
    $child ? _execute_block($state, $child, $_) : $_
  } @$value;

  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'LIST', list_value => \@items);
}

sub _complete_abstract {
  my ($state, $instruction, $value) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;

  my $runtime_type = _resolve_runtime_type($state, $instruction, $value);
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$runtime_type;

  my $child_block_name = ($instruction->abstract_child_blocks || {})->{ $runtime_type->name };
  my $child = $child_block_name ? $state->program->block_by_name($child_block_name) : undef;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$child;

  return GraphQL::Houtou::Runtime::Outcome->new(
    kind => 'OBJECT',
    object_value => _execute_block($state, $child, $value),
  );
}

sub _resolve_runtime_type {
  my ($state, $instruction, $value) = @_;
  my $cache = $state->runtime_schema->runtime_cache;
  my $abstract_name = $instruction->return_type_name;
  my $abstract_type = $cache->{name2type}{$abstract_name} or return;

  if (my $tag_resolver = $cache->{tag_resolver_map}{$abstract_name}) {
    my $tag = $tag_resolver->($value, $state->context, $abstract_type);
    if (defined $tag) {
      my $type = ($cache->{runtime_tag_map}{$abstract_name} || {})->{$tag};
      return $type if $type;
    }
  }

  if (my $resolve_type = $cache->{resolve_type_map}{$abstract_name}) {
    my $resolved = $resolve_type->($value, $state->context, undef, $abstract_type);
    return if !defined $resolved;
    return ref($resolved) ? $resolved : $cache->{name2type}{$resolved};
  }

  for my $type (@{ $cache->{possible_types}{$abstract_name} || [] }) {
    next if !$type;
    my $cb = $cache->{is_type_of_map}{ $type->name } or next;
    return $type if $cb->($value, $state->context, undef, $type);
  }

  return;
}

sub _consume_outcome {
  my ($writer, $data, $result_name, $outcome) = @_;
  return if !$outcome;
  $data->{$result_name} = $outcome->value;
  push @{ $writer->errors }, @{ $outcome->errors || [] } if @{ $outcome->errors || [] };
  return;
}

1;
