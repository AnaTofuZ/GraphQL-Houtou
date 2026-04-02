package GraphQL::Houtou::GraphQLJS::Util;

use 5.014;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
  rebase_loc
);

sub rebase_loc {
  my ($node, $loc) = @_;
  if (ref $node eq 'HASH') {
    if ($loc) {
      $node->{loc} = { %$loc };
    }
    else {
      delete $node->{loc};
    }
    rebase_loc($node->{$_}, $loc) for grep $_ ne 'loc', keys %$node;
    return $node;
  }
  if (ref $node eq 'ARRAY') {
    rebase_loc($_, $loc) for @$node;
  }
  return $node;
}

1;
