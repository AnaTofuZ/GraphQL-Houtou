package GraphQL::Houtou::Runtime::BlockFrame;

use 5.014;
use strict;
use warnings;

sub _xs_finalize_callback {
  my ($merge) = @_;
  return sub {
    my @resolved = @_ == 1 && ref($_[0]) eq 'ARRAY' ? @{ $_[0] } : @_;
    return GraphQL::Houtou::XS::VM::block_frame_merge_pending_state_xs($merge, \@resolved);
  };
}

1;
