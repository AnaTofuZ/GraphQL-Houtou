package GraphQL::Houtou::Backend::GraphQLJS::XS;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Houtou::GraphQLJS::Canonical qw(parse_canonical_document);

our @EXPORT_OK = qw(
  parse
);

sub parse {
  my ($source, $options) = @_;
  $options ||= {};
  return parse_canonical_document($source, {
    %$options,
    backend => 'xs',
  });
}

1;
