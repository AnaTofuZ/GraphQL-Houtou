package GraphQL::Houtou::Runtime::BlockFrame;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Promise::Adapter qw(
  all_promise
  then_promise
);

sub new {
  my ($class, %args) = @_;
  return bless {
    values => $args{values} || {},
    pending_names => $args{pending_names} || [],
    pending_outcomes => $args{pending_outcomes} || [],
  }, $class;
}

sub values { return $_[0]{values} }
sub pending_names { return $_[0]{pending_names} }
sub pending_outcomes { return $_[0]{pending_outcomes} }
sub has_pending { return @{ $_[0]{pending_outcomes} || [] } ? 1 : 0 }

sub consume_outcome {
  my ($self, $writer, $result_name, $outcome) = @_;
  return if !$outcome;
  $writer->consume_outcome($self->{values}, $result_name, $outcome);
  return;
}

sub add_pending {
  my ($self, $result_name, $outcome) = @_;
  push @{ $self->{pending_names} }, $result_name;
  push @{ $self->{pending_outcomes} }, $outcome;
  return;
}

sub merge_resolved_pending {
  my ($self, $writer, $resolved) = @_;
  my %merged = %{ $self->{values} || {} };
  for my $i (0 .. $#$resolved) {
    $writer->consume_outcome(\%merged, $self->{pending_names}[$i], $resolved->[$i]);
  }
  return \%merged;
}

sub finalize {
  my ($self, $promise_code, $writer) = @_;
  return $self->{values} if !$self->has_pending;

  my $aggregate = all_promise($promise_code, @{ $self->{pending_outcomes} });
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
