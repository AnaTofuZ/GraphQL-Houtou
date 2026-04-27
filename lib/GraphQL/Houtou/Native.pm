package GraphQL::Houtou::Native;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou ();

our @EXPORT_OK = qw(
  native_codes
  load_native_bundle
  load_native_bundle_parts
  load_native_runtime
  native_bundle_summary
  native_runtime_summary
  execute_native_bundle
);

sub _ensure_vm_xs_loaded {
  GraphQL::Houtou::_bootstrap_xs();
  return 1;
}

sub native_codes {
  _ensure_vm_xs_loaded();
  return GraphQL::Houtou::XS::VM::native_codes_xs(@_);
}

sub load_native_bundle {
  _ensure_vm_xs_loaded();
  return GraphQL::Houtou::XS::VM::load_native_bundle_xs(@_);
}

sub load_native_bundle_parts {
  _ensure_vm_xs_loaded();
  return GraphQL::Houtou::XS::VM::load_native_bundle_parts_xs(@_);
}

sub load_native_runtime {
  _ensure_vm_xs_loaded();
  return GraphQL::Houtou::XS::VM::load_native_runtime_xs(@_);
}

sub native_bundle_summary {
  _ensure_vm_xs_loaded();
  return GraphQL::Houtou::XS::VM::native_bundle_summary_xs(@_);
}

sub native_runtime_summary {
  _ensure_vm_xs_loaded();
  return GraphQL::Houtou::XS::VM::native_runtime_summary_xs(@_);
}

sub execute_native_bundle {
  _ensure_vm_xs_loaded();
  return GraphQL::Houtou::XS::VM::execute_native_bundle_xs(@_);
}

1;
