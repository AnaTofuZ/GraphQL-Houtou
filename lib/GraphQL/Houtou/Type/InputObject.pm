package GraphQL::Houtou::Type::InputObject;

use 5.014;
use strict;
use warnings;

use Moo;

extends 'GraphQL::Type::InputObject';

sub list {
  require GraphQL::Houtou::Type::List;
  $_[0]->{_houtou_list} ||= GraphQL::Houtou::Type::List->new(of => $_[0]);
}

sub non_null {
  require GraphQL::Houtou::Type::NonNull;
  $_[0]->{_houtou_non_null} ||= GraphQL::Houtou::Type::NonNull->new(of => $_[0]);
}

1;
