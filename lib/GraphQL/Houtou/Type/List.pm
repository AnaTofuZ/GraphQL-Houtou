package GraphQL::Houtou::Type::List;

use 5.014;
use strict;
use warnings;

use Moo;

extends 'GraphQL::Type::List';

sub list {
  $_[0]->{_houtou_list} ||= __PACKAGE__->new(of => $_[0]);
}

sub non_null {
  require GraphQL::Houtou::Type::NonNull;
  $_[0]->{_houtou_non_null} ||= GraphQL::Houtou::Type::NonNull->new(of => $_[0]);
}

1;
