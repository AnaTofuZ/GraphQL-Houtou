package GraphQL::Houtou::XS::VM;

use 5.014;
use strict;
use warnings;

use Exporter 'import';

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  native_codes_xs
  load_native_bundle_xs
  load_native_runtime_xs
  native_bundle_summary_xs
  native_runtime_summary_xs
  execute_native_bundle_xs
);

require GraphQL::Houtou::XS::Parser;

1;
