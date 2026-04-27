package GraphQL::Houtou::Runtime::InputCoercion;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou ();
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
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::materialize_dynamic_value_xs(
    $value,
    ($variables || {}),
  );
}

sub evaluate_runtime_guards {
  my ($guards, $variables) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::evaluate_runtime_guards_xs(
    ($guards || []),
    ($variables || {}),
  );
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
