package GraphQL::Houtou::Runtime;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou::Native ();
use GraphQL::Houtou::Runtime::Compiler ();
use GraphQL::Houtou::Runtime::NativeRuntime ();
use GraphQL::Houtou::Runtime::OperationCompiler ();
use GraphQL::Houtou::Runtime::ProgramSpecializer ();
use GraphQL::Houtou::Runtime::VMCompiler ();
use GraphQL::Houtou::Runtime::VMExecutor ();

our @EXPORT_OK = qw(
  compile_schema
  build_runtime
  build_native_runtime
  inflate_schema
  compile_program
  compile_operation
  inflate_program
  inflate_operation
  execute_program
  execute_operation
  inflate_vm_bundle
  inflate_vm_program
  inflate_vm_native_bundle
  execute_vm
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

sub build_native_runtime {
  my ($schema, %opts) = @_;
  my $runtime_schema = build_runtime($schema, %opts);
  return GraphQL::Houtou::Runtime::NativeRuntime->new(
    runtime_schema => $runtime_schema,
  );
}

sub inflate_schema {
  return GraphQL::Houtou::Runtime::Compiler->inflate_schema(@_);
}

sub compile_program {
  my ($runtime_schema, $document, %opts) = @_;
  return GraphQL::Houtou::Runtime::OperationCompiler->compile_operation($runtime_schema, $document, %opts);
}

sub compile_operation {
  my ($runtime_schema, $document, %opts) = @_;
  return compile_program($runtime_schema, $document, %opts);
}

sub inflate_program {
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_program(@_);
}

sub inflate_operation {
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_program(@_);
}

sub execute_program {
  my ($runtime_schema, $program, %opts) = @_;
  my $vm_program = _is_vm_program($program)
    ? $program
    : GraphQL::Houtou::Runtime::VMCompiler->lower_program($runtime_schema, $program);
  my $candidate_program = $vm_program;
  $opts{engine} = delete $opts{vm_engine}
    if !defined $opts{engine} && exists $opts{vm_engine};
  if (!defined $opts{engine} || $opts{engine} eq 'native') {
    $candidate_program = GraphQL::Houtou::Runtime::ProgramSpecializer->specialize_for_native(
      $runtime_schema,
      $vm_program,
      %opts,
    );
  }
  $opts{engine} = _preferred_engine_for_program($candidate_program, %opts)
    if !defined $opts{engine};
  if ($opts{engine} eq 'native' && _preferred_engine_for_program($candidate_program, %opts) ne 'native') {
    die "Requested native engine for a program that cannot be specialized into the native VM path.\n";
  }
  my $program_for_exec = $opts{engine} eq 'native' ? $candidate_program : $vm_program;
  return execute_vm($runtime_schema, $program_for_exec, %opts);
}

sub execute_operation {
  my ($runtime_schema, $program, %opts) = @_;
  return execute_program($runtime_schema, $program, %opts);
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
    program => $program->to_native_compact_struct,
  };
  return execute_vm_native_bundle($runtime_schema, $descriptor, %opts);
}

sub execute_vm_native_bundle {
  my ($runtime_schema, $descriptor, %opts) = @_;
  my $bundle = GraphQL::Houtou::Native::load_native_bundle($descriptor);
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
  return GraphQL::Houtou::Native::native_codes(@_);
}

sub load_native_bundle {
  return GraphQL::Houtou::Native::load_native_bundle(@_);
}

sub load_native_runtime {
  return GraphQL::Houtou::Native::load_native_runtime(@_);
}

sub native_bundle_summary {
  return GraphQL::Houtou::Native::native_bundle_summary(@_);
}

sub native_runtime_summary {
  return GraphQL::Houtou::Native::native_runtime_summary(@_);
}

sub execute_native_bundle {
  my ($runtime_struct, $bundle, %opts) = @_;
  return GraphQL::Houtou::Native::execute_native_bundle(
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
      return 'perl' if $op->has_directives;
      my $slot = $op->bound_slot or next;
      my $shape = $slot->resolver_shape || q();
      my $mode = $slot->resolver_mode || q();
      if ($shape ne 'DEFAULT') {
        return 'perl' if $shape ne 'EXPLICIT';
        return 'perl' if $mode ne 'NATIVE';
      }
      if ($op->has_args) {
        my $args_mode = $op->args_mode || q();
        return 'perl' if $args_mode ne 'STATIC';
      }
      my $dispatch = $slot->dispatch_family || q();
      return 'perl'
        if $dispatch ne 'GENERIC'
        && $dispatch ne 'TAG'
        && $dispatch ne 'OBJECT'
        && $dispatch ne 'LIST'
        && $dispatch ne 'ABSTRACT';
    }
  }

  return 'native';
}

1;
