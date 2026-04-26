package GraphQL::Houtou::Runtime::Slot;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    schema_slot_key => $args{schema_slot_key},
    schema_slot_index => $args{schema_slot_index},
    field_name => $args{field_name},
    result_name => $args{result_name},
    return_type_name => $args{return_type_name},
    resolver_shape => $args{resolver_shape} || 'DEFAULT',
    completion_family => $args{completion_family} || 'GENERIC',
    dispatch_family => $args{dispatch_family} || 'GENERIC',
    arg_defs => $args{arg_defs} || {},
    has_args => $args{has_args} ? 1 : 0,
    has_directives => $args{has_directives} ? 1 : 0,
    resolve => $args{resolve},
    return_type => $args{return_type},
  }, $class;
}

sub schema_slot_key { return $_[0]{schema_slot_key} }
sub schema_slot_index { return $_[0]{schema_slot_index} }
sub field_name { return $_[0]{field_name} }
sub result_name { return $_[0]{result_name} }
sub return_type_name { return $_[0]{return_type_name} }
sub resolver_shape { return $_[0]{resolver_shape} }
sub completion_family { return $_[0]{completion_family} }
sub dispatch_family { return $_[0]{dispatch_family} }
sub arg_defs { return $_[0]{arg_defs} }
sub has_args { return $_[0]{has_args} }
sub has_directives { return $_[0]{has_directives} }
sub resolve { return $_[0]{resolve} }
sub return_type { return $_[0]{return_type} }

sub to_struct {
  my ($self) = @_;
  return {
    schema_slot_key => $self->{schema_slot_key},
    schema_slot_index => $self->{schema_slot_index},
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

sub to_native_struct {
  my ($self) = @_;
  return {
    schema_slot_key => $self->{schema_slot_key},
    schema_slot_index => $self->{schema_slot_index},
    field_name => $self->{field_name},
    result_name => $self->{result_name},
    return_type_name => $self->{return_type_name},
    resolver_shape => $self->{resolver_shape},
    resolver_shape_code => _resolver_shape_code($self->{resolver_shape}),
    completion_family => $self->{completion_family},
    completion_family_code => _family_code($self->{completion_family}),
    dispatch_family => $self->{dispatch_family},
    dispatch_family_code => _family_code($self->{dispatch_family}),
    arg_defs => _clone_value($self->{arg_defs}),
    has_args => $self->{has_args},
    has_directives => $self->{has_directives},
  };
}

sub _resolver_shape_code {
  my ($shape) = @_;
  return 2 if ($shape || q()) eq 'EXPLICIT';
  return 1;
}

sub _family_code {
  my ($family) = @_;
  return 2 if ($family || q()) eq 'OBJECT';
  return 3 if ($family || q()) eq 'LIST';
  return 4 if ($family || q()) eq 'ABSTRACT';
  return 1;
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
