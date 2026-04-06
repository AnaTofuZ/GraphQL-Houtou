package GraphQL::Houtou::XS::Execution;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou::Promise::Adapter qw(
  all_promise
  normalize_promise_code
  reject_promise
  resolve_promise
  then_promise
);

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  execute_xs
  execute_prepared_ir_xs
  _prepare_executable_ir_xs
  _prepared_executable_ir_stats_xs
  _prepared_executable_ir_plan_xs
  _prepared_executable_ir_frontend_xs
  _prepared_executable_ir_context_seed_xs
  _prepared_executable_ir_operation_legacy_xs
  _prepared_executable_ir_root_selection_plan_xs
  _prepared_executable_ir_root_field_buckets_xs
  _prepared_executable_ir_root_field_plan_xs
  _prepared_executable_ir_root_legacy_fields_xs
  _prepared_executable_ir_execution_context_xs
  _execute_prepared_ir_xs
  _collect_fields_xs
  _execute_fields_xs
  _get_argument_values_xs
  _complete_value_catching_error_xs
  _promise_is_promise_xs
  _promise_all_xs
  _promise_then_xs
  _promise_resolve_xs
  _promise_reject_xs
  _merge_completed_list_xs
  _merge_hash_xs
  _build_response_xs
  _wrap_error_xs
  _located_error_xs
  _then_resolve_wrapped_error_xs
  _then_reject_located_error_xs
  _then_complete_value_xs
  _then_merge_completed_list_xs
  _then_build_response_xs
  _then_merge_hash_xs
  _then_resolve_operation_error_xs
);

require GraphQL::Houtou::XS::Parser;

sub _promise_all_value_to_scalar {
  my ($value) = @_;
  return $value->[0]
    if ref($value) eq 'ARRAY' && @$value == 1;
  return $value;
}

sub _promise_all_values_to_arrayref {
  if (@_ == 1 && ref($_[0]) eq 'ARRAY') {
    my $values = $_[0];
    return [
      map { _promise_all_value_to_scalar($_) } @$values
    ];
  }

  return [
    map { _promise_all_value_to_scalar($_) } @_
  ];
}

sub execute_xs {
  my (
    $schema,
    $document,
    $root_value,
    $context_value,
    $variable_values,
    $operation_name,
    $field_resolver,
    $promise_code,
  ) = @_;

  return _execute_xs_raw(
    $schema,
    $document,
    $root_value,
    $context_value,
    $variable_values,
    $operation_name,
    $field_resolver,
    normalize_promise_code($promise_code),
  );
}

sub execute_prepared_ir_xs {
  my (
    $schema,
    $handle,
    $root_value,
    $context_value,
    $variable_values,
    $operation_name,
    $field_resolver,
    $promise_code,
  ) = @_;

  my $normalized_promise_code = normalize_promise_code($promise_code);
  my $context = _prepared_executable_ir_execution_context_xs(
    $schema,
    $handle,
    $root_value,
    $context_value,
    $variable_values,
    $operation_name,
    $field_resolver,
    $normalized_promise_code,
  );
  my $seed = _prepared_executable_ir_context_seed_xs(
    $schema,
    $handle,
    $operation_name,
    $variable_values,
  );
  if (!defined $context->{field_resolver}) {
    require GraphQL::Houtou::Execution::PP;
    $context->{field_resolver} = \&GraphQL::Houtou::Execution::PP::_default_field_resolver;
  }
  my $fields = _prepared_executable_ir_root_legacy_fields_xs(
    $schema,
    $handle,
    $operation_name,
  );
  my $result = _execute_fields_xs(
    $context,
    $seed->{root_type},
    $root_value,
    [],
    $fields,
  );

  if ($normalized_promise_code && _promise_is_promise_xs($normalized_promise_code, $result)) {
    return _then_build_response_xs($normalized_promise_code, $result, 0);
  }

  return _build_response_xs($result, 0);
}

sub _then_resolve_wrapped_error_xs {
  my ($promise_code, $promise) = @_;
  return then_promise($promise_code, $promise, undef, sub {
    return resolve_promise($promise_code, _wrap_error_xs($_[0]));
  });
}

sub _then_reject_located_error_xs {
  my ($promise_code, $promise, $nodes, $path) = @_;
  return then_promise($promise_code, $promise, undef, sub {
    return reject_promise($promise_code, _located_error_xs($_[0], $nodes, $path));
  });
}

sub _then_complete_value_xs {
  my ($context, $return_type, $nodes, $info, $path, $promise) = @_;
  return then_promise($context->{promise_code}, $promise, sub {
    return _complete_value_catching_error_xs(
      $context,
      $return_type,
      $nodes,
      $info,
      $path,
      $_[0],
    );
  });
}

sub _then_merge_completed_list_xs {
  my ($promise_code, $promise) = @_;
  return then_promise($promise_code, $promise, sub {
    return _merge_completed_list_xs(_promise_all_values_to_arrayref(@_));
  });
}

sub _then_build_response_xs {
  my ($promise_code, $promise, $force_data) = @_;
  return then_promise($promise_code, $promise, sub {
    return _build_response_xs($_[0], $force_data ? 1 : 0);
  });
}

sub _then_merge_hash_xs {
  my ($promise_code, $keys, $promise, $errors) = @_;
  return then_promise($promise_code, $promise, sub {
    return _merge_hash_xs($keys, _promise_all_values_to_arrayref(@_), $errors);
  });
}

sub _then_resolve_operation_error_xs {
  my ($promise_code, $promise) = @_;
  return then_promise($promise_code, $promise, undef, sub {
    return resolve_promise(
      $promise_code,
      +{ data => undef, %{ _wrap_error_xs($_[0]) } },
    );
  });
}

1;
