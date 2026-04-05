package GraphQL::Houtou::Type::Union;

use 5.014;
use strict;
use warnings;

use Moo;
use GraphQL::Houtou::Type::Library qw(UniqueByProperty ArrayRefNonEmpty);
use Types::Standard qw(ArrayRef Object CodeRef Bool);

extends 'GraphQL::Houtou::Type';
with qw(
  GraphQL::Houtou::Role::Output
  GraphQL::Houtou::Role::Composite
  GraphQL::Houtou::Role::Abstract
  GraphQL::Houtou::Role::Named
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

has types => (
  is => 'ro',
  isa => UniqueByProperty['name'] & ArrayRefNonEmpty[Object],
  required => 1,
);

has resolve_type => (is => 'ro', isa => CodeRef);
has _types_validated => (is => 'rw', isa => Bool);

sub get_types {
  my ($self) = @_;
  my @types = @{ $self->types };
  return \@types if $self->_types_validated;

  $self->_types_validated(1);
  if (!$self->resolve_type) {
    my @bad = map $_->name, grep !$_->is_type_of, @types;
    die $self->name . " no resolve_type and no is_type_of for @bad" if @bad;
  }
  return \@types;
}

has to_doc => (
  is => 'lazy',
  builder => sub {
    my ($self) = @_;
    return join '', map "$_\n",
      ($self->description ? (map "# $_", split /\n/, $self->description) : ()),
      "union @{[$self->name]} = " . join(' | ', map $_->name, @{ $self->{types} });
  },
);

1;
