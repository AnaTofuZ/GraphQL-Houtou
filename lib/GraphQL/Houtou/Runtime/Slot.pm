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
    resolver_mode => $args{resolver_mode} || 'DEFAULT',
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
sub resolver_mode { return $_[0]{resolver_mode} }
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
    resolver_mode => $self->{resolver_mode},
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
    return_type_kind_code => _type_kind_code($self->{return_type}),
    resolver_shape => $self->{resolver_shape},
    resolver_shape_code => _resolver_shape_code($self->{resolver_shape}),
    resolver_mode => $self->{resolver_mode},
    resolver_mode_code => _resolver_mode_code($self->{resolver_mode}),
    completion_family => $self->{completion_family},
    completion_family_code => _family_code($self->{completion_family}),
    dispatch_family => $self->{dispatch_family},
    dispatch_family_code => _family_code($self->{dispatch_family}),
    arg_defs => _clone_value($self->{arg_defs}),
    has_args => $self->{has_args},
    has_directives => $self->{has_directives},
  };
}

sub to_native_compact_struct {
  my ($self) = @_;
  my $native = $self->to_native_struct;
  return [
    $native->{field_name},
    $native->{result_name},
    $native->{return_type_name},
    $native->{schema_slot_index},
    $native->{resolver_shape_code},
    $native->{completion_family_code},
    $native->{dispatch_family_code},
    $native->{return_type_kind_code},
    $native->{has_args},
    $native->{has_directives},
  ];
}

sub to_native_exec_struct {
  my ($self) = @_;
  my $struct = $self->to_native_struct;
  $struct->{resolve} = $self->{resolve} if exists $self->{resolve};
  $struct->{return_type} = $self->{return_type} if exists $self->{return_type};
  return $struct;
}

sub _resolver_shape_code {
  my ($shape) = @_;
  return 2 if ($shape || q()) eq 'EXPLICIT';
  return 1;
}

sub _resolver_mode_code {
  my ($mode) = @_;
  return 2 if ($mode || q()) eq 'NATIVE';
  return 1;
}

sub _family_code {
  my ($family) = @_;
  return 2 if ($family || q()) eq 'OBJECT';
  return 3 if ($family || q()) eq 'LIST';
  return 4 if ($family || q()) eq 'ABSTRACT';
  return 1;
}

sub _type_kind_code {
  my ($type) = @_;
  return 0 if !$type;
  return 8 if eval { $type->isa('GraphQL::Houtou::Type::NonNull') };
  return 3 if eval { $type->isa('GraphQL::Houtou::Type::List') };
  return 2 if eval { $type->isa('GraphQL::Houtou::Type::Object') };
  return 4 if eval { $type->isa('GraphQL::Houtou::Type::Interface') };
  return 5 if eval { $type->isa('GraphQL::Houtou::Type::Union') };
  return 6 if eval { $type->isa('GraphQL::Houtou::Type::Enum') };
  return 7 if eval { $type->isa('GraphQL::Houtou::Type::InputObject') };
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
