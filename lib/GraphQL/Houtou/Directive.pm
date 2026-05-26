package GraphQL::Houtou::Directive;

use 5.014;
use strict;
use warnings;

use parent 'GraphQL::Houtou::Type';
use Role::Tiny::With;
use GraphQL::Houtou::Internal::TypeSupport qw(description_doc_lines make_fieldtuples named_from_ast);

use GraphQL::Houtou::Type::Scalar qw($Boolean $String);

with qw(
  GraphQL::Houtou::Role::Input
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

sub new {
  my ($class, %args) = @_;
  my $self = $class->SUPER::new(%args);
  $self->{name} = $args{name};
  $self->{description} = $args{description};
  $self->{locations} = $args{locations} || [];
  $self->{args} = $args{args} || {};
  $self->{repeatable} = $args{repeatable} ? 1 : 0;
  $self->{resolve_field} = $args{resolve_field};
  return bless $self, $class;
}

sub name { $_[0]->{name} }
sub description { $_[0]->{description} }
sub locations { $_[0]->{locations} }
sub args { $_[0]->{args} }
sub repeatable { $_[0]->{repeatable} }
sub resolve_field { $_[0]->{resolve_field} }
sub to_string { $_[0]->{to_string} ||= $_[0]->name }

sub has_executable_location {
  my ($self) = @_;
  return !!grep {
    $_ eq 'FIELD' || $_ eq 'FRAGMENT_SPREAD' || $_ eq 'INLINE_FRAGMENT'
  } @{ $self->locations || [] };
}

sub has_runtime_hook {
  my ($self) = @_;
  return $self->resolve_field ? 1 : 0;
}

sub to_doc {
  my ($self) = @_;
  return $self->{to_doc} ||= do {
    my @start = (
      description_doc_lines($self->description),
      "directive \@@{[$self->name]}(",
    );
    my @argtuples = make_fieldtuples($self->args);
    my $end = ')';
    $end .= ' repeatable' if $self->repeatable;
    $end .= ' on ' . join(' | ', @{ $self->locations });
    return join("\n", @start) . join(', ', map $_->[0], @argtuples) . $end . "\n"
      if !grep $_->[1], @argtuples;
    join '', map "$_\n",
      @start,
      (map {
        my ($main, @description) = @$_;
        (map length() ? "  $_" : "", @description, $main)
      } @argtuples),
      $end;
  };
}

sub _get_directive_values {
  my ($self) = @_;
  die "Directive->_get_directive_values is part of the removed legacy execution path; use GraphQL::Houtou::Schema->compile_program / ->compile_native_bundle for directive evaluation on '$self->{name}'.\n";
}

our $DEPRECATED = __PACKAGE__->new(
  name => 'deprecated',
  description => 'Marks an element of a GraphQL schema as no longer supported.',
  locations => [ qw(FIELD_DEFINITION ENUM_VALUE ARGUMENT_DEFINITION INPUT_FIELD_DEFINITION) ],
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

our $SPECIFIED_BY = __PACKAGE__->new(
  name => 'specifiedBy',
  description => 'Exposes a URL that specifies the behavior of this scalar.',
  locations => [ qw(SCALAR) ],
  args => {
    url => {
      type => $String->non_null,
      description => 'The URL that specifies the behavior of this scalar.',
    },
  },
);

our @SPECIFIED_DIRECTIVES = (
  $INCLUDE,
  $SKIP,
  $DEPRECATED,
  $SPECIFIED_BY,
);

1;
