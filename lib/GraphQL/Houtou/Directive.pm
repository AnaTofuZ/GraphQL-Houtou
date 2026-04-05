package GraphQL::Houtou::Directive;

use 5.014;
use strict;
use warnings;

use Moo;

use GraphQL::Houtou::Type::Scalar qw($Boolean $String);

extends 'GraphQL::Directive';

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
