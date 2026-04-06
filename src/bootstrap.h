/*
 * Responsibility: shared XS types, IR structs, and forward declarations
 * used across the parser, graphql-js compatibility layer, and legacy
 * compatibility builders.
 */
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"
#include "../lib/GraphQL/ppport.h"

typedef enum {
  TOK_EOF = 0,
  TOK_BANG,
  TOK_DOLLAR,
  TOK_AMP,
  TOK_LPAREN,
  TOK_RPAREN,
  TOK_SPREAD,
  TOK_COLON,
  TOK_EQUALS,
  TOK_AT,
  TOK_LBRACKET,
  TOK_RBRACKET,
  TOK_LBRACE,
  TOK_RBRACE,
  TOK_PIPE,
  TOK_NAME,
  TOK_INT,
  TOK_FLOAT,
  TOK_STRING,
  TOK_BLOCK_STRING
} gql_token_kind_t;

typedef struct gql_ir_arena_chunk {
  char *buf;
  Size_t used;
  Size_t cap;
  struct gql_ir_arena_chunk *next;
} gql_ir_arena_chunk_t;

typedef struct {
  gql_ir_arena_chunk_t *head;
  gql_ir_arena_chunk_t *tail;
} gql_ir_arena_t;

typedef struct {
  const char *src;
  STRLEN len;
  STRLEN pos;
  STRLEN last_pos;
  STRLEN tok_start;
  STRLEN tok_end;
  STRLEN val_start;
  STRLEN val_end;
  gql_token_kind_t kind;
  bool is_utf8;
  bool no_location;
  UV *line_starts;
  I32 num_lines;
  gql_ir_arena_t *ir_arena;
} gql_parser_t;

typedef struct {
  const char *src;
  STRLEN len;
  AV *rewrites;
  UV *line_starts;
  I32 num_lines;
  struct gqljs_rewrite_index *rewrite_index;
  I32 rewrite_index_count;
  UV last_original_pos;
  I32 last_line_index;
  bool has_last_line_index;
  bool lazy_location;
  bool compact_location;
} gqljs_loc_context_t;

typedef struct gqljs_rewrite_index {
  UV original_start;
  IV rewritten_start;
  IV rewritten_end;
  IV delta_after;
} gqljs_rewrite_index_t;

typedef struct {
  I32 count;
  I32 cap;
  void **items;
} gql_ir_ptr_array_t;

typedef struct {
  UV start;
  UV end;
} gql_ir_span_t;

typedef enum {
  GQL_IR_TYPE_NAMED = 0,
  GQL_IR_TYPE_LIST,
  GQL_IR_TYPE_NON_NULL
} gql_ir_type_kind_t;

typedef enum {
  GQL_IR_VALUE_NULL = 0,
  GQL_IR_VALUE_BOOL,
  GQL_IR_VALUE_INT,
  GQL_IR_VALUE_FLOAT,
  GQL_IR_VALUE_STRING,
  GQL_IR_VALUE_ENUM,
  GQL_IR_VALUE_VARIABLE,
  GQL_IR_VALUE_LIST,
  GQL_IR_VALUE_OBJECT
} gql_ir_value_kind_t;

typedef enum {
  GQL_IR_SELECTION_FIELD = 0,
  GQL_IR_SELECTION_FRAGMENT_SPREAD,
  GQL_IR_SELECTION_INLINE_FRAGMENT
} gql_ir_selection_kind_t;

typedef enum {
  GQL_IR_DEFINITION_OPERATION = 0,
  GQL_IR_DEFINITION_FRAGMENT
} gql_ir_definition_kind_t;

typedef enum {
  GQL_IR_OPERATION_QUERY = 0,
  GQL_IR_OPERATION_MUTATION,
  GQL_IR_OPERATION_SUBSCRIPTION
} gql_ir_operation_kind_t;

typedef struct gql_ir_type gql_ir_type_t;
typedef struct gql_ir_value gql_ir_value_t;
typedef struct gql_ir_directive gql_ir_directive_t;
typedef struct gql_ir_argument gql_ir_argument_t;
typedef struct gql_ir_object_field gql_ir_object_field_t;
typedef struct gql_ir_variable_definition gql_ir_variable_definition_t;
typedef struct gql_ir_selection gql_ir_selection_t;
typedef struct gql_ir_selection_set gql_ir_selection_set_t;
typedef struct gql_ir_field gql_ir_field_t;
typedef struct gql_ir_fragment_spread gql_ir_fragment_spread_t;
typedef struct gql_ir_inline_fragment gql_ir_inline_fragment_t;
typedef struct gql_ir_operation_definition gql_ir_operation_definition_t;
typedef struct gql_ir_fragment_definition gql_ir_fragment_definition_t;
typedef struct gql_ir_definition gql_ir_definition_t;
typedef struct gql_ir_document gql_ir_document_t;
typedef struct gql_ir_prepared_exec gql_ir_prepared_exec_t;
typedef struct {
  gql_ir_document_t *document;
} gql_ir_document_cleanup_t;

struct gql_ir_prepared_exec {
  gql_ir_document_t *document;
  SV *source_sv;
};

typedef enum {
  GQLJS_LAZY_ARRAY_ARGUMENTS = 1,
  GQLJS_LAZY_ARRAY_DIRECTIVES = 2,
  GQLJS_LAZY_ARRAY_VARIABLE_DEFINITIONS = 3,
  GQLJS_LAZY_ARRAY_OBJECT_FIELDS = 4
} gqljs_lazy_array_kind_t;

typedef struct {
  gql_ir_document_t *document;
  SV *source_sv;
  gqljs_loc_context_t ctx;
  bool has_ctx;
} gqljs_lazy_state_t;

struct gql_ir_type {
  gql_ir_type_kind_t kind;
  UV start_pos;
  gql_ir_span_t name;
  gql_ir_type_t *inner;
};

struct gql_ir_argument {
  UV start_pos;
  gql_ir_span_t name;
  gql_ir_value_t *value;
};

struct gql_ir_object_field {
  UV start_pos;
  gql_ir_span_t name;
  gql_ir_value_t *value;
};

struct gql_ir_value {
  gql_ir_value_kind_t kind;
  UV start_pos;
  UV name_pos;
  bool is_block_string;
  union {
    int boolean;
    gql_ir_span_t span;
    gql_ir_ptr_array_t list_items;
    gql_ir_ptr_array_t object_fields;
  } as;
};

struct gql_ir_directive {
  UV start_pos;
  UV name_pos;
  gql_ir_span_t name;
  gql_ir_ptr_array_t arguments;
};

struct gql_ir_variable_definition {
  UV start_pos;
  UV name_pos;
  gql_ir_span_t name;
  gql_ir_type_t *type;
  gql_ir_value_t *default_value;
  gql_ir_ptr_array_t directives;
};

struct gql_ir_field {
  UV start_pos;
  UV alias_pos;
  UV name_pos;
  gql_ir_span_t alias;
  gql_ir_span_t name;
  gql_ir_ptr_array_t arguments;
  gql_ir_ptr_array_t directives;
  gql_ir_selection_set_t *selection_set;
};

struct gql_ir_fragment_spread {
  UV start_pos;
  UV name_pos;
  gql_ir_span_t name;
  gql_ir_ptr_array_t directives;
};

struct gql_ir_inline_fragment {
  UV start_pos;
  UV type_condition_pos;
  gql_ir_span_t type_condition;
  gql_ir_ptr_array_t directives;
  gql_ir_selection_set_t *selection_set;
};

struct gql_ir_selection {
  gql_ir_selection_kind_t kind;
  union {
    gql_ir_field_t *field;
    gql_ir_fragment_spread_t *fragment_spread;
    gql_ir_inline_fragment_t *inline_fragment;
  } as;
};

struct gql_ir_selection_set {
  UV start_pos;
  gql_ir_ptr_array_t selections;
};

struct gql_ir_operation_definition {
  gql_ir_operation_kind_t operation;
  UV start_pos;
  UV name_pos;
  gql_ir_span_t name;
  gql_ir_ptr_array_t variable_definitions;
  gql_ir_ptr_array_t directives;
  gql_ir_selection_set_t *selection_set;
};

struct gql_ir_fragment_definition {
  UV start_pos;
  UV name_pos;
  UV type_condition_pos;
  gql_ir_span_t name;
  gql_ir_span_t type_condition;
  gql_ir_ptr_array_t directives;
  gql_ir_selection_set_t *selection_set;
};

struct gql_ir_definition {
  gql_ir_definition_kind_t kind;
  union {
    gql_ir_operation_definition_t *operation;
    gql_ir_fragment_definition_t *fragment;
  } as;
};

struct gql_ir_document {
  gql_ir_ptr_array_t definitions;
  gql_ir_arena_t arena;
  const char *src;
  STRLEN len;
  bool is_utf8;
};

static SV *gql_parse_document(pTHX_ SV *source_sv, SV *no_location_sv);
static void gql_advance(pTHX_ gql_parser_t *p);
static void gql_skip_ignored(gql_parser_t *p);
static void gql_lex_token(pTHX_ gql_parser_t *p);
static void gql_throw(pTHX_ gql_parser_t *p, STRLEN pos, const char *msg);
static void gql_expect(pTHX_ gql_parser_t *p, gql_token_kind_t kind, const char *msg);
static int gql_peek_name(gql_parser_t *p, const char *name);
static SV *gql_parse_definition(pTHX_ gql_parser_t *p);
static SV *gql_parse_type_system_definition(pTHX_ gql_parser_t *p, SV *description);
static AV *gql_parse_definitions(pTHX_ gql_parser_t *p);
static SV *gql_parse_operation_definition(pTHX_ gql_parser_t *p);
static SV *gql_parse_fragment_definition(pTHX_ gql_parser_t *p);
static SV *gql_parse_selection_set(pTHX_ gql_parser_t *p);
static SV *gql_parse_selection(pTHX_ gql_parser_t *p);
static SV *gql_parse_field(pTHX_ gql_parser_t *p);
static SV *gql_parse_arguments(pTHX_ gql_parser_t *p, int is_const);
static SV *gql_parse_value(pTHX_ gql_parser_t *p, int is_const);
static SV *gql_parse_object_value(pTHX_ gql_parser_t *p, int is_const);
static SV *gql_parse_list_value(pTHX_ gql_parser_t *p, int is_const);
static SV *gql_parse_directives(pTHX_ gql_parser_t *p);
static SV *gql_parse_directive(pTHX_ gql_parser_t *p);
static SV *gql_parse_variable_definitions(pTHX_ gql_parser_t *p);
static SV *gql_parse_type_reference(pTHX_ gql_parser_t *p);
static SV *gql_parse_schema_definition(pTHX_ gql_parser_t *p);
static SV *gql_parse_schema_definition_extended(pTHX_ gql_parser_t *p, int allow_empty_body);
static SV *gql_parse_scalar_type_definition(pTHX_ gql_parser_t *p);
static SV *gql_parse_object_type_definition(pTHX_ gql_parser_t *p, const char *kind);
static SV *gql_parse_union_type_definition(pTHX_ gql_parser_t *p);
static SV *gql_parse_enum_type_definition(pTHX_ gql_parser_t *p);
static SV *gql_parse_directive_definition(pTHX_ gql_parser_t *p);
static SV *gql_parse_input_value_definition(pTHX_ gql_parser_t *p);
static SV *gql_parse_field_definition(pTHX_ gql_parser_t *p);
static SV *gql_parse_arguments_definition(pTHX_ gql_parser_t *p);
static SV *gql_parse_description(pTHX_ gql_parser_t *p);
static SV *gql_copy_token_sv(pTHX_ gql_parser_t *p);
static SV *gql_copy_value_sv(pTHX_ gql_parser_t *p);
static SV *gql_unescape_string_sv(pTHX_ SV *raw);
static int gql_hex4_to_uv(const char *src, UV *value);
static SV *gql_make_string_sv(pTHX_ gql_parser_t *p, STRLEN start, STRLEN end);
static SV *gql_make_location(pTHX_ gql_parser_t *p);
static SV *gql_make_current_location(pTHX_ gql_parser_t *p);
static SV *gql_make_endline_location(pTHX_ gql_parser_t *p);
static SV *gql_make_current_or_endline_location(pTHX_ gql_parser_t *p);
static void gql_parser_init(pTHX_ gql_parser_t *p, SV *source_sv, int no_location);
static void gql_parser_invalidate(gql_parser_t *p);
static void gql_store_location(pTHX_ gql_parser_t *p, HV *hv);
static void gql_store_current_location(pTHX_ gql_parser_t *p, HV *hv);
static void gql_store_endline_location(pTHX_ gql_parser_t *p, HV *hv);
static void gql_store_current_or_endline_location(pTHX_ gql_parser_t *p, HV *hv);
static void gql_store_sv(HV *hv, const char *key, SV *value);
static SV *gql_make_type_wrapper(pTHX_ SV *type_sv, const char *kind);
static SV *gql_parse_name(pTHX_ gql_parser_t *p, const char *msg);
static SV *gql_parse_fragment_name(pTHX_ gql_parser_t *p);
static gql_ir_span_t gql_ir_parse_name_span(pTHX_ gql_parser_t *p, const char *msg);
static gql_ir_span_t gql_ir_parse_fragment_name_span(pTHX_ gql_parser_t *p);
static void gql_line_column_from_last(gql_parser_t *p, IV *line, IV *column);
static void gql_line_column_from_pos(gql_parser_t *p, STRLEN pos, IV *line, IV *column, int one_based);
static void gql_throw_sv(pTHX_ gql_parser_t *p, STRLEN pos, SV *msg);
static const char *gql_expected_token_label(gql_token_kind_t kind);
static SV *gql_current_token_desc_sv(pTHX_ gql_parser_t *p);
static void gql_throw_expected_message(pTHX_ gql_parser_t *p, STRLEN pos, const char *msg);
static void gql_throw_expected_token(pTHX_ gql_parser_t *p, gql_token_kind_t kind);
static void gql_throw_unexpected_character(pTHX_ gql_parser_t *p, STRLEN pos, unsigned char c);
static int gqljs_is_name_start(char c);
static int gqljs_is_name_continue(char c);
static void gqljs_skip_ignored_raw(const char *src, STRLEN len, STRLEN *pos);
static void gqljs_skip_quoted_string_raw(const char *src, STRLEN len, STRLEN *pos);
static void gqljs_skip_delimited_raw(const char *src, STRLEN len, STRLEN *pos, char open, char close);
static int gqljs_read_name_bounds(const char *src, STRLEN len, STRLEN *pos, STRLEN *start, STRLEN *end);
static SV *gqljs_make_string_sv(pTHX_ const char *src, STRLEN start, STRLEN end, int is_utf8);
static int gqljs_match_word(const char *src, STRLEN start, STRLEN end, const char *word);
static void gqljs_push_rewrite(pTHX_ AV *rewrites, UV start, UV end, const char *replacement);
static UV gqljs_bump_occurrence(pTHX_ HV *counts, const char *kind, SV *name_sv);
static void gqljs_push_extension(pTHX_ AV *extensions, const char *kind, SV *name_sv, UV occurrence);
static void gqljs_store_hash_key_sv(HV *hv, SV *key_sv, SV *value);
static SV *gqljs_apply_rewrites_sv(pTHX_ SV *source_sv, AV *rewrites);
static SV *gqljs_skip_directive_raw(pTHX_ const char *src, STRLEN len, STRLEN *pos, int is_utf8);
static void gqljs_scan_variable_definition_directives(pTHX_ const char *src, STRLEN len, STRLEN *pos, int is_utf8, HV *operation_meta, AV *rewrites);
static SV *gql_graphqljs_preprocess(pTHX_ SV *source_sv);
static SV *gql_parse_directives_only(pTHX_ SV *source_sv);
static SV *gql_tokenize_source(pTHX_ SV *source_sv);
static SV *gql_graphqlperl_find_legacy_empty_object_location(pTHX_ SV *source_sv);
static SV *gql_graphqljs_build_directives_from_source(pTHX_ SV *source_sv);
static int gql_graphqljs_looks_like_executable_source(pTHX_ SV *source_sv);
static int gqljs_legacy_document_is_executable(SV *legacy_sv);
static void gqljs_materialize_operation_variable_directives(pTHX_ HV *meta_hv);
static SV *gql_graphqljs_build_document(pTHX_ SV *legacy_sv);
static SV *gql_graphqljs_parse_document(pTHX_ SV *source_sv, SV *no_location_sv, SV *lazy_location_sv, SV *compact_location_sv);
static SV *gql_graphqljs_parse_executable_document(pTHX_ SV *source_sv, SV *no_location_sv, SV *lazy_location_sv, SV *compact_location_sv);
static void gql_ir_arena_init(gql_ir_arena_t *arena);
static void *gql_ir_arena_alloc_zero(gql_ir_arena_t *arena, Size_t size);
static void gql_ir_arena_free(gql_ir_arena_t *arena);
static void gql_ir_ptr_array_push(gql_ir_ptr_array_t *array, void *item);
static void gql_ir_ptr_array_free(gql_ir_ptr_array_t *array);
static gql_ir_type_t *gql_ir_parse_type_reference(pTHX_ gql_parser_t *p);
static gql_ir_value_t *gql_ir_parse_value(pTHX_ gql_parser_t *p, int is_const);
static gql_ir_ptr_array_t gql_ir_parse_arguments(pTHX_ gql_parser_t *p, int is_const);
static gql_ir_ptr_array_t gql_ir_parse_directives(pTHX_ gql_parser_t *p);
static gql_ir_selection_set_t *gql_ir_parse_selection_set(pTHX_ gql_parser_t *p);
static gql_ir_selection_t *gql_ir_parse_selection(pTHX_ gql_parser_t *p);
static gql_ir_ptr_array_t gql_ir_parse_variable_definitions(pTHX_ gql_parser_t *p);
static gql_ir_operation_definition_t *gql_ir_parse_operation_definition(pTHX_ gql_parser_t *p);
static gql_ir_fragment_definition_t *gql_ir_parse_fragment_definition(pTHX_ gql_parser_t *p);
static gql_ir_definition_t *gql_ir_parse_executable_definition(pTHX_ gql_parser_t *p);
static gql_ir_document_t *gql_ir_parse_executable_document(pTHX_ SV *source_sv);
static SV *gql_ir_prepare_executable_handle_sv(pTHX_ SV *source_sv);
static HV *gql_ir_prepare_executable_stats_hv(pTHX_ gql_ir_prepared_exec_t *prepared);
static HV *gql_ir_prepare_executable_plan_hv(pTHX_ gql_ir_prepared_exec_t *prepared, SV *operation_name);
static void gql_ir_cleanup_document(pTHX_ void *ptr);
static void gql_ir_free_type(gql_ir_type_t *type);
static void gql_ir_free_value(gql_ir_value_t *value);
static void gql_ir_free_directive(gql_ir_directive_t *directive);
static void gql_ir_free_argument(gql_ir_argument_t *argument);
static void gql_ir_free_object_field(gql_ir_object_field_t *field);
static void gql_ir_free_variable_definition(gql_ir_variable_definition_t *definition);
static void gql_ir_free_selection(gql_ir_selection_t *selection);
static void gql_ir_free_selection_set(gql_ir_selection_set_t *selection_set);
static void gql_ir_free_operation_definition(gql_ir_operation_definition_t *definition);
static void gql_ir_free_fragment_definition(gql_ir_fragment_definition_t *definition);
static void gql_ir_free_definition(gql_ir_definition_t *definition);
static void gql_ir_free_document(gql_ir_document_t *document);
static void gql_ir_prepared_exec_destroy(gql_ir_prepared_exec_t *prepared);
static void gqljs_loc_context_init(pTHX_ gqljs_loc_context_t *ctx, SV *source_sv, AV *rewrites);
static void gqljs_loc_context_destroy(gqljs_loc_context_t *ctx);
static UV gqljs_original_pos_from_rewritten_pos(gqljs_loc_context_t *ctx, UV rewritten_pos);
static SV *gqljs_new_loc_sv(pTHX_ IV line, IV column);
static SV *gqljs_new_lazy_loc_sv(pTHX_ UV start);
static SV *gqljs_new_lazy_state_sv(pTHX_ gql_ir_document_t *document, SV *source_sv, int with_locations, SV *lazy_location_sv, SV *compact_location_sv);
static gqljs_lazy_state_t *gqljs_lazy_state_from_sv(SV *state_sv);
static void gqljs_lazy_state_destroy(gqljs_lazy_state_t *state);
static void gqljs_attach_magic_state(pTHX_ SV *sv, SV *state_sv);
static SV *gqljs_new_lazy_arguments_sv(pTHX_ SV *state_sv, gql_ir_ptr_array_t *arguments);
static SV *gqljs_new_lazy_directives_sv(pTHX_ SV *state_sv, gql_ir_ptr_array_t *directives);
static SV *gqljs_new_lazy_variable_definitions_sv(pTHX_ SV *state_sv, gql_ir_ptr_array_t *definitions);
static SV *gqljs_new_lazy_object_fields_sv(pTHX_ SV *state_sv, gql_ir_ptr_array_t *fields);
static AV *gqljs_materialize_lazy_array(pTHX_ SV *state_sv, UV ptr, IV kind);
static SV *gqljs_loc_from_rewritten_pos(pTHX_ gqljs_loc_context_t *ctx, UV rewritten_pos);
static SV *gql_ir_make_sv_from_span(pTHX_ gql_ir_document_t *document, gql_ir_span_t span);
static SV *gql_ir_make_string_value_sv(pTHX_ gql_ir_document_t *document, gql_ir_value_t *value);
static SV *gqljs_build_type_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document, gql_ir_type_t *type);
static AV *gqljs_build_object_fields_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document, gql_ir_ptr_array_t *fields, SV *state_sv);
static SV *gqljs_build_value_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document, gql_ir_value_t *value, SV *state_sv);
static AV *gqljs_build_arguments_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document, gql_ir_ptr_array_t *arguments, SV *state_sv);
static AV *gqljs_build_directives_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document, gql_ir_ptr_array_t *directives, SV *state_sv);
static SV *gqljs_build_selection_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document, gql_ir_selection_t *selection, SV *state_sv);
static SV *gqljs_build_selection_set_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document, gql_ir_selection_set_t *selection_set, SV *state_sv);
static AV *gqljs_build_variable_definitions_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document, gql_ir_ptr_array_t *definitions, SV *state_sv);
static SV *gqljs_build_executable_definition_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document, gql_ir_definition_t *definition, SV *state_sv);
static SV *gqljs_build_executable_document_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document, SV *state_sv);
static SV *gqljs_clone_with_loc(pTHX_ SV *value, SV *loc_sv);
static int gqljs_sv_eq_pv(SV *sv, const char *literal);
static const char *gqljs_definition_source_kind(SV *kind_sv);
static const char *gqljs_extension_kind_name(const char *source_kind);
static SV *gql_graphqljs_patch_document(pTHX_ SV *doc_sv, SV *meta_sv);
static SV *gql_graphqljs_apply_executable_loc(pTHX_ SV *doc_sv, SV *source_sv);
static void gqljs_set_loc_node(pTHX_ SV *node_sv, SV *loc_sv);
static void gqljs_set_rewritten_loc_node(pTHX_ gqljs_loc_context_t *ctx, SV *node_sv, UV rewritten_pos);
static void gqljs_set_shared_rewritten_loc_nodes(pTHX_ gqljs_loc_context_t *ctx, UV rewritten_pos, SV *left_sv, SV *right_sv);
static HV *gqljs_node_hv(SV *node_sv);
static SV *gqljs_fetch_sv(HV *hv, const char *key);
static AV *gqljs_fetch_array(HV *hv, const char *key);
static const char *gqljs_fetch_kind(HV *hv);
static const char *gqljs_name_value(SV *node_sv);
static SV *gqljs_find_named_node(AV *av, const char *name);
static SV *gqljs_find_named_node_sv(AV *av, SV *name_sv);
static SV *gqljs_find_variable_definition(AV *av, const char *name);
static SV *gqljs_find_variable_definition_sv(AV *av, SV *name_sv);
static SV *gqljs_locate_name_node(pTHX_ gql_parser_t *p, SV *node_sv);
static SV *gqljs_locate_type_node(pTHX_ gql_parser_t *p, SV *node_sv);
static SV *gqljs_locate_value_node(pTHX_ gql_parser_t *p, SV *node_sv);
static void gqljs_locate_arguments_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_directives_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_variable_definitions_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_input_value_definitions_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_arguments_definition_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_field_definitions_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_enum_values_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_operation_types_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_interfaces_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_union_types_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_directive_locations_nodes(pTHX_ gql_parser_t *p, AV *av);
static SV *gqljs_locate_selection_set_node(pTHX_ gql_parser_t *p, SV *node_sv);
static void gqljs_locate_selection_node(pTHX_ gql_parser_t *p, SV *node_sv);
static int gqljs_locate_definition(pTHX_ gql_parser_t *p, SV *node_sv);
static SV *gql_graphqljs_build_executable_document(pTHX_ SV *legacy_sv);
static SV *gql_graphqlperl_build_document(pTHX_ SV *doc_sv);
static HV *gqljs_new_node_hv_sized(const char *kind, I32 keys);
static HV *gqljs_new_node_hv(const char *kind);
static SV *gqljs_new_node_ref(const char *kind);
static SV *gqljs_new_name_node_sv(pTHX_ SV *value_sv);
static SV *gqljs_new_named_type_node_sv(pTHX_ SV *value_sv);
static SV *gqljs_new_variable_node_sv(pTHX_ SV *value_sv);
static SV *gqljs_new_description_node_sv(pTHX_ SV *value_sv);
static SV *gqljs_convert_legacy_type_sv(pTHX_ SV *type_sv);
static SV *gqljs_convert_legacy_value_sv(pTHX_ SV *value_sv);
static AV *gqljs_convert_legacy_arguments_hv(pTHX_ HV *hv);
static AV *gqljs_convert_legacy_directives_av(pTHX_ AV *av);
static SV *gqljs_convert_legacy_selection_sv(pTHX_ SV *selection_sv);
static SV *gqljs_convert_legacy_selection_set_av(pTHX_ AV *av);
static AV *gqljs_convert_legacy_variable_definitions_hv(pTHX_ HV *hv);
static AV *gqljs_convert_legacy_named_types_av(pTHX_ AV *av);
static AV *gqljs_convert_legacy_name_nodes_av(pTHX_ AV *av);
static AV *gqljs_convert_legacy_input_value_definitions_hv(pTHX_ HV *hv);
static AV *gqljs_convert_legacy_field_definitions_hv(pTHX_ HV *hv);
static AV *gqljs_convert_legacy_enum_values_hv(pTHX_ HV *hv);
static SV *gqljs_convert_legacy_executable_definition_sv(pTHX_ SV *definition_sv);
static SV *gqljs_convert_legacy_definition_sv(pTHX_ SV *definition_sv);
static int gqljs_cmp_sv_ptrs(const void *a, const void *b);
static SV **gqljs_sorted_hash_keys(pTHX_ HV *hv, I32 *count_out);
static void gqljs_free_sorted_hash_keys(SV **keys, I32 count);
static SV *gqlperl_location_from_gqljs_node(pTHX_ SV *node_sv);
static void gqlperl_store_location_from_gqljs_node(pTHX_ HV *dst_hv, SV *node_sv);
static SV *gqlperl_convert_type_from_gqljs(pTHX_ SV *node_sv);
static SV *gqlperl_convert_value_from_gqljs(pTHX_ SV *node_sv);
static SV *gqlperl_convert_arguments_from_gqljs(pTHX_ AV *av);
static SV *gqlperl_convert_directives_from_gqljs(pTHX_ AV *av);
static SV *gqlperl_convert_selection_from_gqljs(pTHX_ SV *node_sv);
static AV *gqlperl_convert_selections_from_gqljs(pTHX_ AV *av);
static SV *gqlperl_convert_variable_definitions_from_gqljs(pTHX_ AV *av);
static SV *gqlperl_convert_named_types_from_gqljs(pTHX_ AV *av);
static SV *gqlperl_convert_input_value_definitions_from_gqljs(pTHX_ AV *av);
static SV *gqlperl_convert_field_definitions_from_gqljs(pTHX_ AV *av);
static SV *gqlperl_convert_enum_values_from_gqljs(pTHX_ AV *av);
static SV *gqlperl_convert_executable_definition_from_gqljs(pTHX_ SV *node_sv);
static SV *gqlperl_convert_definition_from_gqljs(pTHX_ SV *node_sv);
