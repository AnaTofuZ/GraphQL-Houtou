package GraphQL::Houtou::Runtime::Outcome;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();
use Scalar::Util qw(reftype);

sub new {
  my ($class, %args) = @_;
  my $kind = $args{kind} || 'NONE';
  return $class->scalar($args{scalar_value}, $args{error_records}) if $kind eq 'SCALAR';
  return $class->object($args{object_value}, $args{error_records}) if $kind eq 'OBJECT';
  return $class->list($args{list_value}, $args{error_records}) if $kind eq 'LIST';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::outcome_scalar_xs(undef, ($args{error_records} || []));
}

sub scalar {
  my ($class, $value, $error_records) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::outcome_scalar_xs($value, ($error_records || []));
}

sub object {
  my ($class, $value, $error_records) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::outcome_object_xs($value, ($error_records || []));
}

sub list {
  my ($class, $value, $error_records) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::outcome_list_xs($value, ($error_records || []));
}

sub kind {
  return $_[0]{kind} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::outcome_kind_xs($_[0]);
}

sub scalar_value {
  my ($self) = @_;
  return undef if ($self->kind || q()) ne 'SCALAR';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::outcome_value_xs($self);
}

sub object_value {
  my ($self) = @_;
  return undef if ($self->kind || q()) ne 'OBJECT';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::outcome_value_xs($self);
}

sub list_value {
  my ($self) = @_;
  return undef if ($self->kind || q()) ne 'LIST';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::outcome_value_xs($self);
}

sub value {
  my ($self) = @_;
  return $self->{value} if reftype($self) && reftype($self) eq 'HASH';
  my $kind = $self->kind || q();
  return undef if !$kind;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::outcome_value_xs($self)
    if $kind eq 'SCALAR' || $kind eq 'OBJECT' || $kind eq 'LIST';
  return undef;
}

sub error_records {
  return $_[0]{error_records} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::outcome_error_records_xs($_[0]);
}

1;
