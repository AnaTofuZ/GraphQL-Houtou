package GraphQL::Houtou::Runtime::LazyInfo;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  my %storage;
  tie %storage, $class, \%args;
  return \%storage;
}

sub TIEHASH {
  my ($class, $args) = @_;
  return bless {
    args => $args || {},
    cache => {},
  }, $class;
}

sub FETCH {
  my ($self, $key) = @_;
  return $self->{cache}{$key} if exists $self->{cache}{$key};

  my $args = $self->{args};
  my $state = $args->{state};
  my $value;
  if ($key eq 'field_name') {
    $value = $args->{field_name} if exists $args->{field_name};
    if (!defined $value && $state && $state->can('current_field_name')) {
      $value = $state->current_field_name;
    }
    $value = $args->{instruction} ? $args->{instruction}->field_name : undef if !defined $value;
  }
  elsif ($key eq 'return_type') {
    $value = $args->{return_type} if exists $args->{return_type};
    if (!defined $value && $state && $state->can('current_return_type')) {
      $value = $state->current_return_type;
    }
    my $type_name = !defined $value && $args->{instruction} ? $args->{instruction}->return_type_name : undef;
    $value = $type_name ? $args->{runtime_schema}->runtime_cache->{name2type}{$type_name} : undef if !defined $value;
  }
  elsif ($key eq 'parent_type') {
    my $type_name;
    $value = $args->{parent_type} if exists $args->{parent_type};
    if (!defined $value && $state && $state->can('current_parent_type')) {
      $value = $state->current_parent_type;
    }
    if (!defined $value) {
      $type_name = $args->{block} ? $args->{block}->type_name : undef;
      $value = $type_name ? $args->{runtime_schema}->runtime_cache->{name2type}{$type_name} : undef;
    }
  }
  elsif ($key eq 'path') {
    $value = $args->{path} if exists $args->{path};
    if (!defined $value && $state && $state->can('current_path')) {
      $value = $state->current_path($args->{path_frame});
    }
    $value = $args->{path_frame} ? $args->{path_frame}->materialize_path : undef if !defined $value;
  }
  elsif ($key eq 'schema') {
    $value = $args->{runtime_schema}->schema;
  }
  elsif ($key eq 'runtime_cache') {
    $value = $args->{runtime_schema}->runtime_cache;
  }
  elsif ($key eq 'variable_values') {
    $value = $args->{variable_values} if exists $args->{variable_values};
    $value = $state ? $state->variables : undef if !defined $value;
  }
  elsif ($key eq 'root_value') {
    $value = $args->{root_value} if exists $args->{root_value};
    $value = $state ? $state->root_value : undef if !defined $value;
  }
  elsif ($key eq 'context_value') {
    $value = $args->{context_value} if exists $args->{context_value};
    $value = $state ? $state->context : undef if !defined $value;
  }
  elsif ($key eq 'operation') {
    $value = $args->{operation} if exists $args->{operation};
    $value = $state ? $state->program : undef if !defined $value;
  }
  elsif ($key eq 'field_nodes') {
    $value = undef;
  }
  else {
    $value = undef;
  }

  $self->{cache}{$key} = $value;
  return $value;
}

sub EXISTS {
  my ($self, $key) = @_;
  return 1 if exists $self->{cache}{$key};
  return scalar grep { $_ eq $key } qw(
    field_name
    return_type
    parent_type
    path
    schema
    runtime_cache
    variable_values
    root_value
    context_value
    operation
    field_nodes
  );
}

sub STORE {
  my ($self, $key, $value) = @_;
  $self->{cache}{$key} = $value;
}

sub DELETE {
  my ($self, $key) = @_;
  delete $self->{cache}{$key};
}

sub CLEAR {
  my ($self) = @_;
  %{ $self->{cache} } = ();
}

sub FIRSTKEY {
  my ($self) = @_;
  my %keys = map { $_ => 1 } keys %{ $self->{cache} };
  $keys{$_} = 1 for qw(
    field_name
    return_type
    parent_type
    path
    schema
    runtime_cache
    variable_values
    root_value
    context_value
    operation
    field_nodes
  );
  my @ordered = sort keys %keys;
  $self->{iter_keys} = \@ordered;
  return shift @{ $self->{iter_keys} };
}

sub NEXTKEY {
  my ($self) = @_;
  return shift @{ $self->{iter_keys} || [] };
}

sub SCALAR {
  my ($self) = @_;
  return scalar keys %{ $self->{cache} };
}

1;
