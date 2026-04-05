package GraphQL::Houtou::Execution::PP;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use JSON::MaybeXS;
use Scalar::Util qw(blessed);

use GraphQL::Error;
use GraphQL::Houtou::Directive;
use GraphQL::Houtou::GraphQLPerl::Parser qw(parse_with_options);
use GraphQL::Houtou::Introspection qw(
  $SCHEMA_META_FIELD_DEF
  $TYPE_META_FIELD_DEF
  $TYPE_NAME_META_FIELD_DEF
);
use GraphQL::Houtou::Schema qw(lookup_type);

our @EXPORT_OK = qw(
  execute
);

my $JSON = JSON::MaybeXS->new->allow_nonref;

sub execute {
  my (
    $schema,
    $doc,
    $root_value,
    $context_value,
    $variable_values,
    $operation_name,
    $field_resolver,
    $promise_code,
  ) = @_;

  my $context = eval {
    my $ast = ref($doc) ? $doc : _coerce_ast($doc);
    _build_context(
      $schema,
      $ast,
      $root_value,
      $context_value,
      $variable_values,
      $operation_name,
      $field_resolver,
      $promise_code,
    );
  };

  return _build_response(_wrap_error($@)) if $@;
  return _build_response(execute_prepared_context($context), 1);
}

sub execute_prepared_context {
  my ($context) = @_;
  my $result = eval {
    $context->{field_resolver} ||= \&_default_field_resolver;
    _execute_operation($context, $context->{operation}, $context->{root_value});
  };

  return _wrap_error($@) if $@;
  return $result;
}

sub _coerce_ast {
  my ($document) = @_;
  return parse_with_options($document, { backend => 'xs' });
}

sub _build_response {
  my ($result, $force_data) = @_;
  my @errors = @{ $result->{errors} || [] };

  return {
    $force_data ? (data => undef) : (),
    %$result,
    @errors ? (errors => [ map $_->to_json, @errors ]) : (),
  };
}

sub _wrap_error {
  my ($error) = @_;
  return $error if ref($error) eq 'HASH' && ref($error->{errors}) eq 'ARRAY';
  return { errors => [ GraphQL::Error->coerce($error) ] };
}

sub _build_context {
  my (
    $schema,
    $ast,
    $root_value,
    $context_value,
    $variable_values,
    $operation_name,
    $field_resolver,
    $promise_code,
  ) = @_;

  my %fragments = map { ($_->{name} => $_) } grep { ($_->{kind} || '') eq 'fragment' } @$ast;
  my @operations = grep { ($_->{kind} || '') eq 'operation' } @$ast;
  die "No operations supplied.\n" if !@operations;
  die "Can only execute document containing fragments or operations\n"
    if @$ast != keys(%fragments) + @operations;

  my $operation = _get_operation($operation_name, \@operations);

  return {
    schema => $schema,
    fragments => \%fragments,
    root_value => $root_value,
    context_value => $context_value,
    operation => $operation,
    variable_values => _variables_apply_defaults(
      $schema,
      $operation->{variables} || {},
      $variable_values || {},
    ),
    field_resolver => $field_resolver || \&_default_field_resolver,
    promise_code => $promise_code,
  };
}

sub _variables_apply_defaults {
  my ($schema, $operation_variables, $variable_values) = @_;
  my %values;

  for my $name (keys %$operation_variables) {
    my $opvar = $operation_variables->{$name};
    my $opvar_type = lookup_type($opvar, $schema->name2type);
    my $parsed_value;
    my $maybe_value = exists $variable_values->{$name}
      ? $variable_values->{$name}
      : $opvar->{default_value};

    if (!$opvar_type->DOES('GraphQL::Houtou::Role::Input')
        && !$opvar_type->DOES('GraphQL::Role::Input')) {
      die "Variable '\$$name' is type '@{[$opvar_type->to_string]}' which cannot be used as an input type.\n";
    }

    eval { $parsed_value = $opvar_type->graphql_to_perl($maybe_value) };
    if ($@) {
      my $error = $@;
      my $jsonable = _coerce_for_error($maybe_value);
      $error =~ s#\s+at.*line\s+\d+\.#.#;
      die "Variable '\$$name' got invalid value @{[$JSON->canonical->encode($jsonable)]}.\n$error";
    }

    $values{$name} = {
      value => $parsed_value,
      type => $opvar_type,
    };
  }

  return \%values;
}

sub _get_operation {
  my ($operation_name, $operations) = @_;

  if (!defined $operation_name) {
    die "Must provide operation name if query contains multiple operations.\n"
      if @$operations > 1;
    return $operations->[0];
  }

  my @matching = grep { defined($_->{name}) && $_->{name} eq $operation_name } @$operations;
  return $matching[0] if @matching == 1;
  die "No operations matching '$operation_name' found.\n";
}

sub _execute_operation {
  my ($context, $operation, $root_value) = @_;
  my $op_type = $operation->{operationType} || 'query';
  my $type = $context->{schema}->$op_type;
  my ($fields);

  return _wrap_error("No $op_type in schema") if !$type;

  ($fields) = $type->_collect_fields(
    $context,
    $operation->{selections},
    [ [], {} ],
    {},
  );

  return ($op_type eq 'mutation')
    ? _execute_fields_serially($context, $type, $root_value, [], $fields)
    : _execute_fields($context, $type, $root_value, [], $fields);
}

sub _execute_fields {
  my ($context, $parent_type, $root_value, $path, $fields) = @_;
  my ($field_names, $nodes_defs) = @$fields;
  my %name2executionresult;
  my @errors;

  for my $result_name (@$field_names) {
    my $nodes = $nodes_defs->{$result_name};
    my $field_node = $nodes->[0];
    my $field_name = $field_node->{name};
    my $field_def = _get_field_def($context->{schema}, $parent_type, $field_name);
    my $resolve;
    my $info;
    my $result;

    next if !$field_def;

    $resolve = $field_def->{resolve} || $context->{field_resolver};
    $info = _build_resolve_info(
      $context,
      $parent_type,
      $field_def,
      [ @$path, $result_name ],
      $nodes,
    );
    $result = _resolve_field_value_or_error(
      $context,
      $field_def,
      $nodes,
      $resolve,
      $root_value,
      $info,
    );
    $name2executionresult{$result_name} = _complete_value_catching_error(
      $context,
      $field_def->{type},
      $nodes,
      $info,
      [ @$path, $result_name ],
      $result,
    );
  }

  return _merge_hash(
    [ keys %name2executionresult ],
    [ values %name2executionresult ],
    \@errors,
  );
}

sub _merge_hash {
  my ($keys, $values, $errors) = @_;
  my @all_errors = (@$errors, map @{ $_->{errors} || [] }, @$values);
  my %name2data;

  for (my $i = @$values - 1; $i >= 0; $i--) {
    $name2data{$keys->[$i]} = $values->[$i]{data};
  }

  return {
    %name2data ? (data => \%name2data) : (),
    @all_errors ? (errors => \@all_errors) : (),
  };
}

sub _execute_fields_serially {
  goto &_execute_fields;
}

sub _get_field_def {
  my ($schema, $parent_type, $field_name) = @_;
  my $special = {
    $SCHEMA_META_FIELD_DEF->{name} => $SCHEMA_META_FIELD_DEF,
    $TYPE_META_FIELD_DEF->{name} => $TYPE_META_FIELD_DEF,
  };

  return $TYPE_NAME_META_FIELD_DEF
    if $field_name eq $TYPE_NAME_META_FIELD_DEF->{name};
  return $special->{$field_name}
    if $special->{$field_name} && $parent_type == $schema->query;
  return $parent_type->fields->{$field_name};
}

sub _build_resolve_info {
  my ($context, $parent_type, $field_def, $path, $nodes) = @_;
  return {
    field_name => $nodes->[0]{name},
    field_nodes => $nodes,
    return_type => $field_def->{type},
    parent_type => $parent_type,
    path => $path,
    schema => $context->{schema},
    fragments => $context->{fragments},
    root_value => $context->{root_value},
    operation => $context->{operation},
    variable_values => $context->{variable_values},
    promise_code => $context->{promise_code},
  };
}

sub _resolve_field_value_or_error {
  my ($context, $field_def, $nodes, $resolve, $root_value, $info) = @_;
  my $result = eval {
    my $args = _get_argument_values($field_def, $nodes->[0], $context->{variable_values});
    $resolve->($root_value, $args, $context->{context_value}, $info);
  };

  return GraphQL::Error->coerce($@) if $@;
  return $result;
}

sub _complete_value_catching_error {
  my ($context, $return_type, $nodes, $info, $path, $result) = @_;

  if (_is_non_null_type($return_type)) {
    return _complete_value_with_located_error(@_);
  }

  $result = eval {
    _complete_value_with_located_error(@_);
  };

  return _wrap_error($@) if $@;
  return $result;
}

sub _complete_value_with_located_error {
  my ($context, $return_type, $nodes, $info, $path, $result) = @_;

  $result = eval {
    _complete_value(@_);
  };

  die _located_error($@, $nodes, $path) if $@;
  return $result;
}

sub _complete_value {
  my ($context, $return_type, $nodes, $info, $path, $result) = @_;

  die $result if GraphQL::Error->is($result);

  if (_is_non_null_type($return_type)) {
    my $completed = _complete_value(
      $context,
      $return_type->of,
      $nodes,
      $info,
      $path,
      $result,
    );

    die GraphQL::Error->coerce(
      "Cannot return null for non-nullable field @{[$info->{parent_type}->name]}.@{[$info->{field_name}]}."
    ) if !defined $completed->{data};
    return $completed;
  }

  return { data => undef } if !defined $result;
  return $return_type->_complete_value($context, $nodes, $info, $path, $result);
}

sub _located_error {
  my ($error, $nodes, $path) = @_;
  $error = GraphQL::Error->coerce($error);
  return $error if $error->locations;

  return GraphQL::Error->coerce($error)->but(
    locations => [ map $_->{location}, @$nodes ],
    path => $path,
  );
}

sub _get_argument_values {
  my ($def, $node, $variable_values) = @_;
  my $arg_defs = $def->{args};
  my $arg_nodes = $node->{arguments};
  my %coerced_values;

  $variable_values ||= {};
  return {} if !$arg_defs;

  for my $name (keys %$arg_defs) {
    my $arg_def = $arg_defs->{$name};
    my $arg_type = $arg_def->{type};
    my $default_value = $arg_def->{default_value};
    my $argument_node = $arg_nodes ? $arg_nodes->{$name} : undef;

    if ((!$arg_nodes || !exists $arg_nodes->{$name}) && exists $arg_def->{default_value}) {
      $coerced_values{$name} = $default_value;
      next;
    }

    if ((!$arg_nodes || !exists $arg_nodes->{$name}) && _is_non_null_type($arg_type)) {
      die GraphQL::Error->new(
        message => "Argument '$name' of type '@{[$arg_type->to_string]}' not given.",
        nodes => [ $node ],
      );
    }

    if (ref($argument_node) eq 'SCALAR') {
      my $var_name = $$argument_node;
      if (exists $variable_values->{$var_name}) {
        my $variable = $variable_values->{$var_name};
        if (!_type_will_accept($arg_type, $variable->{type})) {
          die GraphQL::Error->new(
            message => "Variable '\$$var_name' of type '@{[$variable->{type}->to_string]}' where expected '@{[$arg_type->to_string]}'.",
            nodes => [ $node ],
          );
        }
        $coerced_values{$name} = $variable->{value};
        next;
      }

      if (exists $arg_def->{default_value}) {
        $coerced_values{$name} = $default_value;
        next;
      }

      if (_is_non_null_type($arg_type)) {
        die GraphQL::Error->new(
          message => "Argument '$name' of type '@{[$arg_type->to_string]}' was given variable '\$$var_name' but no runtime value.",
          nodes => [ $node ],
        );
      }

      next;
    }

    next if !$arg_nodes || !exists $arg_nodes->{$name};

    $coerced_values{$name} = _coerce_value($argument_node, $variable_values, $default_value);
    next if !exists $coerced_values{$name};

    eval {
      $coerced_values{$name} = $arg_type->graphql_to_perl($coerced_values{$name});
      1;
    } or do {
      my $error = $@;
      my $jsonable = _coerce_for_error($coerced_values{$name});
      $error =~ s#\s+at.*line\s+\d+\.#.#;
      die GraphQL::Error->new(
        message => "Argument '$name' got invalid value @{[$JSON->encode($jsonable)]}.\nExpected '@{[$arg_type->to_string]}'.\n$error",
        nodes => [ $node ],
      );
    };
  }

  return \%coerced_values;
}

sub _coerce_for_error {
  my ($value) = @_;
  my $ref = ref($value);

  return $$value if $ref eq 'SCALAR';
  return [ map { _coerce_for_error($_) } @$value ] if $ref eq 'ARRAY';
  return { map { $_ => _coerce_for_error($value->{$_}) } keys %$value } if $ref eq 'HASH';
  return $value;
}

sub _coerce_value {
  my ($argument_node, $variable_values, $default_value) = @_;

  if (ref($argument_node) eq 'SCALAR') {
    return (exists $variable_values->{$$argument_node}
      ? $variable_values->{$$argument_node}{value}
      : $default_value);
  }

  if (ref($argument_node) eq 'REF') {
    return $$$argument_node;
  }

  if (ref($argument_node) eq 'ARRAY') {
    return [ map { _coerce_value($_, $variable_values, $default_value) } @$argument_node ];
  }

  if (ref($argument_node) eq 'HASH') {
    return { map { $_ => _coerce_value($argument_node->{$_}, $variable_values, $default_value) } keys %$argument_node };
  }

  return $argument_node;
}

sub _type_will_accept {
  my ($arg_type, $var_type) = @_;

  return 1 if $arg_type == $var_type;

  $arg_type = $arg_type->of if _is_non_null_type($arg_type);
  $var_type = $var_type->of if _is_non_null_type($var_type);

  return 1 if $arg_type == $var_type;
  return 1 if $arg_type->to_string eq $var_type->to_string;
  return '';
}

sub _default_field_resolver {
  my ($root_value, $args, $context, $info) = @_;
  my $field_name = $info->{field_name};
  my $property = ref($root_value) eq 'HASH'
    ? $root_value->{$field_name}
    : $root_value;

  if (length(ref($property)) && (
      ref($property) eq 'CODE' ||
      (blessed($property) && overload::Method($property, '&{}'))
  )) {
    return $property->($args, $context, $info);
  }

  if (length(ref($root_value)) && blessed($root_value) && $root_value->can($field_name)) {
    return $root_value->$field_name($args, $context, $info);
  }

  return $property;
}

sub _is_non_null_type {
  my ($type) = @_;
  return $type->isa('GraphQL::Houtou::Type::NonNull') || $type->isa('GraphQL::Type::NonNull');
}

1;
