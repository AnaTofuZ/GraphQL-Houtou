package GraphQL::Houtou::Runtime::VMExecutor;

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
use GraphQL::Houtou::Runtime::ExecState ();
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

  my $data = $state->execute_block($program->root_block, $opts{root_value});
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

sub _execute_op {
  my ($state) = @_;
  return $state->run_current_field_via(\&_resolve_field_value, \&_complete_resolved_value);
}

sub _run_default_generic { return $_[0]->run_current_field_via(\&_resolve_default,  \&_complete_generic) }
sub _run_default_object  { return $_[0]->run_current_field_via(\&_resolve_default,  \&_complete_object) }
sub _run_default_list    { return $_[0]->run_current_field_via(\&_resolve_default,  \&_complete_list) }
sub _run_default_abstract { return $_[0]->run_current_field_via(\&_resolve_default,  \&_complete_abstract) }
sub _run_explicit_generic { return $_[0]->run_current_field_via(\&_resolve_explicit, \&_complete_generic) }
sub _run_explicit_object { return $_[0]->run_current_field_via(\&_resolve_explicit, \&_complete_object) }
sub _run_explicit_list   { return $_[0]->run_current_field_via(\&_resolve_explicit, \&_complete_list) }
sub _run_explicit_abstract { return $_[0]->run_current_field_via(\&_resolve_explicit, \&_complete_abstract) }

sub _resolve_field_value {
  my ($state, $source, $path_frame) = @_;
  my $op = $state->current_op;
  my $dispatch = $op->resolve_dispatch;
  return $dispatch->($state, $source, $path_frame);
}

sub _resolve_default {
  my ($state, $source, $path_frame) = @_;
  my $op = $state->current_op;
  my $slot = $state->current_slot || $op->bound_slot;
  my $resolver = $slot ? $slot->resolve : undef;
  my $return_type = $state->current_return_type;
  my $args = $state->resolve_args_for_current_field;

  if ($resolver) {
    my $info = $state->build_lazy_info_for_current_field($path_frame);
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
  my $op = $state->current_op;
  my $dispatch = $op->complete_dispatch;
  return $dispatch->($state, $value, $path_frame);
}

sub _complete_generic {
  my ($state, $value, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value);
}

sub _complete_object {
  my ($state, $value, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;

  my $child = $state->current_child_block;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$child;

  return $state->object_outcome_from_child_block($child, $value, $path_frame);
}

sub _complete_list {
  my ($state, $value, $path_frame) = @_;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if ref($value) ne 'ARRAY';

  my $child = $state->current_child_block;
  my @items;
  for my $i (0 .. $#$value) {
    my $item_path = GraphQL::Houtou::Runtime::PathFrame->new(parent => $path_frame, key => $i);
    push @items, $child ? $state->execute_block($child, $value->[$i], $item_path) : $value->[$i];
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
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => undef)
    if !defined $value;

  my ($runtime_type, $error_record) = $state->resolve_runtime_type_for_current_field($value, $path_frame);
  return GraphQL::Houtou::Runtime::Outcome->new(
    kind => 'SCALAR',
    scalar_value => undef,
    error_records => [ $error_record ],
  ) if $error_record;
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$runtime_type;

  my $child = $state->current_abstract_child_block($runtime_type->name);
  return GraphQL::Houtou::Runtime::Outcome->new(kind => 'SCALAR', scalar_value => $value)
    if !$child;

  return $state->object_outcome_from_child_block($child, $value, $path_frame);
}

sub _prepare_variables {
  my ($runtime_schema, $provided) = @_;
  return $provided || {};
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
