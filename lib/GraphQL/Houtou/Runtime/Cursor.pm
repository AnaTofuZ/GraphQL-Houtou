package GraphQL::Houtou::Runtime::Cursor;

use 5.014;
use strict;
use warnings;

use constant {
  BLOCK_SLOT => 0,
  SLOT_INDEX_SLOT => 1,
  OP_INDEX_SLOT => 2,
  CURRENT_SLOT_SLOT => 3,
  CURRENT_OP_SLOT => 4,
};

sub new {
  my ($class, %args) = @_;
  return bless [
    $args{block},
    $args{slot_index} || 0,
    $args{op_index} || 0,
    $args{current_slot},
    $args{current_op},
  ], $class;
}

sub block { return $_[0][BLOCK_SLOT] }
sub slot_index { return $_[0][SLOT_INDEX_SLOT] }
sub op_index { return $_[0][OP_INDEX_SLOT] }
sub current_slot { return $_[0][CURRENT_SLOT_SLOT] }
sub current_op { return $_[0][CURRENT_OP_SLOT] }

sub snapshot {
  my ($self) = @_;
  return [
    $self->[BLOCK_SLOT],
    $self->[SLOT_INDEX_SLOT],
    $self->[OP_INDEX_SLOT],
    $self->[CURRENT_SLOT_SLOT],
    $self->[CURRENT_OP_SLOT],
  ];
}

sub restore {
  my ($self, $snapshot) = @_;
  @{$self}[
    BLOCK_SLOT,
    SLOT_INDEX_SLOT,
    OP_INDEX_SLOT,
    CURRENT_SLOT_SLOT,
    CURRENT_OP_SLOT,
  ] = @{$snapshot};
  return $self;
}

sub enter_block {
  my ($self, $block) = @_;
  $self->[BLOCK_SLOT] = $block;
  $self->[SLOT_INDEX_SLOT] = 0;
  $self->[OP_INDEX_SLOT] = -1;
  $self->[CURRENT_SLOT_SLOT] = undef;
  $self->[CURRENT_OP_SLOT] = undef;
  return $self;
}

sub set_current_op {
  my ($self, $op, $index) = @_;
  $self->[OP_INDEX_SLOT] = $index if defined $index;
  $self->[CURRENT_OP_SLOT] = $op;
  $self->[CURRENT_SLOT_SLOT] = $op ? $op->bound_slot : undef;
  return $self;
}

sub advance_op {
  my ($self) = @_;
  my $ops = $self->[BLOCK_SLOT] ? ($self->[BLOCK_SLOT]->ops || []) : [];
  my $next_index = ($self->[OP_INDEX_SLOT] || 0) + 1;
  if ($next_index > $#$ops) {
    $self->set_current_op(undef, $next_index);
    return;
  }
  return $self->set_current_op($ops->[$next_index], $next_index)->current_op;
}

sub has_current_op {
  my ($self) = @_;
  return defined $self->[CURRENT_OP_SLOT];
}

1;
