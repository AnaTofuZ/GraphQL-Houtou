package GraphQL::Houtou::Type::NonNull;

use 5.014;
use strict;
use warnings;

use Moo;

extends 'GraphQL::Type::NonNull';

sub list {
  require GraphQL::Houtou::Type::List;
  $_[0]->{_houtou_list} ||= GraphQL::Houtou::Type::List->new(of => $_[0]);
}

1;
