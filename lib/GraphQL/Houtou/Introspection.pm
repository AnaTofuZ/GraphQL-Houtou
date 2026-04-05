package GraphQL::Houtou::Introspection;

use 5.014;
use strict;
use warnings;

use Exporter 'import';

require GraphQL::Introspection;

our @EXPORT_OK = qw(
  $QUERY
  $TYPE_KIND_META_TYPE
  $DIRECTIVE_LOCATION_META_TYPE
  $ENUM_VALUE_META_TYPE
  $INPUT_VALUE_META_TYPE
  $FIELD_META_TYPE
  $DIRECTIVE_META_TYPE
  $TYPE_META_TYPE
  $SCHEMA_META_TYPE
  $SCHEMA_META_FIELD_DEF
  $TYPE_META_FIELD_DEF
  $TYPE_NAME_META_FIELD_DEF
);

# Responsibility: provide a Houtou-owned introspection namespace while the
# actual introspection implementation is still shared with upstream.

our $QUERY = $GraphQL::Introspection::QUERY;
our $TYPE_KIND_META_TYPE = $GraphQL::Introspection::TYPE_KIND_META_TYPE;
our $DIRECTIVE_LOCATION_META_TYPE = $GraphQL::Introspection::DIRECTIVE_LOCATION_META_TYPE;
our $ENUM_VALUE_META_TYPE = $GraphQL::Introspection::ENUM_VALUE_META_TYPE;
our $INPUT_VALUE_META_TYPE = $GraphQL::Introspection::INPUT_VALUE_META_TYPE;
our $FIELD_META_TYPE = $GraphQL::Introspection::FIELD_META_TYPE;
our $DIRECTIVE_META_TYPE = $GraphQL::Introspection::DIRECTIVE_META_TYPE;
our $TYPE_META_TYPE = $GraphQL::Introspection::TYPE_META_TYPE;
our $SCHEMA_META_TYPE = $GraphQL::Introspection::SCHEMA_META_TYPE;
our $SCHEMA_META_FIELD_DEF = $GraphQL::Introspection::SCHEMA_META_FIELD_DEF;
our $TYPE_META_FIELD_DEF = $GraphQL::Introspection::TYPE_META_FIELD_DEF;
our $TYPE_NAME_META_FIELD_DEF = $GraphQL::Introspection::TYPE_NAME_META_FIELD_DEF;

1;

__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou::Introspection - Houtou introspection namespace

=head1 DESCRIPTION

This module gives Houtou its own introspection entrypoint and export
surface. It currently re-exports the upstream introspection objects so the
rest of Houtou can stop depending on the upstream package name directly.

=cut
