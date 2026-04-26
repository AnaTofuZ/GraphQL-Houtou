package GraphQL::Houtou::Runtime::VMExecutor;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Promise::Adapter qw(
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

sub execute_program {
  my ($class, $runtime_schema, $program, %opts) = @_;
  my $writer = GraphQL::Houtou::Runtime::Writer->new;
  my $promise_code = normalize_promise_code($opts{promise_code});
  my $variables = _prepare_variables($runtime_schema, $opts{variables} || {});
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
  my ($snapshot) = $state->enter_block($block);
  my $cursor = $state->cursor;
  while (my $op = $cursor->advance_op) {
    next if !_should_execute_op($state, $op);
    $state->enter_current_field($source, $base_path);
    my $outcome = _execute_op($state);
    $state->consume_current_field_outcome($outcome);
  }

  return $state->finalize_current_block($snapshot);
}

sub _execute_op {
  my ($state) = @_;
  my $field = $state->current_field_frame;
  my $source = $field->source;
  my $path_frame = $field->path_frame;
  my ($ok, $value) = _capture_eval(sub {
    return _resolve_field_value($state, $source, $path_frame);
  });
  return _error_outcome($value, $path_frame) if !$ok;
  $field->set_resolved_value($value);

  if (_is_promise($state, $value)) {
    return then_promise($state->promise_code, $value, sub {
      my ($resolved_value) = @_;
      $field->set_resolved_value($resolved_value);
      my ($complete_ok, $outcome) = _capture_eval(sub {
        return _complete_resolved_value($state, $resolved_value, $path_frame);
      });
      return $complete_ok ? $field->set_outcome($outcome) : _error_outcome($outcome, $path_frame);
    }, sub {
      return _error_outcome($_[0], $path_frame);
    });
  }

  my ($complete_ok, $outcome) = _capture_eval(sub {
    return _complete_resolved_value($state, $value, $path_frame);
  });
  return $complete_ok ? $field->set_outcome($outcome) : _error_outcome($outcome, $path_frame);
}

sub _resolve_field_value {
  my ($state, $source, $path_frame) = @_;
  my $op = $state->cursor->current_op;
  my $dispatch = $op->resolve_dispatch;
  return $dispatch->($state, $source, $path_frame);
}

sub _resolve_default {
  my ($state, $source, $path_frame) = @_;
  my $cursor = $state->cursor;
  my $block = $cursor->block;
  my $op = $cursor->current_op;
  my $slot = $cursor->current_slot || $op->bound_slot;
  my $resolver = $slot ? $slot->resolve : undef;
  my $return_type = $slot ? $slot->return_type : undef;
  $return_type ||= $state->runtime_schema->runtime_cache->{name2type}{ $block->type_name };
  my $args = _resolve_op_args($state, $op);

  if ($resolver) {
    my $info = _build_info($state, $block, $op, $path_frame);
    return $resolver->($source, $args, $state->context, $info, $return_type);
  }

  return $source->{ $op->field_name } if ref($source) eq 'HASH';
  return;
}

sub _resolve_explicit {
  my ($state, $source, $path_frame) = @_;
  return _resolve_default(@_);
}

sub _complete_resolved_value {
  my ($state, $value, $path_frame) = @_;
  my $op = $state->cursor->current_op;
  my $dispatch = $op->complete_dispatch;
  return $dispatch->($state, $value, $path_frame);
}

sub _complete_generic {
  my ($state, $value, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value);
}

sub _complete_object {
  my ($state, $value, $path_frame) = @_;
  my $op = $state->cursor->current_op;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;

  my $child = $op->bound_child_block
    || $state->program->block_by_name($op->child_block_name);
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$child;

  my $child_value = _execute_block($state, $child, $value, $path_frame);
  if (_is_promise($state, $child_value)) {
    return then_promise($state->promise_code, $child_value, sub {
      return GraphQL::Houtou::Runtime::Outcome->new(kind => 'OBJECT', object_value => $_[0]);
    });
  }

  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'OBJECT', object_value => $child_value);
}

sub _complete_list {
  my ($state, $value, $path_frame) = @_;
  my $op = $state->cursor->current_op;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if ref($value) ne 'ARRAY';

  my $child = $op->bound_child_block
    || $state->program->block_by_name($op->child_block_name);
  my @items;
  for my $i (0 .. $#$value) {
    my $item_path = GraphQL::Houtou::Runtime::PathFrame->new(parent => $path_frame, key => $i);
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
  my ($state, $value, $path_frame) = @_;
  my $op = $state->cursor->current_op;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;

  my ($runtime_type, $error_record) = _resolve_runtime_type($state, $value, $path_frame);
  return GraphQL::Houtou::Runtime::Outcome->new(
    kind => 'SCALAR',
    scalar_value => undef,
    error_records => [ $error_record ],
  ) if $error_record;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$runtime_type;

  my $child = ($op->bound_abstract_child_blocks || {})->{ $runtime_type->name };
  if (!$child) {
    my $child_block_name = ($op->abstract_child_blocks || {})->{ $runtime_type->name };
    $child = $child_block_name ? $state->program->block_by_name($child_block_name) : undef;
  }
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$child;

  my $child_value = _execute_block($state, $child, $value, $path_frame);
  if (_is_promise($state, $child_value)) {
    return then_promise($state->promise_code, $child_value, sub {
      return GraphQL::Houtou::Runtime::Outcome->new(kind => 'OBJECT', object_value => $_[0]);
    });
  }

  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'OBJECT', object_value => $child_value);
}

sub _resolve_runtime_type {
  my ($state, $value, $path_frame) = @_;
  my $cursor = $state->cursor;
  my $block = $cursor->block;
  my $op = $cursor->current_op;
  my $dispatch = $op->abstract_dispatch;
  my $cache = $state->runtime_schema->runtime_cache;
  my $slot = $cursor->current_slot || $op->bound_slot;
  my $abstract_type = $dispatch ? $dispatch->{abstract_type} : ($slot ? $slot->return_type : undef);
  return if !$abstract_type;
  my $abstract_name = $dispatch ? $dispatch->{abstract_name} : $abstract_type->name;
  my $info;
  my $build_info = sub {
    $info ||= _build_info($state, $block, $op, $path_frame);
    return $info;
  };

  if (my $tag_resolver = $dispatch ? $dispatch->{tag_resolver} : $cache->{tag_resolver_map}{$abstract_name}) {
    my ($ok, $tag) = _capture_eval(sub {
      return $tag_resolver->($value, $state->context, $build_info->(), $abstract_type);
    });
    return (undef, _error_record($tag, $path_frame)) if !$ok;
    if (defined $tag) {
      my $type = (($dispatch ? $dispatch->{tag_map} : $cache->{runtime_tag_map}{$abstract_name}) || {})->{$tag};
      return ($type, undef) if $type;
    }
  }

  if (my $resolve_type = $dispatch ? $dispatch->{resolve_type} : $cache->{resolve_type_map}{$abstract_name}) {
    my ($ok, $resolved) = _capture_eval(sub {
      return $resolve_type->($value, $state->context, $build_info->(), $abstract_type);
    });
    return (undef, _error_record($resolved, $path_frame)) if !$ok;
    return if !defined $resolved;
    return (ref($resolved) ? $resolved : (($dispatch ? $dispatch->{name2type} : $cache->{name2type})->{$resolved}), undef);
  }

  for my $type (@{ ($dispatch ? $dispatch->{possible_types} : $cache->{possible_types}{$abstract_name}) || [] }) {
    next if !$type;
    my $cb = ($dispatch ? $dispatch->{is_type_of_map} : $cache->{is_type_of_map})->{ $type->name } or next;
    my ($ok, $matched) = _capture_eval(sub {
      return $cb->($value, $state->context, $build_info->(), $type);
    });
    return (undef, _error_record($matched, $path_frame)) if !$ok;
    return ($type, undef) if $matched;
  }

  return (undef, undef);
}

sub _resolve_op_args {
  my ($state, $op) = @_;
  my $mode = $op->args_mode || 'NONE';
  my $arg_defs = $op->arg_defs || {};
  return $state->empty_args if !keys %$arg_defs;
  return _coerce_static_args($state, $arg_defs, {})
    if $mode eq 'STATIC' && !$op->{args_payload};
  return _coerce_static_args($state, $arg_defs, $op->{args_payload} || {})
    if $mode eq 'STATIC';
  return _coerce_dynamic_args($state, $arg_defs, $op->{args_payload} || {})
    if $mode eq 'DYNAMIC';
  return _coerce_static_args($state, $arg_defs, {});
}

sub _should_execute_op {
  my ($state, $op) = @_;
  my $mode = $op->directives_mode || 'NONE';
  return 1 if $mode eq 'NONE';
  return 1; # VM lowering keeps directive metadata; execution semantics can tighten later.
}

sub _prepare_variables {
  my ($runtime_schema, $provided) = @_;
  return $provided || {};
}

sub _coerce_static_args {
  my ($state, $arg_defs, $payload) = @_;
  my %values;
  for my $name (keys %{$arg_defs || {}}) {
    my $arg_def = $arg_defs->{$name} || {};
    next if !exists $payload->{$name} && !$arg_def->{has_default};
    $values{$name} = exists $payload->{$name} ? $payload->{$name} : $arg_def->{default_value};
  }
  return \%values;
}

sub _coerce_dynamic_args {
  my ($state, $arg_defs, $payload) = @_;
  my %values;
  for my $name (keys %{$arg_defs || {}}) {
    next if !exists $payload->{$name};
    my $raw = $payload->{$name};
    if (ref($raw) eq 'SCALAR') {
      $values{$name} = $state->variables->{ $$raw };
      next;
    }
    $values{$name} = $raw;
  }
  return \%values;
}

sub _build_info {
  my ($state, $block, $op, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::LazyInfo->new(
    state => $state,
    runtime_schema => $state->runtime_schema,
    block => $block,
    instruction => $op,
    path_frame => $path_frame,
  );
}

sub _capture_eval {
  my ($cb) = @_;
  my $ok = eval { 1 };
  my $result;
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

1;
