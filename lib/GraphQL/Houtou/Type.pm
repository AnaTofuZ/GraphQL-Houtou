package GraphQL::Houtou::Type;

use 5.014;
use strict;
use warnings;

use Moo;
use Types::Standard qw(Bool);

has is_introspection => (
  is => 'ro',
  isa => Bool,
  default => sub { 0 },
);

sub list {
  require GraphQL::Houtou::Type::List;
  $_[0]->{_houtou_list} ||= GraphQL::Houtou::Type::List->new(of => $_[0]);
}

sub uplift {
  return $_[1];
}

1;

__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou::Type - Houtou-owned GraphQL type base class

=head1 DESCRIPTION

This class provides the public Houtou namespace for GraphQL type objects.
It currently preserves upstream behavior while making the wrapper classes
owned by Houtou so future XS-backed internals can replace them incrementally.

=cut
