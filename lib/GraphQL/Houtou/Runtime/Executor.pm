package GraphQL::Houtou::Runtime::Executor;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Promise::Adapter qw(
  all_promise
  is_promise_value
  normalize_promise_code
  then_promise
);
use GraphQL::Houtou::Runtime::Cursor ();
use GraphQL::Houtou::Runtime::ErrorRecord ();
use GraphQL::Houtou::Runtime::ExecState ();
use GraphQL::Houtou::Runtime::LazyInfo ();
use GraphQL::Houtou::Runtime::Outcome ();
use GraphQL::Houtou::Runtime::PathFrame ();
use GraphQL::Houtou::Runtime::Writer ();

sub execute_operation {
  my ($class, $runtime_schema, $program, %opts) = @_;
  my $writer = GraphQL::Houtou::Runtime::Writer->new;
  my $promise_code = normalize_promise_code($opts{promise_code});
  my $variables = _prepare_variables($runtime_schema, $program, $opts{variables} || {});
  my $state = GraphQL::Houtou::Runtime::ExecState->new(
    runtime_schema => $runtime_schema,
    program => $program,
    cursor => GraphQL::Houtou::Runtime::Cursor->new(block => $program->root_block),
    writer => $writer,
    context => $opts{context},
    variables => $variables,
    root_value => $opts{root_value},
    promise_code => $promise_code,
    empty_args => {},
  );

  my $data = _execute_block($state, $program->root_block, $opts{root_value});
  if (_is_promise($state, $data)) {
    return then_promise($promise_code, $data, sub {
      return {
        data => $_[0],
        errors => $writer->materialize_errors,
      };
    });
  }
  return {
    data => $data,
    errors => $writer->materialize_errors,
  };
}

sub _execute_block {
  my ($state, $block, $source, $base_path) = @_;
  my %data;
  my @pending_names;
  my @pending_outcomes;

  for my $instruction (@{ $block->instructions || [] }) {
    next if !_should_execute_instruction($state, $instruction);
    my $path_frame = GraphQL::Houtou::Runtime::PathFrame->new(
      parent => $base_path,
      key => $instruction->result_name,
    );
    my $outcome = _execute_instruction($state, $block, $instruction, $source, $path_frame);
    if (_is_promise($state, $outcome)) {
      push @pending_names, $instruction->result_name;
      push @pending_outcomes, $outcome;
      next;
    }
    _consume_outcome($state->writer, \%data, $instruction->result_name, $outcome);
  }

  if (@pending_outcomes) {
    my $aggregate = all_promise($state->promise_code, @pending_outcomes);
    return then_promise($state->promise_code, $aggregate, sub {
      my @resolved = _promise_all_values_to_array(@_);
      my %merged = %data;
      for my $i (0 .. $#resolved) {
        _consume_outcome($state->writer, \%merged, $pending_names[$i], $resolved[$i]);
      }
      return \%merged;
    });
  }

  return \%data;
}

sub _execute_instruction {
  my ($state, $block, $instruction, $source, $path_frame) = @_;
  my ($ok, $value) = _capture_eval(sub {
    return _resolve_field_value($state, $block, $instruction, $source, $path_frame);
  });

  if (!$ok) {
    return _error_outcome($value, $path_frame);
  }

  if (_is_promise($state, $value)) {
    return then_promise($state->promise_code, $value, sub {
      my ($resolved_value) = @_;
      my ($complete_ok, $outcome) = _capture_eval(sub {
      return _complete_resolved_value($state, $block, $instruction, $resolved_value, $path_frame);
    });
      return $complete_ok ? $outcome : _error_outcome($outcome, $path_frame);
    }, sub {
      return _error_outcome($_[0], $path_frame);
    });
  }

  my ($complete_ok, $outcome) = _capture_eval(sub {
    return _complete_resolved_value($state, $block, $instruction, $value, $path_frame);
  });
  return $complete_ok ? $outcome : _error_outcome($outcome, $path_frame);
}

sub _complete_resolved_value {
  my ($state, $block, $instruction, $value, $path_frame) = @_;
  my $op = $instruction->complete_op || 'COMPLETE_GENERIC';

  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if $op eq 'COMPLETE_GENERIC';

  return _complete_object($state, $block, $instruction, $value, $path_frame)
    if $op eq 'COMPLETE_OBJECT';

  return _complete_list($state, $block, $instruction, $value, $path_frame)
    if $op eq 'COMPLETE_LIST';

  return _complete_abstract($state, $block, $instruction, $value, $path_frame)
    if $op eq 'COMPLETE_ABSTRACT';

  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'VALUE', value => $value);
}

sub _resolve_field_value {
  my ($state, $block, $instruction, $source, $path_frame) = @_;
  my $slot = $instruction->bound_slot;
  my $resolver = $slot ? $slot->resolve : undef;
  my $return_type = $slot && $slot->return_type
    ? $slot->return_type
    : $state->runtime_schema->runtime_cache->{name2type}{ $instruction->return_type_name };
  my $args = _resolve_instruction_args($state, $instruction);

  if ($resolver) {
    my $info = _build_info($state, $block, $instruction, $path_frame);
    return $resolver->($source, $args, $state->context, $info, $return_type);
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
  my ($state, $block, $instruction, $value, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;

  my $child = $instruction->bound_child_block;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$child;

  my $child_value = _execute_block($state, $child, $value, $path_frame);
  if (_is_promise($state, $child_value)) {
    return then_promise($state->promise_code, $child_value, sub {
      return GraphQL::Houtou::Runtime::Outcome->new(
        kind => 'OBJECT',
        object_value => $_[0],
      );
    });
  }

  return GraphQL::Houtou::Runtime::Outcome->new(
    kind => 'OBJECT',
    object_value => $child_value,
  );
}

sub _complete_list {
  my ($state, $block, $instruction, $value, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;

  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if ref($value) ne 'ARRAY';

  my $child = $instruction->bound_child_block;
  my @items;
  for my $i (0 .. $#$value) {
    my $item_path = GraphQL::Houtou::Runtime::PathFrame->new(
      parent => $path_frame,
      key => $i,
    );
    push @items, $child ? _execute_block($state, $child, $value->[$i], $item_path) : $value->[$i];
  }

  if (grep { _is_promise($state, $_) } @items) {
    my $aggregate = all_promise($state->promise_code, @items);
    return then_promise($state->promise_code, $aggregate, sub {
      my @resolved = _promise_all_values_to_array(@_);
      return GraphQL::Houtou::Runtime::Outcome->new(kind => 'LIST', list_value => \@resolved);
    });
  }

  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'LIST', list_value => \@items);
}

sub _complete_abstract {
  my ($state, $block, $instruction, $value, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;

  my ($runtime_type, $error_record) = _resolve_runtime_type($state, $block, $instruction, $value, $path_frame);
  return GraphQL::Houtou::Runtime::Outcome->new(
    kind => 'SCALAR',
    scalar_value => undef,
    error_records => [ $error_record ],
  ) if $error_record;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$runtime_type;

  my $child = ($instruction->bound_abstract_child_blocks || {})->{ $runtime_type->name };
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$child;

  my $child_value = _execute_block($state, $child, $value, $path_frame);
  if (_is_promise($state, $child_value)) {
    return then_promise($state->promise_code, $child_value, sub {
      return GraphQL::Houtou::Runtime::Outcome->new(
        kind => 'OBJECT',
        object_value => $_[0],
      );
    });
  }

  return GraphQL::Houtou::Runtime::Outcome->new(
    kind => 'OBJECT',
    object_value => $child_value,
  );
}

sub _resolve_runtime_type {
  my ($state, $block, $instruction, $value, $path_frame) = @_;
  my $dispatch = $instruction->abstract_dispatch;
  my $cache = $state->runtime_schema->runtime_cache;
  my $abstract_name = $dispatch ? $dispatch->{abstract_name} : $instruction->return_type_name;
  my $abstract_type = $dispatch ? $dispatch->{abstract_type} : $cache->{name2type}{$abstract_name};
  return if !$abstract_type;
  my $info;
  my $build_info = sub {
    $info ||= _build_info($state, $block, $instruction, $path_frame);
    return $info;
  };

  if (my $tag_resolver = $dispatch ? $dispatch->{tag_resolver} : $cache->{tag_resolver_map}{$abstract_name}) {
    my ($ok, $tag) = _capture_eval(sub {
      return $tag_resolver->($value, $state->context, $build_info->(), $abstract_type);
    });
    return (undef, _error_record($tag, $path_frame)) if !$ok;
    if (defined $tag) {
      my $tag_map = $dispatch ? $dispatch->{tag_map} : (($cache->{runtime_tag_map}{$abstract_name} || {}));
      my $type = $tag_map->{$tag};
      return ($type, undef) if $type;
    }
  }

  if (my $resolve_type = $dispatch ? $dispatch->{resolve_type} : $cache->{resolve_type_map}{$abstract_name}) {
    my ($ok, $resolved) = _capture_eval(sub {
      return $resolve_type->($value, $state->context, $build_info->(), $abstract_type);
    });
    return (undef, _error_record($resolved, $path_frame)) if !$ok;
    return if !defined $resolved;
    my $name2type = $dispatch ? $dispatch->{name2type} : $cache->{name2type};
    return (ref($resolved) ? $resolved : $name2type->{$resolved}, undef);
  }

  my $possible_types = $dispatch ? $dispatch->{possible_types} : ($cache->{possible_types}{$abstract_name} || []);
  my $is_type_of_map = $dispatch ? $dispatch->{is_type_of_map} : $cache->{is_type_of_map};
  for my $type (@{ $possible_types || [] }) {
    next if !$type;
    my $cb = $is_type_of_map->{ $type->name } or next;
    my ($ok, $matched) = _capture_eval(sub {
      return $cb->($value, $state->context, $build_info->(), $type);
    });
    return (undef, _error_record($matched, $path_frame)) if !$ok;
    return ($type, undef) if $matched;
  }

  return (undef, undef);
}

sub _build_info {
  my ($state, $block, $instruction, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::LazyInfo->new(
    state => $state,
    runtime_schema => $state->runtime_schema,
    block => $block,
    instruction => $instruction,
    path_frame => $path_frame,
  );
}

sub _consume_outcome {
  my ($writer, $data, $result_name, $outcome) = @_;
  return $writer->consume_outcome($data, $result_name, $outcome);
}

sub _capture_eval {
  my ($cb) = @_;
  my $ok = eval { 1 };
  my ($result, @rest);
  $ok = eval {
    $result = $cb->();
    1;
  };
  return (0, $@) if !$ok;
  return (1, $result);
}

sub _error_record {
  my ($error, $path_frame) = @_;
  chomp $error if defined $error;
  return GraphQL::Houtou::Runtime::ErrorRecord->new(
    message => "$error",
    path_frame => $path_frame,
  );
}

sub _error_outcome {
  my ($error, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(
    kind => 'SCALAR',
    scalar_value => undef,
    error_records => [ _error_record($error, $path_frame) ],
  );
}

sub _is_promise {
  my ($state, $value) = @_;
  return is_promise_value($state->promise_code, $value);
}

sub _promise_all_values_to_array {
  return @{ $_[0] } if @_ == 1 && ref($_[0]) eq 'ARRAY';
  return @_;
}

1;
