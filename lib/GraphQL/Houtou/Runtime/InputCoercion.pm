package GraphQL::Houtou::Runtime::InputCoercion;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Schema ();

sub prepare_variables {
  my ($runtime_schema, $program, $provided) = @_;
  my $defs = $program && $program->can('variable_defs') ? ($program->variable_defs || {}) : {};
  my %resolved = %{ $provided || {} };

  for my $name (keys %{$defs || {}}) {
    next if exists $resolved{$name};
    my $def = $defs->{$name} || {};
    next if !$def->{has_default};
    $resolved{$name} = $def->{default_value};
  }

  return coerce_variable_values($runtime_schema, $defs, \%resolved);
}

sub coerce_variable_values {
  my ($runtime_schema, $defs, $values) = @_;
  my %coerced;

  for my $name (keys %{ $defs || {} }) {
    my $def = $defs->{$name} || {};
    next if !exists $values->{$name};
    my $type = lookup_input_type($runtime_schema, $def->{type});
    $coerced{$name} = coerce_input_value($type, $values->{$name});
  }

  for my $name (keys %{ $values || {} }) {
    next if exists $coerced{$name};
    $coerced{$name} = $values->{$name};
  }

  return \%coerced;
}

sub coerce_static_args {
  my ($runtime_schema, $arg_defs, $payload) = @_;
  my %values;

  for my $name (keys %{ $arg_defs || {} }) {
    my $arg_def = $arg_defs->{$name} || {};
    my $type = lookup_input_type($runtime_schema, $arg_def->{type});
    my $has_value = exists $payload->{$name};
    next if !$has_value && !$arg_def->{has_default};
    my $raw = $has_value ? $payload->{$name} : $arg_def->{default_value};
    $values{$name} = coerce_input_value($type, $raw);
  }

  return \%values;
}

sub coerce_dynamic_args {
  my ($runtime_schema, $arg_defs, $payload, $variables) = @_;
  my %values;

  for my $name (keys %{ $arg_defs || {} }) {
    my $arg_def = $arg_defs->{$name} || {};
    my $type = lookup_input_type($runtime_schema, $arg_def->{type});
    next if !exists $payload->{$name} && !$arg_def->{has_default};
    $values{$name} = coerce_dynamic_arg_value(
      $runtime_schema,
      $type,
      exists $payload->{$name} ? $payload->{$name} : undef,
      $variables,
      $arg_def->{has_default} ? $arg_def->{default_value} : undef,
    );
  }

  return \%values;
}

sub coerce_dynamic_arg_value {
  my ($runtime_schema, $type, $raw, $variables, $default) = @_;
  if (ref($raw) eq 'SCALAR') {
    return exists $variables->{$$raw}
      ? $variables->{$$raw}
      : (defined $default ? coerce_input_value($type, $default) : undef);
  }

  my $materialized = defined($raw)
    ? materialize_dynamic_args($raw, $variables)
    : $default;
  return coerce_input_value($type, $materialized);
}

sub materialize_dynamic_args {
  my ($value, $variables) = @_;
  my $ref = ref($value);
  return $value if !$ref;
  return (exists $variables->{$$value} ? $variables->{$$value} : undef) if $ref eq 'SCALAR';
  return $$$value if $ref eq 'REF';
  return [ map { materialize_dynamic_args($_, $variables) } @$value ] if $ref eq 'ARRAY';
  return { map { $_ => materialize_dynamic_args($value->{$_}, $variables) } keys %$value } if $ref eq 'HASH';
  return $value;
}

sub evaluate_runtime_guards {
  my ($guards, $variables) = @_;
  for my $directive (@{ $guards || [] }) {
    next if !$directive;
    my $name = $directive->{name} || '';
    my $arguments = $directive->{arguments} || {};
    my $if_value = materialize_dynamic_args($arguments->{if}, $variables);
    my $bool = $if_value ? 1 : 0;
    return 0 if $name eq 'skip' && $bool;
    return 0 if $name eq 'include' && !$bool;
  }
  return 1;
}

sub lookup_input_type {
  my ($runtime_schema, $typedef) = @_;
  return GraphQL::Houtou::Schema::lookup_type($typedef, $runtime_schema->runtime_cache->{name2type});
}

sub coerce_input_value {
  my ($type, $value) = @_;
  return $value if !defined $type;
  return $type->graphql_to_perl($value);
}

1;
