package GraphQL::Houtou::Type::InputObject;

use 5.014;
use strict;
use warnings;

use Moo;
use GraphQL::Houtou::Type::Library -all;
use Types::Standard -all;

extends 'GraphQL::Houtou::Type';
with qw(
  GraphQL::Role::Input
  GraphQL::Role::Named
  GraphQL::Role::FieldsInput
  GraphQL::Role::HashMappable
  GraphQL::Role::FieldsEither
);

sub list {
  require GraphQL::Houtou::Type::List;
  $_[0]->{_houtou_list} ||= GraphQL::Houtou::Type::List->new(of => $_[0]);
}

sub non_null {
  require GraphQL::Houtou::Type::NonNull;
  $_[0]->{_houtou_non_null} ||= GraphQL::Houtou::Type::NonNull->new(of => $_[0]);
}

use constant DEBUG => $ENV{GRAPHQL_DEBUG};

sub is_valid {
  my ($self, $item) = @_;
  my $fields = $self->fields;

  return 1 if !defined $item;
  return if grep { !$fields->{$_}{type}->is_valid($item->{$_} // $fields->{$_}{default_value}) } keys %$fields;
  return 1;
}

sub uplift {
  my ($self, $item) = @_;
  my $fields = $self->fields;

  return $item if !defined $item;
  return $self->hashmap($item, $fields, sub {
    my ($key, $value) = @_;
    return $fields->{$key}{type}->uplift($value // $fields->{$key}{default_value});
  });
}

sub graphql_to_perl {
  my ($self, $item) = @_;
  my $fields = $self->fields;

  return $item if !defined $item;
  die "found not an object" if ref($item) ne 'HASH';
  $item = $self->uplift($item);
  return $self->hashmap($item, $fields, sub {
    return $fields->{$_[0]}{type}->graphql_to_perl($_[1]);
  });
}

sub perl_to_graphql {
  my ($self, $item) = @_;
  my $fields = $self->fields;

  return $item if !defined $item;
  die "found not an object" if ref($item) ne 'HASH';
  $item = $self->uplift($item);
  return $self->hashmap($item, $fields, sub {
    return $fields->{$_[0]}{type}->perl_to_graphql($_[1]);
  });
}

1;
