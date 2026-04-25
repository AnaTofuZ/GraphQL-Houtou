package GraphQL::Houtou::Runtime::PathFrame;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    parent => $args{parent},
    key => $args{key},
  }, $class;
}

sub parent { return $_[0]{parent} }
sub key { return $_[0]{key} }

sub materialize_path {
  my ($self) = @_;
  return [] if !$self;

  my @path;
  my $cursor = $self;
  while ($cursor) {
    unshift @path, $cursor->{key} if exists $cursor->{key};
    $cursor = $cursor->{parent};
  }

  return \@path;
}

1;
