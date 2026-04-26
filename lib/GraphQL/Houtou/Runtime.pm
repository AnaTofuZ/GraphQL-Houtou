package GraphQL::Houtou::Runtime;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou::XS::VM qw(
  execute_native_bundle_xs
  load_native_bundle_xs
  load_native_runtime_xs
  native_bundle_summary_xs
  native_codes_xs
  native_runtime_summary_xs
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
  compile_lowered_program
  compile_lowered_operation
  inflate_lowered_program
  inflate_lowered_operation
  execute_lowered_program_perl
  execute_lowered_operation_perl
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
  native_codes
  load_native_bundle
  load_native_runtime
  native_bundle_summary
  native_runtime_summary
  execute_native_bundle
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
  my ($runtime_schema, $document, %opts) = @_;
  my $program = compile_lowered_program($runtime_schema, $document, %opts);
  return lower_program_to_vm($runtime_schema, $program);
}

sub compile_operation {
  my ($runtime_schema, $document, %opts) = @_;
  return compile_program($runtime_schema, $document, %opts);
}

sub compile_lowered_program {
  return GraphQL::Houtou::Runtime::OperationCompiler->compile_operation(@_);
}

sub compile_lowered_operation {
  return GraphQL::Houtou::Runtime::OperationCompiler->compile_operation(@_);
}

sub inflate_program {
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_program(@_);
}

sub inflate_operation {
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_program(@_);
}

sub inflate_lowered_program {
  return GraphQL::Houtou::Runtime::OperationCompiler->inflate_operation(@_);
}

sub inflate_lowered_operation {
  return GraphQL::Houtou::Runtime::OperationCompiler->inflate_operation(@_);
}

sub execute_program {
  my ($runtime_schema, $program, %opts) = @_;
  my $vm_program = _is_vm_program($program)
    ? $program
    : lower_program_to_vm($runtime_schema, $program);
  $opts{engine} = delete $opts{vm_engine}
    if !defined $opts{engine} && exists $opts{vm_engine};
  $opts{engine} = _preferred_engine_for_program($vm_program, %opts)
    if !defined $opts{engine};
  return execute_vm($runtime_schema, $vm_program, %opts);
}

sub execute_operation {
  my ($runtime_schema, $program, %opts) = @_;
  return execute_program($runtime_schema, $program, %opts);
}

sub execute_program_perl {
  my ($runtime_schema, $program, %opts) = @_;
  $opts{engine} = 'perl';
  return execute_program($runtime_schema, $program, %opts);
}

sub execute_operation_perl {
  my ($runtime_schema, $program, %opts) = @_;
  return execute_program_perl($runtime_schema, $program, %opts);
}

sub execute_lowered_program_perl {
  return GraphQL::Houtou::Runtime::Executor->execute_operation(@_);
}

sub execute_lowered_operation_perl {
  return GraphQL::Houtou::Runtime::Executor->execute_operation(@_);
}

sub lower_program_to_vm {
  my ($runtime_schema, $program) = @_;
  return $program if _is_vm_program($program);
  return GraphQL::Houtou::Runtime::VMCompiler->lower_program($runtime_schema, $program);
}

sub lower_vm_program {
  return lower_program_to_vm(@_);
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
  my $engine = $opts{engine};
  $engine = delete $opts{vm_engine} if !defined $engine && exists $opts{vm_engine};
  $engine = 'native' if !defined $engine;

  if ($engine eq 'perl') {
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
  my $bundle = load_native_bundle($descriptor);
  my $runtime_struct = $runtime_schema->can('to_native_exec_struct')
    ? $runtime_schema->to_native_exec_struct
    : (
      ref($descriptor) eq 'HASH' && $descriptor->{runtime}
        ? $descriptor->{runtime}
        : $runtime_schema
    );
  return execute_native_bundle($runtime_struct, $bundle, %opts);
}

sub native_codes {
  return native_codes_xs(@_);
}

sub load_native_bundle {
  return load_native_bundle_xs(@_);
}

sub load_native_runtime {
  return load_native_runtime_xs(@_);
}

sub native_bundle_summary {
  return native_bundle_summary_xs(@_);
}

sub native_runtime_summary {
  return native_runtime_summary_xs(@_);
}

sub execute_native_bundle {
  my ($runtime_struct, $bundle, %opts) = @_;
  return execute_native_bundle_xs(
    $runtime_struct,
    $bundle,
    $opts{root_value},
    $opts{context},
  );
}

sub _is_vm_program {
  my ($program) = @_;
  return !!(defined $program && ref($program) && eval { $program->isa('GraphQL::Houtou::Runtime::VMProgram') });
}

sub _preferred_engine_for_program {
  my ($program, %opts) = @_;
  return 'perl' if $opts{promise_code};
  return 'perl' if !$program || !$program->can('blocks');
  return 'perl' if keys %{ $program->variable_defs || {} };

  for my $block (@{ $program->blocks || [] }) {
    for my $op (@{ $block->ops || [] }) {
      return 'perl' if $op->has_args || $op->has_directives;
      my $slot = $op->bound_slot or next;
      return 'perl' if ($slot->resolver_shape || q()) ne 'DEFAULT';
      my $dispatch = $slot->dispatch_family || q();
      return 'perl' if $dispatch ne 'GENERIC' && $dispatch ne 'TAG';
    }
  }

  return 'native';
}

1;
