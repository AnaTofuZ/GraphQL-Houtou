package GraphQL::Houtou::XS::Execution;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou::Promise::Adapter qw(normalize_promise_code);

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  execute_xs
  _collect_fields_xs
  _execute_fields_xs
  _get_argument_values_xs
  _complete_value_catching_error_xs
);

require GraphQL::Houtou::XS::Parser;

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

1;
