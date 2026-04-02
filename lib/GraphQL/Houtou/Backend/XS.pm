package GraphQL::Houtou::Backend::XS;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Houtou::XS::Parser qw(parse_xs);

our @EXPORT_OK = qw(
  parse
);

sub parse {
  my ($source, $no_location) = @_;
  return parse_xs($source, $no_location);
}

1;
