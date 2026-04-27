package GraphQL::Houtou::Runtime::BlockFrame;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Promise::Adapter qw(
  all_promise
  then_promise
);

use constant {
  VALUES_SLOT           => 0,
  PENDING_NAMES_SLOT    => 1,
  PENDING_OUTCOMES_SLOT => 2,
};

sub new {
  my ($class, %args) = @_;
  return bless [
    ($args{values} || {}),
    ($args{pending_names} || []),
    ($args{pending_outcomes} || []),
  ], $class;
}

sub values { return $_[0][VALUES_SLOT] }
sub pending_names { return $_[0][PENDING_NAMES_SLOT] }
sub pending_outcomes { return $_[0][PENDING_OUTCOMES_SLOT] }
sub has_pending { return @{ $_[0][PENDING_OUTCOMES_SLOT] || [] } ? 1 : 0 }

sub consume_outcome {
  my ($self, $writer, $result_name, $outcome) = @_;
  return if !$outcome;
  $writer->consume_outcome($self->[VALUES_SLOT], $result_name, $outcome);
  return;
}

sub add_pending {
  my ($self, $result_name, $outcome) = @_;
  push @{ $self->[PENDING_NAMES_SLOT] }, $result_name;
  push @{ $self->[PENDING_OUTCOMES_SLOT] }, $outcome;
  return;
}

sub merge_resolved_pending {
  my ($self, $writer, $resolved) = @_;
  my %merged = %{ $self->[VALUES_SLOT] || {} };
  for my $i (0 .. $#$resolved) {
    $writer->consume_outcome(\%merged, $self->[PENDING_NAMES_SLOT][$i], $resolved->[$i]);
  }
  return \%merged;
}

sub finalize {
  my ($self, $promise_code, $writer) = @_;
  return $self->[VALUES_SLOT] if !$self->has_pending;

  my $aggregate = all_promise($promise_code, @{ $self->[PENDING_OUTCOMES_SLOT] });
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
