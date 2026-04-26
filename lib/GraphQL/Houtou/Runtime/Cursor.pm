package GraphQL::Houtou::Runtime::Cursor;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    block => $args{block},
    slot_index => $args{slot_index} || 0,
    op_index => $args{op_index} || 0,
    current_slot => $args{current_slot},
    current_op => $args{current_op},
  }, $class;
}

sub block { return $_[0]{block} }
sub slot_index { return $_[0]{slot_index} }
sub op_index { return $_[0]{op_index} }
sub current_slot { return $_[0]{current_slot} }
sub current_op { return $_[0]{current_op} }

sub snapshot {
  my ($self) = @_;
  return {
    block => $self->{block},
    slot_index => $self->{slot_index},
    op_index => $self->{op_index},
    current_slot => $self->{current_slot},
    current_op => $self->{current_op},
  };
}

sub restore {
  my ($self, $snapshot) = @_;
  @{$self}{qw(block slot_index op_index current_slot current_op)} =
    @{$snapshot}{qw(block slot_index op_index current_slot current_op)};
  return $self;
}

sub enter_block {
  my ($self, $block) = @_;
  $self->{block} = $block;
  $self->{slot_index} = 0;
  $self->{op_index} = -1;
  $self->{current_slot} = undef;
  $self->{current_op} = undef;
  return $self;
}

sub set_current_op {
  my ($self, $op, $index) = @_;
  $self->{op_index} = $index if defined $index;
  $self->{current_op} = $op;
  $self->{current_slot} = $op ? $op->bound_slot : undef;
  return $self;
}

sub advance_op {
  my ($self) = @_;
  my $ops = $self->{block} ? ($self->{block}->ops || []) : [];
  my $next_index = ($self->{op_index} || 0) + 1;
  if ($next_index > $#$ops) {
    $self->set_current_op(undef, $next_index);
    return;
  }
  return $self->set_current_op($ops->[$next_index], $next_index)->current_op;
}

sub has_current_op {
  my ($self) = @_;
  return defined $self->{current_op};
}

1;
