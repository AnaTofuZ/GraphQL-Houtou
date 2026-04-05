package GraphQL::Houtou::Type::Enum;

use 5.014;
use strict;
use warnings;

use Moo;
use GraphQL::Houtou::Type::Library -all;
use Types::Standard -all;

extends 'GraphQL::Houtou::Type';
with qw(
  GraphQL::Houtou::Role::Input
  GraphQL::Houtou::Role::Output
  GraphQL::Houtou::Role::Leaf
  GraphQL::Houtou::Role::Named
  GraphQL::Houtou::Role::FieldDeprecation
  GraphQL::Houtou::Role::FieldsEither
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

has values => (
  is => 'ro',
  isa => Map[
    StrNameValid,
    Dict[
      value => Optional[Any],
      deprecation_reason => Optional[Str],
      description => Optional[Str],
    ]
  ],
  required => 1,
);

has _name2value => (is => 'lazy', isa => Map[StrNameValid, Any]);
sub _build__name2value {
  my ($self) = @_;
  my $v = $self->values;
  return +{ map { ($_ => $v->{$_}{value}) } keys %$v };
}

has _value2name => (is => 'lazy', isa => Map[Str, StrNameValid]);
sub _build__value2name {
  my ($self) = @_;
  my $n2v = $self->_name2value;
  return +{ reverse %$n2v };
}

sub is_valid {
  my ($self, $item) = @_;
  return 1 if !defined $item;
  return !!$self->_value2name->{$item};
}

sub graphql_to_perl {
  my ($self, $item) = @_;
  return undef if !defined $item;
  $item = $$$item if ref($item) eq 'REF';
  return $self->_name2value->{$item} // die "Expected type '@{[$self->to_string]}', found $item.\n";
}

sub perl_to_graphql {
  my ($self, $item) = @_;
  return undef if !defined $item;
  return $self->_value2name->{$item}
    // die "Expected a value of type '@{[$self->to_string]}' but received: @{[ref($item)||qq{'$item'}]}.\n";
}

sub BUILD {
  my ($self) = @_;
  my $v = $self->values;
  $self->_fields_deprecation_apply('values');
  for my $name (keys %$v) {
    $v->{$name}{value} = $name if !exists $v->{$name}{value};
  }
}

1;
