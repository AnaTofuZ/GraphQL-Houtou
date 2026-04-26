package GraphQL::Houtou::Runtime;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou::XS::VM qw(
  execute_native_bundle_xs
  load_native_bundle_xs
  load_native_runtime_xs
);
use GraphQL::Houtou::Runtime::Compiler ();
use GraphQL::Houtou::Runtime::Executor ();
use GraphQL::Houtou::Runtime::OperationCompiler ();
use GraphQL::Houtou::Runtime::VMCompiler ();
use GraphQL::Houtou::Runtime::VMExecutor ();

our @EXPORT_OK = qw(
  compile_schema
  build_runtime
  inflate_schema
  compile_program
  compile_operation
  inflate_program
  inflate_operation
  execute_program_perl
  execute_operation_perl
  execute_program
  execute_operation
  lower_program_to_vm
  lower_vm_program
  inflate_vm_bundle
  inflate_vm_program
  inflate_vm_native_bundle
  execute_vm
  execute_vm_program
  execute_vm_native_bundle
);

sub compile_schema {
  return GraphQL::Houtou::Runtime::Compiler->compile_schema(@_);
}

sub build_runtime {
  return GraphQL::Houtou::Runtime::Compiler->compile_schema(@_);
}

sub inflate_schema {
  return GraphQL::Houtou::Runtime::Compiler->inflate_schema(@_);
}

sub compile_program {
  return GraphQL::Houtou::Runtime::OperationCompiler->compile_operation(@_);
}

sub compile_operation {
  return GraphQL::Houtou::Runtime::OperationCompiler->compile_operation(@_);
}

sub inflate_program {
  return GraphQL::Houtou::Runtime::OperationCompiler->inflate_operation(@_);
}

sub inflate_operation {
  return GraphQL::Houtou::Runtime::OperationCompiler->inflate_operation(@_);
}

sub execute_program {
  return GraphQL::Houtou::Runtime::Executor->execute_operation(@_);
}

sub execute_operation {
  return GraphQL::Houtou::Runtime::Executor->execute_operation(@_);
}

sub execute_program_perl {
  return GraphQL::Houtou::Runtime::Executor->execute_operation(@_);
}

sub execute_operation_perl {
  return GraphQL::Houtou::Runtime::Executor->execute_operation(@_);
}

sub lower_program_to_vm {
  return GraphQL::Houtou::Runtime::VMCompiler->lower_program(@_);
}

sub lower_vm_program {
  return GraphQL::Houtou::Runtime::VMCompiler->lower_program(@_);
}

sub inflate_vm_bundle {
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_native_bundle(@_);
}

sub inflate_vm_program {
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_program(@_);
}

sub inflate_vm_native_bundle {
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_native_bundle(@_);
}

sub execute_vm {
  my ($runtime_schema, $program, %opts) = @_;
  if (($opts{vm_engine} || q()) eq 'perl') {
    return GraphQL::Houtou::Runtime::VMExecutor->execute_program($runtime_schema, $program, %opts);
  }
  my $descriptor = {
    runtime => $runtime_schema->to_native_exec_struct,
    program => $program->to_native_struct,
  };
  return execute_vm_native_bundle($runtime_schema, $descriptor, %opts);
}

sub execute_vm_program {
  my ($runtime_schema, $program, %opts) = @_;
  return execute_vm($runtime_schema, $program, %opts);
}

sub execute_vm_native_bundle {
  my ($runtime_schema, $descriptor, %opts) = @_;
  my $bundle = load_native_bundle_xs($descriptor);
  my $runtime_struct = $runtime_schema->can('to_native_exec_struct')
    ? $runtime_schema->to_native_exec_struct
    : (
      ref($descriptor) eq 'HASH' && $descriptor->{runtime}
        ? $descriptor->{runtime}
        : $runtime_schema
    );
  return execute_native_bundle_xs(
    $runtime_struct,
    $bundle,
    $opts{root_value},
    $opts{context},
  );
}

1;
