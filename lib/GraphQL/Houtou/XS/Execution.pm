package GraphQL::Houtou::XS::Execution;

use 5.014;
use strict;
use warnings;

use Exporter 'import';

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  execute_xs
  _execute_fields_xs
);

require GraphQL::Houtou::XS::Parser;

1;
