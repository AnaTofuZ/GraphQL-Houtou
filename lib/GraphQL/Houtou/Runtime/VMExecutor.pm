package GraphQL::Houtou::Runtime::VMExecutor;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Promise::Adapter qw(
  normalize_promise_code
);
use GraphQL::Houtou::Runtime::Cursor ();
use GraphQL::Houtou::Runtime::ExecState ();
use GraphQL::Houtou::Runtime::Outcome ();
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
  return $state->finalize_response($data);
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
  return $state->scalar_outcome($value);
}

sub _complete_object {
  my ($state, $value, $path_frame) = @_;
  return $state->complete_object_value($value, $path_frame);
}

sub _complete_list {
  my ($state, $value, $path_frame) = @_;
  return $state->complete_list_value($value, $path_frame);
}

sub _complete_abstract {
  my ($state, $value, $path_frame) = @_;
  return $state->complete_abstract_value($value, $path_frame);
}

sub _prepare_variables {
  my ($runtime_schema, $provided) = @_;
  return $provided || {};
}

1;
