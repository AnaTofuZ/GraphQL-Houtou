package GraphQL::Houtou::Runtime::VMExecutor;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Runtime::ExecState ();

sub execute_program {
  my ($class, $runtime_schema, $program, %opts) = @_;
  return GraphQL::Houtou::Runtime::ExecState->run_program($runtime_schema, $program, %opts);
}

1;
