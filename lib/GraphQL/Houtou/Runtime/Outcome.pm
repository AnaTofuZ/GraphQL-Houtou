package GraphQL::Houtou::Runtime::Outcome;

use 5.014;
use strict;
use warnings;

use constant {
  KIND_SLOT          => 0,
  SCALAR_VALUE_SLOT  => 1,
  OBJECT_VALUE_SLOT  => 2,
  LIST_VALUE_SLOT    => 3,
  ERROR_RECORDS_SLOT => 4,
};

sub new {
  my ($class, %args) = @_;
  my $kind = $args{kind} || 'NONE';
  return bless [
    $kind,
    (exists $args{scalar_value} ? $args{scalar_value} : undef),
    (exists $args{object_value} ? $args{object_value} : undef),
    (exists $args{list_value} ? $args{list_value} : undef),
    ($args{error_records} || []),
  ], $class;
}

sub scalar {
  my ($class, $value, $error_records) = @_;
  return bless [ 'SCALAR', $value, undef, undef, ($error_records || []) ], $class;
}

sub object {
  my ($class, $value, $error_records) = @_;
  return bless [ 'OBJECT', undef, $value, undef, ($error_records || []) ], $class;
}

sub list {
  my ($class, $value, $error_records) = @_;
  return bless [ 'LIST', undef, undef, $value, ($error_records || []) ], $class;
}

sub kind { return $_[0][KIND_SLOT] }
sub scalar_value { return $_[0][SCALAR_VALUE_SLOT] }
sub object_value { return $_[0][OBJECT_VALUE_SLOT] }
sub list_value { return $_[0][LIST_VALUE_SLOT] }
sub value {
  my ($self) = @_;
  return $self->[SCALAR_VALUE_SLOT] if ($self->[KIND_SLOT] || '') eq 'SCALAR';
  return $self->[OBJECT_VALUE_SLOT] if ($self->[KIND_SLOT] || '') eq 'OBJECT';
  return $self->[LIST_VALUE_SLOT] if ($self->[KIND_SLOT] || '') eq 'LIST';
  return undef;
}
sub error_records { return $_[0][ERROR_RECORDS_SLOT] }

1;
