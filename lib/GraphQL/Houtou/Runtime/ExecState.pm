package GraphQL::Houtou::Runtime::ExecState;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();

use GraphQL::Houtou::Promise::Adapter qw(is_promise_value normalize_promise_code then_promise);
use GraphQL::Houtou::Runtime::BlockFrame ();
use GraphQL::Houtou::Runtime::Cursor ();
use GraphQL::Houtou::Runtime::ErrorRecord ();
use GraphQL::Houtou::Runtime::FieldFrame ();
use GraphQL::Houtou::Runtime::InputCoercion ();
use GraphQL::Houtou::Runtime::LazyInfo ();
use GraphQL::Houtou::Runtime::Outcome ();
use GraphQL::Houtou::Runtime::PathFrame ();
use GraphQL::Houtou::Runtime::Writer ();

sub new {
  my ($class, %args) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_new_xs(
    $class,
    $args{runtime_schema},
    $args{program},
    $args{cursor},
    $args{writer},
    $args{context},
    ($args{variables} || {}),
    $args{root_value},
    $args{promise_code},
    ($args{empty_args} || {}),
  );
}

sub build_for_program {
  my ($class, $runtime_schema, $program, %opts) = @_;
  return $class->new(
    runtime_schema => $runtime_schema,
    program => $program,
    cursor => GraphQL::Houtou::Runtime::Cursor->new(block => $program->root_block),
    writer => GraphQL::Houtou::Runtime::Writer->new,
    context => $opts{context},
    variables => GraphQL::Houtou::Runtime::InputCoercion::prepare_variables(
      $runtime_schema,
      $program,
      $opts{variables} || {},
    ),
    root_value => $opts{root_value},
    promise_code => normalize_promise_code($opts{promise_code}),
    empty_args => {},
  );
}

sub run_program {
  my ($class, $runtime_schema, $program, %opts) = @_;
  my $state = $class->build_for_program($runtime_schema, $program, %opts);
  my $data = $state->execute_block($program->root_block, $opts{root_value});
  return $state->finalize_response($data);
}

sub runtime_schema {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_runtime_schema_xs($_[0]);
}

sub program {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_program_xs($_[0]);
}

sub cursor {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_cursor_xs($_[0]);
}

sub current_block { return $_[0]->cursor->block }
sub current_op { return $_[0]->cursor->current_op }
sub current_slot { return $_[0]->cursor->current_slot }

sub frame {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_frame_xs($_[0]);
}

sub frame_stack {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_frame_stack_xs($_[0]);
}

sub field_frame {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_field_frame_xs($_[0]);
}

sub writer {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_writer_xs($_[0]);
}

sub context {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_context_xs($_[0]);
}

sub variables {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_variables_xs($_[0]);
}

sub root_value {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_root_value_xs($_[0]);
}

sub promise_code {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_promise_code_xs($_[0]);
}

sub empty_args {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_empty_args_xs($_[0]);
}

sub push_frame {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_push_frame_xs($_[0], $_[1]);
}

sub pop_frame {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_pop_frame_xs($_[0]);
}

sub current_frame { return $_[0]->frame }

sub enter_field {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_enter_field_xs($_[0], $_[1], $_[2]);
}

sub leave_field {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_leave_field_xs($_[0]);
}

sub current_field_frame { return $_[0]->field_frame }
sub current_path_frame { return $_[0]->field_frame ? $_[0]->field_frame->path_frame : undef }

sub advance_current_op {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_advance_current_op_xs($_[0]);
}

sub enter_current_field {
  my ($self, $source, $base_path) = @_;
  my $op = $self->current_op or return;
  my $path_frame = GraphQL::Houtou::Runtime::PathFrame->new(
    parent => $base_path,
    key => $op->result_name,
  );
  return $self->enter_field($source, $path_frame);
}

sub consume_current_field_outcome {
  my ($self, $outcome) = @_;
  my $op = $self->current_op or return;
  my $frame = $self->current_frame or return;
  my $field = $self->current_field_frame;
  $field->set_outcome($outcome) if $field;
  if ($self->promise_code && is_promise_value($self->promise_code, $outcome)) {
    $frame->add_pending($op->result_name, $outcome);
    return $self->leave_field;
  }
  $frame->consume_outcome($self->writer, $op->result_name, $outcome);
  return $self->leave_field;
}

sub enter_block {
  my ($self, $block) = @_;
  my $frame = GraphQL::Houtou::Runtime::BlockFrame->new;
  GraphQL::Houtou::_bootstrap_xs();
  my $snapshot = GraphQL::Houtou::XS::VM::exec_state_enter_block_xs($self, $block, $frame);
  return ($snapshot, $frame);
}

sub leave_block {
  my ($self, $snapshot, $result) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::exec_state_leave_block_xs($self, $snapshot);
  return $result;
}

sub finalize_current_block {
  my ($self, $snapshot) = @_;
  my $frame = $self->current_frame;
  my $result = $frame->finalize($self->promise_code, $self->writer);
  return $self->leave_block($snapshot, $result);
}

sub run_current_field_via {
  my ($self, $resolve_cb, $complete_cb) = @_;
  my $field = $self->current_field_frame;
  my $source = $field->source;
  my $path_frame = $field->path_frame;
  my ($ok, $value) = $self->_capture_eval(sub {
    return $resolve_cb->($self, $source, $path_frame);
  });
  return $self->_error_outcome($value, $path_frame) if !$ok;
  $field->set_resolved_value($value);

  if ($self->promise_code && is_promise_value($self->promise_code, $value)) {
    return GraphQL::Houtou::Promise::Adapter::then_promise($self->promise_code, $value, sub {
      my ($resolved_value) = @_;
      $field->set_resolved_value($resolved_value);
      my ($complete_ok, $outcome) = $self->_capture_eval(sub {
        return $complete_cb->($self, $resolved_value, $path_frame);
      });
      return $complete_ok ? $field->set_outcome($outcome) : $self->_error_outcome($outcome, $path_frame);
    }, sub {
      return $self->_error_outcome($_[0], $path_frame);
    });
  }

  my ($complete_ok, $outcome) = $self->_capture_eval(sub {
    return $complete_cb->($self, $value, $path_frame);
  });
  return $complete_ok ? $field->set_outcome($outcome) : $self->_error_outcome($outcome, $path_frame);
}

sub execute_current_op {
  my ($self) = @_;
  if (!$self->promise_code) {
    GraphQL::Houtou::_bootstrap_xs();
    return GraphQL::Houtou::XS::VM::exec_state_execute_current_op_xs($self);
  }
  return $self->run_current_field_via(
    sub {
      my ($state, $source, $path_frame) = @_;
      my $op = $state->current_op;
      my $dispatch = $op->resolve_dispatch;
      return $dispatch->($state, $source, $path_frame);
    },
    sub {
      my ($state, $value, $path_frame) = @_;
      my $op = $state->current_op;
      my $dispatch = $op->complete_dispatch;
      return $dispatch->($state, $value, $path_frame);
    },
  );
}

sub run_default_generic { return $_[0]->run_current_field_via(\&resolve_default,  \&complete_generic) }
sub run_default_object  { return $_[0]->run_current_field_via(\&resolve_default,  \&complete_object) }
sub run_default_list    { return $_[0]->run_current_field_via(\&resolve_default,  \&complete_list) }
sub run_default_abstract { return $_[0]->run_current_field_via(\&resolve_default,  \&complete_abstract) }
sub run_explicit_generic { return $_[0]->run_current_field_via(\&resolve_explicit, \&complete_generic) }
sub run_explicit_object { return $_[0]->run_current_field_via(\&resolve_explicit, \&complete_object) }
sub run_explicit_list   { return $_[0]->run_current_field_via(\&resolve_explicit, \&complete_list) }
sub run_explicit_abstract { return $_[0]->run_current_field_via(\&resolve_explicit, \&complete_abstract) }

sub resolve_field_value {
  my ($self, $source, $path_frame) = @_;
  my $op = $self->current_op;
  my $dispatch = $op->resolve_dispatch;
  return $dispatch->($self, $source, $path_frame);
}

sub resolve_default {
  my ($self, $source, $path_frame) = @_;
  my $op = $self->current_op;
  return $self->current_block->type_name
    if ($op->field_name || q()) eq '__typename';
  my $slot = $self->current_slot || $op->bound_slot;
  my $resolver = $slot ? $slot->resolve : undef;
  my $return_type = $self->current_return_type;
  my $args = $self->resolve_args_for_current_field;

  if ($resolver) {
    my $info = $self->build_lazy_info_for_current_field($path_frame);
    return $resolver->($source, $args, $self->context, $info, $return_type);
  }

  return $source->{ $op->field_name } if ref($source) eq 'HASH';
  return;
}

sub resolve_explicit {
  my ($self, $source, $path_frame) = @_;
  return $self->resolve_default($source, $path_frame);
}

sub complete_resolved_value {
  my ($self, $value, $path_frame) = @_;
  my $op = $self->current_op;
  my $dispatch = $op->complete_dispatch;
  return $dispatch->($self, $value, $path_frame);
}

sub complete_generic {
  my ($self, $value, $path_frame) = @_;
  return $self->scalar_outcome($value);
}

sub complete_object {
  my ($self, $value, $path_frame) = @_;
  return $self->complete_object_value($value, $path_frame);
}

sub complete_list {
  my ($self, $value, $path_frame) = @_;
  return $self->complete_list_value($value, $path_frame);
}

sub complete_abstract {
  my ($self, $value, $path_frame) = @_;
  return $self->complete_abstract_value($value, $path_frame);
}

sub execute_child_block {
  my ($self, $block, $source, $path_frame) = @_;
  return $self->execute_block($block, $source, $path_frame);
}

sub current_child_block {
  my ($self) = @_;
  my $op = $self->current_op or return;
  return $op->bound_child_block || $self->program->block_by_name($op->child_block_name);
}

sub current_abstract_child_block {
  my ($self, $runtime_type_name) = @_;
  my $op = $self->current_op or return;
  return ($op->bound_abstract_child_blocks || {})->{$runtime_type_name}
    || do {
      my $child_block_name = ($op->abstract_child_blocks || {})->{$runtime_type_name};
      $child_block_name ? $self->program->block_by_name($child_block_name) : undef;
    };
}

sub current_return_type {
  my ($self) = @_;
  my $slot = $self->current_slot || ($self->current_op ? $self->current_op->bound_slot : undef);
  return $slot->return_type if $slot && $slot->return_type;
  if (my $op = $self->current_op) {
    my $type_name = $op->return_type_name;
    return $self->runtime_schema->runtime_cache->{name2type}{$type_name}
      if defined $type_name;
  }
  my $block = $self->current_block;
  return if !$block;
  return $self->runtime_schema->runtime_cache->{name2type}{ $block->type_name };
}

sub build_lazy_info_for_current_field {
  my ($self, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::LazyInfo->new(
    state => $self,
    runtime_schema => $self->runtime_schema,
    block => $self->current_block,
    instruction => $self->current_op,
    path_frame => $path_frame,
  );
}

sub resolve_args_for_current_field {
  my ($self) = @_;
  my $op = $self->current_op or return $self->empty_args;
  my $mode = $op->args_mode || 'NONE';
  my $arg_defs = $op->arg_defs || {};
  return $self->empty_args if !keys %$arg_defs;
  return $self->_coerce_static_args($arg_defs, {})
    if $mode eq 'STATIC' && !$op->args_payload;
  return $self->_coerce_static_args($arg_defs, $op->args_payload || {})
    if $mode eq 'STATIC';
  return $self->_coerce_dynamic_args($arg_defs, $op->args_payload || {})
    if $mode eq 'DYNAMIC';
  return $self->_coerce_static_args($arg_defs, {});
}

sub object_outcome_from_child_block {
  my ($self, $block, $value, $path_frame) = @_;
  my $child_value = $self->execute_child_block($block, $value, $path_frame);
  if ($self->promise_code && is_promise_value($self->promise_code, $child_value)) {
    return then_promise($self->promise_code, $child_value, sub {
      return GraphQL::Houtou::Runtime::Outcome->object($_[0]);
    });
  }
  return GraphQL::Houtou::Runtime::Outcome->object($child_value);
}

sub scalar_outcome {
  my ($self, $value, $error_record) = @_;
  return GraphQL::Houtou::Runtime::Outcome->scalar(
    $value,
    ($error_record ? [ $error_record ] : []),
  );
}

sub complete_object_value {
  my ($self, $value, $path_frame) = @_;
  return $self->scalar_outcome(undef) if !defined $value;
  my $child = $self->current_child_block;
  return $self->scalar_outcome($value) if !$child;
  return $self->object_outcome_from_child_block($child, $value, $path_frame);
}

sub complete_list_value {
  my ($self, $value, $path_frame) = @_;
  return $self->scalar_outcome(undef) if !defined $value;
  return $self->scalar_outcome($value) if ref($value) ne 'ARRAY';

  my $child = $self->current_child_block;
  my @items;
  for my $i (0 .. $#$value) {
    my $item_path = GraphQL::Houtou::Runtime::PathFrame->new(parent => $path_frame, key => $i);
    push @items, $child ? $self->execute_block($child, $value->[$i], $item_path) : $value->[$i];
  }

  if ($self->promise_code && grep { is_promise_value($self->promise_code, $_) } @items) {
    my $aggregate = GraphQL::Houtou::Promise::Adapter::all_promise($self->promise_code, @items);
    return then_promise($self->promise_code, $aggregate, sub {
      my @resolved = _promise_all_values_to_array(@_);
      return GraphQL::Houtou::Runtime::Outcome->list(\@resolved);
    });
  }

  return GraphQL::Houtou::Runtime::Outcome->list(\@items);
}

sub complete_abstract_value {
  my ($self, $value, $path_frame) = @_;
  return $self->scalar_outcome(undef) if !defined $value;

  my ($runtime_type, $error_record) = $self->resolve_runtime_type_for_current_field($value, $path_frame);
  return $self->scalar_outcome(undef, $error_record) if $error_record;
  return $self->scalar_outcome($value) if !$runtime_type;

  my $child = $self->current_abstract_child_block($runtime_type->name);
  return $self->scalar_outcome($value) if !$child;

  return $self->object_outcome_from_child_block($child, $value, $path_frame);
}

sub resolve_runtime_type_for_current_field {
  my ($self, $value, $path_frame, %args) = @_;
  my $op = $self->current_op;
  my $dispatch = $args{dispatch} || $op->abstract_dispatch;
  my $cache = $self->runtime_schema->runtime_cache;
  my $slot = $args{slot} || $self->current_slot || $op->bound_slot;
  my $abstract_type = $dispatch ? $dispatch->{abstract_type} : ($slot ? $slot->return_type : undef);
  return if !$abstract_type;
  my $abstract_name = $dispatch ? $dispatch->{abstract_name} : $abstract_type->name;
  my $has_callbacks =
       ($dispatch ? $dispatch->{tag_resolver} : $cache->{tag_resolver_map}{$abstract_name})
    || ($dispatch ? $dispatch->{resolve_type} : $cache->{resolve_type_map}{$abstract_name})
    || @{ ($dispatch ? $dispatch->{possible_types} : $cache->{possible_types}{$abstract_name}) || [] };
  my $info = $args{info};
  if (!$info && $has_callbacks) {
    if ($args{info_builder}) {
      $info = $args{info_builder}->();
    }
    $info ||= GraphQL::Houtou::Runtime::LazyInfo->new(
      state => $self,
      runtime_schema => $self->runtime_schema,
      block => $self->current_block,
      instruction => $op,
      path_frame => $path_frame,
    );
  }

  my ($runtime_type, $error) = GraphQL::Houtou::XS::VM::resolve_runtime_type_xs(
    $dispatch,
    $cache,
    $value,
    $self->context,
    $info,
    $abstract_type,
  );
  return (undef, $self->_error_record($error, $path_frame)) if defined $error;
  return (undef, undef) if !defined $runtime_type;
  return ($runtime_type, undef);
}

sub execute_block {
  my ($self, $block, $source, $base_path) = @_;
  if (!$self->promise_code) {
    GraphQL::Houtou::_bootstrap_xs();
    return GraphQL::Houtou::XS::VM::exec_state_execute_block_xs(
      $self,
      $block,
      $source,
      $base_path,
    );
  }
  return $self->_execute_block_perl($block, $source, $base_path);
}

sub _execute_block_perl {
  my ($self, $block, $source, $base_path) = @_;
  my ($snapshot) = $self->enter_block($block);
  while (my $op = $self->advance_current_op) {
    next if !$self->should_execute_current_op($op);
    $self->enter_current_field($source, $base_path);
    my $dispatch = $op->run_dispatch || \&GraphQL::Houtou::Runtime::ExecState::execute_current_op;
    my $outcome = $dispatch->($self);
    $self->consume_current_field_outcome($outcome);
  }
  return $self->finalize_current_block($snapshot);
}

sub finalize_response {
  my ($self, $data) = @_;
  if ($self->promise_code && is_promise_value($self->promise_code, $data)) {
    return then_promise($self->promise_code, $data, sub {
      return {
        data => $_[0],
        errors => $self->writer->materialize_errors,
      };
    });
  }
  return {
    data => $data,
    errors => $self->writer->materialize_errors,
  };
}

sub should_execute_current_op {
  my ($self, $op) = @_;
  my $mode = $op->directives_mode || 'NONE';
  return 1 if $mode eq 'NONE';
  my $guards = $op->directives_payload || [];
  return $self->_evaluate_runtime_guards($guards, $self->variables || {});
}

sub _coerce_static_args {
  my ($self, $arg_defs, $payload) = @_;
  return GraphQL::Houtou::Runtime::InputCoercion::coerce_static_args(
    $self->runtime_schema,
    $arg_defs,
    $payload,
  );
}

sub _coerce_dynamic_args {
  my ($self, $arg_defs, $payload) = @_;
  return GraphQL::Houtou::Runtime::InputCoercion::coerce_dynamic_args(
    $self->runtime_schema,
    $arg_defs,
    $payload,
    $self->variables || {},
  );
}

sub _capture_eval {
  my ($self, $cb) = @_;
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
  my ($self, $error, $path_frame) = @_;
  chomp $error if defined $error;
  return GraphQL::Houtou::Runtime::ErrorRecord->new(
    message => "$error",
    path_frame => $path_frame,
  );
}

sub _error_outcome {
  my ($self, $error, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::Outcome->scalar(
    undef,
    [ $self->_error_record($error, $path_frame) ],
  );
}

sub _promise_all_values_to_array {
  return @{ $_[0] } if @_ == 1 && ref($_[0]) eq 'ARRAY';
  return @_;
}

sub _evaluate_runtime_guards {
  my ($self, $guards, $variables) = @_;
  return GraphQL::Houtou::Runtime::InputCoercion::evaluate_runtime_guards($guards, $variables);
}

1;
