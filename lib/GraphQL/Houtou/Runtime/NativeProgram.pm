package GraphQL::Houtou::Runtime::NativeProgram;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Native ();

sub from_descriptor {
  my ($class, $descriptor) = @_;
  return GraphQL::Houtou::Native::load_native_program($descriptor);
}

sub from_vm_program {
  my ($class, $program) = @_;
  die "VMProgram is required\n" if !$program;
  return $program->to_native_program_handle;
}

sub summary {
  my ($self) = @_;
  return GraphQL::Houtou::Native::native_program_summary($self);
}

1;
