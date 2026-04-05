package GraphQL::Houtou::Type::NonNull;

use 5.014;
use strict;
use warnings;

use Moo;
use Role::Tiny ();
use Types::Standard qw(Object Any);

extends 'GraphQL::Houtou::Type';

sub list {
  require GraphQL::Houtou::Type::List;
  $_[0]->{_houtou_list} ||= GraphQL::Houtou::Type::List->new(of => $_[0]);
}

has of => (
  is => 'ro',
  isa => Object,
  required => 1,
  handles => [ qw(name) ],
);

sub BUILD {
  my ($self) = @_;
  my $of = $self->of;
  Role::Tiny->apply_roles_to_object($self, grep $of->DOES($_), qw(
    GraphQL::Role::Input
    GraphQL::Role::Output
  ));
}

has to_string => (
  is => 'lazy',
  builder => sub {
    my ($self) = @_;
    $self->of->to_string . '!';
  },
);

sub is_valid {
  my ($self, $item) = @_;
  return if !defined $item || !$self->of->is_valid($item);
  return 1;
}

sub graphql_to_perl {
  my ($self, $item) = @_;
  my $value = $self->of->graphql_to_perl($item);
  return defined($value) ? $value : die $self->to_string . " given null value.\n";
}

1;
