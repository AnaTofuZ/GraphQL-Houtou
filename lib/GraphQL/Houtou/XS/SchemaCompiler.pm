package GraphQL::Houtou::XS::SchemaCompiler;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou ();

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  compile_schema_xs
);

BEGIN {
  GraphQL::Houtou::_bootstrap_xs();
}

1;
