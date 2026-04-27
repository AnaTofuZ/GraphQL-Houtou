package GraphQL::Houtou::Type::Enum;

use 5.014;
use strict;
use warnings;

use parent 'GraphQL::Houtou::Type';
use Role::Tiny::With;
use GraphQL::Houtou::Internal::TypeSupport qw(apply_fields_deprecation);

with qw(
  GraphQL::Houtou::Role::Input
  GraphQL::Houtou::Role::Output
  GraphQL::Houtou::Role::Leaf
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

sub new {
  my ($class, %args) = @_;
  my $self = $class->SUPER::new(%args);
  $self->{name} = $args{name};
  $self->{description} = $args{description};
  my $values = apply_fields_deprecation($args{values} || {});
  for my $name (keys %$values) {
    $values->{$name}{value} = $name if !exists $values->{$name}{value};
  }
  $self->{values} = $values;
  return bless $self, $class;
}

sub name { $_[0]->{name} }
sub description { $_[0]->{description} }
sub to_string { $_[0]->{to_string} ||= $_[0]->name }
sub values { $_[0]->{values} }

sub _name2value {
  my ($self) = @_;
  return $self->{_name2value} ||= do {
    my $v = $self->values;
    +{ map { ($_ => $v->{$_}{value}) } keys %$v };
  };
}

sub _value2name {
  my ($self) = @_;
  return $self->{_value2name} ||= do {
    my $n2v = $self->_name2value;
    +{ reverse %$n2v };
  };
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

1;
