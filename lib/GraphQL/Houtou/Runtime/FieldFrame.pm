package GraphQL::Houtou::Runtime::FieldFrame;

use 5.014;
use strict;
use warnings;

use constant {
  SOURCE_SLOT => 0,
  PATH_FRAME_SLOT => 1,
  RESOLVED_VALUE_SLOT => 2,
  OUTCOME_SLOT => 3,
};

sub new {
  my ($class, %args) = @_;
  return bless [
    $args{source},
    $args{path_frame},
    $args{resolved_value},
    $args{outcome},
  ], $class;
}

sub source { return $_[0][SOURCE_SLOT] }
sub path_frame { return $_[0][PATH_FRAME_SLOT] }
sub resolved_value { return $_[0][RESOLVED_VALUE_SLOT] }
sub outcome { return $_[0][OUTCOME_SLOT] }

sub set_resolved_value {
  my ($self, $value) = @_;
  $self->[RESOLVED_VALUE_SLOT] = $value;
  return $value;
}

sub set_outcome {
  my ($self, $outcome) = @_;
  $self->[OUTCOME_SLOT] = $outcome;
  return $outcome;
}

1;
