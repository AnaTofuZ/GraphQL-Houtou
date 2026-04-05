package GraphQL::Houtou::Role::Named;

use 5.014;
use strict;
use warnings;

use Moo::Role;
use Types::Standard qw(Maybe Str);

use GraphQL::Houtou::Type::Library qw(StrNameValid);

# Shared attributes and helpers for named schema objects.

has name => (
  is => 'ro',
  isa => StrNameValid,
  required => 1,
);

has description => (
  is => 'ro',
  isa => Maybe[Str],
);

has to_string => (
  is => 'lazy',
  isa => Str,
  init_arg => undef,
  builder => sub {
    my ($self) = @_;
    return $self->name;
  },
);

sub _from_ast_named {
  my ($self, $ast_node) = @_;
  return (
    name => $ast_node->{name},
    ($ast_node->{description} ? (description => $ast_node->{description}) : ()),
  );
}

1;
