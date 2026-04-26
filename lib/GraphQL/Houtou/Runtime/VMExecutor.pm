package GraphQL::Houtou::Runtime::VMExecutor;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Promise::Adapter qw(
  normalize_promise_code
);
use GraphQL::Houtou::Runtime::Cursor ();
use GraphQL::Houtou::Runtime::ExecState ();
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

sub _prepare_variables {
  my ($runtime_schema, $provided) = @_;
  return $provided || {};
}

1;
