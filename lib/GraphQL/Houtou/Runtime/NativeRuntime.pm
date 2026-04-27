package GraphQL::Houtou::Runtime::NativeRuntime;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Native ();
use GraphQL::Houtou::Runtime::NativeBundle ();
use GraphQL::Houtou::Runtime::ProgramSpecializer ();
use JSON::PP ();

sub new {
  my ($class, %args) = @_;
  die "runtime_schema is required\n" if !$args{runtime_schema};
  return bless {
    runtime_schema => $args{runtime_schema},
    native_runtime_struct => $args{native_runtime_struct},
    native_runtime_handle => $args{native_runtime_handle},
  }, $class;
}

sub runtime_schema { return $_[0]{runtime_schema} }

sub native_runtime_struct {
  my ($self) = @_;
  $self->{native_runtime_struct} ||= $self->runtime_schema->to_native_exec_struct;
  return $self->{native_runtime_struct};
}

sub native_runtime_handle {
  my ($self) = @_;
  $self->{native_runtime_handle} ||= GraphQL::Houtou::Native::load_native_runtime(
    $self->native_runtime_struct,
  );
  return $self->{native_runtime_handle};
}

sub compile_program {
  my ($self, $document, %opts) = @_;
  return $self->runtime_schema->compile_program($document, %opts);
}

sub specialize_program {
  my ($self, $program, %opts) = @_;
  my $candidate = GraphQL::Houtou::Runtime::ProgramSpecializer->specialize_for_native(
    $self->runtime_schema,
    $program,
    %opts,
  );
  require GraphQL::Houtou::Runtime;
  my $engine = GraphQL::Houtou::Runtime::_preferred_engine_for_program($candidate, %opts);
  die "Program cannot be specialized into the native VM path.\n" if $engine ne 'native';
  return $candidate;
}

sub compile_bundle {
  my ($self, $program, %opts) = @_;
  my $descriptor = $self->compile_bundle_descriptor($program, %opts);
  return $self->load_bundle_descriptor($descriptor);
}

sub compile_bundle_descriptor {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program($program, %opts);
  return {
    runtime => $self->runtime_schema->to_native_compact_struct,
    program => $candidate->to_native_compact_struct,
  };
}

sub load_bundle_descriptor {
  my ($self, $descriptor) = @_;
  my $bundle_handle = GraphQL::Houtou::Native::load_native_bundle($descriptor);
  my $program = $self->runtime_schema->inflate_vm_native_bundle($descriptor);
  return GraphQL::Houtou::Runtime::NativeBundle->new(
    runtime => $self,
    program => $program,
    descriptor => $descriptor,
    native_bundle_handle => $bundle_handle,
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
  my $bundle = $self->compile_bundle($program, %opts);
  return $self->execute_bundle($bundle, %opts);
}

sub execute_bundle {
  my ($self, $bundle, %opts) = @_;
  return GraphQL::Houtou::Native::execute_native_bundle(
    $self->native_runtime_handle,
    $bundle->native_bundle_handle,
    $opts{root_value},
    $opts{context},
  );
}

1;
