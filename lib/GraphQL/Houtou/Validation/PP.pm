package GraphQL::Houtou::Validation::PP;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use Scalar::Util qw(reftype);

use GraphQL::Houtou::GraphQLPerl::Parser qw(parse_with_options);
use GraphQL::Houtou::Schema qw(lookup_type);
use GraphQL::Houtou::Schema::Compiler qw(compile_schema);

our @EXPORT_OK = qw(
  validate
  validate_prepared
);

sub validate {
  my ($schema, $document, $options) = @_;
  $options ||= {};

  my $ast = _coerce_ast($document, $options);
  my $compiled = compile_schema($schema);
  return validate_prepared($schema, $ast, $compiled, $options);
}

sub validate_prepared {
  my ($schema, $ast, $compiled, $options) = @_;
  $options ||= {};

  my @errors;
  my @operations = grep { $_->{kind} && $_->{kind} eq 'operation' } @$ast;
  my %fragments = map { ($_->{name} => $_) } grep { $_->{kind} && $_->{kind} eq 'fragment' } @$ast;

  if (!@operations && !$options->{skip_no_operations}) {
    push @errors, _error('No operations supplied.');
  }

  push @errors, @{ $options->{seed_errors} || [] };

  _validate_operation_names(\@errors, \@operations)
    if !$options->{skip_operation_name_uniqueness};
  _validate_lone_anonymous_operation(\@errors, \@operations)
    if !$options->{skip_lone_anonymous_operation};
  _validate_fragments(\@errors, $compiled, \%fragments);
  push @errors, @{ $options->{seed_fragment_cycle_errors} || [] };
  _validate_fragment_cycles(\@errors, \%fragments)
    if !$options->{skip_fragment_cycles};

  for my $index (0 .. $#operations) {
    my $operation = $operations[$index];
    push @errors, @{ $options->{seed_operation_errors}[$index] || [] };
    _validate_operation(\@errors, $schema, $compiled, $operation, \%fragments, $options);
  }

  return \@errors;
}

sub _coerce_ast {
  my ($document, $options) = @_;
  return $document if ref $document;

  return parse_with_options($document, {
    backend => 'xs',
    no_location => $options->{no_location} ? 1 : 0,
  });
}

sub _validate_operation_names {
  my ($errors, $operations) = @_;
  my %seen;

  for my $operation (@$operations) {
    next if !defined $operation->{name};
    next if !$seen{$operation->{name}}++;
    push @$errors, _error(
      "Operation '$operation->{name}' is defined more than once.",
      $operation->{location},
    );
  }
}

sub _validate_lone_anonymous_operation {
  my ($errors, $operations) = @_;
  return if @$operations <= 1;

  for my $operation (@$operations) {
    next if defined $operation->{name};
    push @$errors, _error(
      'Anonymous operations must be the only operation in the document.',
      $operation->{location},
    );
  }
}

sub _validate_operation {
  my ($errors, $schema, $compiled, $operation, $fragments, $options) = @_;
  my $operation_type = $operation->{operationType} || 'query';
  my $root_type_name = $compiled->{roots}{$operation_type};
  my $variables = $operation->{variables} || {};

  if (!$root_type_name) {
    push @$errors, _error(
      "Schema does not define a root type for '$operation_type'.",
      $operation->{location},
    );
    return;
  }

  _validate_variable_definitions($errors, $schema, $variables, $operation->{location});
  _validate_directives(
    $errors,
    $compiled,
    $operation->{directives} || [],
    _directive_location_for_operation($operation_type),
    $variables,
  );
  _validate_subscription_operation($errors, $operation, $fragments)
    if $operation_type eq 'subscription' && !$options->{skip_subscription_single_root_field};
  _validate_selections(
    $errors,
    $schema,
    $compiled,
    $operation->{selections} || [],
    $root_type_name,
    $variables,
    $fragments,
  );
}

sub _validate_fragments {
  my ($errors, $compiled, $fragments) = @_;

  for my $name (sort keys %$fragments) {
    my $fragment = $fragments->{$name};
    my $type_name = $fragment->{on};
    my $type = $compiled->{types}{$type_name};

    if (!$type) {
      push @$errors, _error(
        "Fragment '$name' references unknown type '$type_name'.",
        $fragment->{location},
      );
      next;
    }

    if (!$type->{is_abstract} && $type->{kind} ne 'OBJECT') {
      push @$errors, _error(
        "Fragment '$name' cannot target non-composite type '$type_name'.",
        $fragment->{location},
      );
      next;
    }

    _validate_directives(
      $errors,
      $compiled,
      $fragment->{directives} || [],
      'FRAGMENT_DEFINITION',
      {},
    );
    _validate_selections(
      $errors,
      undef,
      $compiled,
      $fragment->{selections} || [],
      $type_name,
      {},
      $fragments,
    );
  }
}

sub _validate_fragment_cycles {
  my ($errors, $fragments) = @_;
  my %state;

  for my $name (sort keys %$fragments) {
    _visit_fragment($errors, $fragments, \%state, [], $name);
  }
}

sub _visit_fragment {
  my ($errors, $fragments, $state, $stack, $name) = @_;
  return if !$fragments->{$name};
  return if ($state->{$name} || '') eq 'done';

  if (($state->{$name} || '') eq 'visiting') {
    push @$errors, _error(
      "Fragment '$name' participates in a cycle.",
      $fragments->{$name}{location},
    );
    return;
  }

  $state->{$name} = 'visiting';
  push @$stack, $name;

  for my $spread_name (_fragment_spreads_in_selections($fragments->{$name}{selections} || [])) {
    _visit_fragment($errors, $fragments, $state, [ @$stack ], $spread_name);
  }

  $state->{$name} = 'done';
}

sub _fragment_spreads_in_selections {
  my ($selections) = @_;
  my @names;

  for my $selection (@$selections) {
    if ($selection->{kind} eq 'fragment_spread' && defined $selection->{name}) {
      push @names, $selection->{name};
      next;
    }

    if ($selection->{kind} eq 'field') {
      push @names, _fragment_spreads_in_selections($selection->{selections} || []);
      next;
    }

    if ($selection->{kind} eq 'inline_fragment') {
      push @names, _fragment_spreads_in_selections($selection->{selections} || []);
    }
  }

  return @names;
}

sub _validate_variable_definitions {
  my ($errors, $schema, $variables, $location) = @_;

  for my $name (sort keys %$variables) {
    my $type;
    my $error;
    eval {
      $type = lookup_type($variables->{$name}, $schema->name2type);
      1;
    } or do {
      $error = $@ || "Unknown variable type for '\$$name'.";
    };

    if ($error) {
      $error =~ s/\s+at\s+.+\z//s;
      push @$errors, _error("Variable '\$$name' has an invalid type. $error", $location);
      next;
    }

    next if $type->DOES('GraphQL::Houtou::Role::Input') || $type->DOES('GraphQL::Role::Input');

    push @$errors, _error(
      "Variable '\$$name' is type '" . $type->to_string . "' which cannot be used as an input type.",
      $location,
    );
  }
}

sub _validate_selections {
  my ($errors, $schema, $compiled, $selections, $parent_type_name, $variables, $fragments) = @_;
  my $parent_type = $compiled->{types}{$parent_type_name};

  return if !$parent_type;

  for my $selection (@$selections) {
    if ($selection->{kind} eq 'field') {
      _validate_field_selection(
        $errors,
        $schema,
        $compiled,
        $selection,
        $parent_type,
        $variables,
        $fragments,
      );
      next;
    }

    if ($selection->{kind} eq 'fragment_spread') {
      my $fragment;
      _validate_directives(
        $errors,
        $compiled,
        $selection->{directives} || [],
        'FRAGMENT_SPREAD',
        $variables,
      );
      if (!$fragments->{$selection->{name}}) {
        push @$errors, _error(
          "Unknown fragment '$selection->{name}'.",
          $selection->{location},
        );
        next;
      }

      $fragment = $fragments->{$selection->{name}};
      if ($compiled->{types}{ $fragment->{on} }
          && !_selection_types_overlap($compiled, $parent_type->{name}, $fragment->{on})) {
        push @$errors, _error(
          "Fragment '$selection->{name}' cannot be spread here because type '$fragment->{on}' can never apply to '$parent_type->{name}'.",
          $selection->{location},
        );
      }
      next;
    }

    if ($selection->{kind} eq 'inline_fragment') {
      my $target_type_name = $selection->{on} || $parent_type->{name};
      my $target_type = $compiled->{types}{$target_type_name};

      _validate_directives(
        $errors,
        $compiled,
        $selection->{directives} || [],
        'INLINE_FRAGMENT',
        $variables,
      );

      if (!$target_type) {
        push @$errors, _error(
          "Inline fragment references unknown type '$target_type_name'.",
          $selection->{location},
        );
        next;
      }

      if (!_selection_types_overlap($compiled, $parent_type->{name}, $target_type_name)) {
        push @$errors, _error(
          "Inline fragment on '$target_type_name' cannot be used where type '$parent_type->{name}' is expected.",
          $selection->{location},
        );
        next;
      }

      _validate_selections(
        $errors,
        $schema,
        $compiled,
        $selection->{selections} || [],
        $target_type_name,
        $variables,
        $fragments,
      );
    }
  }
}

sub _validate_field_selection {
  my ($errors, $schema, $compiled, $selection, $parent_type, $variables, $fragments) = @_;
  my $field_name = $selection->{name};
  my $field_defs = $parent_type->{fields} || {};
  my $field_def = $field_defs->{$field_name};

  _validate_directives(
    $errors,
    $compiled,
    $selection->{directives} || [],
    'FIELD',
    $variables,
  );

  if (!$field_def) {
    if ($field_name ne '__typename') {
      push @$errors, _error(
        "Field '$field_name' does not exist on type '$parent_type->{name}'.",
        $selection->{location},
      );
    }
    return;
  }

  _validate_arguments(
    $errors,
    $compiled,
    $selection->{arguments} || {},
    $field_def->{args} || {},
    $variables,
    $selection->{location},
  );

  if ($selection->{selections}) {
    my $next_type_name = _named_type_name($field_def->{type});
    _validate_selections(
      $errors,
      $schema,
      $compiled,
      $selection->{selections},
      $next_type_name,
      $variables,
      $fragments,
    ) if defined $next_type_name;
  }
}

sub _validate_directives {
  my ($errors, $compiled, $directives, $location, $variables) = @_;
  my %seen;

  for my $directive (@$directives) {
    my $name = $directive->{name};
    my $definition = $compiled->{directives}{$name};

    if (!$definition) {
      push @$errors, _error(
        "Directive '\@$name' is not defined.",
        $directive->{location},
      );
      next;
    }

    if (!$seen{$name}++) {
      if (!_directive_allows_location($definition, $location)) {
        push @$errors, _error(
          "Directive '\@$name' cannot be used at location '$location'.",
          $directive->{location},
        );
      }
    } else {
      push @$errors, _error(
        "Directive '\@$name' may not be used more than once at the same location.",
        $directive->{location},
      );
    }

    _validate_arguments(
      $errors,
      $compiled,
      $directive->{arguments} || {},
      $definition->{args} || {},
      $variables,
      $directive->{location},
    );
  }
}

sub _directive_allows_location {
  my ($definition, $location) = @_;
  return scalar grep { $_ eq $location } @{ $definition->{locations} || [] };
}

sub _validate_subscription_operation {
  my ($errors, $operation, $fragments) = @_;
  my @field_names = _collect_top_level_subscription_fields($operation->{selections} || [], $fragments);

  if (@field_names != 1) {
    push @$errors, _error(
      "Subscription needs to have only one field; got (@field_names)",
      $operation->{location},
    );
  }
}

sub _collect_top_level_subscription_fields {
  my ($selections, $fragments) = @_;
  my @field_names;

  for my $selection (@$selections) {
    if ($selection->{kind} eq 'field') {
      push @field_names, $selection->{name} if defined $selection->{name};
      next;
    }

    if ($selection->{kind} eq 'fragment_spread') {
      my $fragment = $fragments->{$selection->{name}};
      next if !$fragment;
      push @field_names, _collect_top_level_subscription_fields($fragment->{selections} || [], $fragments);
      next;
    }

    if ($selection->{kind} eq 'inline_fragment') {
      push @field_names, _collect_top_level_subscription_fields($selection->{selections} || [], $fragments);
    }
  }

  return @field_names;
}

sub _validate_arguments {
  my ($errors, $compiled, $arguments, $argument_defs, $variables, $location) = @_;

  for my $name (sort keys %$arguments) {
    my $argument_def = $argument_defs->{$name};
    if (!$argument_def) {
      push @$errors, _error(
        "Unknown argument '$name'.",
        $location,
      );
      next;
    }

    _validate_value(
      $errors,
      $compiled,
      $arguments->{$name},
      $argument_def->{type},
      $variables,
      $location,
    );
  }

  for my $name (sort keys %$argument_defs) {
    my $argument_def = $argument_defs->{$name};
    next if exists $arguments->{$name};
    next if !_type_is_non_null($argument_def->{type});
    next if $argument_def->{has_default_value};
    push @$errors, _error(
      "Required argument '$name' was not provided.",
      $location,
    );
  }
}

sub _validate_value {
  my ($errors, $compiled, $value, $expected_type, $variables, $location) = @_;

  if (!ref $value) {
    return;
  }

  if (reftype($value) && reftype($value) eq 'SCALAR') {
    my $inner = $$value;

    if (!ref $inner) {
      if (!exists $variables->{$inner}) {
        push @$errors, _error(
          "Variable '\$$inner' is used but not defined.",
          $location,
        );
      }
      return;
    }

    if (reftype($inner) && reftype($inner) eq 'SCALAR') {
      my $enum_name = $$inner;
      my $named_type = _unwrap_named_type($compiled, $expected_type);
      if ($named_type && $named_type->{kind} eq 'ENUM' && !exists $named_type->{values}{$enum_name}) {
        push @$errors, _error(
          "Enum value '$enum_name' is not valid for type '$named_type->{name}'.",
          $location,
        );
      }
      return;
    }
  }

  if (ref $value eq 'ARRAY') {
    my $item_type = _type_kind($expected_type) eq 'LIST' ? $expected_type->{of} : $expected_type;
    _validate_value($errors, $compiled, $_, $item_type, $variables, $location) for @$value;
    return;
  }

  if (ref $value eq 'HASH') {
    my $named_type = _unwrap_named_type($compiled, $expected_type);
    return if !$named_type || $named_type->{kind} ne 'INPUT_OBJECT';

    for my $field_name (sort keys %$value) {
      my $field = $named_type->{fields}{$field_name};
      if (!$field) {
        push @$errors, _error(
          "Input field '$field_name' is not defined on type '$named_type->{name}'.",
          $location,
        );
        next;
      }

      _validate_value(
        $errors,
        $compiled,
        $value->{$field_name},
        $field->{type},
        $variables,
        $location,
      );
    }

    for my $field_name (sort keys %{ $named_type->{fields} || {} }) {
      my $field = $named_type->{fields}{$field_name};
      next if exists $value->{$field_name};
      next if !_type_is_non_null($field->{type});
      next if $field->{has_default_value};
      push @$errors, _error(
        "Required input field '$field_name' was not provided for type '$named_type->{name}'.",
        $location,
      );
    }
  }
}

sub _directive_location_for_operation {
  my ($operation_type) = @_;
  return 'MUTATION' if $operation_type eq 'mutation';
  return 'SUBSCRIPTION' if $operation_type eq 'subscription';
  return 'QUERY';
}

sub _type_is_non_null {
  my ($type_ref) = @_;
  return _type_kind($type_ref) eq 'NON_NULL' ? 1 : 0;
}

sub _named_type_name {
  my ($type_ref) = @_;
  if (_type_kind($type_ref) eq 'NAMED') {
    return $type_ref->{name};
  }
  return _named_type_name($type_ref->{of}) if ref $type_ref eq 'HASH' && exists $type_ref->{of};
  return undef;
}

sub _unwrap_named_type {
  my ($compiled, $type_ref) = @_;
  my $name = _named_type_name($type_ref);
  return $name ? $compiled->{types}{$name} : undef;
}

sub _selection_types_overlap {
  my ($compiled, $left_name, $right_name) = @_;
  my $left = $compiled->{types}{$left_name};
  my $right = $compiled->{types}{$right_name};
  my %left_objects;

  return 0 if !$left || !$right;
  return 1 if $left_name eq $right_name;

  %left_objects = map { ($_ => 1) } _possible_object_names($compiled, $left_name);
  return scalar grep { $left_objects{$_} } _possible_object_names($compiled, $right_name);
}

sub _possible_object_names {
  my ($compiled, $type_name) = @_;
  my $type = $compiled->{types}{$type_name};

  return () if !$type;
  return ($type_name) if $type->{kind} eq 'OBJECT';
  return @{ $compiled->{possible_types}{$type_name} || [] }
    if $type->{kind} eq 'INTERFACE' || $type->{kind} eq 'UNION';
  return ();
}

sub _type_kind {
  my ($type_ref) = @_;
  return ref $type_ref eq 'HASH' ? ($type_ref->{kind} || '') : '';
}

sub _error {
  my ($message, $location) = @_;
  my %error = (message => $message);
  $error{locations} = [ $location ] if $location;
  return \%error;
}

1;
