package GraphQL::Houtou::Backend::GraphQLJS::XS;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Houtou::GraphQLJS::Parser ();

our @EXPORT_OK = qw(
  parse
);

sub parse {
  my ($source, $options) = @_;
  $options ||= {};
  return GraphQL::Houtou::GraphQLJS::Parser::parse($source, {
    %$options,
    backend => 'xs',
  });
}

1;
