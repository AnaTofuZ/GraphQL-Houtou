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
  }, $class;
}

sub block { return $_[0]{block} }
sub slot_index { return $_[0]{slot_index} }
sub op_index { return $_[0]{op_index} }
sub current_slot { return $_[0]{current_slot} }

1;
