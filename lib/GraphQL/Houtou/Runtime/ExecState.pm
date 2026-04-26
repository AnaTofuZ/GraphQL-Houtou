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

sub should_execute_current_op {
  my ($self, $op) = @_;
  my $mode = $op->directives_mode || 'NONE';
  return 1 if $mode eq 'NONE';
  return 1;
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

1;
