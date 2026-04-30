package GraphQL::Houtou::Runtime::Cursor;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();

sub new {
  my ($class, %args) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_new_xs(
    $class,
    $args{block},
    $args{native_program},
    (defined $args{block_index} ? $args{block_index} : -1),
    ($args{slot_index} || 0),
    ($args{op_index} || 0),
    $args{current_slot},
    $args{current_op},
  );
}

sub block {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_block_xs($_[0]);
}

sub slot_index {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_slot_index_xs($_[0]);
}

sub op_index {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_op_index_xs($_[0]);
}

sub current_slot {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_current_slot_xs($_[0]);
}

sub current_op {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_current_op_xs($_[0]);
}

sub snapshot {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_snapshot_xs($_[0]);
}

sub restore {
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::cursor_restore_xs($_[0], $_[1]);
  return $_[0];
}

sub enter_block {
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::cursor_enter_block_xs($_[0], $_[1], (@_ > 2 ? $_[2] : -1));
  return $_[0];
}

sub set_current_op {
  GraphQL::Houtou::_bootstrap_xs();
  if (@_ > 2) {
    GraphQL::Houtou::XS::VM::cursor_set_current_op_xs($_[0], $_[1], $_[2]);
  } else {
    GraphQL::Houtou::XS::VM::cursor_set_current_op_xs($_[0], $_[1]);
  }
  return $_[0];
}

sub advance_op {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_advance_op_xs($_[0]);
}

sub has_current_op {
  my ($self) = @_;
  return defined $self->current_op;
}

1;
