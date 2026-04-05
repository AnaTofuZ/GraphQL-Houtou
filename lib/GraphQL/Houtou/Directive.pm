package GraphQL::Houtou::Directive;

use 5.014;
use strict;
use warnings;

use Moo;
use GraphQL::Houtou::Type::Library -all;
use Types::Standard -all;

use GraphQL::Houtou::Type::Scalar qw($Boolean $String);

with qw(
  GraphQL::Houtou::Role::Named
  GraphQL::Houtou::Role::FieldsEither
);

use constant DEBUG => $ENV{GRAPHQL_DEBUG};

my @LOCATIONS = qw(
  QUERY
  MUTATION
  SUBSCRIPTION
  FIELD
  FRAGMENT_DEFINITION
  FRAGMENT_SPREAD
  INLINE_FRAGMENT
  SCHEMA
  SCALAR
  OBJECT
  FIELD_DEFINITION
  ARGUMENT_DEFINITION
  INTERFACE
  UNION
  ENUM
  ENUM_VALUE
  INPUT_OBJECT
  INPUT_FIELD_DEFINITION
);

has locations => (is => 'ro', isa => ArrayRef[Enum[@LOCATIONS]], required => 1);
has args => (is => 'ro', isa => FieldMapInput, default => sub { {} });

has to_doc => (
  is => 'lazy',
  builder => sub {
    my ($self) = @_;
    my @start = (
      $self->_description_doc_lines($self->description),
      "directive \@@{[$self->name]}(",
    );
    my @argtuples = $self->_make_fieldtuples($self->args);
    my $end = ") on " . join(' | ', @{ $self->locations });
    return join("\n", @start) . join(', ', map $_->[0], @argtuples) . $end . "\n"
      if !grep $_->[1], @argtuples;
    return join '', map "$_\n",
      @start,
      (map {
        my ($main, @description) = @$_;
        (map length() ? "  $_" : "", @description, $main)
      } @argtuples),
      $end;
  },
);

sub _get_directive_values {
  my ($self, $node, $variables) = @_;
  my ($d) = grep $_->{name} eq $self->name, @{ $node->{directives} || [] };
  return if !$d;
  require GraphQL::Houtou::Execution::PP;
  return GraphQL::Houtou::Execution::PP::_get_argument_values($self, $d, $variables);
}

our $DEPRECATED = __PACKAGE__->new(
  name => 'deprecated',
  description => 'Marks an element of a GraphQL schema as no longer supported.',
  locations => [ qw(FIELD_DEFINITION ENUM_VALUE) ],
  args => {
    reason => {
      type => $String,
      description =>
        'Explains why this element was deprecated, usually also including ' .
        'a suggestion for how to access supported similar data. Formatted ' .
        'in [Markdown](https://daringfireball.net/projects/markdown/).',
      default_value => 'No longer supported',
    },
  },
);

our $INCLUDE = __PACKAGE__->new(
  name => 'include',
  description => 'Directs the executor to include this field or fragment only when the `if` argument is true.',
  locations => [ qw(FIELD FRAGMENT_SPREAD INLINE_FRAGMENT) ],
  args => {
    if => {
      type => $Boolean->non_null,
      description => 'Included when true.',
    },
  },
);

our $SKIP = __PACKAGE__->new(
  name => 'skip',
  description => 'Directs the executor to skip this field or fragment when the `if` argument is true.',
  locations => [ qw(FIELD FRAGMENT_SPREAD INLINE_FRAGMENT) ],
  args => {
    if => {
      type => $Boolean->non_null,
      description => 'Skipped when true.',
    },
  },
);

our @SPECIFIED_DIRECTIVES = (
  $INCLUDE,
  $SKIP,
  $DEPRECATED,
);

1;
