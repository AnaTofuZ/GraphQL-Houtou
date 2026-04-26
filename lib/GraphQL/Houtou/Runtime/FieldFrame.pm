package GraphQL::Houtou::Runtime::FieldFrame;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    source => $args{source},
    path_frame => $args{path_frame},
    resolved_value => $args{resolved_value},
    outcome => $args{outcome},
  }, $class;
}

sub source { return $_[0]{source} }
sub path_frame { return $_[0]{path_frame} }
sub resolved_value { return $_[0]{resolved_value} }
sub outcome { return $_[0]{outcome} }

sub set_resolved_value {
  my ($self, $value) = @_;
  $self->{resolved_value} = $value;
  return $value;
}

sub set_outcome {
  my ($self, $outcome) = @_;
  $self->{outcome} = $outcome;
  return $outcome;
}

1;
