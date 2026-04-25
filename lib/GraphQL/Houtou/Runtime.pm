package GraphQL::Houtou::Runtime;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou::Runtime::Compiler ();
use GraphQL::Houtou::Runtime::Executor ();
use GraphQL::Houtou::Runtime::OperationCompiler ();
use GraphQL::Houtou::Runtime::VMCompiler ();

our @EXPORT_OK = qw(
  compile_schema
  inflate_schema
  compile_operation
  inflate_operation
  execute_operation
  lower_vm_program
  inflate_vm_program
);

sub compile_schema {
  return GraphQL::Houtou::Runtime::Compiler->compile_schema(@_);
}

sub inflate_schema {
  return GraphQL::Houtou::Runtime::Compiler->inflate_schema(@_);
}

sub compile_operation {
  return GraphQL::Houtou::Runtime::OperationCompiler->compile_operation(@_);
}

sub inflate_operation {
  return GraphQL::Houtou::Runtime::OperationCompiler->inflate_operation(@_);
}

sub execute_operation {
  return GraphQL::Houtou::Runtime::Executor->execute_operation(@_);
}

sub lower_vm_program {
  return GraphQL::Houtou::Runtime::VMCompiler->lower_program(@_);
}

sub inflate_vm_program {
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_program(@_);
}

1;
