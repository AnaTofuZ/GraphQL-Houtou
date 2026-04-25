package GraphQL::Houtou::Runtime::Outcome;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  my $kind = $args{kind} || 'NONE';
  my $self = {
    kind => $kind,
    error_records => $args{error_records} || [],
    completed => $args{completed},
  };
  $self->{scalar_value} = $args{scalar_value} if exists $args{scalar_value};
  $self->{object_value} = $args{object_value} if exists $args{object_value};
  $self->{list_value} = $args{list_value} if exists $args{list_value};
  $self->{value} = $args{value} if exists $args{value};
  return bless $self, $class;
}

sub kind { return $_[0]{kind} }
sub scalar_value { return $_[0]{scalar_value} }
sub object_value { return $_[0]{object_value} }
sub list_value { return $_[0]{list_value} }
sub value {
  my ($self) = @_;
  return $self->{scalar_value} if ($self->{kind} || '') eq 'SCALAR';
  return $self->{object_value} if ($self->{kind} || '') eq 'OBJECT';
  return $self->{list_value} if ($self->{kind} || '') eq 'LIST';
  return $self->{value};
}
sub error_records { return $_[0]{error_records} }
sub completed { return $_[0]{completed} }

1;
