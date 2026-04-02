package GraphQL::Houtou::Backend::Pegex;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Language::Parser ();

our @EXPORT_OK = qw(
  parse
);

sub parse {
  my ($source, $no_location) = @_;
  return GraphQL::Language::Parser::parse($source, $no_location);
}

1;
