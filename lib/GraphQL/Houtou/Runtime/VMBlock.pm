package GraphQL::Houtou::Runtime::VMBlock;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    name => $args{name},
    type_name => $args{type_name},
    family => $args{family} || 'OBJECT',
    ops => $args{ops} || [],
  }, $class;
}

sub name { return $_[0]{name} }
sub type_name { return $_[0]{type_name} }
sub family { return $_[0]{family} }
sub ops { return $_[0]{ops} }

sub to_struct {
  my ($self) = @_;
  return {
    name => $self->{name},
    type_name => $self->{type_name},
    family => $self->{family},
    ops => [ map { $_->to_struct } @{ $self->{ops} || [] } ],
  };
}

sub to_native_struct {
  my ($self, $block_index) = @_;
  return {
    name => $self->{name},
    type_name => $self->{type_name},
    family => $self->{family},
    ops => [ map { $_->to_native_struct($block_index) } @{ $self->{ops} || [] } ],
  };
}

1;
