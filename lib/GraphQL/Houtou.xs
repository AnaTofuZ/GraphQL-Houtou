#include "houtou_xs/bootstrap.h"
#include "houtou_xs/parser_core.h"
#include "houtou_xs/graphqljs_runtime.h"
#include "houtou_xs/graphqljs_convert.h"
#include "houtou_xs/schema_compiler.h"
#include "houtou_xs/validation.h"
#include "houtou_xs/execution.h"
#include "houtou_xs/ir_engine.h"
#include "houtou_xs/legacy_compat.h"

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Parser

SV *
parse_xs(source, no_location = &PL_sv_undef)
    SV *source
    SV *no_location
  CODE:
    RETVAL = gql_parse_document(aTHX_ source, no_location);
  OUTPUT:
    RETVAL

SV *
graphqljs_preprocess_xs(source)
    SV *source
  CODE:
    RETVAL = gql_graphqljs_preprocess(aTHX_ source);
  OUTPUT:
    RETVAL

SV *
graphqljs_parse_document_xs(source, no_location = &PL_sv_undef, lazy_location = &PL_sv_undef, compact_location = &PL_sv_undef)
    SV *source
    SV *no_location
    SV *lazy_location
    SV *compact_location
  CODE:
    RETVAL = gql_graphqljs_parse_document(aTHX_ source, no_location, lazy_location, compact_location);
  OUTPUT:
    RETVAL

SV *
graphqljs_parse_executable_document_xs(source, no_location = &PL_sv_undef, lazy_location = &PL_sv_undef, compact_location = &PL_sv_undef)
    SV *source
    SV *no_location
    SV *lazy_location
    SV *compact_location
  CODE:
    RETVAL = gql_graphqljs_parse_executable_document(aTHX_ source, no_location, lazy_location, compact_location);
  OUTPUT:
    RETVAL

SV *
_graphqljs_materialize_arguments_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gqljs_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_ARGUMENTS
      ));
    }
  OUTPUT:
    RETVAL

SV *
_graphqljs_materialize_directives_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gqljs_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_DIRECTIVES
      ));
    }
  OUTPUT:
    RETVAL

SV *
_graphqljs_materialize_variable_definitions_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gqljs_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_VARIABLE_DEFINITIONS
      ));
    }
  OUTPUT:
    RETVAL

SV *
_graphqljs_materialize_object_fields_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gqljs_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_OBJECT_FIELDS
      ));
    }
  OUTPUT:
    RETVAL

SV *
parse_directives_xs(source)
    SV *source
  CODE:
    RETVAL = gql_parse_directives_only(aTHX_ source);
  OUTPUT:
    RETVAL

SV *
graphqljs_build_directives_xs(source)
    SV *source
  CODE:
    RETVAL = gql_graphqljs_build_directives_from_source(aTHX_ source);
  OUTPUT:
    RETVAL

SV *
tokenize_xs(source)
    SV *source
  CODE:
    RETVAL = gql_tokenize_source(aTHX_ source);
  OUTPUT:
    RETVAL

SV *
graphqlperl_find_legacy_empty_object_location_xs(source)
    SV *source
  CODE:
    RETVAL = gql_graphqlperl_find_legacy_empty_object_location(aTHX_ source);
  OUTPUT:
    RETVAL

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::LazyState

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gqljs_lazy_state_t *state = INT2PTR(gqljs_lazy_state_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gqljs_lazy_state_destroy(state);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Parser

SV *
graphqljs_patch_document_xs(doc, meta)
    SV *doc
    SV *meta
  CODE:
    RETVAL = gql_graphqljs_patch_document(aTHX_ doc, meta);
  OUTPUT:
    RETVAL

SV *
graphqljs_build_executable_document_xs(legacy)
    SV *legacy
  CODE:
    RETVAL = gql_graphqljs_build_executable_document(aTHX_ legacy);
  OUTPUT:
    RETVAL

SV *
graphqljs_build_document_xs(legacy)
    SV *legacy
  CODE:
    RETVAL = gql_graphqljs_build_document(aTHX_ legacy);
  OUTPUT:
    RETVAL

SV *
graphqlperl_build_document_xs(doc)
    SV *doc
  CODE:
    RETVAL = gql_graphqlperl_build_document(aTHX_ doc);
  OUTPUT:
    RETVAL

SV *
graphqljs_apply_executable_loc_xs(doc, source)
    SV *doc
    SV *source
  CODE:
    RETVAL = gql_graphqljs_apply_executable_loc(aTHX_ doc, source);
  OUTPUT:
    RETVAL

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::SchemaCompiler

SV *
compile_schema_xs(schema)
    SV *schema
  CODE:
    RETVAL = gql_schema_compile_schema(aTHX_ schema);
  OUTPUT:
    RETVAL

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Validation

SV *
validate_xs(schema, document, options = NULL)
    SV *schema
    SV *document
    SV *options
  CODE:
    RETVAL = gql_validation_validate(aTHX_ schema, document, options);
  OUTPUT:
    RETVAL

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Execution

SV *
execute_xs(schema, document, root_value = NULL, context_value = NULL, variable_values = NULL, operation_name = NULL, field_resolver = NULL, promise_code = NULL)
    SV *schema
    SV *document
    SV *root_value
    SV *context_value
    SV *variable_values
    SV *operation_name
    SV *field_resolver
    SV *promise_code
  CODE:
    RETVAL = gql_execution_execute(
      aTHX_ schema,
      document,
      root_value,
      context_value,
      variable_values,
      operation_name,
      field_resolver,
      promise_code
    );
  OUTPUT:
    RETVAL

SV *
_execute_fields_xs(context, parent_type, root_value, path, fields)
    SV *context
    SV *parent_type
    SV *root_value
    SV *path
    SV *fields
  CODE:
    RETVAL = gql_execution_execute_fields(aTHX_ context, parent_type, root_value, path, fields);
  OUTPUT:
    RETVAL
