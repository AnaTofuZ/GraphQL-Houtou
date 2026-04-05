package GraphQL::Houtou::XS::Validation;

use 5.014;
use strict;
use warnings;

use Exporter 'import';

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  validate_xs
);

require GraphQL::Houtou::XS::Parser;

1;
