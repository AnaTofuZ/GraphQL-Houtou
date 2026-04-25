package GraphQL::Houtou::Runtime::ExecutionBlock;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    name => $args{name},
    type_name => $args{type_name},
    family => $args{family} || 'OBJECT',
    instructions => $args{instructions} || [],
  }, $class;
}

sub name { return $_[0]{name} }
sub type_name { return $_[0]{type_name} }
sub family { return $_[0]{family} }
sub instructions { return $_[0]{instructions} }

sub to_struct {
  my ($self) = @_;
  return {
    name => $self->{name},
    type_name => $self->{type_name},
    family => $self->{family},
    instructions => [ map { $_->to_struct } @{ $self->{instructions} || [] } ],
  };
}

1;
