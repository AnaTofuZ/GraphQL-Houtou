package GraphQL::Houtou::Runtime::Writer;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();

sub new {
  my ($class, %args) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::writer_new_xs($class);
}

sub error_records {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::writer_error_records_xs($_[0]);
}

sub consume_outcome {
  my ($self, $data, $result_name, $outcome) = @_;
  return if !$outcome;
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::consume_outcome_xs(
    $self,
    $data,
    $result_name,
    $outcome,
  );
  return;
}

sub materialize_errors {
  my ($self) = @_;
  return [ map { $_->to_error } @{ $self->error_records || [] } ];
}

1;
