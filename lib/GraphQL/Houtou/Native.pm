package GraphQL::Houtou::Native;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou::XS::Parser ();
use GraphQL::Houtou::XS::VM ();

our @EXPORT_OK = qw(
  native_codes
  load_native_bundle
  load_native_runtime
  native_bundle_summary
  native_runtime_summary
  execute_native_bundle
  promise_is_promise
  promise_all
  promise_then
  promise_resolve
  promise_reject
  merge_hash_result
);

sub native_codes {
  return GraphQL::Houtou::XS::VM::native_codes_xs(@_);
}

sub load_native_bundle {
  return GraphQL::Houtou::XS::VM::load_native_bundle_xs(@_);
}

sub load_native_runtime {
  return GraphQL::Houtou::XS::VM::load_native_runtime_xs(@_);
}

sub native_bundle_summary {
  return GraphQL::Houtou::XS::VM::native_bundle_summary_xs(@_);
}

sub native_runtime_summary {
  return GraphQL::Houtou::XS::VM::native_runtime_summary_xs(@_);
}

sub execute_native_bundle {
  return GraphQL::Houtou::XS::VM::execute_native_bundle_xs(@_);
}

sub promise_is_promise {
  return GraphQL::Houtou::XS::Execution::_promise_is_promise_xs(@_);
}

sub promise_all {
  return GraphQL::Houtou::XS::Execution::_promise_all_xs(@_);
}

sub promise_then {
  return GraphQL::Houtou::XS::Execution::_promise_then_xs(@_);
}

sub promise_resolve {
  return GraphQL::Houtou::XS::Execution::_promise_resolve_xs(@_);
}

sub promise_reject {
  return GraphQL::Houtou::XS::Execution::_promise_reject_xs(@_);
}

sub merge_hash_result {
  return GraphQL::Houtou::XS::Execution::_merge_hash_xs(@_);
}

1;
