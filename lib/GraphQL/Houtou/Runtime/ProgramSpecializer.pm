package GraphQL::Houtou::Runtime::ProgramSpecializer;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Runtime::VMCompiler ();
use GraphQL::Houtou::Schema ();

sub specialize_for_native {
  my ($class, $runtime_schema, $program, %opts) = @_;
  return $program if !$program;

  my $variables = _prepare_variables($runtime_schema, $program, $opts{variables} || {});
  my $clone = GraphQL::Houtou::Runtime::VMCompiler->inflate_program(
    $runtime_schema,
    $program->to_struct,
  );

  for my $block (@{ $clone->blocks || [] }) {
    my @ops;
    for my $op (@{ $block->ops || [] }) {
      next if !_specialize_directives($op, $variables);
      _specialize_args($runtime_schema, $op, $variables);
      push @ops, $op;
    }
    $block->{ops} = \@ops;
  }

  $clone->{variable_defs} = {};
  return $clone;
}

sub _specialize_directives {
  my ($op, $variables) = @_;
  my $mode = $op->directives_mode || 'NONE';
  return 1 if $mode eq 'NONE';

  my $guards = $op->directives_payload || [];
  return 0 if !_evaluate_runtime_guards($guards, $variables);

  $op->{has_directives} = 0;
  $op->{directives_mode} = 'NONE';
  $op->{directives_payload} = undef;
  return 1;
}

sub _specialize_args {
  my ($runtime_schema, $op, $variables) = @_;
  my $arg_defs = $op->arg_defs || {};
  if (!keys %$arg_defs) {
    $op->{has_args} = 0;
    $op->{args_mode} = 'NONE';
    $op->{args_payload} = undef;
    return;
  }

  my $mode = $op->args_mode || 'NONE';
  my $payload = $op->args_payload || {};
  my $coerced = $mode eq 'DYNAMIC'
    ? _coerce_dynamic_args($runtime_schema, $arg_defs, $payload, $variables)
    : _coerce_static_args($runtime_schema, $arg_defs, $payload);

  $op->{has_args} = keys %$coerced ? 1 : 0;
  $op->{args_mode} = $op->{has_args} ? 'STATIC' : 'NONE';
  $op->{args_payload} = $op->{has_args} ? $coerced : undef;
}

sub _evaluate_runtime_guards {
  my ($guards, $variables) = @_;
  for my $directive (@{ $guards || [] }) {
    next if !$directive;
    my $name = $directive->{name} || '';
    my $arguments = $directive->{arguments} || {};
    my $if_value = _materialize_dynamic_args($arguments->{if}, $variables);
    my $bool = $if_value ? 1 : 0;
    return 0 if $name eq 'skip' && $bool;
    return 0 if $name eq 'include' && !$bool;
  }
  return 1;
}

sub _prepare_variables {
  my ($runtime_schema, $program, $provided) = @_;
  my %resolved = %{ $provided || {} };
  for my $name (keys %{ $program->variable_defs || {} }) {
    next if exists $resolved{$name};
    my $def = $program->variable_defs->{$name} || {};
    next if !$def->{has_default};
    $resolved{$name} = $def->{default_value};
  }
  return _coerce_variable_values($runtime_schema, $program->variable_defs || {}, \%resolved);
}

sub _coerce_variable_values {
  my ($runtime_schema, $defs, $values) = @_;
  my %coerced;
  for my $name (keys %{ $defs || {} }) {
    my $def = $defs->{$name} || {};
    next if !exists $values->{$name};
    my $type = _lookup_input_type($runtime_schema, $def->{type});
    $coerced{$name} = _coerce_input_value($type, $values->{$name});
  }
  for my $name (keys %{ $values || {} }) {
    next if exists $coerced{$name};
    $coerced{$name} = $values->{$name};
  }
  return \%coerced;
}

sub _coerce_static_args {
  my ($runtime_schema, $arg_defs, $payload) = @_;
  my %values;

  for my $name (keys %{$arg_defs || {}}) {
    my $arg_def = $arg_defs->{$name} || {};
    my $type = _lookup_input_type($runtime_schema, $arg_def->{type});
    my $has_value = exists $payload->{$name};
    next if !$has_value && !$arg_def->{has_default};
    my $raw = $has_value ? $payload->{$name} : $arg_def->{default_value};
    $values{$name} = _coerce_input_value($type, $raw);
  }

  return \%values;
}

sub _coerce_dynamic_args {
  my ($runtime_schema, $arg_defs, $payload, $variables) = @_;
  my %values;

  for my $name (keys %{$arg_defs || {}}) {
    my $arg_def = $arg_defs->{$name} || {};
    my $type = _lookup_input_type($runtime_schema, $arg_def->{type});
    next if !exists $payload->{$name} && !$arg_def->{has_default};
    $values{$name} = _coerce_dynamic_arg_value(
      $runtime_schema,
      $type,
      exists $payload->{$name} ? $payload->{$name} : undef,
      $variables,
      $arg_def->{has_default} ? $arg_def->{default_value} : undef,
    );
  }

  return \%values;
}

sub _coerce_dynamic_arg_value {
  my ($runtime_schema, $type, $raw, $variables, $default) = @_;
  if (ref($raw) eq 'SCALAR') {
    return exists $variables->{$$raw}
      ? $variables->{$$raw}
      : (defined $default ? _coerce_input_value($type, $default) : undef);
  }
  my $materialized = defined($raw)
    ? _materialize_dynamic_args($raw, $variables)
    : $default;
  return _coerce_input_value($type, $materialized);
}

sub _materialize_dynamic_args {
  my ($value, $variables) = @_;
  my $ref = ref($value);
  return $value if !$ref;
  return (exists $variables->{$$value} ? $variables->{$$value} : undef) if $ref eq 'SCALAR';
  return $$$value if $ref eq 'REF';
  return [ map { _materialize_dynamic_args($_, $variables) } @$value ] if $ref eq 'ARRAY';
  return { map { $_ => _materialize_dynamic_args($value->{$_}, $variables) } keys %$value } if $ref eq 'HASH';
  return $value;
}

sub _lookup_input_type {
  my ($runtime_schema, $typedef) = @_;
  return GraphQL::Houtou::Schema::lookup_type($typedef, $runtime_schema->runtime_cache->{name2type});
}

sub _coerce_input_value {
  my ($type, $value) = @_;
  return $value if !defined $type;
  return $type->graphql_to_perl($value);
}

1;
