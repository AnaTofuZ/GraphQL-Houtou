package GraphQL::Houtou::XS::SchemaCompiler;

use 5.014;
use strict;
use warnings;

use Exporter 'import';

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  compile_schema_xs
);

require GraphQL::Houtou::XS::Parser;

1;
