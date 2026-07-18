package GraphQL::Houtou::Validation;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou ();
use GraphQL::Houtou::Schema qw(lookup_type);

our @EXPORT_OK = qw(
  validate
);

sub validate {
  my ($schema, $source_or_ast, @rest) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  require GraphQL::Houtou::XS::Parser if !ref($source_or_ast);
  return GraphQL::Houtou::XS::Validation::validate_xs($schema, $source_or_ast, @rest);
}

sub _validate_directives {
  my ($schema, $document) = @_;
  return [] if ref($document) ne 'ARRAY';

  my $directive_defs = $schema->name2directive || {};
  my $schema_name2type = $schema->name2type || {};
  my @errors;
  my %fragments = map {
    ($_->{kind} || q()) eq 'fragment' && defined $_->{name}
      ? ($_->{name} => $_)
      : ()
  } @$document;

  for my $definition (@$document) {
    next if ref($definition) ne 'HASH';
    if (($definition->{kind} || q()) eq 'operation') {
      _validate_directive_list(
        errors => \@errors,
        directive_defs => $directive_defs,
        directives => $definition->{directives},
        location => uc($definition->{operationType} || 'query'),
        variable_defs => $definition->{variables} || {},
        schema_name2type => $schema_name2type,
      );
      _validate_variable_definitions(
        errors => \@errors,
        directive_defs => $directive_defs,
        variable_defs => $definition->{variables} || {},
        schema_name2type => $schema_name2type,
      );
      _validate_selections(
        errors => \@errors,
        directive_defs => $directive_defs,
        selections => $definition->{selections},
        variable_defs => $definition->{variables} || {},
        schema_name2type => $schema_name2type,
      );
      next;
    }

    next if ($definition->{kind} || q()) ne 'fragment';
    _validate_directive_list(
      errors => \@errors,
      directive_defs => $directive_defs,
      directives => $definition->{directives},
      location => 'FRAGMENT_DEFINITION',
      variable_defs => {},
      schema_name2type => $schema_name2type,
    );
    _validate_selections(
      errors => \@errors,
      directive_defs => $directive_defs,
      selections => $definition->{selections},
      variable_defs => {},
      schema_name2type => $schema_name2type,
    );
  }

  return \@errors;
}

sub _validate_variable_definitions {
  my (%args) = @_;
  my $variable_defs = $args{variable_defs} || {};
  for my $name (sort keys %$variable_defs) {
    my $def = $variable_defs->{$name} || next;
    _validate_directive_list(
      %args,
      directives => $def->{directives},
      location => 'VARIABLE_DEFINITION',
    );
  }
}

sub _validate_selections {
  my (%args) = @_;
  my $selections = $args{selections} || [];

  for my $selection (@$selections) {
    next if ref($selection) ne 'HASH';
    my $kind = $selection->{kind} || q();

    if ($kind eq 'field') {
      _validate_directive_list(
        %args,
        directives => $selection->{directives},
        location => 'FIELD',
      );
      _validate_selections(%args, selections => $selection->{selections});
      next;
    }

    if ($kind eq 'fragment_spread') {
      _validate_directive_list(
        %args,
        directives => $selection->{directives},
        location => 'FRAGMENT_SPREAD',
      );
      next;
    }

    if ($kind eq 'inline_fragment') {
      _validate_directive_list(
        %args,
        directives => $selection->{directives},
        location => 'INLINE_FRAGMENT',
      );
      _validate_selections(%args, selections => $selection->{selections});
    }
  }
}

sub _validate_directive_list {
  my (%args) = @_;
  my $directives = $args{directives} || [];
  return if !@$directives;

  my $directive_defs = $args{directive_defs} || {};
  my $location = $args{location};
  my $variable_defs = $args{variable_defs} || {};
  my %seen;

  for my $directive (@$directives) {
    next if ref($directive) ne 'HASH';
    my $name = $directive->{name} || next;
    my $def = $directive_defs->{$name};

    if (!$def) {
      push @{ $args{errors} }, _validation_error($directive, "Unknown directive '\@$name'.");
      next;
    }

    if (!grep { $_ eq $location } @{ $def->locations || [] }) {
      push @{ $args{errors} }, _validation_error(
        $directive,
        "Directive '\@$name' may not be used on $location.",
      );
    }

    if (!$def->repeatable && $seen{$name}++) {
      push @{ $args{errors} }, _validation_error(
        $directive,
        "Directive '\@$name' is not repeatable and cannot be used more than once at this location.",
      );
    }

    _validate_directive_arguments(
      errors => $args{errors},
      directive => $directive,
      directive_def => $def,
      variable_defs => $variable_defs,
      schema_name2type => $args{schema_name2type},
    );
  }
}

sub _validate_directive_arguments {
  my (%args) = @_;
  my $directive = $args{directive} || {};
  my $directive_def = $args{directive_def} || return;
  my $directive_name = $directive->{name} || $directive_def->name;
  my $arg_defs = $directive_def->args || {};
  my $arg_values = $directive->{arguments} || {};

  for my $arg_name (sort keys %$arg_values) {
    next if exists $arg_defs->{$arg_name};
    push @{ $args{errors} }, _validation_error(
      $directive,
      "Unknown argument '$arg_name' on directive '\@$directive_name'.",
    );
  }

  for my $arg_name (sort keys %$arg_defs) {
    my $arg_def = $arg_defs->{$arg_name} || {};
    my $type = $arg_def->{type} || next;
    if (!exists $arg_values->{$arg_name}) {
      if (_is_non_null_type($type) && !exists $arg_def->{default_value}) {
        push @{ $args{errors} }, _validation_error(
          $directive,
          "Required argument '$arg_name' was not provided to directive '\@$directive_name'.",
        );
      }
      next;
    }

    _validate_argument_value(
      errors => $args{errors},
      directive => $directive,
      directive_name => $directive_name,
      arg_name => $arg_name,
      expected_type => $type,
      location_has_default => exists $arg_def->{default_value} ? 1 : 0,
      value => $arg_values->{$arg_name},
      variable_defs => $args{variable_defs},
      schema_name2type => $args{schema_name2type},
    );
  }
}

sub _validate_argument_value {
  my (%args) = @_;
  my $value = $args{value};
  my $expected_type = $args{expected_type};

  if (_is_variable_ref($value)) {
    my $var_name = $$value;
    my $var_def = ($args{variable_defs} || {})->{$var_name};
    return if !$var_def;
    my $var_type = lookup_type($var_def, $args{schema_name2type});
    # Spec AllowedVariableUsage: a nullable variable may flow into a
    # non-null location when either side supplies a default value; the
    # inner types are then compared instead.
    my $location_type = $expected_type;
    if (_is_non_null_type($location_type) && !_is_non_null_type($var_type)) {
      my $has_var_default = defined $var_def->{default_value};
      if ($has_var_default || $args{location_has_default}) {
        $location_type = $location_type->of;
      }
    }
    if (!_variable_type_compatible($var_type, $location_type)) {
      push @{ $args{errors} }, _validation_error(
        $args{directive},
        "Variable '\$$var_name' of type '" . $var_type->to_string .
          "' cannot be used for directive '\@$args{directive_name}' argument '$args{arg_name}' of type '" .
          $expected_type->to_string . "'.",
      );
    }
    return;
  }

  return if _contains_variable_ref($value);

  my $ok = eval {
    $expected_type->graphql_to_perl($value);
    1;
  };
  return if $ok;

  my $error = $@ || "invalid value\n";
  chomp $error;
  push @{ $args{errors} }, _validation_error(
    $args{directive},
    "Argument '$args{arg_name}' on directive '\@$args{directive_name}' has invalid value: $error",
  );
}

sub _contains_variable_ref {
  my ($value) = @_;
  my $ref = ref($value);
  return 0 if !$ref;
  return 1 if $ref eq 'SCALAR' || $ref eq 'REF';
  return !!grep { _contains_variable_ref($_) } @$value if $ref eq 'ARRAY';
  return !!grep { _contains_variable_ref($value->{$_}) } keys %$value if $ref eq 'HASH';
  return 0;
}

sub _is_variable_ref {
  my ($value) = @_;
  return ref($value) eq 'SCALAR';
}

sub _variable_type_compatible {
  my ($variable_type, $location_type) = @_;
  return 0 if !$variable_type || !$location_type;

  if (_is_non_null_type($location_type)) {
    return 0 if !_is_non_null_type($variable_type);
    return _variable_type_compatible($variable_type->of, $location_type->of);
  }

  if (_is_non_null_type($variable_type)) {
    return _variable_type_compatible($variable_type->of, $location_type);
  }

  if (_is_list_type($location_type) || _is_list_type($variable_type)) {
    return 0 if !_is_list_type($location_type) || !_is_list_type($variable_type);
    return _variable_type_compatible($variable_type->of, $location_type->of);
  }

  return ($variable_type->name || q()) eq ($location_type->name || q());
}

sub _is_non_null_type {
  my ($type) = @_;
  return !!($type && eval { $type->isa('GraphQL::Houtou::Type::NonNull') });
}

sub _is_list_type {
  my ($type) = @_;
  return !!($type && eval { $type->isa('GraphQL::Houtou::Type::List') });
}

sub _validation_error {
  my ($node, $message) = @_;
  my %error = (message => $message);
  if ($node && ref($node) eq 'HASH' && $node->{location}) {
    $error{locations} = [ { %{ $node->{location} } } ];
  }
  return \%error;
}

1;

__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou::Validation - GraphQL document validation facade

=head1 SYNOPSIS

    use GraphQL::Houtou::Validation qw(validate);

    my $errors = validate($schema, $source_or_ast);

=head1 DESCRIPTION

This module is the public entry point for GraphQL validation.
The active runtime path requires the XS validator and does not keep a
pure-Perl fallback in the mainline surface.

=cut
