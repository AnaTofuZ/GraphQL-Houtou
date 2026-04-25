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
  my $value;
  if ($key eq 'field_name') {
    $value = $args->{instruction} ? $args->{instruction}->field_name : undef;
  }
  elsif ($key eq 'return_type') {
    my $type_name = $args->{instruction} ? $args->{instruction}->return_type_name : undef;
    $value = $type_name ? $args->{runtime_schema}->runtime_cache->{name2type}{$type_name} : undef;
  }
  elsif ($key eq 'parent_type') {
    my $type_name = $args->{block} ? $args->{block}->type_name : undef;
    $value = $type_name ? $args->{runtime_schema}->runtime_cache->{name2type}{$type_name} : undef;
  }
  elsif ($key eq 'path') {
    $value = $args->{path_frame} ? $args->{path_frame}->materialize_path : undef;
  }
  elsif ($key eq 'schema') {
    $value = $args->{runtime_schema}->schema;
  }
  elsif ($key eq 'runtime_cache') {
    $value = $args->{runtime_schema}->runtime_cache;
  }
  elsif ($key eq 'variable_values') {
    $value = $args->{state} ? $args->{state}->variables : undef;
  }
  elsif ($key eq 'root_value') {
    $value = $args->{state} ? $args->{state}->root_value : undef;
  }
  elsif ($key eq 'context_value') {
    $value = $args->{state} ? $args->{state}->context : undef;
  }
  elsif ($key eq 'operation') {
    $value = $args->{state} ? $args->{state}->program : undef;
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
