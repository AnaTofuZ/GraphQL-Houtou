package GraphQL::Houtou::Runtime::BlockFrame;

use 5.014;
use strict;
use warnings;

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

1;
