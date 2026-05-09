package GraphQL::Houtou::Native;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou ();

our @EXPORT_OK = qw(
  native_codes
  load_native_bundle
  load_native_bundle_from_handles
  load_native_program
  native_program_descriptor
  load_native_runtime
  native_bundle_summary
  native_program_summary
  native_runtime_summary
  execute_native_bundle
  execute_native_program
  execute_native_program_handle
);

BEGIN {
  GraphQL::Houtou::_bootstrap_xs();
}

sub native_codes {
  return GraphQL::Houtou::XS::VM::native_codes_xs(@_);
}

sub load_native_bundle {
  return GraphQL::Houtou::XS::VM::load_native_bundle_xs(@_);
}

sub load_native_bundle_from_handles {
  return GraphQL::Houtou::XS::VM::load_native_bundle_from_handles_xs(@_);
}

sub load_native_program {
  return GraphQL::Houtou::XS::VM::load_native_program_xs(@_);
}

sub native_program_descriptor {
  return GraphQL::Houtou::XS::VM::native_program_descriptor_xs(@_);
}

sub load_native_runtime {
  return GraphQL::Houtou::XS::VM::load_native_runtime_xs(@_);
}

sub native_bundle_summary {
  return GraphQL::Houtou::XS::VM::native_bundle_summary_xs(@_);
}

sub native_program_summary {
  return GraphQL::Houtou::XS::VM::native_program_summary_xs(@_);
}

sub native_runtime_summary {
  return GraphQL::Houtou::XS::VM::native_runtime_summary_xs(@_);
}

sub execute_native_bundle {
  return GraphQL::Houtou::XS::VM::execute_native_bundle_xs(@_);
}

sub execute_native_program {
  return GraphQL::Houtou::XS::VM::execute_native_program_xs(@_);
}

sub execute_native_program_handle {
  return GraphQL::Houtou::XS::VM::execute_native_program_handle_xs(@_);
}

1;
