package GraphQL::Houtou::Runtime::ExecState;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Promise::Adapter qw(is_promise_value);
use GraphQL::Houtou::Runtime::BlockFrame ();
use GraphQL::Houtou::Runtime::ErrorRecord ();
use GraphQL::Houtou::Runtime::FieldFrame ();
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
