package GraphQL::Houtou::Runtime::Slot;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    field_name => $args{field_name},
    result_name => $args{result_name},
    return_type_name => $args{return_type_name},
    resolver_shape => $args{resolver_shape} || 'DEFAULT',
    completion_family => $args{completion_family} || 'GENERIC',
    dispatch_family => $args{dispatch_family} || 'GENERIC',
    arg_defs => $args{arg_defs} || {},
    has_args => $args{has_args} ? 1 : 0,
    has_directives => $args{has_directives} ? 1 : 0,
  }, $class;
}

sub field_name { return $_[0]{field_name} }
sub result_name { return $_[0]{result_name} }
sub return_type_name { return $_[0]{return_type_name} }
sub resolver_shape { return $_[0]{resolver_shape} }
sub completion_family { return $_[0]{completion_family} }
sub dispatch_family { return $_[0]{dispatch_family} }
sub arg_defs { return $_[0]{arg_defs} }
sub has_args { return $_[0]{has_args} }
sub has_directives { return $_[0]{has_directives} }

sub to_struct {
  my ($self) = @_;
  return {
    field_name => $self->{field_name},
    result_name => $self->{result_name},
    return_type_name => $self->{return_type_name},
    resolver_shape => $self->{resolver_shape},
    completion_family => $self->{completion_family},
    dispatch_family => $self->{dispatch_family},
    arg_defs => _clone_value($self->{arg_defs}),
    has_args => $self->{has_args},
    has_directives => $self->{has_directives},
  };
}

sub _clone_value {
  my ($value) = @_;
  my $ref = ref($value);
  return $value if !$ref;
  return [ map { _clone_value($_) } @$value ] if $ref eq 'ARRAY';
  return { map { $_ => _clone_value($value->{$_}) } keys %$value } if $ref eq 'HASH';
  return $value;
}

1;
