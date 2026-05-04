package GraphQL::Houtou::Runtime::ExecState;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();

use GraphQL::Houtou::Promise::Adapter qw(is_promise_value normalize_promise_code then_promise);
use GraphQL::Houtou::Runtime::InputCoercion ();

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
  my $promise_code = normalize_promise_code($opts{promise_code});
  my $native_program = _native_program_handle($program);
  my $root_block_index = _root_block_index($native_program);
  return $class->new(
    runtime_schema => $runtime_schema,
    program => $native_program,
    cursor => GraphQL::Houtou::XS::VM::cursor_new_xs(
      'GraphQL::Houtou::Runtime::Cursor',
      undef,
      $native_program,
      $root_block_index,
      0,
      0,
      undef,
      undef,
    ),
    writer => GraphQL::Houtou::XS::VM::writer_new_xs('GraphQL::Houtou::Runtime::Writer'),
    context => $opts{context},
    variables => GraphQL::Houtou::Runtime::InputCoercion::prepare_variables(
      $runtime_schema,
      $native_program,
      $opts{variables} || {},
    ),
    root_value => $opts{root_value},
    promise_code => $promise_code,
    empty_args => {},
  );
}

sub run_program {
  my ($class, $runtime_schema, $program, %opts) = @_;
  my $native_program = _native_program_handle($program);
  my $state = $class->build_for_program($runtime_schema, $native_program, %opts);
  if (!$state->promise_code) {
    GraphQL::Houtou::_bootstrap_xs();
    return GraphQL::Houtou::XS::VM::exec_state_run_program_xs($state, $opts{root_value});
  }
  my $data = $state->execute_block(_root_block_index($native_program), $opts{root_value});
  return $state->finalize_response($data);
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

sub execute_block {
  my ($self, $block_index, $source, $base_path) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_execute_block_async_xs(
    $self,
    $block_index,
    $source,
    $base_path,
  ) if $self->promise_code;
  return GraphQL::Houtou::XS::VM::exec_state_execute_block_index_xs(
    $self,
    $block_index,
    $source,
    $base_path,
  );
}

sub finalize_response {
  my ($self, $data) = @_;
  if (!$self->promise_code) {
    GraphQL::Houtou::_bootstrap_xs();
    return GraphQL::Houtou::XS::VM::exec_state_run_program_xs($self, $self->root_value)
      if !defined $data;
  return {
    data => $data,
    errors => GraphQL::Houtou::XS::VM::writer_materialize_errors_xs($self->writer),
  };
}
if ($self->promise_code && is_promise_value($self->promise_code, $data)) {
  return then_promise($self->promise_code, $data, sub {
    return {
      data => $_[0],
      errors => GraphQL::Houtou::XS::VM::writer_materialize_errors_xs($self->writer),
    };
  });
}
return {
  data => $data,
  errors => GraphQL::Houtou::XS::VM::writer_materialize_errors_xs($self->writer),
};
}

sub _native_program_handle {
  my ($program) = @_;
  return undef if !$program;
  return $program
    if ref($program) && eval { $program->isa('GraphQL::Houtou::Runtime::NativeProgram') };
  return $program->to_native_program_handle
    if ref($program) && eval { $program->can('to_native_program_handle') };
  return $program;
}

sub _root_block_index {
  my ($program) = @_;
  my $native_program = _native_program_handle($program);
  if ($native_program && ref($native_program) && eval { $native_program->isa('GraphQL::Houtou::Runtime::NativeProgram') }) {
    GraphQL::Houtou::_bootstrap_xs();
    my $index = GraphQL::Houtou::XS::VM::native_program_root_block_index_xs($native_program);
    return defined $index ? $index : -1;
  }
  return -1;
}

1;
