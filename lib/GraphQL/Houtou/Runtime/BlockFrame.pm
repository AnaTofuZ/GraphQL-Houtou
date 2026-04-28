package GraphQL::Houtou::Runtime::BlockFrame;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();

sub new {
  my ($class, %args) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_new_xs(
    $class,
    ($args{values} || {}),
    ($args{pending_names} || []),
    ($args{pending_outcomes} || []),
  );
}

sub values {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_values_xs($_[0]);
}

sub has_pending {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_has_pending_xs($_[0]);
}

sub consume_outcome {
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::block_frame_consume_outcome_xs($_[0], $_[1], $_[2], $_[3]);
  return;
}

sub add_pending {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_add_pending_xs($_[0], $_[1], $_[2]);
}

sub _xs_finalize_callback {
  my ($merge) = @_;
  return sub {
    my @resolved = @_ == 1 && ref($_[0]) eq 'ARRAY' ? @{ $_[0] } : @_;
    return GraphQL::Houtou::XS::VM::block_frame_merge_pending_state_xs($merge, \@resolved);
  };
}

sub finalize {
  my ($self, $promise_code, $writer) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_finalize_xs($self, $promise_code, $writer);
}

1;
