package GraphQL::Houtou::XS::Validation;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou ();

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  validate_xs
);

BEGIN {
  GraphQL::Houtou::_bootstrap_xs();
}

1;
