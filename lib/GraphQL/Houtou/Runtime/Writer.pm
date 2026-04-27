package GraphQL::Houtou::Runtime::Writer;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();

use constant {
  VALUES_SLOT => 0,
  ERROR_RECORDS_SLOT => 1,
  PENDING_SLOT => 2,
};

sub new {
  my ($class, %args) = @_;
  return bless [
    $args{values} || {},
    $args{error_records} || [],
    $args{pending} || [],
  ], $class;
}

sub values { return $_[0][VALUES_SLOT] }
sub error_records { return $_[0][ERROR_RECORDS_SLOT] }
sub pending { return $_[0][PENDING_SLOT] }

sub consume_outcome {
  my ($self, $data, $result_name, $outcome) = @_;
  return if !$outcome;
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::consume_outcome_xs(
    $data,
    $result_name,
    $outcome,
    $self->[ERROR_RECORDS_SLOT],
  );
  return;
}

sub materialize_errors {
  my ($self) = @_;
  return [ map { $_->to_error } @{ $self->[ERROR_RECORDS_SLOT] || [] } ];
}

1;
