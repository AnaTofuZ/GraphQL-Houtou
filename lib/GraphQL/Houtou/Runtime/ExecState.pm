package GraphQL::Houtou::Runtime::ExecState;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Promise::Adapter qw(is_promise_value then_promise);
use GraphQL::Houtou::Runtime::BlockFrame ();
use GraphQL::Houtou::Runtime::ErrorRecord ();
use GraphQL::Houtou::Runtime::FieldFrame ();
use GraphQL::Houtou::Runtime::LazyInfo ();
use GraphQL::Houtou::Runtime::Outcome ();
use GraphQL::Houtou::Runtime::PathFrame ();

sub new {
  my ($class, %args) = @_;
  return bless {
    runtime_schema => $args{runtime_schema},
    program => $args{program},
    cursor => $args{cursor},
    frame => $args{frame},
    frame_stack => $args{frame_stack} || [],
    field_frame => $args{field_frame},
    writer => $args{writer},
    context => $args{context},
    variables => $args{variables} || {},
    root_value => $args{root_value},
    promise_code => $args{promise_code},
    empty_args => $args{empty_args} || {},
  }, $class;
}

sub runtime_schema { return $_[0]{runtime_schema} }
sub program { return $_[0]{program} }
sub cursor { return $_[0]{cursor} }
sub current_block { return $_[0]{cursor}->block }
sub current_op { return $_[0]{cursor}->current_op }
sub current_slot { return $_[0]{cursor}->current_slot }
sub frame { return $_[0]{frame} }
sub frame_stack { return $_[0]{frame_stack} }
sub field_frame { return $_[0]{field_frame} }
sub writer { return $_[0]{writer} }
sub context { return $_[0]{context} }
sub variables { return $_[0]{variables} }
sub root_value { return $_[0]{root_value} }
sub promise_code { return $_[0]{promise_code} }
sub empty_args { return $_[0]{empty_args} }

sub push_frame {
  my ($self, $frame) = @_;
  push @{ $self->{frame_stack} }, $frame;
  $self->{frame} = $frame;
  return $frame;
}

sub pop_frame {
  my ($self) = @_;
  my $frame = pop @{ $self->{frame_stack} };
  $self->{frame} = $self->{frame_stack}[-1];
  return $frame;
}

sub current_frame { return $_[0]{frame} }

sub enter_field {
  my ($self, $source, $path_frame) = @_;
  my $field = GraphQL::Houtou::Runtime::FieldFrame->new(
    source => $source,
    path_frame => $path_frame,
  );
  $self->{field_frame} = $field;
  return $field;
}

sub leave_field {
  my ($self) = @_;
  my $field = $self->{field_frame};
  $self->{field_frame} = undef;
  return $field;
}

sub current_field_frame { return $_[0]{field_frame} }
sub current_path_frame { return $_[0]{field_frame} ? $_[0]{field_frame}->path_frame : undef }

sub advance_current_op {
  my ($self) = @_;
  return $self->{cursor}->advance_op;
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
  my $snapshot = {
    cursor => $self->{cursor}->snapshot,
  };
  $self->{cursor}->enter_block($block);
  my $frame = $self->push_frame(GraphQL::Houtou::Runtime::BlockFrame->new);
  return ($snapshot, $frame);
}

sub leave_block {
  my ($self, $snapshot, $result) = @_;
  $self->pop_frame;
  $self->{cursor}->restore($snapshot->{cursor}) if $snapshot && $snapshot->{cursor};
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
    if $mode eq 'STATIC' && !$op->{args_payload};
  return $self->_coerce_static_args($arg_defs, $op->{args_payload} || {})
    if $mode eq 'STATIC';
  return $self->_coerce_dynamic_args($arg_defs, $op->{args_payload} || {})
    if $mode eq 'DYNAMIC';
  return $self->_coerce_static_args($arg_defs, {});
}

sub object_outcome_from_child_block {
  my ($self, $block, $value, $path_frame) = @_;
  my $child_value = $self->execute_child_block($block, $value, $path_frame);
  if ($self->promise_code && is_promise_value($self->promise_code, $child_value)) {
    return then_promise($self->promise_code, $child_value, sub {
      return GraphQL::Houtou::Runtime::Outcome->new(kind => 'OBJECT', object_value => $_[0]);
    });
  }
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'OBJECT', object_value => $child_value);
}

sub scalar_outcome {
  my ($self, $value, $error_record) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(
    kind => 'SCALAR',
    scalar_value => $value,
    error_records => $error_record ? [ $error_record ] : [],
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
      return GraphQL::Houtou::Runtime::Outcome->new(kind => 'LIST', list_value => \@resolved);
    });
  }

  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'LIST', list_value => \@items);
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
  my $info;
  my $build_info = sub {
    my $built_info = $args{info};
    if (!$built_info && $args{info_builder}) {
      $built_info = $args{info_builder}->();
    }
    $info ||= $built_info || GraphQL::Houtou::Runtime::LazyInfo->new(
        state => $self,
        runtime_schema => $self->runtime_schema,
        block => $self->current_block,
        instruction => $op,
        path_frame => $path_frame,
      );
    return $info;
  };

  if (my $tag_resolver = $dispatch ? $dispatch->{tag_resolver} : $cache->{tag_resolver_map}{$abstract_name}) {
    my ($ok, $tag) = $self->_capture_eval(sub {
      return $tag_resolver->($value, $self->context, $build_info->(), $abstract_type);
    });
    return (undef, $self->_error_record($tag, $path_frame)) if !$ok;
    if (defined $tag) {
      my $type = (($dispatch ? $dispatch->{tag_map} : $cache->{runtime_tag_map}{$abstract_name}) || {})->{$tag};
      return ($type, undef) if $type;
    }
  }

  if (my $resolve_type = $dispatch ? $dispatch->{resolve_type} : $cache->{resolve_type_map}{$abstract_name}) {
    my ($ok, $resolved) = $self->_capture_eval(sub {
      return $resolve_type->($value, $self->context, $build_info->(), $abstract_type);
    });
    return (undef, $self->_error_record($resolved, $path_frame)) if !$ok;
    return if !defined $resolved;
    return (ref($resolved) ? $resolved : (($dispatch ? $dispatch->{name2type} : $cache->{name2type})->{$resolved}), undef);
  }

  for my $type (@{ ($dispatch ? $dispatch->{possible_types} : $cache->{possible_types}{$abstract_name}) || [] }) {
    next if !$type;
    my $cb = ($dispatch ? $dispatch->{is_type_of_map} : $cache->{is_type_of_map})->{ $type->name } or next;
    my ($ok, $matched) = $self->_capture_eval(sub {
      return $cb->($value, $self->context, $build_info->(), $type);
    });
    return (undef, $self->_error_record($matched, $path_frame)) if !$ok;
    return ($type, undef) if $matched;
  }

  return (undef, undef);
}

sub execute_block {
  my ($self, $block, $source, $base_path) = @_;
  my ($snapshot) = $self->enter_block($block);
  while (my $op = $self->advance_current_op) {
    next if !$self->should_execute_current_op($op);
    $self->enter_current_field($source, $base_path);
    my $dispatch = $op->run_dispatch || \&GraphQL::Houtou::Runtime::VMExecutor::_execute_op;
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
  return 1;
}

sub _coerce_static_args {
  my ($self, $arg_defs, $payload) = @_;
  my %values;
  for my $name (keys %{$arg_defs || {}}) {
    my $arg_def = $arg_defs->{$name} || {};
    next if !exists $payload->{$name} && !$arg_def->{has_default};
    $values{$name} = exists $payload->{$name} ? $payload->{$name} : $arg_def->{default_value};
  }
  return \%values;
}

sub _coerce_dynamic_args {
  my ($self, $arg_defs, $payload) = @_;
  my %values;
  for my $name (keys %{$arg_defs || {}}) {
    next if !exists $payload->{$name};
    my $raw = $payload->{$name};
    if (ref($raw) eq 'SCALAR') {
      $values{$name} = $self->variables->{ $$raw };
      next;
    }
    $values{$name} = $raw;
  }
  return \%values;
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
  return GraphQL::Houtou::Runtime::Outcome->new(
    kind => 'SCALAR',
    scalar_value => undef,
    error_records => [ $self->_error_record($error, $path_frame) ],
  );
}

sub _promise_all_values_to_array {
  return @{ $_[0] } if @_ == 1 && ref($_[0]) eq 'ARRAY';
  return @_;
}

1;
