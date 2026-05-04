package GraphQL::Houtou::Runtime::NativeRuntime;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Native ();
use GraphQL::Houtou::Runtime::InputCoercion ();
use GraphQL::Houtou::Runtime::NativeProgram ();
use GraphQL::Houtou::Runtime::VMCompiler ();
use GraphQL::Houtou::Schema ();
use JSON::PP ();

sub new {
  my ($class, %args) = @_;
  die "runtime_schema is required\n" if !$args{runtime_schema};
  return bless {
    runtime_schema => $args{runtime_schema},
    native_runtime_struct => $args{native_runtime_struct},
    native_runtime_compact_struct => $args{native_runtime_compact_struct},
    native_runtime_handle => $args{native_runtime_handle},
  }, $class;
}

sub runtime_schema { return $_[0]{runtime_schema} }

sub _native_runtime_struct {
  my ($self) = @_;
  $self->{native_runtime_struct} ||= $self->runtime_schema->to_native_exec_struct;
  return $self->{native_runtime_struct};
}

sub _native_runtime_compact_struct {
  my ($self) = @_;
  $self->{native_runtime_compact_struct} ||= $self->runtime_schema->to_native_compact_struct;
  return $self->{native_runtime_compact_struct};
}

sub _native_runtime_handle {
  my ($self) = @_;
  $self->{native_runtime_handle} ||= GraphQL::Houtou::Native::load_native_runtime(
    $self->_native_runtime_struct,
  );
  return $self->{native_runtime_handle};
}

sub compile_program {
  my ($self, $document, %opts) = @_;
  return $self->runtime_schema->compile_program($document, %opts);
}

sub compile_bundle_for_document {
  my ($self, $document, %opts) = @_;
  my $descriptor = $self->compile_bundle_descriptor_for_document($document, %opts);
  return $self->load_bundle_descriptor($descriptor);
}

sub specialize_program {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program_for_native(
    $program,
    %opts,
  );
  my $engine = __PACKAGE__->preferred_engine_for_program($candidate, %opts);
  die "Program cannot be specialized into the native VM path.\n" if $engine ne 'native';
  return $candidate;
}

sub specialize_program_for_native {
  my ($self, $program, %opts) = @_;
  return $program if !$program;

  my $variables = GraphQL::Houtou::Runtime::InputCoercion::prepare_variables(
    $self->runtime_schema,
    $program,
    $opts{variables} || {},
  );
  GraphQL::Houtou::_bootstrap_xs();
  my $native_program = ref($program) && eval { $program->isa('GraphQL::Houtou::Runtime::NativeProgram') }
    ? $program
    : $program->to_native_program_handle;
  return GraphQL::Houtou::XS::VM::specialize_native_program_xs(
    $self->_native_runtime_handle,
    $native_program,
    $variables,
  );
}

sub preferred_engine_for_program {
  my ($class, $program, %opts) = @_;
  return 'perl' if !$program;
  my $struct = $program;
  if (ref($program) && eval { $program->isa('GraphQL::Houtou::Runtime::NativeProgram') }) {
    $struct = $program;
  } elsif ($program->can('to_native_program_handle')) {
    $struct = $program->to_native_program_handle;
  } elsif ($program->can('to_native_compact_struct')) {
    $struct = $program->to_native_compact_struct;
  }
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::program_native_eligible_xs(
    $struct,
    $opts{promise_code} ? 1 : 0,
  ) ? 'native' : 'perl';
}

sub compile_bundle {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program($program, %opts);
  return $self->_load_bundle_parts($self->_native_program($candidate));
}

sub compile_bundle_descriptor {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program($program, %opts);
  return {
    runtime => $self->_native_runtime_compact_struct,
    program => GraphQL::Houtou::Native::native_program_descriptor($candidate),
  };
}

sub compile_program_descriptor {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program($program, %opts);
  return GraphQL::Houtou::Native::native_program_descriptor($candidate);
}

sub compile_program_descriptor_for_document {
  my ($self, $document, %opts) = @_;
  my $program = $self->compile_program($document, %opts);
  return $self->compile_program_descriptor($program, %opts);
}

sub compile_bundle_descriptor_for_document {
  my ($self, $document, %opts) = @_;
  my $program = $self->compile_program($document, %opts);
  return $self->compile_bundle_descriptor($program, %opts);
}

sub _load_bundle_parts {
  my ($self, $program) = @_;
  return GraphQL::Houtou::Native::load_native_bundle_from_handles(
    $self->_native_runtime_handle,
    $program,
  );
}

sub _native_program {
  my ($self, $program) = @_;
  return $program if ref($program) && eval { $program->isa('GraphQL::Houtou::Runtime::NativeProgram') };
  return GraphQL::Houtou::Runtime::NativeProgram->from_vm_program($program);
}

sub load_bundle_descriptor {
  my ($self, $descriptor) = @_;
  return GraphQL::Houtou::Native::load_native_bundle($descriptor);
}

sub inflate_bundle_descriptor {
  my ($self, $descriptor) = @_;
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_native_bundle(
    $self->runtime_schema,
    $descriptor,
  );
}

sub dump_bundle_descriptor {
  my ($self, $program, $path, %opts) = @_;
  my $descriptor = $self->compile_bundle_descriptor($program, %opts);
  open my $fh, '>', $path or die "Cannot open $path for write: $!";
  print {$fh} JSON::PP::encode_json($descriptor);
  close $fh;
  return $descriptor;
}

sub dump_bundle_descriptor_for_document {
  my ($self, $document, $path, %opts) = @_;
  my $descriptor = $self->compile_bundle_descriptor_for_document($document, %opts);
  open my $fh, '>', $path or die "Cannot open $path for write: $!";
  print {$fh} JSON::PP::encode_json($descriptor);
  close $fh;
  return $descriptor;
}

sub load_bundle_descriptor_file {
  my ($self, $path) = @_;
  open my $fh, '<', $path or die "Cannot open $path for read: $!";
  local $/;
  my $json = <$fh>;
  close $fh;
  my $descriptor = JSON::PP::decode_json($json);
  return $self->load_bundle_descriptor($descriptor);
}

sub execute_program {
  my ($self, $program, %opts) = @_;
  require GraphQL::Houtou::Runtime::VMCompiler;

  if (ref($program) && eval { $program->isa('GraphQL::Houtou::Runtime::NativeProgram') }) {
    die "engine => 'perl' is no longer supported for native program handles.\n"
      if defined $opts{engine} && $opts{engine} eq 'perl';
    return $self->execute_compact_program($program, %opts);
  }

  my $vm_program = $program->isa('GraphQL::Houtou::Runtime::VMProgram')
    ? $program
    : GraphQL::Houtou::Runtime::VMCompiler->lower_program($self->runtime_schema, $program);

  if ($opts{promise_code}) {
    require GraphQL::Houtou::Runtime::ExecState;
    return GraphQL::Houtou::Runtime::ExecState->run_program($self->runtime_schema, $vm_program, %opts);
  }

  die "engine => 'perl' is no longer supported for sync runtime execution.\n"
    if defined $opts{engine} && $opts{engine} eq 'perl';

  $opts{engine} = delete $opts{vm_engine}
    if !defined $opts{engine} && exists $opts{vm_engine};
  my $prepared_variables = GraphQL::Houtou::Runtime::InputCoercion::prepare_variables(
    $self->runtime_schema,
    $vm_program,
    $opts{variables} || {},
  );
  GraphQL::Houtou::_bootstrap_xs();
  my $native_program = $vm_program->to_native_program_handle;
  my $candidate = GraphQL::Houtou::XS::VM::specialize_native_program_xs(
    $self->_native_runtime_handle,
    $native_program,
    $prepared_variables,
  );
  return $self->execute_compact_program($candidate, %opts, variables => $prepared_variables);
}

sub execute_compact_program {
  my ($self, $program, %opts) = @_;
  my $native_program = $self->_native_program($program);
  return GraphQL::Houtou::Native::execute_native_program_handle(
    $self->_native_runtime_handle,
    $native_program,
    $opts{root_value},
    $opts{context},
    $opts{variables},
  );
}

sub execute_bundle_descriptor {
  my ($self, $descriptor, %opts) = @_;
  my $bundle = $self->load_bundle_descriptor($descriptor);
  return $self->execute_bundle($bundle, %opts);
}

sub execute_document {
  my ($self, $document, %opts) = @_;
  my $program = $self->compile_program($document, %opts);
  return $self->execute_program($program, %opts);
}

sub execute_bundle {
  my ($self, $bundle, %opts) = @_;
  return GraphQL::Houtou::Native::execute_native_bundle(
    $self->_native_runtime_handle,
    $bundle,
    $opts{root_value},
    $opts{context},
    $opts{variables},
  );
}

1;
