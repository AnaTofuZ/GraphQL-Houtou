package GraphQL::Houtou::Runtime::BlockFrame;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();

use GraphQL::Houtou::Promise::Adapter qw(
  all_promise
  then_promise
);

sub new {
  my ($class, %args) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_new_xs(
    $class,
    ($args{values} || {}),
    ($args{pending_names} || []),
    ($args{pending_outcomes} || []),
  );
}

sub values {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_values_xs($_[0]);
}

sub pending_names {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_pending_names_xs($_[0]);
}

sub pending_outcomes {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_pending_outcomes_xs($_[0]);
}

sub has_pending {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_has_pending_xs($_[0]);
}

sub consume_outcome {
  my ($self, $writer, $result_name, $outcome) = @_;
  return if !$outcome;
  $writer->consume_outcome($self->values, $result_name, $outcome);
  return;
}

sub add_pending {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_add_pending_xs($_[0], $_[1], $_[2]);
}

sub merge_resolved_pending {
  my ($self, $writer, $resolved) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_merge_pending_xs($self, $writer, $resolved);
}

sub finalize {
  my ($self, $promise_code, $writer) = @_;
  return $self->values if !$self->has_pending;

  my $aggregate = all_promise($promise_code, @{ $self->pending_outcomes });
  return then_promise($promise_code, $aggregate, sub {
    my @resolved = _promise_all_values_to_array(@_);
    return $self->merge_resolved_pending($writer, \@resolved);
  });
}

sub _promise_all_values_to_array {
  return @{ $_[0] } if @_ == 1 && ref($_[0]) eq 'ARRAY';
  return @_;
}

1;
