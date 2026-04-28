package GraphQL::Houtou::Runtime::Cursor;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();
use Scalar::Util qw(reftype);

sub new {
  my ($class, %args) = @_;
  if ($args{perl_only}) {
    return bless {
      block => $args{block},
      slot_index => defined $args{slot_index} ? $args{slot_index} : 0,
      op_index => defined $args{op_index} ? $args{op_index} : 0,
      current_slot => $args{current_slot},
      current_op => $args{current_op},
    }, $class;
  }
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_new_xs(
    $class,
    $args{block},
    ($args{slot_index} || 0),
    ($args{op_index} || 0),
    $args{current_slot},
    $args{current_op},
  );
}

sub block {
  return $_[0]{block} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_block_xs($_[0]);
}

sub slot_index {
  return $_[0]{slot_index} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_slot_index_xs($_[0]);
}

sub op_index {
  return $_[0]{op_index} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_op_index_xs($_[0]);
}

sub current_slot {
  return $_[0]{current_slot} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_current_slot_xs($_[0]);
}

sub current_op {
  return $_[0]{current_op} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_current_op_xs($_[0]);
}

sub snapshot {
  if (reftype($_[0]) && reftype($_[0]) eq 'HASH') {
    return bless {
      %{ $_[0] },
    }, ref($_[0]);
  }
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_snapshot_xs($_[0]);
}

sub restore {
  if (reftype($_[0]) && reftype($_[0]) eq 'HASH') {
    %{ $_[0] } = %{ $_[1] };
    return $_[0];
  }
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::cursor_restore_xs($_[0], $_[1]);
  return $_[0];
}

sub enter_block {
  if (reftype($_[0]) && reftype($_[0]) eq 'HASH') {
    $_[0]{block} = $_[1];
    $_[0]{slot_index} = 0;
    $_[0]{op_index} = 0;
    $_[0]{current_slot} = undef;
    $_[0]{current_op} = undef;
    return $_[0];
  }
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::cursor_enter_block_xs($_[0], $_[1]);
  return $_[0];
}

sub set_current_op {
  if (reftype($_[0]) && reftype($_[0]) eq 'HASH') {
    $_[0]{current_op} = $_[1];
    $_[0]{current_slot} = $_[2];
    return $_[0];
  }
  GraphQL::Houtou::_bootstrap_xs();
  if (@_ > 2) {
    GraphQL::Houtou::XS::VM::cursor_set_current_op_xs($_[0], $_[1], $_[2]);
  } else {
    GraphQL::Houtou::XS::VM::cursor_set_current_op_xs($_[0], $_[1]);
  }
  return $_[0];
}

sub advance_op {
  if (reftype($_[0]) && reftype($_[0]) eq 'HASH') {
    my $ops = $_[0]{block} ? ($_[0]{block}->ops || []) : [];
    return undef if $_[0]{op_index} > $#$ops;
    my $op = $ops->[ $_[0]{op_index}++ ];
    $_[0]{current_op} = $op;
    $_[0]{current_slot} = $op ? $op->bound_slot : undef;
    return $op;
  }
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::cursor_advance_op_xs($_[0]);
}

sub has_current_op {
  my ($self) = @_;
  return defined $self->current_op;
}

1;
