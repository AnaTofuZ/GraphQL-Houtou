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
  my $variables = _prepare_variables($runtime_schema, $program, $opts{variables} || {});
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
    next if !_should_execute_instruction($state, $instruction);
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
  my $arg_defs = $instruction->arg_defs || {};
  return $state->empty_args if !keys %$arg_defs;
  return _coerce_static_args($state, $arg_defs, $instruction->args_payload || {})
    if $mode eq 'STATIC';
  return _coerce_dynamic_args($state, $arg_defs, $instruction->args_payload || {})
    if $mode eq 'DYNAMIC';
  return _coerce_static_args($state, $arg_defs, {});
}

sub _should_execute_instruction {
  my ($state, $instruction) = @_;
  my $mode = $instruction->directives_mode || 'NONE';
  return 1 if $mode eq 'NONE';
  my $guards = $instruction->directives_payload || [];
  return _evaluate_runtime_guards($guards, $state->variables || {});
}

sub _evaluate_runtime_guards {
  my ($guards, $variables) = @_;
  for my $directive (@{ $guards || [] }) {
    next if !$directive;
    my $name = $directive->{name} || '';
    my $arguments = $directive->{arguments} || {};
    my $if_value = _materialize_dynamic_args($arguments->{if}, $variables);
    my $bool = $if_value ? 1 : 0;
    return 0 if $name eq 'skip' && $bool;
    return 0 if $name eq 'include' && !$bool;
  }
  return 1;
}

sub _prepare_variables {
  my ($runtime_schema, $program, $provided) = @_;
  my %resolved = %{ $provided || {} };
  for my $name (keys %{ $program->variable_defs || {} }) {
    next if exists $resolved{$name};
    my $def = $program->variable_defs->{$name} || {};
    next if !$def->{has_default};
    $resolved{$name} = $def->{default_value};
  }
  return _coerce_variable_values($runtime_schema, $program->variable_defs || {}, \%resolved);
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

sub _coerce_variable_values {
  my ($runtime_schema, $defs, $values) = @_;
  my %coerced;
  for my $name (keys %{ $defs || {} }) {
    my $def = $defs->{$name} || {};
    next if !exists $values->{$name};
    my $type = _lookup_input_type($runtime_schema, $def->{type});
    $coerced{$name} = _coerce_input_value($type, $values->{$name});
  }
  for my $name (keys %{$values || {}}) {
    next if exists $coerced{$name};
    $coerced{$name} = $values->{$name};
  }
  return \%coerced;
}

sub _coerce_static_args {
  my ($state, $arg_defs, $payload) = @_;
  my %values;

  for my $name (keys %{$arg_defs || {}}) {
    my $arg_def = $arg_defs->{$name} || {};
    my $type = _lookup_input_type($state->runtime_schema, $arg_def->{type});
    my $has_value = exists $payload->{$name};
    next if !$has_value && !$arg_def->{has_default};
    my $raw = $has_value ? $payload->{$name} : $arg_def->{default_value};
    $values{$name} = _coerce_input_value($type, $raw);
  }

  return \%values;
}

sub _coerce_dynamic_args {
  my ($state, $arg_defs, $payload) = @_;
  my %values;

  for my $name (keys %{$arg_defs || {}}) {
    my $arg_def = $arg_defs->{$name} || {};
    my $type = _lookup_input_type($state->runtime_schema, $arg_def->{type});
    next if !exists $payload->{$name} && !$arg_def->{has_default};
    $values{$name} = _coerce_dynamic_arg_value(
      $type,
      exists $payload->{$name} ? $payload->{$name} : undef,
      $state->variables || {},
      $arg_def->{has_default} ? $arg_def->{default_value} : undef,
    );
  }

  return \%values;
}

sub _coerce_dynamic_arg_value {
  my ($type, $raw, $variables, $default) = @_;
  if (ref($raw) eq 'SCALAR') {
    return exists $variables->{$$raw}
      ? $variables->{$$raw}
      : (defined $default ? _coerce_input_value($type, $default) : undef);
  }
  my $materialized = defined($raw)
    ? _materialize_dynamic_args($raw, $variables)
    : $default;
  return _coerce_input_value($type, $materialized);
}

sub _lookup_input_type {
  my ($runtime_schema, $typedef) = @_;
  return GraphQL::Houtou::Schema::lookup_type($typedef, $runtime_schema->runtime_cache->{name2type});
}

sub _coerce_input_value {
  my ($type, $value) = @_;
  return $value if !defined $type;
  return $type->graphql_to_perl($value);
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
