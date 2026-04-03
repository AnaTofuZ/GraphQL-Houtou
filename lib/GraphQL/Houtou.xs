#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

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
  gql_ir_arena_t *ir_arena;
} gql_parser_t;

typedef struct {
  const char *src;
  STRLEN len;
  AV *rewrites;
  UV *line_starts;
  I32 num_lines;
  SV **loc_cache;
  UV loc_cache_len;
  struct gqljs_rewrite_index *rewrite_index;
  I32 rewrite_index_count;
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

struct gql_ir_type {
  gql_ir_type_kind_t kind;
  UV start_pos;
  SV *name;
  gql_ir_type_t *inner;
};

struct gql_ir_argument {
  UV start_pos;
  SV *name;
  gql_ir_value_t *value;
};

struct gql_ir_object_field {
  UV start_pos;
  SV *name;
  gql_ir_value_t *value;
};

struct gql_ir_value {
  gql_ir_value_kind_t kind;
  UV start_pos;
  UV name_pos;
  union {
    int boolean;
    SV *sv;
    gql_ir_ptr_array_t list_items;
    gql_ir_ptr_array_t object_fields;
  } as;
};

struct gql_ir_directive {
  UV start_pos;
  UV name_pos;
  SV *name;
  gql_ir_ptr_array_t arguments;
};

struct gql_ir_variable_definition {
  UV start_pos;
  UV name_pos;
  SV *name;
  gql_ir_type_t *type;
  gql_ir_value_t *default_value;
  gql_ir_ptr_array_t directives;
};

struct gql_ir_field {
  UV start_pos;
  UV alias_pos;
  UV name_pos;
  SV *alias;
  SV *name;
  gql_ir_ptr_array_t arguments;
  gql_ir_ptr_array_t directives;
  gql_ir_selection_set_t *selection_set;
};

struct gql_ir_fragment_spread {
  UV start_pos;
  UV name_pos;
  SV *name;
  gql_ir_ptr_array_t directives;
};

struct gql_ir_inline_fragment {
  UV start_pos;
  UV type_condition_pos;
  SV *type_condition;
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
  SV *name;
  gql_ir_ptr_array_t variable_definitions;
  gql_ir_ptr_array_t directives;
  gql_ir_selection_set_t *selection_set;
};

struct gql_ir_fragment_definition {
  UV start_pos;
  UV name_pos;
  UV type_condition_pos;
  SV *name;
  SV *type_condition;
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
};

static SV *gql_parse_document(pTHX_ SV *source_sv);
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
static SV *gql_make_string_sv(pTHX_ gql_parser_t *p, STRLEN start, STRLEN end);
static SV *gql_make_location(pTHX_ gql_parser_t *p);
static SV *gql_make_current_location(pTHX_ gql_parser_t *p);
static SV *gql_make_endline_location(pTHX_ gql_parser_t *p);
static SV *gql_make_current_or_endline_location(pTHX_ gql_parser_t *p);
static void gql_store_location(pTHX_ gql_parser_t *p, HV *hv);
static void gql_store_current_location(pTHX_ gql_parser_t *p, HV *hv);
static void gql_store_endline_location(pTHX_ gql_parser_t *p, HV *hv);
static void gql_store_current_or_endline_location(pTHX_ gql_parser_t *p, HV *hv);
static void gql_store_sv(HV *hv, const char *key, SV *value);
static SV *gql_make_type_wrapper(pTHX_ SV *type_sv, const char *kind);
static SV *gql_parse_name(pTHX_ gql_parser_t *p, const char *msg);
static SV *gql_parse_fragment_name(pTHX_ gql_parser_t *p);
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
static SV *gql_graphqljs_parse_document(pTHX_ SV *source_sv, SV *no_location_sv);
static SV *gql_graphqljs_parse_executable_document(pTHX_ SV *source_sv, SV *no_location_sv);
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
static void gqljs_loc_context_init(pTHX_ gqljs_loc_context_t *ctx, SV *source_sv, AV *rewrites);
static void gqljs_loc_context_destroy(gqljs_loc_context_t *ctx);
static SV *gqljs_new_loc_sv(pTHX_ IV line, IV column);
static SV *gqljs_loc_from_rewritten_pos(pTHX_ gqljs_loc_context_t *ctx, UV rewritten_pos);
static SV *gqljs_build_type_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_type_t *type);
static SV *gqljs_build_value_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_value_t *value);
static AV *gqljs_build_arguments_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_ptr_array_t *arguments);
static AV *gqljs_build_directives_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_ptr_array_t *directives);
static SV *gqljs_build_selection_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_selection_t *selection);
static SV *gqljs_build_selection_set_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_selection_set_t *selection_set);
static AV *gqljs_build_variable_definitions_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_ptr_array_t *definitions);
static SV *gqljs_build_executable_definition_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_definition_t *definition);
static SV *gqljs_build_executable_document_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document);
static SV *gqljs_clone_with_loc(pTHX_ SV *value, SV *loc_sv);
static int gqljs_sv_eq_pv(SV *sv, const char *literal);
static const char *gqljs_definition_source_kind(SV *kind_sv);
static const char *gqljs_extension_kind_name(const char *source_kind);
static SV *gql_graphqljs_patch_document(pTHX_ SV *doc_sv, SV *meta_sv);
static SV *gql_graphqljs_apply_executable_loc(pTHX_ SV *doc_sv, SV *source_sv);
static void gqljs_set_loc_node(pTHX_ SV *node_sv, SV *loc_sv);
static void gqljs_set_rewritten_loc_node(pTHX_ gqljs_loc_context_t *ctx, SV *node_sv, UV rewritten_pos);
static HV *gqljs_node_hv(SV *node_sv);
static SV *gqljs_fetch_sv(HV *hv, const char *key);
static AV *gqljs_fetch_array(HV *hv, const char *key);
static const char *gqljs_fetch_kind(HV *hv);
static const char *gqljs_name_value(SV *node_sv);
static SV *gqljs_find_named_node(AV *av, const char *name);
static SV *gqljs_find_variable_definition(AV *av, const char *name);
static SV *gqljs_locate_name_node(pTHX_ gql_parser_t *p, SV *node_sv);
static SV *gqljs_locate_type_node(pTHX_ gql_parser_t *p, SV *node_sv);
static SV *gqljs_locate_value_node(pTHX_ gql_parser_t *p, SV *node_sv);
static void gqljs_locate_arguments_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_directives_nodes(pTHX_ gql_parser_t *p, AV *av);
static void gqljs_locate_variable_definitions_nodes(pTHX_ gql_parser_t *p, AV *av);
static SV *gqljs_locate_selection_set_node(pTHX_ gql_parser_t *p, SV *node_sv);
static void gqljs_locate_selection_node(pTHX_ gql_parser_t *p, SV *node_sv);
static int gqljs_locate_executable_definition(pTHX_ gql_parser_t *p, SV *node_sv);
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

static void
gql_store_sv(HV *hv, const char *key, SV *value) {
  hv_store(hv, key, (I32)strlen(key), value, 0);
}

static SV *
gql_make_string_sv(pTHX_ gql_parser_t *p, STRLEN start, STRLEN end) {
  SV *sv = newSVpvn(p->src + start, end - start);
  if (p->is_utf8) {
    SvUTF8_on(sv);
  }
  return sv;
}

static SV *
gql_copy_token_sv(pTHX_ gql_parser_t *p) {
  return gql_make_string_sv(aTHX_ p, p->tok_start, p->tok_end);
}

static const char *
gql_token_kind_name(gql_token_kind_t kind) {
  switch (kind) {
    case TOK_EOF: return "EOF";
    case TOK_BANG: return "BANG";
    case TOK_DOLLAR: return "DOLLAR";
    case TOK_AMP: return "AMP";
    case TOK_LPAREN: return "LPAREN";
    case TOK_RPAREN: return "RPAREN";
    case TOK_SPREAD: return "SPREAD";
    case TOK_COLON: return "COLON";
    case TOK_EQUALS: return "EQUALS";
    case TOK_AT: return "AT";
    case TOK_LBRACKET: return "LBRACKET";
    case TOK_RBRACKET: return "RBRACKET";
    case TOK_LBRACE: return "LBRACE";
    case TOK_RBRACE: return "RBRACE";
    case TOK_PIPE: return "PIPE";
    case TOK_NAME: return "NAME";
    case TOK_INT: return "INT";
    case TOK_FLOAT: return "FLOAT";
    case TOK_STRING: return "STRING";
    case TOK_BLOCK_STRING: return "BLOCK_STRING";
  }
  return "UNKNOWN";
}

static SV *
gql_call_helper1(pTHX_ const char *subname, SV *arg) {
  dSP;
  int count;
  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(arg);
  PUTBACK;
  count = call_pv(subname, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("Helper %s did not return a scalar", subname);
  }
  SV *ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_copy_value_sv(pTHX_ gql_parser_t *p) {
  SV *raw = gql_make_string_sv(aTHX_ p, p->val_start, p->val_end);
  if (p->kind == TOK_BLOCK_STRING) {
    return gql_call_helper1(aTHX_ "GraphQL::Houtou::XS::Parser::_block_string_value", raw);
  }
  return gql_call_helper1(aTHX_ "GraphQL::Houtou::XS::Parser::_string_value", raw);
}

static void
gql_throw(pTHX_ gql_parser_t *p, STRLEN pos, const char *msg) {
  gql_throw_sv(aTHX_ p, pos, newSVpv(msg, 0));
}

static void
gql_throw_sv(pTHX_ gql_parser_t *p, STRLEN pos, SV *msg) {
  dSP;
  SV *source = gql_make_string_sv(aTHX_ p, 0, p->len);
  SV *err;
  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(source);
  XPUSHs(sv_2mortal(newSVuv((UV)pos)));
  XPUSHs(sv_2mortal(msg));
  PUTBACK;
  call_pv("GraphQL::Houtou::XS::Parser::_format_error", G_SCALAR);
  SPAGAIN;
  err = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  croak_sv(err);
}

static const char *
gql_expected_token_label(gql_token_kind_t kind) {
  switch (kind) {
    case TOK_BANG: return "\"!\"";
    case TOK_DOLLAR: return "\"$\"";
    case TOK_AMP: return "\"&\"";
    case TOK_LPAREN: return "\"(\"";
    case TOK_RPAREN: return "\")\"";
    case TOK_SPREAD: return "\"...\"";
    case TOK_COLON: return "\":\"";
    case TOK_EQUALS: return "\"=\"";
    case TOK_AT: return "\"@\"";
    case TOK_LBRACKET: return "\"[\"";
    case TOK_RBRACKET: return "\"]\"";
    case TOK_LBRACE: return "\"{\"";
    case TOK_RBRACE: return "\"}\"";
    case TOK_PIPE: return "\"|\"";
    case TOK_NAME: return "name";
    case TOK_INT: return "int";
    case TOK_FLOAT: return "float";
    case TOK_STRING: return "string";
    case TOK_BLOCK_STRING: return "block string";
    case TOK_EOF: return "EOF";
  }
  return "token";
}

static SV *
gql_current_token_desc_sv(pTHX_ gql_parser_t *p) {
  switch (p->kind) {
    case TOK_NAME:
      return newSVpvf("Name \"%.*s\"", (int)(p->tok_end - p->tok_start), p->src + p->tok_start);
    case TOK_INT:
      return newSVpvf("Int \"%.*s\"", (int)(p->tok_end - p->tok_start), p->src + p->tok_start);
    case TOK_FLOAT:
      return newSVpvf("Float \"%.*s\"", (int)(p->tok_end - p->tok_start), p->src + p->tok_start);
    case TOK_STRING:
      return newSVpv("string", 0);
    case TOK_BLOCK_STRING:
      return newSVpv("block string", 0);
    default:
      return newSVpv(gql_expected_token_label(p->kind), 0);
  }
}

static void
gql_throw_expected_message(pTHX_ gql_parser_t *p, STRLEN pos, const char *msg) {
  SV *got = gql_current_token_desc_sv(aTHX_ p);
  SV *full_msg = newSVpvf("%s but got %s", msg, SvPV_nolen(got));
  SvREFCNT_dec(got);
  gql_throw_sv(aTHX_ p, pos, full_msg);
}

static void
gql_throw_expected_token(pTHX_ gql_parser_t *p, gql_token_kind_t kind) {
  SV *prefix = newSVpvf("Expected %s", gql_expected_token_label(kind));
  gql_throw_expected_message(aTHX_ p, p->tok_start, SvPV_nolen(prefix));
  SvREFCNT_dec(prefix);
}

static void
gql_throw_unexpected_character(pTHX_ gql_parser_t *p, STRLEN pos, unsigned char c) {
  if (c >= 0x20 && c <= 0x7E) {
    gql_throw_sv(aTHX_ p, pos, newSVpvf("Unexpected character \"%c\"", c));
  }
  gql_throw_sv(aTHX_ p, pos, newSVpvf("Unexpected character code %u", (unsigned int)c));
}

static int
gqljs_is_name_start(char c) {
  return (c == '_')
    || (c >= 'A' && c <= 'Z')
    || (c >= 'a' && c <= 'z');
}

static int
gqljs_is_name_continue(char c) {
  return gqljs_is_name_start(c)
    || (c >= '0' && c <= '9');
}

static void
gqljs_skip_ignored_raw(const char *src, STRLEN len, STRLEN *pos) {
  while (*pos < len) {
    unsigned char c = (unsigned char)src[*pos];
    if (c == 0xEF && *pos + 2 < len &&
        (unsigned char)src[*pos + 1] == 0xBB &&
        (unsigned char)src[*pos + 2] == 0xBF) {
      *pos += 3;
      continue;
    }
    if (c == ',' || c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      (*pos)++;
      continue;
    }
    if (c == '#') {
      while (*pos < len && src[*pos] != '\n' && src[*pos] != '\r') {
        (*pos)++;
      }
      continue;
    }
    break;
  }
}

static void
gqljs_skip_quoted_string_raw(const char *src, STRLEN len, STRLEN *pos) {
  if (*pos + 2 < len &&
      src[*pos] == '"' &&
      src[*pos + 1] == '"' &&
      src[*pos + 2] == '"') {
    *pos += 3;
    while (*pos + 2 < len) {
      if (src[*pos] == '"' && src[*pos + 1] == '"' && src[*pos + 2] == '"') {
        *pos += 3;
        return;
      }
      (*pos)++;
    }
    *pos = len;
    return;
  }

  (*pos)++;
  while (*pos < len) {
    char c = src[*pos];
    if (c == '\\') {
      *pos += 2;
      continue;
    }
    (*pos)++;
    if (c == '"') {
      return;
    }
  }
}

static void
gqljs_skip_delimited_raw(const char *src, STRLEN len, STRLEN *pos, char open, char close) {
  if (*pos >= len || src[*pos] != open) {
    return;
  }

  (*pos)++;
  while (*pos < len) {
    char c = src[*pos];
    if (c == '#') {
      while (*pos < len && src[*pos] != '\n' && src[*pos] != '\r') {
        (*pos)++;
      }
      continue;
    }
    if (c == '"') {
      gqljs_skip_quoted_string_raw(src, len, pos);
      continue;
    }
    if (c == open) {
      gqljs_skip_delimited_raw(src, len, pos, open, close);
      continue;
    }
    if (c == '(' && open != '(') {
      gqljs_skip_delimited_raw(src, len, pos, '(', ')');
      continue;
    }
    if (c == '[' && open != '[') {
      gqljs_skip_delimited_raw(src, len, pos, '[', ']');
      continue;
    }
    if (c == '{' && open != '{') {
      gqljs_skip_delimited_raw(src, len, pos, '{', '}');
      continue;
    }
    (*pos)++;
    if (c == close) {
      return;
    }
  }
}

static int
gqljs_read_name_bounds(const char *src, STRLEN len, STRLEN *pos, STRLEN *start, STRLEN *end) {
  if (*pos >= len || !gqljs_is_name_start(src[*pos])) {
    return 0;
  }

  *start = *pos;
  (*pos)++;
  while (*pos < len && gqljs_is_name_continue(src[*pos])) {
    (*pos)++;
  }
  *end = *pos;
  return 1;
}

static SV *
gqljs_make_string_sv(pTHX_ const char *src, STRLEN start, STRLEN end, int is_utf8) {
  SV *sv = newSVpvn(src + start, end - start);
  if (is_utf8) {
    SvUTF8_on(sv);
  }
  return sv;
}

static int
gqljs_match_word(const char *src, STRLEN start, STRLEN end, const char *word) {
  STRLEN want = (STRLEN)strlen(word);
  return (end - start) == want && memcmp(src + start, word, want) == 0;
}

static void
gqljs_push_rewrite(pTHX_ AV *rewrites, UV start, UV end, const char *replacement) {
  HV *hv = newHV();
  gql_store_sv(hv, "start", newSVuv(start));
  gql_store_sv(hv, "end", newSVuv(end));
  gql_store_sv(hv, "replacement", newSVpv(replacement, 0));
  av_push(rewrites, newRV_noinc((SV *)hv));
}

static void
gqljs_push_extension(pTHX_ AV *extensions, const char *kind, SV *name_sv, UV occurrence) {
  HV *hv = newHV();
  gql_store_sv(hv, "kind", newSVpv(kind, 0));
  if (name_sv) {
    gql_store_sv(hv, "name", newSVsv(name_sv));
  }
  gql_store_sv(hv, "occurrence", newSVuv(occurrence));
  av_push(extensions, newRV_noinc((SV *)hv));
}

static UV
gqljs_bump_occurrence(pTHX_ HV *counts, const char *kind, SV *name_sv) {
  SV *key_sv = newSVpv(kind, 0);
  SV **current_svp;
  UV next = 1;
  STRLEN key_len;
  const char *key;

  sv_catpvn(key_sv, "\x1e", 1);
  if (name_sv) {
    sv_catsv(key_sv, name_sv);
  }

  key = SvPV(key_sv, key_len);
  current_svp = hv_fetch(counts, key, (I32)key_len, 0);
  if (current_svp) {
    next = SvUV(*current_svp) + 1;
  }
  hv_store(counts, key, (I32)key_len, newSVuv(next), 0);

  SvREFCNT_dec(key_sv);
  return next;
}

static void
gqljs_store_hash_key_sv(HV *hv, SV *key_sv, SV *value) {
  STRLEN key_len;
  const char *key = SvPV(key_sv, key_len);
  hv_store(hv, key, (I32)key_len, value, 0);
}

static SV *
gqljs_apply_rewrites_sv(pTHX_ SV *source_sv, AV *rewrites) {
  STRLEN src_len;
  const char *src = SvPV(source_sv, src_len);
  STRLEN cursor = 0;
  I32 i;
  SV *rewritten = newSVpvn("", 0);

  if (SvUTF8(source_sv)) {
    SvUTF8_on(rewritten);
  }

  for (i = 0; i <= av_len(rewrites); i++) {
    SV **rewrite_svp = av_fetch(rewrites, i, 0);
    HV *rewrite_hv;
    UV start;
    UV end;
    SV **start_svp;
    SV **end_svp;
    SV **replacement_svp;
    STRLEN replacement_len;
    const char *replacement;

    if (!rewrite_svp || !SvROK(*rewrite_svp) || SvTYPE(SvRV(*rewrite_svp)) != SVt_PVHV) {
      continue;
    }
    rewrite_hv = (HV *)SvRV(*rewrite_svp);
    start_svp = hv_fetch(rewrite_hv, "start", 5, 0);
    end_svp = hv_fetch(rewrite_hv, "end", 3, 0);
    replacement_svp = hv_fetch(rewrite_hv, "replacement", 11, 0);
    if (!start_svp || !end_svp || !replacement_svp) {
      continue;
    }

    start = SvUV(*start_svp);
    end = SvUV(*end_svp);
    replacement = SvPV(*replacement_svp, replacement_len);

    if (start > src_len) start = src_len;
    if (end > src_len) end = src_len;
    if (start < cursor) start = cursor;
    if (start > cursor) {
      sv_catpvn(rewritten, src + cursor, start - cursor);
    }
    sv_catpvn(rewritten, replacement, replacement_len);
    cursor = end;
  }

  if (cursor < src_len) {
    sv_catpvn(rewritten, src + cursor, src_len - cursor);
  }

  return rewritten;
}

static SV *
gqljs_skip_directive_raw(pTHX_ const char *src, STRLEN len, STRLEN *pos, int is_utf8) {
  STRLEN start = *pos;
  STRLEN name_start;
  STRLEN name_end;

  if (*pos >= len || src[*pos] != '@') {
    return &PL_sv_undef;
  }

  (*pos)++;
  (void)gqljs_read_name_bounds(src, len, pos, &name_start, &name_end);
  gqljs_skip_ignored_raw(src, len, pos);
  if (*pos < len && src[*pos] == '(') {
    gqljs_skip_delimited_raw(src, len, pos, '(', ')');
  }

  return gqljs_make_string_sv(aTHX_ src, start, *pos, is_utf8);
}

static void
gqljs_scan_variable_definition_directives(pTHX_ const char *src, STRLEN len, STRLEN *pos, int is_utf8, HV *operation_meta, AV *rewrites) {
  if (*pos >= len || src[*pos] != '(') {
    return;
  }

  (*pos)++;
  while (*pos < len) {
    AV *directive_texts = NULL;
    STRLEN name_start;
    STRLEN name_end;
    SV *name_sv;

    gqljs_skip_ignored_raw(src, len, pos);
    if (*pos >= len) {
      return;
    }
    if (src[*pos] == ')') {
      (*pos)++;
      return;
    }
    if (src[*pos] != '$') {
      (*pos)++;
      continue;
    }

    (*pos)++;
    if (!gqljs_read_name_bounds(src, len, pos, &name_start, &name_end)) {
      continue;
    }
    name_sv = gqljs_make_string_sv(aTHX_ src, name_start, name_end, is_utf8);

    while (*pos < len) {
      char c = src[*pos];
      if (c == '#') {
        while (*pos < len && src[*pos] != '\n' && src[*pos] != '\r') {
          (*pos)++;
        }
        continue;
      }
      if (c == '"') {
        gqljs_skip_quoted_string_raw(src, len, pos);
        continue;
      }
      if (c == '(') {
        gqljs_skip_delimited_raw(src, len, pos, '(', ')');
        continue;
      }
      if (c == '[') {
        gqljs_skip_delimited_raw(src, len, pos, '[', ']');
        continue;
      }
      if (c == '{') {
        gqljs_skip_delimited_raw(src, len, pos, '{', '}');
        continue;
      }
      if (c == '@') {
        STRLEN directive_start = *pos;
        SV *directive_text = gqljs_skip_directive_raw(aTHX_ src, len, pos, is_utf8);
        if (!directive_texts) {
          directive_texts = newAV();
        }
        gqljs_push_rewrite(aTHX_ rewrites, directive_start, *pos, "");
        av_push(directive_texts, directive_text);
        continue;
      }
      if (c == '$' || c == ')' || c == ',') {
        break;
      }
      (*pos)++;
    }

    if (directive_texts && av_count(directive_texts) > 0) {
      gqljs_store_hash_key_sv(operation_meta, name_sv, newRV_noinc((SV *)directive_texts));
    } else if (directive_texts) {
      SvREFCNT_dec((SV *)directive_texts);
    }
    SvREFCNT_dec(name_sv);
  }
}

static SV *
gql_graphqljs_preprocess(pTHX_ SV *source_sv) {
  STRLEN len;
  const char *src = SvPV(source_sv, len);
  int is_utf8 = SvUTF8(source_sv) ? 1 : 0;
  STRLEN pos = 0;
  IV brace_depth = 0;
  HV *meta = newHV();
  AV *rewrites = newAV();
  AV *extensions = newAV();
  AV *operation_variable_directives = newAV();
  HV *definition_counts = newHV();
  HV *interface_implements = newHV();
  HV *repeatable_directives = newHV();

  while (pos < len) {
    char c = src[pos];
    if (c == '#') {
      while (pos < len && src[pos] != '\n' && src[pos] != '\r') {
        pos++;
      }
      continue;
    }
    if (c == '"') {
      gqljs_skip_quoted_string_raw(src, len, &pos);
      continue;
    }
    if (c == '{') {
      brace_depth++;
      pos++;
      continue;
    }
    if (c == '}') {
      if (brace_depth > 0) {
        brace_depth--;
      }
      pos++;
      continue;
    }
    if (brace_depth == 0 && gqljs_is_name_start(c)) {
      STRLEN word_start;
      STRLEN word_end;
      STRLEN temp_pos;
      if (!gqljs_read_name_bounds(src, len, &pos, &word_start, &word_end)) {
        continue;
      }

      if (gqljs_match_word(src, word_start, word_end, "extend")) {
        STRLEN kind_start;
        STRLEN kind_end;
        gqljs_skip_ignored_raw(src, len, &pos);
        if (!gqljs_read_name_bounds(src, len, &pos, &kind_start, &kind_end)) {
          continue;
        }
        if (gqljs_match_word(src, kind_start, kind_end, "schema") ||
            gqljs_match_word(src, kind_start, kind_end, "scalar") ||
            gqljs_match_word(src, kind_start, kind_end, "type") ||
            gqljs_match_word(src, kind_start, kind_end, "interface") ||
            gqljs_match_word(src, kind_start, kind_end, "union") ||
            gqljs_match_word(src, kind_start, kind_end, "enum") ||
            gqljs_match_word(src, kind_start, kind_end, "input") ||
            gqljs_match_word(src, kind_start, kind_end, "directive")) {
          SV *name_sv = NULL;
          const char *extension_kind;
          UV occurrence;
          if (!gqljs_match_word(src, kind_start, kind_end, "schema")) {
            STRLEN name_start;
            STRLEN name_end;
            gqljs_skip_ignored_raw(src, len, &pos);
            if (gqljs_match_word(src, kind_start, kind_end, "directive")) {
              if (pos < len && src[pos] == '@') {
                pos++;
              }
            }
            if (gqljs_read_name_bounds(src, len, &pos, &name_start, &name_end)) {
              name_sv = gqljs_make_string_sv(aTHX_ src, name_start, name_end, is_utf8);
            }
          }
          extension_kind =
            gqljs_match_word(src, kind_start, kind_end, "schema") ? "schema" :
            gqljs_match_word(src, kind_start, kind_end, "scalar") ? "scalar" :
            gqljs_match_word(src, kind_start, kind_end, "type") ? "type" :
            gqljs_match_word(src, kind_start, kind_end, "interface") ? "interface" :
            gqljs_match_word(src, kind_start, kind_end, "union") ? "union" :
            gqljs_match_word(src, kind_start, kind_end, "enum") ? "enum" :
            gqljs_match_word(src, kind_start, kind_end, "input") ? "input" :
            "directive";
          occurrence = gqljs_bump_occurrence(aTHX_ definition_counts, extension_kind, name_sv);
          gqljs_push_extension(
            aTHX_ extensions,
            extension_kind,
            name_sv,
            occurrence
          );
          if (gqljs_match_word(src, kind_start, kind_end, "directive")) {
            gqljs_push_rewrite(aTHX_ rewrites, word_start, kind_start, "");
          }
          if (gqljs_match_word(src, kind_start, kind_end, "interface") && name_sv) {
            temp_pos = pos;
            gqljs_skip_ignored_raw(src, len, &temp_pos);
            if (temp_pos < len && gqljs_is_name_start(src[temp_pos])) {
              STRLEN kw_start;
              STRLEN kw_end;
              if (gqljs_read_name_bounds(src, len, &temp_pos, &kw_start, &kw_end)
                  && gqljs_match_word(src, kw_start, kw_end, "implements")) {
                gqljs_store_hash_key_sv(interface_implements, name_sv, newSViv(1));
                gqljs_push_rewrite(aTHX_ rewrites, kind_start, kind_end, "type");
              }
            }
          }
          if (name_sv) {
            SvREFCNT_dec(name_sv);
          }
        }
        continue;
      }

      if (gqljs_match_word(src, word_start, word_end, "interface")) {
        STRLEN name_start;
        STRLEN name_end;
        temp_pos = pos;
        gqljs_skip_ignored_raw(src, len, &temp_pos);
        if (gqljs_read_name_bounds(src, len, &temp_pos, &name_start, &name_end)) {
          SV *name_sv = gqljs_make_string_sv(aTHX_ src, name_start, name_end, is_utf8);
          (void)gqljs_bump_occurrence(aTHX_ definition_counts, "interface", name_sv);
          gqljs_skip_ignored_raw(src, len, &temp_pos);
          if (temp_pos < len && gqljs_is_name_start(src[temp_pos])) {
            STRLEN kw_start;
            STRLEN kw_end;
            if (gqljs_read_name_bounds(src, len, &temp_pos, &kw_start, &kw_end)
                && gqljs_match_word(src, kw_start, kw_end, "implements")) {
              gqljs_store_hash_key_sv(interface_implements, name_sv, newSViv(1));
              gqljs_push_rewrite(aTHX_ rewrites, word_start, word_end, "type");
            }
          }
          SvREFCNT_dec(name_sv);
        }
        continue;
      }

      if (gqljs_match_word(src, word_start, word_end, "directive")) {
        STRLEN name_start;
        STRLEN name_end;
        temp_pos = pos;
        gqljs_skip_ignored_raw(src, len, &temp_pos);
        if (temp_pos < len && src[temp_pos] == '@') {
          SV *name_sv;
          temp_pos++;
          if (!gqljs_read_name_bounds(src, len, &temp_pos, &name_start, &name_end)) {
            continue;
          }
          name_sv = gqljs_make_string_sv(aTHX_ src, name_start, name_end, is_utf8);
          (void)gqljs_bump_occurrence(aTHX_ definition_counts, "directive", name_sv);
          gqljs_skip_ignored_raw(src, len, &temp_pos);
          if (temp_pos < len && src[temp_pos] == '(') {
            gqljs_skip_delimited_raw(src, len, &temp_pos, '(', ')');
            gqljs_skip_ignored_raw(src, len, &temp_pos);
          }
          if (temp_pos < len && gqljs_is_name_start(src[temp_pos])) {
            STRLEN repeat_start;
            STRLEN repeat_end;
            if (gqljs_read_name_bounds(src, len, &temp_pos, &repeat_start, &repeat_end)
                && gqljs_match_word(src, repeat_start, repeat_end, "repeatable")) {
              gqljs_store_hash_key_sv(repeatable_directives, name_sv, newSViv(1));
              gqljs_push_rewrite(aTHX_ rewrites, repeat_start, repeat_end, "");
            }
          }
          SvREFCNT_dec(name_sv);
        }
        continue;
      }

      if (gqljs_match_word(src, word_start, word_end, "schema") ||
          gqljs_match_word(src, word_start, word_end, "scalar") ||
          gqljs_match_word(src, word_start, word_end, "type") ||
          gqljs_match_word(src, word_start, word_end, "union") ||
          gqljs_match_word(src, word_start, word_end, "enum") ||
          gqljs_match_word(src, word_start, word_end, "input")) {
        const char *definition_kind =
          gqljs_match_word(src, word_start, word_end, "schema") ? "schema" :
          gqljs_match_word(src, word_start, word_end, "scalar") ? "scalar" :
          gqljs_match_word(src, word_start, word_end, "type") ? "type" :
          gqljs_match_word(src, word_start, word_end, "union") ? "union" :
          gqljs_match_word(src, word_start, word_end, "enum") ? "enum" :
          "input";
        if (gqljs_match_word(src, word_start, word_end, "schema")) {
          (void)gqljs_bump_occurrence(aTHX_ definition_counts, definition_kind, NULL);
        } else {
          STRLEN name_start;
          STRLEN name_end;
          SV *name_sv = NULL;
          temp_pos = pos;
          gqljs_skip_ignored_raw(src, len, &temp_pos);
          if (gqljs_read_name_bounds(src, len, &temp_pos, &name_start, &name_end)) {
            name_sv = gqljs_make_string_sv(aTHX_ src, name_start, name_end, is_utf8);
            (void)gqljs_bump_occurrence(aTHX_ definition_counts, definition_kind, name_sv);
            SvREFCNT_dec(name_sv);
          }
        }
        continue;
      }

      if (gqljs_match_word(src, word_start, word_end, "query") ||
          gqljs_match_word(src, word_start, word_end, "mutation") ||
          gqljs_match_word(src, word_start, word_end, "subscription")) {
        HV *operation_meta = newHV();
        temp_pos = pos;
        gqljs_skip_ignored_raw(src, len, &temp_pos);
        if (temp_pos < len && gqljs_is_name_start(src[temp_pos])) {
          STRLEN maybe_name_start;
          STRLEN maybe_name_end;
          (void)gqljs_read_name_bounds(src, len, &temp_pos, &maybe_name_start, &maybe_name_end);
          gqljs_skip_ignored_raw(src, len, &temp_pos);
        }
        if (temp_pos < len && src[temp_pos] == '(') {
          gqljs_scan_variable_definition_directives(aTHX_ src, len, &temp_pos, is_utf8, operation_meta, rewrites);
        }
        if (HvUSEDKEYS(operation_meta) > 0) {
          av_push(operation_variable_directives, newRV_noinc((SV *)operation_meta));
        }
        else {
          SvREFCNT_dec((SV *)operation_meta);
        }
        continue;
      }
    }

    pos++;
  }

  gql_store_sv(meta, "rewrites", newRV_noinc((SV *)rewrites));
  gql_store_sv(meta, "rewritten_source", gqljs_apply_rewrites_sv(aTHX_ source_sv, rewrites));
  gql_store_sv(meta, "extensions", newRV_noinc((SV *)extensions));
  gql_store_sv(meta, "interface_implements", newRV_noinc((SV *)interface_implements));
  gql_store_sv(meta, "repeatable_directives", newRV_noinc((SV *)repeatable_directives));
  gql_store_sv(meta, "operation_variable_directives", newRV_noinc((SV *)operation_variable_directives));
  return newRV_noinc((SV *)meta);
}

static SV *
gql_parse_directives_only(pTHX_ SV *source_sv) {
  gql_parser_t p;
  STRLEN len;
  const char *src = SvPV(source_sv, len);
  SV *directives;

  p.src = src;
  p.len = len;
  p.pos = 0;
  p.last_pos = (STRLEN)-1;
  p.tok_start = 0;
  p.tok_end = 0;
  p.val_start = 0;
  p.val_end = 0;
  p.kind = TOK_EOF;
  p.is_utf8 = SvUTF8(source_sv) ? 1 : 0;

  gql_advance(aTHX_ &p);
  directives = gql_parse_directives(aTHX_ &p);
  if (p.kind != TOK_EOF) {
    gql_throw(aTHX_ &p, p.tok_start, "Expected directive");
  }
  return directives;
}

static SV *
gqljs_clone_with_loc(pTHX_ SV *value, SV *loc_sv) {
  if (!SvROK(value)) {
    return newSVsv(value);
  }

  if (SvTYPE(SvRV(value)) == SVt_PVHV) {
    HV *src_hv = (HV *)SvRV(value);
    HV *dst_hv = newHV();
    HE *he;
    hv_iterinit(src_hv);
    while ((he = hv_iternext(src_hv))) {
      SV *key_sv = hv_iterkeysv(he);
      STRLEN key_len;
      const char *key = SvPV(key_sv, key_len);
      if (key_len == 3 && memcmp(key, "loc", 3) == 0) {
        continue;
      }
      gqljs_store_hash_key_sv(dst_hv, key_sv, gqljs_clone_with_loc(aTHX_ hv_iterval(src_hv, he), loc_sv));
    }
    if (loc_sv && SvOK(loc_sv)) {
      gql_store_sv(dst_hv, "loc", newSVsv(loc_sv));
    }
    return newRV_noinc((SV *)dst_hv);
  }

  if (SvTYPE(SvRV(value)) == SVt_PVAV) {
    AV *src_av = (AV *)SvRV(value);
    AV *dst_av = newAV();
    I32 i;
    for (i = 0; i <= av_len(src_av); i++) {
      SV **svp = av_fetch(src_av, i, 0);
      if (!svp) {
        continue;
      }
      av_push(dst_av, gqljs_clone_with_loc(aTHX_ *svp, loc_sv));
    }
    return newRV_noinc((SV *)dst_av);
  }

  return newSVsv(value);
}

static int
gqljs_sv_eq_pv(SV *sv, const char *literal) {
  STRLEN len;
  const char *value = SvPV(sv, len);
  STRLEN literal_len = (STRLEN)strlen(literal);
  return len == literal_len && memcmp(value, literal, literal_len) == 0;
}

static const char *
gqljs_definition_source_kind(SV *kind_sv) {
  STRLEN len;
  const char *kind = SvPV(kind_sv, len);

  if (len == 16 && memcmp(kind, "SchemaDefinition", 16) == 0) return "schema";
  if (len == 20 && memcmp(kind, "ScalarTypeDefinition", 20) == 0) return "scalar";
  if (len == 20 && memcmp(kind, "ObjectTypeDefinition", 20) == 0) return "type";
  if (len == 23 && memcmp(kind, "InterfaceTypeDefinition", 23) == 0) return "interface";
  if (len == 19 && memcmp(kind, "UnionTypeDefinition", 19) == 0) return "union";
  if (len == 18 && memcmp(kind, "EnumTypeDefinition", 18) == 0) return "enum";
  if (len == 25 && memcmp(kind, "InputObjectTypeDefinition", 25) == 0) return "input";
  if (len == 19 && memcmp(kind, "DirectiveDefinition", 19) == 0) return "directive";

  return NULL;
}

static const char *
gqljs_extension_kind_name(const char *source_kind) {
  if (strcmp(source_kind, "schema") == 0) return "SchemaExtension";
  if (strcmp(source_kind, "scalar") == 0) return "ScalarTypeExtension";
  if (strcmp(source_kind, "type") == 0) return "ObjectTypeExtension";
  if (strcmp(source_kind, "interface") == 0) return "InterfaceTypeExtension";
  if (strcmp(source_kind, "union") == 0) return "UnionTypeExtension";
  if (strcmp(source_kind, "enum") == 0) return "EnumTypeExtension";
  if (strcmp(source_kind, "input") == 0) return "InputObjectTypeExtension";
  if (strcmp(source_kind, "directive") == 0) return "DirectiveExtension";
  return NULL;
}

static SV *
gql_graphqljs_patch_document(pTHX_ SV *doc_sv, SV *meta_sv) {
  HV *doc_hv;
  HV *meta_hv;
  AV *definitions;
  AV *extensions = NULL;
  AV *operation_variable_directives = NULL;
  HV *interface_implements = NULL;
  HV *repeatable_directives = NULL;
  HV *seen_occurrences = newHV();
  I32 i;

  if (!SvROK(doc_sv) || SvTYPE(SvRV(doc_sv)) != SVt_PVHV ||
      !SvROK(meta_sv) || SvTYPE(SvRV(meta_sv)) != SVt_PVHV) {
    croak("graphqljs_patch_document_xs expects hash references");
  }

  doc_hv = (HV *)SvRV(doc_sv);
  meta_hv = (HV *)SvRV(meta_sv);

  {
    SV **svp = hv_fetch(doc_hv, "definitions", 11, 0);
    if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVAV) {
      croak("graphqljs_patch_document_xs expected document definitions");
    }
    definitions = (AV *)SvRV(*svp);
  }

  {
    SV **svp = hv_fetch(meta_hv, "extensions", 10, 0);
    if (svp && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVAV) {
      extensions = (AV *)SvRV(*svp);
    }
  }
  {
    SV **svp = hv_fetch(meta_hv, "operation_variable_directives", 29, 0);
    if (svp && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVAV) {
      operation_variable_directives = (AV *)SvRV(*svp);
    }
  }
  {
    SV **svp = hv_fetch(meta_hv, "interface_implements", 20, 0);
    if (svp && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVHV) {
      interface_implements = (HV *)SvRV(*svp);
    }
  }
  {
    SV **svp = hv_fetch(meta_hv, "repeatable_directives", 21, 0);
    if (svp && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVHV) {
      repeatable_directives = (HV *)SvRV(*svp);
    }
  }

  for (i = 0; i <= av_len(definitions); i++) {
    SV **def_svp = av_fetch(definitions, i, 0);
    HV *def_hv;
    SV **kind_svp;

    if (!def_svp || !SvROK(*def_svp) || SvTYPE(SvRV(*def_svp)) != SVt_PVHV) {
      continue;
    }
    def_hv = (HV *)SvRV(*def_svp);
    kind_svp = hv_fetch(def_hv, "kind", 4, 0);
    if (!kind_svp) {
      continue;
    }

    if (interface_implements && gqljs_sv_eq_pv(*kind_svp, "ObjectTypeDefinition")) {
      SV **name_svp = hv_fetch(def_hv, "name", 4, 0);
      if (name_svp && SvROK(*name_svp) && SvTYPE(SvRV(*name_svp)) == SVt_PVHV) {
        HV *name_hv = (HV *)SvRV(*name_svp);
        SV **value_svp = hv_fetch(name_hv, "value", 5, 0);
        if (value_svp) {
          STRLEN key_len;
          const char *key = SvPV(*value_svp, key_len);
          if (hv_exists(interface_implements, key, (I32)key_len)) {
            hv_store(def_hv, "kind", 4, newSVpv("InterfaceTypeDefinition", 0), 0);
            kind_svp = hv_fetch(def_hv, "kind", 4, 0);
          }
        }
      }
    }

    if (extensions && av_len(extensions) >= 0 && kind_svp) {
      const char *source_kind = gqljs_definition_source_kind(*kind_svp);
      if (source_kind) {
        SV **name_svp = hv_fetch(def_hv, "name", 4, 0);
        SV *name_value = NULL;
        UV occurrence;
        if (strcmp(source_kind, "schema") == 0) {
          occurrence = gqljs_bump_occurrence(aTHX_ seen_occurrences, source_kind, NULL);
        } else if (name_svp && SvROK(*name_svp) && SvTYPE(SvRV(*name_svp)) == SVt_PVHV) {
          HV *name_hv = (HV *)SvRV(*name_svp);
          SV **value_svp = hv_fetch(name_hv, "value", 5, 0);
          if (value_svp) {
            name_value = *value_svp;
          }
          occurrence = gqljs_bump_occurrence(aTHX_ seen_occurrences, source_kind, name_value);
        } else {
          occurrence = gqljs_bump_occurrence(aTHX_ seen_occurrences, source_kind, NULL);
        }
        SV **ext_svp = av_fetch(extensions, 0, 0);
        if (ext_svp && SvROK(*ext_svp) && SvTYPE(SvRV(*ext_svp)) == SVt_PVHV) {
          HV *ext_hv = (HV *)SvRV(*ext_svp);
          SV **ext_kind_svp = hv_fetch(ext_hv, "kind", 4, 0);
          SV **ext_occurrence_svp = hv_fetch(ext_hv, "occurrence", 10, 0);
          const char *expected_kind = gqljs_extension_kind_name(source_kind);
          int matches = 0;

          if (ext_kind_svp && ext_occurrence_svp &&
              gqljs_sv_eq_pv(*ext_kind_svp, source_kind) &&
              SvUV(*ext_occurrence_svp) == occurrence) {
            if (strcmp(source_kind, "schema") == 0) {
              matches = 1;
            } else if (name_value) {
              SV **ext_name_svp = hv_fetch(ext_hv, "name", 4, 0);
              if (ext_name_svp && sv_eq(name_value, *ext_name_svp)) {
                matches = 1;
              }
            }
          }

          if (matches && expected_kind) {
            SV *shifted = av_shift(extensions);
            if (shifted) {
              SvREFCNT_dec(shifted);
            }
            hv_store(def_hv, "kind", 4, newSVpv(expected_kind, 0), 0);
            kind_svp = hv_fetch(def_hv, "kind", 4, 0);
          }
        }
      }
    }

    if (repeatable_directives && kind_svp && gqljs_sv_eq_pv(*kind_svp, "DirectiveDefinition")) {
      SV **name_svp = hv_fetch(def_hv, "name", 4, 0);
      if (name_svp && SvROK(*name_svp) && SvTYPE(SvRV(*name_svp)) == SVt_PVHV) {
        HV *name_hv = (HV *)SvRV(*name_svp);
        SV **value_svp = hv_fetch(name_hv, "value", 5, 0);
        if (value_svp) {
          STRLEN key_len;
          const char *key = SvPV(*value_svp, key_len);
          if (hv_exists(repeatable_directives, key, (I32)key_len)) {
            hv_store(def_hv, "repeatable", 10, newSViv(1), 0);
          }
        }
      }
    }

    if (operation_variable_directives && kind_svp && gqljs_sv_eq_pv(*kind_svp, "OperationDefinition")) {
      if (av_len(operation_variable_directives) >= 0) {
        SV *shifted = av_shift(operation_variable_directives);
        if (shifted && SvROK(shifted) && SvTYPE(SvRV(shifted)) == SVt_PVHV) {
          HV *operation_meta = (HV *)SvRV(shifted);
          SV **vars_svp = hv_fetch(def_hv, "variableDefinitions", 19, 0);
          if (vars_svp && SvROK(*vars_svp) && SvTYPE(SvRV(*vars_svp)) == SVt_PVAV) {
            AV *variable_definitions = (AV *)SvRV(*vars_svp);
            I32 j;
            for (j = 0; j <= av_len(variable_definitions); j++) {
              SV **var_svp = av_fetch(variable_definitions, j, 0);
              HV *var_hv;
              SV **var_name_svp;
              if (!var_svp || !SvROK(*var_svp) || SvTYPE(SvRV(*var_svp)) != SVt_PVHV) {
                continue;
              }
              var_hv = (HV *)SvRV(*var_svp);
              var_name_svp = hv_fetch(var_hv, "variable", 8, 0);
              if (var_name_svp && SvROK(*var_name_svp) && SvTYPE(SvRV(*var_name_svp)) == SVt_PVHV) {
                HV *variable_hv = (HV *)SvRV(*var_name_svp);
                SV **name_node_svp = hv_fetch(variable_hv, "name", 4, 0);
                if (name_node_svp && SvROK(*name_node_svp) && SvTYPE(SvRV(*name_node_svp)) == SVt_PVHV) {
                  HV *name_node_hv = (HV *)SvRV(*name_node_svp);
                  SV **value_svp = hv_fetch(name_node_hv, "value", 5, 0);
                  if (value_svp) {
                    STRLEN key_len;
                    const char *key = SvPV(*value_svp, key_len);
                    SV **directives_svp = hv_fetch(operation_meta, key, (I32)key_len, 0);
                    if (directives_svp) {
                      SV **loc_svp = hv_fetch(var_hv, "loc", 3, 0);
                      SV *loc_sv = (loc_svp && SvROK(*loc_svp)) ? *loc_svp : &PL_sv_undef;
                      hv_store(var_hv, "directives", 10, gqljs_clone_with_loc(aTHX_ *directives_svp, loc_sv), 0);
                    }
                  }
                }
              }
            }
          }
        }
        if (shifted) {
          SvREFCNT_dec(shifted);
        }
      }
    }
  }

  SvREFCNT_dec((SV *)seen_occurrences);
  return newSVsv(doc_sv);
}

static void
gqljs_set_loc_node(pTHX_ SV *node_sv, SV *loc_sv) {
  if (!node_sv || !loc_sv || !SvROK(node_sv) || SvTYPE(SvRV(node_sv)) != SVt_PVHV) {
    return;
  }
  hv_stores((HV *)SvRV(node_sv), "loc", SvREFCNT_inc_simple_NN(loc_sv));
}

static void
gqljs_set_rewritten_loc_node(pTHX_ gqljs_loc_context_t *ctx, SV *node_sv, UV rewritten_pos) {
  SV *loc_sv;

  if (!ctx || !node_sv) {
    return;
  }
  loc_sv = gqljs_loc_from_rewritten_pos(aTHX_ ctx, rewritten_pos);
  gqljs_set_loc_node(aTHX_ node_sv, loc_sv);
  SvREFCNT_dec(loc_sv);
}

static HV *
gqljs_node_hv(SV *node_sv) {
  if (!node_sv || !SvROK(node_sv) || SvTYPE(SvRV(node_sv)) != SVt_PVHV) {
    return NULL;
  }
  return (HV *)SvRV(node_sv);
}

static SV *
gqljs_fetch_sv(HV *hv, const char *key) {
  SV **svp;
  if (!hv) {
    return NULL;
  }
  svp = hv_fetch(hv, key, (I32)strlen(key), 0);
  return svp ? *svp : NULL;
}

static AV *
gqljs_fetch_array(HV *hv, const char *key) {
  SV *sv = gqljs_fetch_sv(hv, key);
  if (!sv || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVAV) {
    return NULL;
  }
  return (AV *)SvRV(sv);
}

static const char *
gqljs_fetch_kind(HV *hv) {
  SV *sv = gqljs_fetch_sv(hv, "kind");
  STRLEN len;
  if (!sv) {
    return NULL;
  }
  return SvPV(sv, len);
}

static const char *
gqljs_name_value(SV *node_sv) {
  HV *hv = gqljs_node_hv(node_sv);
  HV *name_hv;
  SV *value_sv;
  STRLEN len;

  if (!hv) {
    return NULL;
  }

  value_sv = gqljs_fetch_sv(hv, "value");
  if (value_sv && !SvROK(value_sv)) {
    return SvPV(value_sv, len);
  }

  value_sv = gqljs_fetch_sv(hv, "name");
  if (value_sv && SvROK(value_sv) && SvTYPE(SvRV(value_sv)) == SVt_PVHV) {
    name_hv = (HV *)SvRV(value_sv);
    value_sv = gqljs_fetch_sv(name_hv, "value");
    if (value_sv) {
      return SvPV(value_sv, len);
    }
  }

  return NULL;
}

static SV *
gqljs_find_named_node(AV *av, const char *name) {
  I32 i;
  if (!av || !name) {
    return NULL;
  }
  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    const char *node_name;
    if (!svp) {
      continue;
    }
    node_name = gqljs_name_value(*svp);
    if (node_name && strcmp(node_name, name) == 0) {
      return *svp;
    }
  }
  return NULL;
}

static SV *
gqljs_find_variable_definition(AV *av, const char *name) {
  I32 i;
  if (!av || !name) {
    return NULL;
  }
  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *hv;
    SV *variable_sv;
    const char *node_name;
    if (!svp) {
      continue;
    }
    hv = gqljs_node_hv(*svp);
    if (!hv) {
      continue;
    }
    variable_sv = gqljs_fetch_sv(hv, "variable");
    node_name = gqljs_name_value(variable_sv);
    if (node_name && strcmp(node_name, name) == 0) {
      return *svp;
    }
  }
  return NULL;
}

static SV *
gqljs_new_loc_sv(pTHX_ IV line, IV column) {
  HV *loc_hv = newHV();
  hv_ksplit(loc_hv, 2);
  hv_stores(loc_hv, "line", newSViv(line));
  hv_stores(loc_hv, "column", newSViv(column));
  return newRV_noinc((SV *)loc_hv);
}

static SV *
gqljs_loc_from_rewritten_pos(pTHX_ gqljs_loc_context_t *ctx, UV rewritten_pos) {
  UV original_pos = rewritten_pos;
  I32 line_index;
  SV *loc_sv;

  if (!ctx) {
    return &PL_sv_undef;
  }

  if (ctx->rewrite_index_count > 0) {
    IV rewritten_iv = (IV)rewritten_pos;
    I32 low = 0;
    I32 high = ctx->rewrite_index_count - 1;
    I32 match = -1;

    while (low <= high) {
      I32 mid = low + ((high - low) / 2);
      gqljs_rewrite_index_t *entry = &ctx->rewrite_index[mid];
      if (entry->rewritten_start <= rewritten_iv) {
        match = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }

    if (match >= 0) {
      gqljs_rewrite_index_t *entry = &ctx->rewrite_index[match];
      if (rewritten_iv < entry->rewritten_end) {
        original_pos = entry->original_start;
      } else {
        original_pos = (UV)(rewritten_iv + entry->delta_after);
      }
    }
  }

  if (ctx->num_lines <= 0) {
    return gqljs_new_loc_sv(aTHX_ 1, (IV)(original_pos + 1));
  }

  {
    I32 low = 0;
    I32 high = ctx->num_lines - 1;
    line_index = 0;

    while (low <= high) {
      I32 mid = low + ((high - low) / 2);
      if (ctx->line_starts[mid] <= original_pos) {
        line_index = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
  }

  if (ctx->loc_cache && original_pos < ctx->loc_cache_len && ctx->loc_cache[original_pos]) {
    return SvREFCNT_inc_simple_NN(ctx->loc_cache[original_pos]);
  }

  loc_sv = gqljs_new_loc_sv(
    aTHX_
    (IV)(line_index + 1),
    (IV)(original_pos - ctx->line_starts[line_index] + 1)
  );
  if (ctx->loc_cache && original_pos < ctx->loc_cache_len) {
    ctx->loc_cache[original_pos] = SvREFCNT_inc_simple_NN(loc_sv);
  }
  return loc_sv;
}

static void
gqljs_loc_context_init(pTHX_ gqljs_loc_context_t *ctx, SV *source_sv, AV *rewrites) {
  STRLEN len;
  const char *src = SvPV(source_sv, len);
  I32 line_count = 1;
  I32 rewrite_count = 0;
  STRLEN i;

  ctx->src = src;
  ctx->len = len;
  ctx->rewrites = rewrites;
  ctx->line_starts = NULL;
  ctx->num_lines = 0;
  ctx->loc_cache = NULL;
  ctx->loc_cache_len = 0;
  ctx->rewrite_index = NULL;
  ctx->rewrite_index_count = 0;

  for (i = 0; i < len; i++) {
    if (src[i] == '\n') {
      line_count++;
    } else if (src[i] == '\r') {
      line_count++;
      if (i + 1 < len && src[i + 1] == '\n') {
        i++;
      }
    }
  }

  Newx(ctx->line_starts, line_count, UV);
  ctx->line_starts[0] = 0;
  ctx->num_lines = line_count;
  ctx->loc_cache_len = (UV)len + 1;
  Newxz(ctx->loc_cache, ctx->loc_cache_len, SV *);

  {
    I32 line_index = 1;
    for (i = 0; i < len; i++) {
      if (src[i] == '\n') {
        ctx->line_starts[line_index++] = (UV)(i + 1);
      } else if (src[i] == '\r') {
        if (i + 1 < len && src[i + 1] == '\n') {
          i++;
        }
        ctx->line_starts[line_index++] = (UV)(i + 1);
      }
    }
  }

  if (rewrites) {
    rewrite_count = av_len(rewrites) + 1;
  }
  if (rewrite_count > 0) {
    IV cumulative_delta = 0;
    I32 rewrite_index = 0;

    Newx(ctx->rewrite_index, rewrite_count, gqljs_rewrite_index_t);
    for (i = 0; i < (STRLEN)rewrite_count; i++) {
      SV **rewrite_svp = av_fetch(rewrites, (I32)i, 0);
      HV *rewrite_hv;
      SV **start_svp;
      SV **end_svp;
      SV **replacement_svp;
      UV start;
      UV end;
      STRLEN replacement_len;
      gqljs_rewrite_index_t *entry;

      if (!rewrite_svp || !SvROK(*rewrite_svp) || SvTYPE(SvRV(*rewrite_svp)) != SVt_PVHV) {
        continue;
      }
      rewrite_hv = (HV *)SvRV(*rewrite_svp);
      start_svp = hv_fetch(rewrite_hv, "start", 5, 0);
      end_svp = hv_fetch(rewrite_hv, "end", 3, 0);
      replacement_svp = hv_fetch(rewrite_hv, "replacement", 11, 0);
      if (!start_svp || !end_svp || !replacement_svp) {
        continue;
      }

      start = SvUV(*start_svp);
      end = SvUV(*end_svp);
      (void)SvPV(*replacement_svp, replacement_len);

      entry = &ctx->rewrite_index[rewrite_index++];
      entry->original_start = start;
      entry->rewritten_start = (IV)start - cumulative_delta;
      entry->rewritten_end = entry->rewritten_start + (IV)replacement_len;
      cumulative_delta += (IV)((end - start) - replacement_len);
      entry->delta_after = cumulative_delta;
    }
    ctx->rewrite_index_count = rewrite_index;
  }
}

static void
gqljs_loc_context_destroy(gqljs_loc_context_t *ctx) {
  UV i;

  if (ctx->line_starts) {
    Safefree(ctx->line_starts);
  }
  if (ctx->loc_cache) {
    for (i = 0; i < ctx->loc_cache_len; i++) {
      if (ctx->loc_cache[i]) {
        SvREFCNT_dec(ctx->loc_cache[i]);
      }
    }
    Safefree(ctx->loc_cache);
  }
  if (ctx->rewrite_index) {
    Safefree(ctx->rewrite_index);
  }
  ctx->line_starts = NULL;
  ctx->num_lines = 0;
  ctx->loc_cache = NULL;
  ctx->loc_cache_len = 0;
  ctx->rewrite_index = NULL;
  ctx->rewrite_index_count = 0;
}

static SV *
gqljs_locate_name_node(pTHX_ gql_parser_t *p, SV *node_sv) {
  SV *loc;
  if (p->kind != TOK_NAME) {
    gql_throw_expected_token(aTHX_ p, TOK_NAME);
  }
  loc = sv_2mortal(gql_make_current_location(aTHX_ p));
  gqljs_set_loc_node(aTHX_ node_sv, loc);
  gql_advance(aTHX_ p);
  return loc;
}

static SV *
gqljs_locate_type_node(pTHX_ gql_parser_t *p, SV *node_sv) {
  HV *hv = gqljs_node_hv(node_sv);
  const char *kind = gqljs_fetch_kind(hv);
  SV *loc;

  if (!kind) {
    croak("graphqljs executable loc expected type node");
  }

  if (strcmp(kind, "NamedType") == 0) {
    loc = gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    return loc;
  }
  if (strcmp(kind, "ListType") == 0) {
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_expect(aTHX_ p, TOK_LBRACKET, NULL);
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_type_node(aTHX_ p, gqljs_fetch_sv(hv, "type"));
    gql_expect(aTHX_ p, TOK_RBRACKET, NULL);
    return loc;
  }
  if (strcmp(kind, "NonNullType") == 0) {
    loc = gqljs_locate_type_node(aTHX_ p, gqljs_fetch_sv(hv, "type"));
    gql_expect(aTHX_ p, TOK_BANG, NULL);
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    return loc;
  }

  croak("Unsupported graphqljs executable type node %s", kind);
}

static SV *
gqljs_locate_value_node(pTHX_ gql_parser_t *p, SV *node_sv) {
  HV *hv = gqljs_node_hv(node_sv);
  const char *kind = gqljs_fetch_kind(hv);
  SV *loc;
  AV *av;
  I32 i;

  if (!kind) {
    croak("graphqljs executable loc expected value node");
  }

  if (strcmp(kind, "Variable") == 0) {
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_expect(aTHX_ p, TOK_DOLLAR, NULL);
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    return loc;
  }
  if (strcmp(kind, "IntValue") == 0 || strcmp(kind, "FloatValue") == 0) {
    if (p->kind != TOK_INT && p->kind != TOK_FLOAT) {
      gql_throw_expected_message(aTHX_ p, p->tok_start, "Expected numeric token");
    }
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gql_advance(aTHX_ p);
    return loc;
  }
  if (strcmp(kind, "StringValue") == 0) {
    if (p->kind != TOK_STRING && p->kind != TOK_BLOCK_STRING) {
      gql_throw(aTHX_ p, p->tok_start, "Expected string token");
    }
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gql_advance(aTHX_ p);
    return loc;
  }
  if (strcmp(kind, "BooleanValue") == 0 || strcmp(kind, "NullValue") == 0 || strcmp(kind, "EnumValue") == 0) {
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    return loc;
  }
  if (strcmp(kind, "ListValue") == 0) {
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_expect(aTHX_ p, TOK_LBRACKET, NULL);
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    av = gqljs_fetch_array(hv, "values");
    if (av) {
      for (i = 0; i <= av_len(av); i++) {
        SV **svp = av_fetch(av, i, 0);
        if (svp) {
          gqljs_locate_value_node(aTHX_ p, *svp);
        }
      }
    }
    gql_expect(aTHX_ p, TOK_RBRACKET, NULL);
    return loc;
  }
  if (strcmp(kind, "ObjectValue") == 0) {
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_expect(aTHX_ p, TOK_LBRACE, NULL);
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    av = gqljs_fetch_array(hv, "fields");
    while (p->kind != TOK_RBRACE) {
      char *name = savepvn(p->src + p->tok_start, p->tok_end - p->tok_start);
      SV *field_sv = gqljs_find_named_node(av, name);
      HV *field_hv;
      SV *field_loc;
      Safefree(name);
      if (!field_sv) {
        croak("Missing object field node");
      }
      field_hv = gqljs_node_hv(field_sv);
      field_loc = sv_2mortal(gql_make_current_location(aTHX_ p));
      gqljs_set_loc_node(aTHX_ field_sv, field_loc);
      gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(field_hv, "name"));
      gql_expect(aTHX_ p, TOK_COLON, NULL);
      gqljs_locate_value_node(aTHX_ p, gqljs_fetch_sv(field_hv, "value"));
    }
    gql_expect(aTHX_ p, TOK_RBRACE, NULL);
    return loc;
  }

  croak("Unsupported graphqljs executable value node %s", kind);
}

static void
gqljs_locate_arguments_nodes(pTHX_ gql_parser_t *p, AV *av) {
  if (!av || av_len(av) < 0) {
    return;
  }
  gql_expect(aTHX_ p, TOK_LPAREN, NULL);
  while (p->kind != TOK_RPAREN) {
    char *name = savepvn(p->src + p->tok_start, p->tok_end - p->tok_start);
    SV *node_sv = gqljs_find_named_node(av, name);
    HV *node_hv;
    SV *loc;
    Safefree(name);
    if (!node_sv) {
      croak("Missing argument node");
    }
    node_hv = gqljs_node_hv(node_sv);
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(node_hv, "name"));
    gql_expect(aTHX_ p, TOK_COLON, NULL);
    gqljs_locate_value_node(aTHX_ p, gqljs_fetch_sv(node_hv, "value"));
  }
  gql_expect(aTHX_ p, TOK_RPAREN, NULL);
}

static void
gqljs_locate_directives_nodes(pTHX_ gql_parser_t *p, AV *av) {
  I32 i;
  if (!av || av_len(av) < 0) {
    return;
  }
  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *hv;
    SV *loc;
    if (!svp) {
      continue;
    }
    hv = gqljs_node_hv(*svp);
    if (!hv) {
      continue;
    }
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_expect(aTHX_ p, TOK_AT, NULL);
    gqljs_set_loc_node(aTHX_ *svp, loc);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    gqljs_locate_arguments_nodes(aTHX_ p, gqljs_fetch_array(hv, "arguments"));
  }
}

static void
gqljs_locate_variable_definitions_nodes(pTHX_ gql_parser_t *p, AV *av) {
  if (!av || av_len(av) < 0) {
    return;
  }
  gql_expect(aTHX_ p, TOK_LPAREN, NULL);
  while (p->kind != TOK_RPAREN) {
    SV *loc;
    char *name;
    SV *node_sv;
    HV *node_hv;
    SV *variable_sv;
    if (p->kind != TOK_DOLLAR) {
      gql_throw_expected_token(aTHX_ p, TOK_DOLLAR);
    }
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_expect(aTHX_ p, TOK_DOLLAR, NULL);
    if (p->kind != TOK_NAME) {
      gql_throw_expected_token(aTHX_ p, TOK_NAME);
    }
    name = savepvn(p->src + p->tok_start, p->tok_end - p->tok_start);
    node_sv = gqljs_find_variable_definition(av, name);
    Safefree(name);
    if (!node_sv) {
      croak("Missing variable definition node");
    }
    node_hv = gqljs_node_hv(node_sv);
    variable_sv = gqljs_fetch_sv(node_hv, "variable");
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_set_loc_node(aTHX_ variable_sv, loc);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(gqljs_node_hv(variable_sv), "name"));
    gql_expect(aTHX_ p, TOK_COLON, NULL);
    gqljs_locate_type_node(aTHX_ p, gqljs_fetch_sv(node_hv, "type"));
    if (gqljs_fetch_sv(node_hv, "defaultValue")) {
      gql_expect(aTHX_ p, TOK_EQUALS, NULL);
      gqljs_locate_value_node(aTHX_ p, gqljs_fetch_sv(node_hv, "defaultValue"));
    }
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(node_hv, "directives"));
  }
  gql_expect(aTHX_ p, TOK_RPAREN, NULL);
}

static SV *
gqljs_locate_selection_set_node(pTHX_ gql_parser_t *p, SV *node_sv) {
  HV *hv = gqljs_node_hv(node_sv);
  AV *av = gqljs_fetch_array(hv, "selections");
  I32 i;
  SV *loc = sv_2mortal(gql_make_current_location(aTHX_ p));
  gql_expect(aTHX_ p, TOK_LBRACE, NULL);
  gqljs_set_loc_node(aTHX_ node_sv, loc);
  if (av) {
    for (i = 0; i <= av_len(av); i++) {
      SV **svp = av_fetch(av, i, 0);
      if (svp) {
        gqljs_locate_selection_node(aTHX_ p, *svp);
      }
    }
  }
  gql_expect(aTHX_ p, TOK_RBRACE, NULL);
  return loc;
}

static void
gqljs_locate_selection_node(pTHX_ gql_parser_t *p, SV *node_sv) {
  HV *hv = gqljs_node_hv(node_sv);
  const char *kind = gqljs_fetch_kind(hv);
  SV *loc;

  if (!kind) {
    croak("graphqljs executable loc expected selection node");
  }

  if (strcmp(kind, "Field") == 0) {
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    if (gqljs_fetch_sv(hv, "alias")) {
      gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "alias"));
      gql_expect(aTHX_ p, TOK_COLON, NULL);
      gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    } else {
      gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    }
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_arguments_nodes(aTHX_ p, gqljs_fetch_array(hv, "arguments"));
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(hv, "directives"));
    if (gqljs_fetch_sv(hv, "selectionSet")) {
      gqljs_locate_selection_set_node(aTHX_ p, gqljs_fetch_sv(hv, "selectionSet"));
    }
    return;
  }
  if (strcmp(kind, "FragmentSpread") == 0) {
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_expect(aTHX_ p, TOK_SPREAD, NULL);
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(hv, "directives"));
    return;
  }
  if (strcmp(kind, "InlineFragment") == 0) {
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_expect(aTHX_ p, TOK_SPREAD, NULL);
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    if (gqljs_fetch_sv(hv, "typeCondition")) {
      gql_expect(aTHX_ p, TOK_NAME, NULL);
      gqljs_locate_type_node(aTHX_ p, gqljs_fetch_sv(hv, "typeCondition"));
    }
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(hv, "directives"));
    gqljs_locate_selection_set_node(aTHX_ p, gqljs_fetch_sv(hv, "selectionSet"));
    return;
  }

  croak("Unsupported graphqljs executable selection node %s", kind);
}

static int
gqljs_locate_executable_definition(pTHX_ gql_parser_t *p, SV *node_sv) {
  HV *hv = gqljs_node_hv(node_sv);
  const char *kind = gqljs_fetch_kind(hv);
  SV *loc;

  if (!kind) {
    croak("graphqljs executable loc expected definition node");
  }

  if (strcmp(kind, "OperationDefinition") == 0) {
    if (p->kind == TOK_LBRACE) {
      loc = gqljs_locate_selection_set_node(aTHX_ p, gqljs_fetch_sv(hv, "selectionSet"));
      gqljs_set_loc_node(aTHX_ node_sv, loc);
      return 1;
    }
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    if (gqljs_fetch_sv(hv, "name")) {
      gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    }
    gqljs_locate_variable_definitions_nodes(aTHX_ p, gqljs_fetch_array(hv, "variableDefinitions"));
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(hv, "directives"));
    gqljs_locate_selection_set_node(aTHX_ p, gqljs_fetch_sv(hv, "selectionSet"));
    return 1;
  }

  if (strcmp(kind, "FragmentDefinition") == 0) {
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gqljs_locate_type_node(aTHX_ p, gqljs_fetch_sv(hv, "typeCondition"));
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(hv, "directives"));
    gqljs_locate_selection_set_node(aTHX_ p, gqljs_fetch_sv(hv, "selectionSet"));
    return 1;
  }

  return 0;
}

static SV *
gql_graphqljs_apply_executable_loc(pTHX_ SV *doc_sv, SV *source_sv) {
  HV *doc_hv;
  AV *definitions;
  gql_parser_t p;
  STRLEN len;
  const char *src = SvPV(source_sv, len);
  I32 i;
  HV *loc_hv;

  if (!SvROK(doc_sv) || SvTYPE(SvRV(doc_sv)) != SVt_PVHV) {
    croak("graphqljs_apply_executable_loc_xs expects a document hash reference");
  }
  doc_hv = (HV *)SvRV(doc_sv);
  definitions = gqljs_fetch_array(doc_hv, "definitions");
  if (!definitions) {
    croak("graphqljs_apply_executable_loc_xs expected document definitions");
  }

  p.src = src;
  p.len = len;
  p.pos = 0;
  p.last_pos = (STRLEN)-1;
  p.tok_start = 0;
  p.tok_end = 0;
  p.val_start = 0;
  p.val_end = 0;
  p.kind = TOK_EOF;
  p.is_utf8 = SvUTF8(source_sv) ? 1 : 0;
  gql_advance(aTHX_ &p);

  loc_hv = newHV();
  gql_store_sv(loc_hv, "line", newSViv(1));
  gql_store_sv(loc_hv, "column", newSViv(1));
  hv_store(doc_hv, "loc", 3, newRV_noinc((SV *)loc_hv), 0);

  for (i = 0; i <= av_len(definitions); i++) {
    SV **svp = av_fetch(definitions, i, 0);
    if (!svp) {
      continue;
    }
    if (!gqljs_locate_executable_definition(aTHX_ &p, *svp)) {
      return &PL_sv_undef;
    }
  }

  if (p.kind != TOK_EOF) {
    gql_throw_expected_token(aTHX_ &p, TOK_EOF);
  }

  return newSVsv(doc_sv);
}

static HV *
gqljs_new_node_hv_sized(const char *kind, I32 keys) {
  HV *hv = newHV();
  if (keys > 1) {
    hv_ksplit(hv, keys);
  }
  gql_store_sv(hv, "kind", newSVpv(kind, 0));
  return hv;
}

static SV *
gqljs_new_named_type_node_sv(pTHX_ SV *value_sv) {
  HV *hv = gqljs_new_node_hv_sized("NamedType", 2);
  hv_stores(hv, "name", gqljs_new_name_node_sv(aTHX_ value_sv));
  return newRV_noinc((SV *)hv);
}

static SV *
gqljs_new_variable_node_sv(pTHX_ SV *value_sv) {
  HV *hv = gqljs_new_node_hv_sized("Variable", 2);
  hv_stores(hv, "name", gqljs_new_name_node_sv(aTHX_ value_sv));
  return newRV_noinc((SV *)hv);
}

static HV *
gqljs_new_node_hv(const char *kind) {
  return gqljs_new_node_hv_sized(kind, 1);
}

static SV *
gqljs_new_node_ref(const char *kind) {
  return newRV_noinc((SV *)gqljs_new_node_hv(kind));
}

static SV *
gqljs_new_name_node_sv(pTHX_ SV *value_sv) {
  HV *hv = gqljs_new_node_hv_sized("Name", 2);
  gql_store_sv(hv, "value", SvREFCNT_inc_simple_NN(value_sv));
  return newRV_noinc((SV *)hv);
}

static SV *
gqljs_new_description_node_sv(pTHX_ SV *value_sv) {
  HV *hv = gqljs_new_node_hv_sized("StringValue", 3);
  STRLEN len;
  const char *value;
  value = SvPV(value_sv, len);
  gql_store_sv(hv, "value", SvREFCNT_inc_simple_NN(value_sv));
  gql_store_sv(hv, "block", newSViv(memchr(value, '\n', len) ? 1 : 0));
  return newRV_noinc((SV *)hv);
}

static int
gqljs_cmp_sv_ptrs(const void *a, const void *b) {
  SV *const *left = (SV *const *)a;
  SV *const *right = (SV *const *)b;
  STRLEN left_len, right_len;
  const char *left_str = SvPV(*left, left_len);
  const char *right_str = SvPV(*right, right_len);
  STRLEN min_len = left_len < right_len ? left_len : right_len;
  int cmp = memcmp(left_str, right_str, min_len);
  if (cmp != 0) {
    return cmp;
  }
  if (left_len < right_len) {
    return -1;
  }
  if (left_len > right_len) {
    return 1;
  }
  return 0;
}

static SV **
gqljs_sorted_hash_keys(pTHX_ HV *hv, I32 *count_out) {
  I32 count;
  I32 i = 0;
  HE *he;
  SV **keys;

  *count_out = 0;
  if (!hv) {
    return NULL;
  }

  count = hv_iterinit(hv);
  if (count <= 0) {
    return NULL;
  }

  Newxz(keys, count, SV *);
  hv_iterinit(hv);
  while ((he = hv_iternext(hv))) {
    keys[i++] = newSVsv(hv_iterkeysv(he));
  }
  qsort(keys, count, sizeof(SV *), gqljs_cmp_sv_ptrs);
  *count_out = count;
  return keys;
}

static void
gqljs_free_sorted_hash_keys(SV **keys, I32 count) {
  I32 i;
  if (!keys) {
    return;
  }
  for (i = 0; i < count; i++) {
    if (keys[i]) {
      SvREFCNT_dec(keys[i]);
    }
  }
  Safefree(keys);
}

static SV *
gqljs_convert_legacy_type_sv(pTHX_ SV *type_sv) {
  if (!type_sv) {
    return &PL_sv_undef;
  }

  if (!SvROK(type_sv)) {
    HV *hv = gqljs_new_node_hv("NamedType");
    gql_store_sv(hv, "name", gqljs_new_name_node_sv(aTHX_ type_sv));
    return newRV_noinc((SV *)hv);
  }

  if (SvTYPE(SvRV(type_sv)) == SVt_PVAV) {
    AV *av = (AV *)SvRV(type_sv);
    SV **kind_svp = av_fetch(av, 0, 0);
    SV **inner_svp = av_fetch(av, 1, 0);
    HV *inner_hv;
    STRLEN len;
    const char *kind;
    HV *hv;
    if (!kind_svp || !inner_svp || !SvROK(*inner_svp) || SvTYPE(SvRV(*inner_svp)) != SVt_PVHV) {
      croak("Unsupported graphql-perl type representation");
    }
    kind = SvPV(*kind_svp, len);
    inner_hv = (HV *)SvRV(*inner_svp);
    if (strcmp(kind, "list") == 0) {
      hv = gqljs_new_node_hv("ListType");
      gql_store_sv(hv, "type", gqljs_convert_legacy_type_sv(aTHX_ gqljs_fetch_sv(inner_hv, "type")));
      return newRV_noinc((SV *)hv);
    }
    if (strcmp(kind, "non_null") == 0) {
      hv = gqljs_new_node_hv("NonNullType");
      gql_store_sv(hv, "type", gqljs_convert_legacy_type_sv(aTHX_ gqljs_fetch_sv(inner_hv, "type")));
      return newRV_noinc((SV *)hv);
    }
  }

  croak("Unsupported graphql-perl type representation");
}

static SV *
gqljs_convert_legacy_value_sv(pTHX_ SV *value_sv) {
  HV *hv;

  if (!value_sv || !SvOK(value_sv)) {
    return gqljs_new_node_ref("NullValue");
  }

  if (sv_isobject(value_sv) && sv_derived_from(value_sv, "JSON::PP::Boolean")) {
    hv = gqljs_new_node_hv("BooleanValue");
    gql_store_sv(hv, "value", newSViv(SvTRUE(value_sv) ? 1 : 0));
    return newRV_noinc((SV *)hv);
  }

  if (!SvROK(value_sv)) {
    if (looks_like_number(value_sv)) {
      const char *value = SvPV_nolen(value_sv);
      hv = gqljs_new_node_hv(strchr(value, '.') || strchr(value, 'e') || strchr(value, 'E')
        ? "FloatValue"
        : "IntValue");
      gql_store_sv(hv, "value", newSVsv(value_sv));
      return newRV_noinc((SV *)hv);
    }
    hv = gqljs_new_node_hv("StringValue");
    gql_store_sv(hv, "value", newSVsv(value_sv));
    gql_store_sv(hv, "block", newSViv(0));
    return newRV_noinc((SV *)hv);
  }

  if (SvROK(value_sv) && SvTYPE(SvRV(value_sv)) == SVt_PVAV) {
    AV *src_av = (AV *)SvRV(value_sv);
    AV *dst_av = newAV();
    I32 i;
    hv = gqljs_new_node_hv("ListValue");
    for (i = 0; i <= av_len(src_av); i++) {
      SV **svp = av_fetch(src_av, i, 0);
      if (svp) {
        av_push(dst_av, gqljs_convert_legacy_value_sv(aTHX_ *svp));
      }
    }
    gql_store_sv(hv, "values", newRV_noinc((SV *)dst_av));
    return newRV_noinc((SV *)hv);
  }

  if (SvROK(value_sv) && SvTYPE(SvRV(value_sv)) == SVt_PVHV) {
    HV *src_hv = (HV *)SvRV(value_sv);
    AV *fields = newAV();
    I32 count = 0;
    SV **keys = gqljs_sorted_hash_keys(aTHX_ src_hv, &count);
    I32 i;
    hv = gqljs_new_node_hv("ObjectValue");
    for (i = 0; i < count; i++) {
      STRLEN key_len;
      const char *key = SvPV(keys[i], key_len);
      SV **field_svp = hv_fetch(src_hv, key, (I32)key_len, 0);
      HV *field_hv = gqljs_new_node_hv("ObjectField");
      if (!field_svp) {
        continue;
      }
      gql_store_sv(field_hv, "name", gqljs_new_name_node_sv(aTHX_ keys[i]));
      gql_store_sv(field_hv, "value", gqljs_convert_legacy_value_sv(aTHX_ *field_svp));
      av_push(fields, newRV_noinc((SV *)field_hv));
    }
    gqljs_free_sorted_hash_keys(keys, count);
    gql_store_sv(hv, "fields", newRV_noinc((SV *)fields));
    return newRV_noinc((SV *)hv);
  }

  if (SvROK(value_sv) && !SvROK(SvRV(value_sv))) {
    hv = gqljs_new_node_hv("Variable");
    gql_store_sv(hv, "name", gqljs_new_name_node_sv(aTHX_ SvRV(value_sv)));
    return newRV_noinc((SV *)hv);
  }

  if (SvROK(value_sv) && SvROK(SvRV(value_sv)) && !SvROK(SvRV(SvRV(value_sv)))) {
    hv = gqljs_new_node_hv("EnumValue");
    gql_store_sv(hv, "value", newSVsv(SvRV(SvRV(value_sv))));
    return newRV_noinc((SV *)hv);
  }


  croak("Unsupported graphql-perl value representation");
}

static AV *
gqljs_convert_legacy_arguments_hv(pTHX_ HV *hv) {
  AV *av = newAV();
  I32 count = 0;
  SV **keys = gqljs_sorted_hash_keys(aTHX_ hv, &count);
  I32 i;
  if (!hv) {
    return av;
  }
  for (i = 0; i < count; i++) {
    STRLEN key_len;
    const char *key = SvPV(keys[i], key_len);
    SV **value_svp = hv_fetch(hv, key, (I32)key_len, 0);
    HV *arg_hv;
    if (!value_svp) {
      continue;
    }
    arg_hv = gqljs_new_node_hv("Argument");
    gql_store_sv(arg_hv, "name", gqljs_new_name_node_sv(aTHX_ keys[i]));
    gql_store_sv(arg_hv, "value", gqljs_convert_legacy_value_sv(aTHX_ *value_svp));
    av_push(av, newRV_noinc((SV *)arg_hv));
  }
  gqljs_free_sorted_hash_keys(keys, count);
  return av;
}

static AV *
gqljs_convert_legacy_directives_av(pTHX_ AV *av) {
  AV *out = newAV();
  I32 i;
  if (!av) {
    return out;
  }
  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *src_hv;
    HV *dst_hv;
    SV *name_sv;
    SV *args_sv;
    if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVHV) {
      continue;
    }
    src_hv = (HV *)SvRV(*svp);
    dst_hv = gqljs_new_node_hv("Directive");
    name_sv = gqljs_fetch_sv(src_hv, "name");
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    args_sv = gqljs_fetch_sv(src_hv, "arguments");
    if (args_sv && SvROK(args_sv) && SvTYPE(SvRV(args_sv)) == SVt_PVHV) {
      gql_store_sv(dst_hv, "arguments", newRV_noinc((SV *)gqljs_convert_legacy_arguments_hv(aTHX_ (HV *)SvRV(args_sv))));
    } else {
      gql_store_sv(dst_hv, "arguments", newRV_noinc((SV *)newAV()));
    }
    av_push(out, newRV_noinc((SV *)dst_hv));
  }
  return out;
}

static SV *
gqljs_convert_legacy_selection_set_av(pTHX_ AV *av) {
  HV *hv = gqljs_new_node_hv("SelectionSet");
  AV *selections = newAV();
  I32 i;
  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    if (svp) {
      av_push(selections, gqljs_convert_legacy_selection_sv(aTHX_ *svp));
    }
  }
  gql_store_sv(hv, "selections", newRV_noinc((SV *)selections));
  return newRV_noinc((SV *)hv);
}

static SV *
gqljs_convert_legacy_selection_sv(pTHX_ SV *selection_sv) {
  HV *src_hv;
  STRLEN kind_len;
  const char *kind;
  HV *dst_hv;
  if (!selection_sv || !SvROK(selection_sv) || SvTYPE(SvRV(selection_sv)) != SVt_PVHV) {
    croak("Unsupported graphql-perl selection");
  }
  src_hv = (HV *)SvRV(selection_sv);
  kind = SvPV(gqljs_fetch_sv(src_hv, "kind"), kind_len);

  if (strcmp(kind, "field") == 0) {
    SV *name_sv = gqljs_fetch_sv(src_hv, "name");
    SV *alias_sv = gqljs_fetch_sv(src_hv, "alias");
    SV *args_sv = gqljs_fetch_sv(src_hv, "arguments");
    SV *dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    SV *sels_sv = gqljs_fetch_sv(src_hv, "selections");
    dst_hv = gqljs_new_node_hv("Field");
    if (alias_sv) {
      gql_store_sv(dst_hv, "alias", gqljs_new_name_node_sv(aTHX_ alias_sv));
    }
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    gql_store_sv(dst_hv, "arguments",
      (args_sv && SvROK(args_sv) && SvTYPE(SvRV(args_sv)) == SVt_PVHV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_arguments_hv(aTHX_ (HV *)SvRV(args_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    if (sels_sv && SvROK(sels_sv) && SvTYPE(SvRV(sels_sv)) == SVt_PVAV) {
      gql_store_sv(dst_hv, "selectionSet", gqljs_convert_legacy_selection_set_av(aTHX_ (AV *)SvRV(sels_sv)));
    }
    return newRV_noinc((SV *)dst_hv);
  }

  if (strcmp(kind, "fragment_spread") == 0) {
    SV *name_sv = gqljs_fetch_sv(src_hv, "name");
    SV *dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    dst_hv = gqljs_new_node_hv("FragmentSpread");
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    return newRV_noinc((SV *)dst_hv);
  }

  if (strcmp(kind, "inline_fragment") == 0) {
    SV *on_sv = gqljs_fetch_sv(src_hv, "on");
    SV *dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    SV *sels_sv = gqljs_fetch_sv(src_hv, "selections");
    dst_hv = gqljs_new_node_hv("InlineFragment");
    if (on_sv) {
      HV *type_hv = gqljs_new_node_hv("NamedType");
      gql_store_sv(type_hv, "name", gqljs_new_name_node_sv(aTHX_ on_sv));
      gql_store_sv(dst_hv, "typeCondition", newRV_noinc((SV *)type_hv));
    }
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "selectionSet",
      (sels_sv && SvROK(sels_sv) && SvTYPE(SvRV(sels_sv)) == SVt_PVAV)
        ? gqljs_convert_legacy_selection_set_av(aTHX_ (AV *)SvRV(sels_sv))
        : gqljs_convert_legacy_selection_set_av(aTHX_ newAV()));
    return newRV_noinc((SV *)dst_hv);
  }

  croak("Unsupported graphql-perl executable selection kind %s", kind);
}

static AV *
gqljs_convert_legacy_variable_definitions_hv(pTHX_ HV *hv) {
  AV *av = newAV();
  I32 count = 0;
  SV **keys = gqljs_sorted_hash_keys(aTHX_ hv, &count);
  I32 i;
  if (!hv) {
    return av;
  }
  for (i = 0; i < count; i++) {
    STRLEN key_len;
    const char *key = SvPV(keys[i], key_len);
    SV **value_svp = hv_fetch(hv, key, (I32)key_len, 0);
    HV *src_hv;
    HV *dst_hv;
    HV *var_hv;
    SV *dirs_sv;
    if (!value_svp || !SvROK(*value_svp) || SvTYPE(SvRV(*value_svp)) != SVt_PVHV) {
      continue;
    }
    src_hv = (HV *)SvRV(*value_svp);
    dst_hv = gqljs_new_node_hv("VariableDefinition");
    var_hv = gqljs_new_node_hv("Variable");
    gql_store_sv(var_hv, "name", gqljs_new_name_node_sv(aTHX_ keys[i]));
    gql_store_sv(dst_hv, "variable", newRV_noinc((SV *)var_hv));
    gql_store_sv(dst_hv, "type", gqljs_convert_legacy_type_sv(aTHX_ gqljs_fetch_sv(src_hv, "type")));
    if (gqljs_fetch_sv(src_hv, "default_value")) {
      gql_store_sv(dst_hv, "defaultValue",
        gqljs_convert_legacy_value_sv(aTHX_ gqljs_fetch_sv(src_hv, "default_value")));
    }
    dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    av_push(av, newRV_noinc((SV *)dst_hv));
  }
  gqljs_free_sorted_hash_keys(keys, count);
  return av;
}

static SV *
gqljs_convert_legacy_input_value_definition_sv(pTHX_ SV *name_sv, HV *src_hv) {
  HV *dst_hv = gqljs_new_node_hv("InputValueDefinition");
  SV *desc_sv = gqljs_fetch_sv(src_hv, "description");
  SV *dirs_sv = gqljs_fetch_sv(src_hv, "directives");
  if (desc_sv) {
    gql_store_sv(dst_hv, "description", gqljs_new_description_node_sv(aTHX_ desc_sv));
  }
  gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
  gql_store_sv(dst_hv, "type", gqljs_convert_legacy_type_sv(aTHX_ gqljs_fetch_sv(src_hv, "type")));
  if (gqljs_fetch_sv(src_hv, "default_value")) {
    gql_store_sv(dst_hv, "defaultValue",
      gqljs_convert_legacy_value_sv(aTHX_ gqljs_fetch_sv(src_hv, "default_value")));
  }
  gql_store_sv(dst_hv, "directives",
    (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
      ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
      : newRV_noinc((SV *)newAV()));
  return newRV_noinc((SV *)dst_hv);
}

static AV *
gqljs_convert_legacy_named_types_av(pTHX_ AV *av) {
  AV *out = newAV();
  I32 i;
  if (!av) {
    return out;
  }
  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *type_hv;
    if (!svp) {
      continue;
    }
    type_hv = gqljs_new_node_hv("NamedType");
    gql_store_sv(type_hv, "name", gqljs_new_name_node_sv(aTHX_ *svp));
    av_push(out, newRV_noinc((SV *)type_hv));
  }
  return out;
}

static AV *
gqljs_convert_legacy_name_nodes_av(pTHX_ AV *av) {
  AV *out = newAV();
  I32 i;
  if (!av) {
    return out;
  }
  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    if (svp) {
      av_push(out, gqljs_new_name_node_sv(aTHX_ *svp));
    }
  }
  return out;
}

static AV *
gqljs_convert_legacy_input_value_definitions_hv(pTHX_ HV *hv) {
  AV *av = newAV();
  I32 count = 0;
  SV **keys;
  I32 i;
  if (!hv) {
    return av;
  }
  keys = gqljs_sorted_hash_keys(aTHX_ hv, &count);
  for (i = 0; i < count; i++) {
    STRLEN key_len;
    const char *key = SvPV(keys[i], key_len);
    SV **value_svp = hv_fetch(hv, key, (I32)key_len, 0);
    if (!value_svp || !SvROK(*value_svp) || SvTYPE(SvRV(*value_svp)) != SVt_PVHV) {
      continue;
    }
    av_push(av, gqljs_convert_legacy_input_value_definition_sv(aTHX_ keys[i], (HV *)SvRV(*value_svp)));
  }
  gqljs_free_sorted_hash_keys(keys, count);
  return av;
}

static AV *
gqljs_convert_legacy_field_definitions_hv(pTHX_ HV *hv) {
  AV *av = newAV();
  I32 count = 0;
  SV **keys;
  I32 i;
  if (!hv) {
    return av;
  }
  keys = gqljs_sorted_hash_keys(aTHX_ hv, &count);
  for (i = 0; i < count; i++) {
    STRLEN key_len;
    const char *key = SvPV(keys[i], key_len);
    SV **value_svp = hv_fetch(hv, key, (I32)key_len, 0);
    HV *src_hv;
    HV *dst_hv;
    SV *desc_sv;
    SV *args_sv;
    SV *dirs_sv;
    if (!value_svp || !SvROK(*value_svp) || SvTYPE(SvRV(*value_svp)) != SVt_PVHV) {
      continue;
    }
    src_hv = (HV *)SvRV(*value_svp);
    dst_hv = gqljs_new_node_hv("FieldDefinition");
    desc_sv = gqljs_fetch_sv(src_hv, "description");
    args_sv = gqljs_fetch_sv(src_hv, "args");
    dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    if (desc_sv) {
      gql_store_sv(dst_hv, "description", gqljs_new_description_node_sv(aTHX_ desc_sv));
    }
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ keys[i]));
    gql_store_sv(dst_hv, "arguments",
      (args_sv && SvROK(args_sv) && SvTYPE(SvRV(args_sv)) == SVt_PVHV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_input_value_definitions_hv(aTHX_ (HV *)SvRV(args_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "type", gqljs_convert_legacy_type_sv(aTHX_ gqljs_fetch_sv(src_hv, "type")));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    av_push(av, newRV_noinc((SV *)dst_hv));
  }
  gqljs_free_sorted_hash_keys(keys, count);
  return av;
}

static AV *
gqljs_convert_legacy_enum_values_hv(pTHX_ HV *hv) {
  AV *av = newAV();
  I32 count = 0;
  SV **keys;
  I32 i;
  if (!hv) {
    return av;
  }
  keys = gqljs_sorted_hash_keys(aTHX_ hv, &count);
  for (i = 0; i < count; i++) {
    STRLEN key_len;
    const char *key = SvPV(keys[i], key_len);
    SV **value_svp = hv_fetch(hv, key, (I32)key_len, 0);
    HV *src_hv;
    HV *dst_hv;
    SV *desc_sv;
    SV *dirs_sv;
    if (!value_svp || !SvROK(*value_svp) || SvTYPE(SvRV(*value_svp)) != SVt_PVHV) {
      continue;
    }
    src_hv = (HV *)SvRV(*value_svp);
    dst_hv = gqljs_new_node_hv("EnumValueDefinition");
    desc_sv = gqljs_fetch_sv(src_hv, "description");
    dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    if (desc_sv) {
      gql_store_sv(dst_hv, "description", gqljs_new_description_node_sv(aTHX_ desc_sv));
    }
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ keys[i]));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    av_push(av, newRV_noinc((SV *)dst_hv));
  }
  gqljs_free_sorted_hash_keys(keys, count);
  return av;
}

static SV *
gqljs_convert_legacy_definition_sv(pTHX_ SV *definition_sv) {
  HV *src_hv;
  STRLEN kind_len;
  const char *kind;
  HV *dst_hv;
  SV *name_sv;
  SV *dirs_sv;
  SV *desc_sv;

  if (!definition_sv || !SvROK(definition_sv) || SvTYPE(SvRV(definition_sv)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  src_hv = (HV *)SvRV(definition_sv);
  kind = SvPV(gqljs_fetch_sv(src_hv, "kind"), kind_len);

  if (strcmp(kind, "operation") == 0 || strcmp(kind, "fragment") == 0) {
    return gqljs_convert_legacy_executable_definition_sv(aTHX_ definition_sv);
  }

  if (strcmp(kind, "schema") == 0) {
    AV *operation_types = newAV();
    static const char *ops[] = { "query", "mutation", "subscription" };
    int i;
    dst_hv = gqljs_new_node_hv("SchemaDefinition");
    dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    for (i = 0; i < 3; i++) {
      SV *type_name_sv = gqljs_fetch_sv(src_hv, ops[i]);
      if (type_name_sv) {
        HV *op_hv = gqljs_new_node_hv("OperationTypeDefinition");
        HV *type_hv = gqljs_new_node_hv("NamedType");
        gql_store_sv(type_hv, "name", gqljs_new_name_node_sv(aTHX_ type_name_sv));
        gql_store_sv(op_hv, "operation", newSVpv(ops[i], 0));
        gql_store_sv(op_hv, "type", newRV_noinc((SV *)type_hv));
        av_push(operation_types, newRV_noinc((SV *)op_hv));
      }
    }
    gql_store_sv(dst_hv, "operationTypes", newRV_noinc((SV *)operation_types));
    return newRV_noinc((SV *)dst_hv);
  }

  if (strcmp(kind, "scalar") == 0) {
    dst_hv = gqljs_new_node_hv("ScalarTypeDefinition");
    desc_sv = gqljs_fetch_sv(src_hv, "description");
    name_sv = gqljs_fetch_sv(src_hv, "name");
    dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    if (desc_sv) {
      gql_store_sv(dst_hv, "description", gqljs_new_description_node_sv(aTHX_ desc_sv));
    }
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    return newRV_noinc((SV *)dst_hv);
  }

  if (strcmp(kind, "type") == 0) {
    SV *interfaces_sv = gqljs_fetch_sv(src_hv, "interfaces");
    SV *fields_sv = gqljs_fetch_sv(src_hv, "fields");
    dst_hv = gqljs_new_node_hv("ObjectTypeDefinition");
    desc_sv = gqljs_fetch_sv(src_hv, "description");
    name_sv = gqljs_fetch_sv(src_hv, "name");
    dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    if (desc_sv) {
      gql_store_sv(dst_hv, "description", gqljs_new_description_node_sv(aTHX_ desc_sv));
    }
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    gql_store_sv(dst_hv, "interfaces",
      (interfaces_sv && SvROK(interfaces_sv) && SvTYPE(SvRV(interfaces_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_named_types_av(aTHX_ (AV *)SvRV(interfaces_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "fields",
      (fields_sv && SvROK(fields_sv) && SvTYPE(SvRV(fields_sv)) == SVt_PVHV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_field_definitions_hv(aTHX_ (HV *)SvRV(fields_sv)))
        : newRV_noinc((SV *)newAV()));
    return newRV_noinc((SV *)dst_hv);
  }

  if (strcmp(kind, "interface") == 0) {
    SV *fields_sv = gqljs_fetch_sv(src_hv, "fields");
    dst_hv = gqljs_new_node_hv("InterfaceTypeDefinition");
    desc_sv = gqljs_fetch_sv(src_hv, "description");
    name_sv = gqljs_fetch_sv(src_hv, "name");
    dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    if (desc_sv) {
      gql_store_sv(dst_hv, "description", gqljs_new_description_node_sv(aTHX_ desc_sv));
    }
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    gql_store_sv(dst_hv, "interfaces", newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "fields",
      (fields_sv && SvROK(fields_sv) && SvTYPE(SvRV(fields_sv)) == SVt_PVHV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_field_definitions_hv(aTHX_ (HV *)SvRV(fields_sv)))
        : newRV_noinc((SV *)newAV()));
    return newRV_noinc((SV *)dst_hv);
  }

  if (strcmp(kind, "union") == 0) {
    SV *types_sv = gqljs_fetch_sv(src_hv, "types");
    dst_hv = gqljs_new_node_hv("UnionTypeDefinition");
    desc_sv = gqljs_fetch_sv(src_hv, "description");
    name_sv = gqljs_fetch_sv(src_hv, "name");
    dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    if (desc_sv) {
      gql_store_sv(dst_hv, "description", gqljs_new_description_node_sv(aTHX_ desc_sv));
    }
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "types",
      (types_sv && SvROK(types_sv) && SvTYPE(SvRV(types_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_named_types_av(aTHX_ (AV *)SvRV(types_sv)))
        : newRV_noinc((SV *)newAV()));
    return newRV_noinc((SV *)dst_hv);
  }

  if (strcmp(kind, "enum") == 0) {
    SV *values_sv = gqljs_fetch_sv(src_hv, "values");
    dst_hv = gqljs_new_node_hv("EnumTypeDefinition");
    desc_sv = gqljs_fetch_sv(src_hv, "description");
    name_sv = gqljs_fetch_sv(src_hv, "name");
    dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    if (desc_sv) {
      gql_store_sv(dst_hv, "description", gqljs_new_description_node_sv(aTHX_ desc_sv));
    }
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "values",
      (values_sv && SvROK(values_sv) && SvTYPE(SvRV(values_sv)) == SVt_PVHV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_enum_values_hv(aTHX_ (HV *)SvRV(values_sv)))
        : newRV_noinc((SV *)newAV()));
    return newRV_noinc((SV *)dst_hv);
  }

  if (strcmp(kind, "input") == 0) {
    SV *fields_sv = gqljs_fetch_sv(src_hv, "fields");
    dst_hv = gqljs_new_node_hv("InputObjectTypeDefinition");
    desc_sv = gqljs_fetch_sv(src_hv, "description");
    name_sv = gqljs_fetch_sv(src_hv, "name");
    dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    if (desc_sv) {
      gql_store_sv(dst_hv, "description", gqljs_new_description_node_sv(aTHX_ desc_sv));
    }
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "fields",
      (fields_sv && SvROK(fields_sv) && SvTYPE(SvRV(fields_sv)) == SVt_PVHV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_input_value_definitions_hv(aTHX_ (HV *)SvRV(fields_sv)))
        : newRV_noinc((SV *)newAV()));
    return newRV_noinc((SV *)dst_hv);
  }

  if (strcmp(kind, "directive") == 0) {
    SV *args_sv = gqljs_fetch_sv(src_hv, "args");
    SV *locations_sv = gqljs_fetch_sv(src_hv, "locations");
    dst_hv = gqljs_new_node_hv("DirectiveDefinition");
    desc_sv = gqljs_fetch_sv(src_hv, "description");
    name_sv = gqljs_fetch_sv(src_hv, "name");
    if (desc_sv) {
      gql_store_sv(dst_hv, "description", gqljs_new_description_node_sv(aTHX_ desc_sv));
    }
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    gql_store_sv(dst_hv, "arguments",
      (args_sv && SvROK(args_sv) && SvTYPE(SvRV(args_sv)) == SVt_PVHV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_input_value_definitions_hv(aTHX_ (HV *)SvRV(args_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "repeatable", newSViv(0));
    gql_store_sv(dst_hv, "locations",
      (locations_sv && SvROK(locations_sv) && SvTYPE(SvRV(locations_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_name_nodes_av(aTHX_ (AV *)SvRV(locations_sv)))
        : newRV_noinc((SV *)newAV()));
    return newRV_noinc((SV *)dst_hv);
  }

  return &PL_sv_undef;
}

static SV *
gqljs_convert_legacy_executable_definition_sv(pTHX_ SV *definition_sv) {
  HV *src_hv;
  STRLEN kind_len;
  const char *kind;
  HV *dst_hv;
  if (!definition_sv || !SvROK(definition_sv) || SvTYPE(SvRV(definition_sv)) != SVt_PVHV) {
    return &PL_sv_undef;
  }
  src_hv = (HV *)SvRV(definition_sv);
  kind = SvPV(gqljs_fetch_sv(src_hv, "kind"), kind_len);

  if (strcmp(kind, "operation") == 0) {
    SV *name_sv = gqljs_fetch_sv(src_hv, "name");
    SV *vars_sv = gqljs_fetch_sv(src_hv, "variables");
    SV *dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    SV *sels_sv = gqljs_fetch_sv(src_hv, "selections");
    dst_hv = gqljs_new_node_hv("OperationDefinition");
    {
      SV *operation_sv = gqljs_fetch_sv(src_hv, "operationType");
      gql_store_sv(dst_hv, "operation",
        operation_sv ? newSVsv(operation_sv) : newSVpv("query", 0));
    }
    if (name_sv) {
      gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    }
    gql_store_sv(dst_hv, "variableDefinitions",
      (vars_sv && SvROK(vars_sv) && SvTYPE(SvRV(vars_sv)) == SVt_PVHV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_variable_definitions_hv(aTHX_ (HV *)SvRV(vars_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "selectionSet",
      (sels_sv && SvROK(sels_sv) && SvTYPE(SvRV(sels_sv)) == SVt_PVAV)
        ? gqljs_convert_legacy_selection_set_av(aTHX_ (AV *)SvRV(sels_sv))
        : gqljs_convert_legacy_selection_set_av(aTHX_ newAV()));
    return newRV_noinc((SV *)dst_hv);
  }

  if (strcmp(kind, "fragment") == 0) {
    SV *name_sv = gqljs_fetch_sv(src_hv, "name");
    SV *on_sv = gqljs_fetch_sv(src_hv, "on");
    SV *dirs_sv = gqljs_fetch_sv(src_hv, "directives");
    SV *sels_sv = gqljs_fetch_sv(src_hv, "selections");
    HV *type_hv;
    dst_hv = gqljs_new_node_hv("FragmentDefinition");
    gql_store_sv(dst_hv, "name", gqljs_new_name_node_sv(aTHX_ name_sv));
    type_hv = gqljs_new_node_hv("NamedType");
    gql_store_sv(type_hv, "name", gqljs_new_name_node_sv(aTHX_ on_sv));
    gql_store_sv(dst_hv, "typeCondition", newRV_noinc((SV *)type_hv));
    gql_store_sv(dst_hv, "directives",
      (dirs_sv && SvROK(dirs_sv) && SvTYPE(SvRV(dirs_sv)) == SVt_PVAV)
        ? newRV_noinc((SV *)gqljs_convert_legacy_directives_av(aTHX_ (AV *)SvRV(dirs_sv)))
        : newRV_noinc((SV *)newAV()));
    gql_store_sv(dst_hv, "selectionSet",
      (sels_sv && SvROK(sels_sv) && SvTYPE(SvRV(sels_sv)) == SVt_PVAV)
        ? gqljs_convert_legacy_selection_set_av(aTHX_ (AV *)SvRV(sels_sv))
        : gqljs_convert_legacy_selection_set_av(aTHX_ newAV()));
    return newRV_noinc((SV *)dst_hv);
  }

  return &PL_sv_undef;
}

static SV *
gql_graphqljs_build_document(pTHX_ SV *legacy_sv) {
  AV *legacy_av;
  AV *definitions;
  HV *doc_hv;
  I32 i;

  if (!legacy_sv || !SvROK(legacy_sv) || SvTYPE(SvRV(legacy_sv)) != SVt_PVAV) {
    croak("graphqljs_build_document_xs expects an array reference");
  }

  legacy_av = (AV *)SvRV(legacy_sv);
  definitions = newAV();
  for (i = 0; i <= av_len(legacy_av); i++) {
    SV **svp = av_fetch(legacy_av, i, 0);
    SV *definition_sv;
    if (!svp) {
      continue;
    }
    definition_sv = gqljs_convert_legacy_definition_sv(aTHX_ *svp);
    if (!definition_sv || !SvOK(definition_sv) || definition_sv == &PL_sv_undef) {
      SvREFCNT_dec((SV *)definitions);
      return &PL_sv_undef;
    }
    av_push(definitions, definition_sv);
  }

  doc_hv = gqljs_new_node_hv("Document");
  gql_store_sv(doc_hv, "definitions", newRV_noinc((SV *)definitions));
  return newRV_noinc((SV *)doc_hv);
}

static SV *
gql_graphqljs_build_executable_document(pTHX_ SV *legacy_sv) {
  AV *legacy_av;
  AV *definitions;
  HV *doc_hv;
  I32 i;

  if (!legacy_sv || !SvROK(legacy_sv) || SvTYPE(SvRV(legacy_sv)) != SVt_PVAV) {
    croak("graphqljs_build_executable_document_xs expects an array reference");
  }
  legacy_av = (AV *)SvRV(legacy_sv);
  definitions = newAV();
  for (i = 0; i <= av_len(legacy_av); i++) {
    SV **svp = av_fetch(legacy_av, i, 0);
    SV *definition_sv;
    if (!svp) {
      continue;
    }
    definition_sv = gqljs_convert_legacy_executable_definition_sv(aTHX_ *svp);
    if (!definition_sv || !SvOK(definition_sv) || (definition_sv == &PL_sv_undef)) {
      SvREFCNT_dec((SV *)definitions);
      return &PL_sv_undef;
    }
    av_push(definitions, definition_sv);
  }

  doc_hv = gqljs_new_node_hv("Document");
  gql_store_sv(doc_hv, "definitions", newRV_noinc((SV *)definitions));
  return newRV_noinc((SV *)doc_hv);
}

static SV *
gql_graphqljs_build_directives_from_source(pTHX_ SV *source_sv) {
  SV *legacy_sv = gql_parse_directives_only(aTHX_ source_sv);
  AV *legacy_av;
  AV *directives_av;

  if (!legacy_sv || !SvROK(legacy_sv) || SvTYPE(SvRV(legacy_sv)) != SVt_PVAV) {
    return newRV_noinc((SV *)newAV());
  }

  legacy_av = (AV *)SvRV(legacy_sv);
  directives_av = gqljs_convert_legacy_directives_av(aTHX_ legacy_av);
  return newRV_noinc((SV *)directives_av);
}

static int
gqljs_legacy_document_is_executable(SV *legacy_sv) {
  AV *legacy_av;
  I32 i;

  if (!legacy_sv || !SvROK(legacy_sv) || SvTYPE(SvRV(legacy_sv)) != SVt_PVAV) {
    return 0;
  }

  legacy_av = (AV *)SvRV(legacy_sv);
  for (i = 0; i <= av_len(legacy_av); i++) {
    SV **svp = av_fetch(legacy_av, i, 0);
    HV *hv;
    SV *kind_sv;
    STRLEN len;
    const char *kind;

    if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVHV) {
      return 0;
    }
    hv = (HV *)SvRV(*svp);
    kind_sv = gqljs_fetch_sv(hv, "kind");
    if (!kind_sv) {
      return 0;
    }

    kind = SvPV(kind_sv, len);
    if (!(len == 9 && memcmp(kind, "operation", 9) == 0)
        && !(len == 8 && memcmp(kind, "fragment", 8) == 0)) {
      return 0;
    }
  }

  return 1;
}

static void
gqljs_materialize_operation_variable_directives(pTHX_ HV *meta_hv) {
  SV *operations_sv = gqljs_fetch_sv(meta_hv, "operation_variable_directives");
  AV *operations_av;
  I32 i;

  if (!operations_sv || !SvROK(operations_sv) || SvTYPE(SvRV(operations_sv)) != SVt_PVAV) {
    return;
  }

  operations_av = (AV *)SvRV(operations_sv);
  for (i = 0; i <= av_len(operations_av); i++) {
    SV **operation_svp = av_fetch(operations_av, i, 0);
    HV *operation_hv;
    SV **keys;
    I32 key_count;
    I32 j;

    if (!operation_svp || !SvROK(*operation_svp) || SvTYPE(SvRV(*operation_svp)) != SVt_PVHV) {
      continue;
    }

    operation_hv = (HV *)SvRV(*operation_svp);
    keys = gqljs_sorted_hash_keys(aTHX_ operation_hv, &key_count);
    for (j = 0; j < key_count; j++) {
      SV *key_sv = keys[j];
      STRLEN key_len;
      const char *key = SvPV(key_sv, key_len);
      SV **raw_svp = hv_fetch(operation_hv, key, (I32)key_len, 0);
      AV *raw_av;
      SV *joined;
      I32 k;

      if (!raw_svp || !SvROK(*raw_svp) || SvTYPE(SvRV(*raw_svp)) != SVt_PVAV) {
        continue;
      }

      raw_av = (AV *)SvRV(*raw_svp);
      joined = newSVpvn("", 0);
      for (k = 0; k <= av_len(raw_av); k++) {
        SV **text_svp = av_fetch(raw_av, k, 0);
        if (!text_svp) {
          continue;
        }
        if (SvCUR(joined) > 0) {
          sv_catpvn(joined, " ", 1);
        }
        sv_catsv(joined, *text_svp);
      }

      hv_store(operation_hv, key, (I32)key_len,
        gql_graphqljs_build_directives_from_source(aTHX_ joined), 0);
      SvREFCNT_dec(joined);
    }
    gqljs_free_sorted_hash_keys(keys, key_count);
  }
}

static int
gql_graphqljs_looks_like_executable_source(pTHX_ SV *source_sv) {
  STRLEN len;
  const char *src = SvPV(source_sv, len);
  STRLEN pos = 0;
  STRLEN start = 0;
  STRLEN end = 0;

  gqljs_skip_ignored_raw(src, len, &pos);
  if (pos >= len) {
    return 0;
  }
  if (src[pos] == '{') {
    return 1;
  }
  if (!gqljs_read_name_bounds(src, len, &pos, &start, &end)) {
    return 0;
  }

  return gqljs_match_word(src, start, end, "query")
    || gqljs_match_word(src, start, end, "mutation")
    || gqljs_match_word(src, start, end, "subscription")
    || gqljs_match_word(src, start, end, "fragment");
}

static SV *
gql_graphqljs_parse_document(pTHX_ SV *source_sv, SV *no_location_sv) {
  SV *meta_sv;
  HV *meta_hv;
  SV **rewritten_svp;
  SV *legacy_sv;
  SV *doc_sv;

  if (gql_graphqljs_looks_like_executable_source(aTHX_ source_sv)) {
    return gql_graphqljs_parse_executable_document(aTHX_ source_sv, no_location_sv);
  }

  meta_sv = gql_graphqljs_preprocess(aTHX_ source_sv);
  if (!meta_sv || !SvROK(meta_sv) || SvTYPE(SvRV(meta_sv)) != SVt_PVHV) {
    return &PL_sv_undef;
  }
  meta_hv = (HV *)SvRV(meta_sv);
  rewritten_svp = hv_fetch(meta_hv, "rewritten_source", 16, 0);
  if (!rewritten_svp) {
    return &PL_sv_undef;
  }

  legacy_sv = gql_parse_document(aTHX_ *rewritten_svp);
  if (!legacy_sv || !SvROK(legacy_sv) || SvTYPE(SvRV(legacy_sv)) != SVt_PVAV) {
    return &PL_sv_undef;
  }

  if (gqljs_legacy_document_is_executable(legacy_sv)) {
    doc_sv = gql_graphqljs_build_executable_document(aTHX_ legacy_sv);
  } else {
    doc_sv = gql_graphqljs_build_document(aTHX_ legacy_sv);
  }
  if (!doc_sv || !SvOK(doc_sv) || doc_sv == &PL_sv_undef) {
    return &PL_sv_undef;
  }

  gqljs_materialize_operation_variable_directives(aTHX_ meta_hv);
  doc_sv = gql_graphqljs_patch_document(aTHX_ doc_sv, meta_sv);
  if (SvTRUE(no_location_sv)) {
    return doc_sv;
  }

  return &PL_sv_undef;
}

static SV *
gql_graphqljs_parse_executable_document(pTHX_ SV *source_sv, SV *no_location_sv) {
  gql_ir_document_t *ir_document;
  SV *doc_sv;
  gqljs_loc_context_t ctx;
  gqljs_loc_context_t *ctx_ptr = NULL;

  ir_document = gql_ir_parse_executable_document(aTHX_ source_sv);
  if (!SvTRUE(no_location_sv)) {
    gqljs_loc_context_init(aTHX_ &ctx, source_sv, NULL);
    ctx_ptr = &ctx;
  }
  doc_sv = gqljs_build_executable_document_from_ir(aTHX_ ctx_ptr, ir_document);
  if (ctx_ptr) {
    gqljs_loc_context_destroy(ctx_ptr);
  }
  if (!doc_sv || !SvOK(doc_sv) || doc_sv == &PL_sv_undef) {
    gql_ir_free_document(ir_document);
    return &PL_sv_undef;
  }
  gql_ir_free_document(ir_document);

  return doc_sv;
}

static void
gql_ir_arena_init(gql_ir_arena_t *arena) {
  arena->head = NULL;
  arena->tail = NULL;
}

static void *
gql_ir_arena_alloc_zero(gql_ir_arena_t *arena, Size_t size) {
  gql_ir_arena_chunk_t *chunk;
  Size_t aligned_used;
  Size_t next_used;
  Size_t chunk_cap;
  char *ptr;

  chunk = arena->tail;
  aligned_used = chunk ? ((chunk->used + sizeof(void *) - 1) & ~(sizeof(void *) - 1)) : 0;
  next_used = aligned_used + size;
  if (!chunk || next_used > chunk->cap) {
    chunk_cap = 4096;
    while (chunk_cap < size) {
      chunk_cap *= 2;
    }
    Newxz(chunk, 1, gql_ir_arena_chunk_t);
    Newx(chunk->buf, chunk_cap, char);
    chunk->cap = chunk_cap;
    if (arena->tail) {
      arena->tail->next = chunk;
    } else {
      arena->head = chunk;
    }
    arena->tail = chunk;
    aligned_used = 0;
    next_used = size;
  }
  ptr = chunk->buf + aligned_used;
  Zero(ptr, size, char);
  chunk->used = next_used;
  return ptr;
}

static void
gql_ir_arena_free(gql_ir_arena_t *arena) {
  gql_ir_arena_chunk_t *chunk = arena->head;

  while (chunk) {
    gql_ir_arena_chunk_t *next = chunk->next;
    if (chunk->buf) {
      Safefree(chunk->buf);
    }
    Safefree(chunk);
    chunk = next;
  }
  arena->head = NULL;
  arena->tail = NULL;
}

static void
gql_ir_ptr_array_push(gql_ir_ptr_array_t *array, void *item) {
  if (array->count == array->cap) {
    I32 next_cap = array->cap ? array->cap * 2 : 4;
    Renew(array->items, next_cap, void *);
    array->cap = next_cap;
  }
  array->items[array->count++] = item;
}

static void
gql_ir_ptr_array_free(gql_ir_ptr_array_t *array) {
  if (array->items) {
    Safefree(array->items);
  }
  array->items = NULL;
  array->count = 0;
  array->cap = 0;
}

static gql_ir_type_t *
gql_ir_parse_type_reference(pTHX_ gql_parser_t *p) {
  gql_ir_type_t *type;
  UV start_pos = (UV)p->tok_start;

  type = (gql_ir_type_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_type_t));
  type->start_pos = start_pos;
  if (p->kind == TOK_LBRACKET) {
    type->kind = GQL_IR_TYPE_LIST;
    gql_advance(aTHX_ p);
    type->inner = gql_ir_parse_type_reference(aTHX_ p);
    gql_expect(aTHX_ p, TOK_RBRACKET, NULL);
  } else {
    type->kind = GQL_IR_TYPE_NAMED;
    type->name = gql_parse_name(aTHX_ p, "Expected name");
  }

  if (p->kind == TOK_BANG) {
    gql_ir_type_t *wrapped;
    gql_advance(aTHX_ p);
    wrapped = (gql_ir_type_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_type_t));
    wrapped->kind = GQL_IR_TYPE_NON_NULL;
    wrapped->start_pos = type->start_pos;
    wrapped->inner = type;
    type = wrapped;
  }

  return type;
}

static gql_ir_value_t *
gql_ir_parse_value(pTHX_ gql_parser_t *p, int is_const) {
  gql_ir_value_t *value;
  UV start_pos = (UV)p->tok_start;

  value = (gql_ir_value_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_value_t));
  value->start_pos = start_pos;
  switch (p->kind) {
    case TOK_DOLLAR:
      if (is_const) {
        gql_throw(aTHX_ p, p->tok_start, "Expected name or constant");
      }
      value->kind = GQL_IR_VALUE_VARIABLE;
      gql_advance(aTHX_ p);
      value->name_pos = (UV)p->tok_start;
      value->as.sv = gql_parse_name(aTHX_ p, "Expected name");
      return value;
    case TOK_INT:
      value->kind = GQL_IR_VALUE_INT;
      value->as.sv = gql_copy_token_sv(aTHX_ p);
      gql_advance(aTHX_ p);
      return value;
    case TOK_FLOAT:
      value->kind = GQL_IR_VALUE_FLOAT;
      value->as.sv = gql_copy_token_sv(aTHX_ p);
      gql_advance(aTHX_ p);
      return value;
    case TOK_STRING:
    case TOK_BLOCK_STRING:
      value->kind = GQL_IR_VALUE_STRING;
      value->as.sv = gql_copy_value_sv(aTHX_ p);
      gql_advance(aTHX_ p);
      return value;
    case TOK_NAME:
      if (gql_peek_name(p, "true")) {
        value->kind = GQL_IR_VALUE_BOOL;
        value->as.boolean = 1;
        gql_advance(aTHX_ p);
        return value;
      }
      if (gql_peek_name(p, "false")) {
        value->kind = GQL_IR_VALUE_BOOL;
        value->as.boolean = 0;
        gql_advance(aTHX_ p);
        return value;
      }
      if (gql_peek_name(p, "null")) {
        value->kind = GQL_IR_VALUE_NULL;
        gql_advance(aTHX_ p);
        return value;
      }
      value->kind = GQL_IR_VALUE_ENUM;
      value->as.sv = gql_copy_token_sv(aTHX_ p);
      gql_advance(aTHX_ p);
      return value;
    case TOK_LBRACKET:
      value->kind = GQL_IR_VALUE_LIST;
      gql_expect(aTHX_ p, TOK_LBRACKET, NULL);
      while (p->kind != TOK_RBRACKET) {
        gql_ir_ptr_array_push(&value->as.list_items, gql_ir_parse_value(aTHX_ p, is_const));
      }
      gql_expect(aTHX_ p, TOK_RBRACKET, NULL);
      return value;
    case TOK_LBRACE:
      value->kind = GQL_IR_VALUE_OBJECT;
      gql_expect(aTHX_ p, TOK_LBRACE, "Expected name");
      while (p->kind != TOK_RBRACE) {
        gql_ir_object_field_t *field;
        field = (gql_ir_object_field_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_object_field_t));
        field->start_pos = (UV)p->tok_start;
        field->name = gql_parse_name(aTHX_ p, "Expected name");
        gql_expect(aTHX_ p, TOK_COLON, NULL);
        field->value = gql_ir_parse_value(aTHX_ p, is_const);
        gql_ir_ptr_array_push(&value->as.object_fields, field);
      }
      gql_expect(aTHX_ p, TOK_RBRACE, NULL);
      return value;
    default:
      gql_throw(aTHX_ p, p->tok_start, is_const ? "Expected name or constant" : "Expected value");
  }
  return NULL;
}

static gql_ir_ptr_array_t
gql_ir_parse_arguments(pTHX_ gql_parser_t *p, int is_const) {
  gql_ir_ptr_array_t arguments = { 0, 0, NULL };

  gql_expect(aTHX_ p, TOK_LPAREN, NULL);
  if (p->kind == TOK_RPAREN) {
    gql_throw_expected_message(aTHX_ p, p->tok_start, "Expected name");
  }
  while (p->kind != TOK_RPAREN) {
    gql_ir_argument_t *argument;
    argument = (gql_ir_argument_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_argument_t));
    argument->start_pos = (UV)p->tok_start;
    argument->name = gql_parse_name(aTHX_ p, "Expected name");
    gql_expect(aTHX_ p, TOK_COLON, NULL);
    argument->value = gql_ir_parse_value(aTHX_ p, is_const);
    gql_ir_ptr_array_push(&arguments, argument);
  }
  gql_expect(aTHX_ p, TOK_RPAREN, NULL);
  return arguments;
}

static gql_ir_ptr_array_t
gql_ir_parse_directives(pTHX_ gql_parser_t *p) {
  gql_ir_ptr_array_t directives = { 0, 0, NULL };

  while (p->kind == TOK_AT) {
    gql_ir_directive_t *directive;
    directive = (gql_ir_directive_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_directive_t));
    directive->start_pos = (UV)p->tok_start;
    gql_expect(aTHX_ p, TOK_AT, NULL);
    directive->name_pos = (UV)p->tok_start;
    directive->name = gql_parse_name(aTHX_ p, "Expected name");
    if (p->kind == TOK_LPAREN) {
      directive->arguments = gql_ir_parse_arguments(aTHX_ p, 0);
    }
    gql_ir_ptr_array_push(&directives, directive);
  }

  return directives;
}

static gql_ir_selection_set_t *
gql_ir_parse_selection_set(pTHX_ gql_parser_t *p) {
  gql_ir_selection_set_t *selection_set;

  selection_set = (gql_ir_selection_set_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_selection_set_t));
  selection_set->start_pos = (UV)p->tok_start;
  gql_expect(aTHX_ p, TOK_LBRACE, "Expected name");
  if (p->kind == TOK_RBRACE) {
    gql_throw(aTHX_ p, p->tok_start, "Expected name");
  }
  while (p->kind != TOK_RBRACE) {
    gql_ir_ptr_array_push(&selection_set->selections, gql_ir_parse_selection(aTHX_ p));
  }
  gql_expect(aTHX_ p, TOK_RBRACE, NULL);
  return selection_set;
}

static gql_ir_selection_t *
gql_ir_parse_selection(pTHX_ gql_parser_t *p) {
  gql_ir_selection_t *selection;

  selection = (gql_ir_selection_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_selection_t));
  if (p->kind == TOK_SPREAD) {
    UV spread_start = (UV)p->tok_start;
    gql_advance(aTHX_ p);
    if (gql_peek_name(p, "on")) {
      gql_parser_t lookahead = *p;
      gql_ir_inline_fragment_t *fragment;
      gql_advance(aTHX_ &lookahead);
      if (lookahead.kind != TOK_NAME) {
        gql_throw(aTHX_ p, p->tok_start, "Unexpected Name \"on\"");
      }
      selection->kind = GQL_IR_SELECTION_INLINE_FRAGMENT;
      fragment = (gql_ir_inline_fragment_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_inline_fragment_t));
      fragment->start_pos = spread_start;
      gql_advance(aTHX_ p);
      fragment->type_condition_pos = (UV)p->tok_start;
      fragment->type_condition = gql_parse_name(aTHX_ p, "Expected name");
      if (p->kind == TOK_AT) {
        fragment->directives = gql_ir_parse_directives(aTHX_ p);
      }
      fragment->selection_set = gql_ir_parse_selection_set(aTHX_ p);
      selection->as.inline_fragment = fragment;
      return selection;
    }
    if (p->kind == TOK_LBRACE || p->kind == TOK_AT) {
      gql_ir_inline_fragment_t *fragment;
      selection->kind = GQL_IR_SELECTION_INLINE_FRAGMENT;
      fragment = (gql_ir_inline_fragment_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_inline_fragment_t));
      fragment->start_pos = spread_start;
      if (p->kind == TOK_AT) {
        fragment->directives = gql_ir_parse_directives(aTHX_ p);
      }
      fragment->selection_set = gql_ir_parse_selection_set(aTHX_ p);
      selection->as.inline_fragment = fragment;
      return selection;
    }
    {
      gql_ir_fragment_spread_t *spread;
      selection->kind = GQL_IR_SELECTION_FRAGMENT_SPREAD;
      spread = (gql_ir_fragment_spread_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_fragment_spread_t));
      spread->start_pos = spread_start;
      spread->name_pos = (UV)p->tok_start;
      spread->name = gql_parse_fragment_name(aTHX_ p);
      if (p->kind == TOK_AT) {
        spread->directives = gql_ir_parse_directives(aTHX_ p);
      }
      selection->as.fragment_spread = spread;
      return selection;
    }
  }

  {
    gql_ir_field_t *field;
    SV *first_name;
    selection->kind = GQL_IR_SELECTION_FIELD;
    field = (gql_ir_field_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_field_t));
    field->start_pos = (UV)p->tok_start;
    field->name_pos = (UV)p->tok_start;
    first_name = gql_parse_name(aTHX_ p, "Expected name");
    if (p->kind == TOK_COLON) {
      field->alias_pos = field->name_pos;
      field->alias = first_name;
      gql_advance(aTHX_ p);
      field->name_pos = (UV)p->tok_start;
      field->name = gql_parse_name(aTHX_ p, "Expected name");
    } else {
      field->name = first_name;
    }
    if (p->kind == TOK_LPAREN) {
      field->arguments = gql_ir_parse_arguments(aTHX_ p, 0);
    }
    if (p->kind == TOK_AT) {
      field->directives = gql_ir_parse_directives(aTHX_ p);
    }
    if (p->kind == TOK_LBRACE) {
      field->selection_set = gql_ir_parse_selection_set(aTHX_ p);
    }
    selection->as.field = field;
    return selection;
  }
}

static gql_ir_ptr_array_t
gql_ir_parse_variable_definitions(pTHX_ gql_parser_t *p) {
  gql_ir_ptr_array_t definitions = { 0, 0, NULL };

  gql_expect(aTHX_ p, TOK_LPAREN, NULL);
  if (p->kind == TOK_RPAREN) {
    gql_throw(aTHX_ p, p->tok_start, "Expected $argument: Type");
  }
  while (p->kind != TOK_RPAREN) {
    gql_ir_variable_definition_t *definition;
    definition = (gql_ir_variable_definition_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_variable_definition_t));
    definition->start_pos = (UV)p->tok_start;
    gql_expect(aTHX_ p, TOK_DOLLAR, NULL);
    definition->name_pos = (UV)p->tok_start;
    definition->name = gql_parse_name(aTHX_ p, "Expected name");
    gql_expect(aTHX_ p, TOK_COLON, NULL);
    definition->type = gql_ir_parse_type_reference(aTHX_ p);
    if (p->kind == TOK_EQUALS) {
      gql_advance(aTHX_ p);
      definition->default_value = gql_ir_parse_value(aTHX_ p, 1);
    }
    if (p->kind == TOK_AT) {
      definition->directives = gql_ir_parse_directives(aTHX_ p);
    }
    gql_ir_ptr_array_push(&definitions, definition);
  }
  gql_expect(aTHX_ p, TOK_RPAREN, NULL);
  return definitions;
}

static gql_ir_operation_definition_t *
gql_ir_parse_operation_definition(pTHX_ gql_parser_t *p) {
  gql_ir_operation_definition_t *definition;

  definition = (gql_ir_operation_definition_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_operation_definition_t));
  definition->operation = GQL_IR_OPERATION_QUERY;
  definition->start_pos = (UV)p->tok_start;
  if (p->kind == TOK_LBRACE) {
    definition->selection_set = gql_ir_parse_selection_set(aTHX_ p);
    return definition;
  }

  if (!(gql_peek_name(p, "query") || gql_peek_name(p, "mutation") || gql_peek_name(p, "subscription"))) {
    gql_throw(aTHX_ p, p->tok_start, "Expected executable definition");
  }
  if (gql_peek_name(p, "mutation")) {
    definition->operation = GQL_IR_OPERATION_MUTATION;
  } else if (gql_peek_name(p, "subscription")) {
    definition->operation = GQL_IR_OPERATION_SUBSCRIPTION;
  }
  gql_advance(aTHX_ p);
  if (p->kind == TOK_NAME) {
    definition->name_pos = (UV)p->tok_start;
    definition->name = gql_parse_name(aTHX_ p, "Expected name");
  }
  if (p->kind == TOK_LPAREN) {
    definition->variable_definitions = gql_ir_parse_variable_definitions(aTHX_ p);
  }
  if (p->kind == TOK_AT) {
    definition->directives = gql_ir_parse_directives(aTHX_ p);
  }
  definition->selection_set = gql_ir_parse_selection_set(aTHX_ p);
  return definition;
}

static gql_ir_fragment_definition_t *
gql_ir_parse_fragment_definition(pTHX_ gql_parser_t *p) {
  gql_ir_fragment_definition_t *definition;

  definition = (gql_ir_fragment_definition_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_fragment_definition_t));
  definition->start_pos = (UV)p->tok_start;
  gql_advance(aTHX_ p);
  definition->name_pos = (UV)p->tok_start;
  definition->name = gql_parse_fragment_name(aTHX_ p);
  if (!gql_peek_name(p, "on")) {
    gql_throw(aTHX_ p, p->tok_start, "Expected \"on\"");
  }
  gql_advance(aTHX_ p);
  definition->type_condition_pos = (UV)p->tok_start;
  definition->type_condition = gql_parse_name(aTHX_ p, "Expected name");
  if (p->kind == TOK_AT) {
    definition->directives = gql_ir_parse_directives(aTHX_ p);
  }
  definition->selection_set = gql_ir_parse_selection_set(aTHX_ p);
  return definition;
}

static gql_ir_definition_t *
gql_ir_parse_executable_definition(pTHX_ gql_parser_t *p) {
  gql_ir_definition_t *definition;

  definition = (gql_ir_definition_t *)gql_ir_arena_alloc_zero(p->ir_arena, sizeof(gql_ir_definition_t));
  if (p->kind == TOK_LBRACE
      || gql_peek_name(p, "query")
      || gql_peek_name(p, "mutation")
      || gql_peek_name(p, "subscription")) {
    definition->kind = GQL_IR_DEFINITION_OPERATION;
    definition->as.operation = gql_ir_parse_operation_definition(aTHX_ p);
    return definition;
  }
  if (gql_peek_name(p, "fragment")) {
    definition->kind = GQL_IR_DEFINITION_FRAGMENT;
    definition->as.fragment = gql_ir_parse_fragment_definition(aTHX_ p);
    return definition;
  }

  gql_throw(aTHX_ p, p->tok_start, "Expected executable definition");
  return NULL;
}

static gql_ir_document_t *
gql_ir_parse_executable_document(pTHX_ SV *source_sv) {
  gql_parser_t p;
  STRLEN len;
  const char *src = SvPV(source_sv, len);
  gql_ir_document_t *document;

  Newxz(document, 1, gql_ir_document_t);
  gql_ir_arena_init(&document->arena);
  p.src = src;
  p.len = len;
  p.pos = 0;
  p.last_pos = (STRLEN)-1;
  p.tok_start = 0;
  p.tok_end = 0;
  p.val_start = 0;
  p.val_end = 0;
  p.kind = TOK_EOF;
  p.is_utf8 = SvUTF8(source_sv) ? 1 : 0;
  p.ir_arena = &document->arena;

  gql_advance(aTHX_ &p);
  while (p.kind != TOK_EOF) {
    gql_ir_ptr_array_push(&document->definitions, gql_ir_parse_executable_definition(aTHX_ &p));
  }
  return document;
}

static void
gql_ir_free_type(gql_ir_type_t *type) {
  if (!type) {
    return;
  }
  if (type->name) {
    SvREFCNT_dec(type->name);
  }
  gql_ir_free_type(type->inner);
}

static void
gql_ir_free_argument(gql_ir_argument_t *argument) {
  if (!argument) {
    return;
  }
  if (argument->name) {
    SvREFCNT_dec(argument->name);
  }
  gql_ir_free_value(argument->value);
}

static void
gql_ir_free_object_field(gql_ir_object_field_t *field) {
  if (!field) {
    return;
  }
  if (field->name) {
    SvREFCNT_dec(field->name);
  }
  gql_ir_free_value(field->value);
}

static void
gql_ir_free_value(gql_ir_value_t *value) {
  I32 i;

  if (!value) {
    return;
  }
  switch (value->kind) {
    case GQL_IR_VALUE_INT:
    case GQL_IR_VALUE_FLOAT:
    case GQL_IR_VALUE_STRING:
    case GQL_IR_VALUE_ENUM:
    case GQL_IR_VALUE_VARIABLE:
      if (value->as.sv) {
        SvREFCNT_dec(value->as.sv);
      }
      break;
    case GQL_IR_VALUE_LIST:
      for (i = 0; i < value->as.list_items.count; i++) {
        gql_ir_free_value((gql_ir_value_t *)value->as.list_items.items[i]);
      }
      gql_ir_ptr_array_free(&value->as.list_items);
      break;
    case GQL_IR_VALUE_OBJECT:
      for (i = 0; i < value->as.object_fields.count; i++) {
        gql_ir_free_object_field((gql_ir_object_field_t *)value->as.object_fields.items[i]);
      }
      gql_ir_ptr_array_free(&value->as.object_fields);
      break;
    default:
      break;
  }
}

static void
gql_ir_free_directive(gql_ir_directive_t *directive) {
  I32 i;

  if (!directive) {
    return;
  }
  if (directive->name) {
    SvREFCNT_dec(directive->name);
  }
  for (i = 0; i < directive->arguments.count; i++) {
    gql_ir_free_argument((gql_ir_argument_t *)directive->arguments.items[i]);
  }
  gql_ir_ptr_array_free(&directive->arguments);
}

static void
gql_ir_free_variable_definition(gql_ir_variable_definition_t *definition) {
  I32 i;

  if (!definition) {
    return;
  }
  if (definition->name) {
    SvREFCNT_dec(definition->name);
  }
  gql_ir_free_type(definition->type);
  gql_ir_free_value(definition->default_value);
  for (i = 0; i < definition->directives.count; i++) {
    gql_ir_free_directive((gql_ir_directive_t *)definition->directives.items[i]);
  }
  gql_ir_ptr_array_free(&definition->directives);
}

static void
gql_ir_free_selection_set(gql_ir_selection_set_t *selection_set) {
  I32 i;

  if (!selection_set) {
    return;
  }
  for (i = 0; i < selection_set->selections.count; i++) {
    gql_ir_free_selection((gql_ir_selection_t *)selection_set->selections.items[i]);
  }
  gql_ir_ptr_array_free(&selection_set->selections);
}

static void
gql_ir_free_selection(gql_ir_selection_t *selection) {
  if (!selection) {
    return;
  }
  switch (selection->kind) {
    case GQL_IR_SELECTION_FIELD:
      if (selection->as.field) {
        gql_ir_field_t *field = selection->as.field;
        I32 i;
        if (field->alias) {
          SvREFCNT_dec(field->alias);
        }
        if (field->name) {
          SvREFCNT_dec(field->name);
        }
        for (i = 0; i < field->arguments.count; i++) {
          gql_ir_free_argument((gql_ir_argument_t *)field->arguments.items[i]);
        }
        gql_ir_ptr_array_free(&field->arguments);
        for (i = 0; i < field->directives.count; i++) {
          gql_ir_free_directive((gql_ir_directive_t *)field->directives.items[i]);
        }
        gql_ir_ptr_array_free(&field->directives);
        gql_ir_free_selection_set(field->selection_set);
      }
      break;
    case GQL_IR_SELECTION_FRAGMENT_SPREAD:
      if (selection->as.fragment_spread) {
        gql_ir_fragment_spread_t *spread = selection->as.fragment_spread;
        I32 i;
        if (spread->name) {
          SvREFCNT_dec(spread->name);
        }
        for (i = 0; i < spread->directives.count; i++) {
          gql_ir_free_directive((gql_ir_directive_t *)spread->directives.items[i]);
        }
        gql_ir_ptr_array_free(&spread->directives);
      }
      break;
    case GQL_IR_SELECTION_INLINE_FRAGMENT:
      if (selection->as.inline_fragment) {
        gql_ir_inline_fragment_t *fragment = selection->as.inline_fragment;
        I32 i;
        if (fragment->type_condition) {
          SvREFCNT_dec(fragment->type_condition);
        }
        for (i = 0; i < fragment->directives.count; i++) {
          gql_ir_free_directive((gql_ir_directive_t *)fragment->directives.items[i]);
        }
        gql_ir_ptr_array_free(&fragment->directives);
        gql_ir_free_selection_set(fragment->selection_set);
      }
      break;
  }
}

static void
gql_ir_free_operation_definition(gql_ir_operation_definition_t *definition) {
  I32 i;

  if (!definition) {
    return;
  }
  if (definition->name) {
    SvREFCNT_dec(definition->name);
  }
  for (i = 0; i < definition->variable_definitions.count; i++) {
    gql_ir_free_variable_definition((gql_ir_variable_definition_t *)definition->variable_definitions.items[i]);
  }
  gql_ir_ptr_array_free(&definition->variable_definitions);
  for (i = 0; i < definition->directives.count; i++) {
    gql_ir_free_directive((gql_ir_directive_t *)definition->directives.items[i]);
  }
  gql_ir_ptr_array_free(&definition->directives);
  gql_ir_free_selection_set(definition->selection_set);
}

static void
gql_ir_free_fragment_definition(gql_ir_fragment_definition_t *definition) {
  I32 i;

  if (!definition) {
    return;
  }
  if (definition->name) {
    SvREFCNT_dec(definition->name);
  }
  if (definition->type_condition) {
    SvREFCNT_dec(definition->type_condition);
  }
  for (i = 0; i < definition->directives.count; i++) {
    gql_ir_free_directive((gql_ir_directive_t *)definition->directives.items[i]);
  }
  gql_ir_ptr_array_free(&definition->directives);
  gql_ir_free_selection_set(definition->selection_set);
}

static void
gql_ir_free_definition(gql_ir_definition_t *definition) {
  if (!definition) {
    return;
  }
  if (definition->kind == GQL_IR_DEFINITION_OPERATION) {
    gql_ir_free_operation_definition(definition->as.operation);
  } else {
    gql_ir_free_fragment_definition(definition->as.fragment);
  }
}

static void
gql_ir_free_document(gql_ir_document_t *document) {
  I32 i;

  if (!document) {
    return;
  }
  for (i = 0; i < document->definitions.count; i++) {
    gql_ir_free_definition((gql_ir_definition_t *)document->definitions.items[i]);
  }
  gql_ir_ptr_array_free(&document->definitions);
  gql_ir_arena_free(&document->arena);
  Safefree(document);
}

static SV *
gqljs_build_type_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_type_t *type) {
  HV *hv;
  SV *node_sv;
  SV *name_sv;

  if (!type) {
    return &PL_sv_undef;
  }
  if (type->kind == GQL_IR_TYPE_NAMED) {
    node_sv = gqljs_new_named_type_node_sv(aTHX_ type->name);
    if (ctx) {
      SV *type_loc = gqljs_loc_from_rewritten_pos(aTHX_ ctx, type->start_pos);
      gqljs_set_loc_node(aTHX_ node_sv, type_loc);
      name_sv = gqljs_fetch_sv(gqljs_node_hv(node_sv), "name");
      gqljs_set_loc_node(aTHX_ name_sv, type_loc);
      SvREFCNT_dec(type_loc);
    }
    return node_sv;
  }

  hv = gqljs_new_node_hv_sized(type->kind == GQL_IR_TYPE_LIST ? "ListType" : "NonNullType", 2);
  node_sv = gqljs_build_type_from_ir(aTHX_ ctx, type->inner);
  hv_stores(hv, "type", node_sv);
  node_sv = newRV_noinc((SV *)hv);
  if (ctx) {
    gqljs_set_rewritten_loc_node(aTHX_ ctx, node_sv, type->start_pos);
  }
  return node_sv;
}

static SV *
gqljs_build_value_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_value_t *value) {
  HV *hv;
  I32 i;
  SV *node_sv;
  SV *name_sv;

  if (!value) {
    return &PL_sv_undef;
  }
  switch (value->kind) {
    case GQL_IR_VALUE_NULL:
      node_sv = gqljs_new_node_ref("NullValue");
      break;
    case GQL_IR_VALUE_BOOL:
      hv = gqljs_new_node_hv_sized("BooleanValue", 2);
      hv_stores(hv, "value", newSViv(value->as.boolean ? 1 : 0));
      node_sv = newRV_noinc((SV *)hv);
      break;
    case GQL_IR_VALUE_INT:
      hv = gqljs_new_node_hv_sized("IntValue", 2);
      hv_stores(hv, "value", SvREFCNT_inc_simple_NN(value->as.sv));
      node_sv = newRV_noinc((SV *)hv);
      break;
    case GQL_IR_VALUE_FLOAT:
      hv = gqljs_new_node_hv_sized("FloatValue", 2);
      hv_stores(hv, "value", SvREFCNT_inc_simple_NN(value->as.sv));
      node_sv = newRV_noinc((SV *)hv);
      break;
    case GQL_IR_VALUE_STRING:
      hv = gqljs_new_node_hv_sized("StringValue", 2);
      hv_stores(hv, "value", SvREFCNT_inc_simple_NN(value->as.sv));
      node_sv = newRV_noinc((SV *)hv);
      break;
    case GQL_IR_VALUE_ENUM:
      hv = gqljs_new_node_hv_sized("EnumValue", 2);
      hv_stores(hv, "value", SvREFCNT_inc_simple_NN(value->as.sv));
      node_sv = newRV_noinc((SV *)hv);
      break;
    case GQL_IR_VALUE_VARIABLE:
      node_sv = gqljs_new_variable_node_sv(aTHX_ value->as.sv);
      if (ctx) {
        gqljs_set_rewritten_loc_node(aTHX_ ctx, node_sv, value->start_pos);
        name_sv = gqljs_fetch_sv(gqljs_node_hv(node_sv), "name");
        gqljs_set_rewritten_loc_node(aTHX_ ctx, name_sv, value->name_pos);
      }
      return node_sv;
    case GQL_IR_VALUE_LIST: {
      AV *items = newAV();
      hv = gqljs_new_node_hv_sized("ListValue", 2);
      if (value->as.list_items.count > 0) {
        av_extend(items, value->as.list_items.count - 1);
      }
      for (i = 0; i < value->as.list_items.count; i++) {
        av_push(items, gqljs_build_value_from_ir(aTHX_ ctx, (gql_ir_value_t *)value->as.list_items.items[i]));
      }
      hv_stores(hv, "values", newRV_noinc((SV *)items));
      node_sv = newRV_noinc((SV *)hv);
      break;
    }
    case GQL_IR_VALUE_OBJECT: {
      AV *fields = newAV();
      hv = gqljs_new_node_hv_sized("ObjectValue", 2);
      if (value->as.object_fields.count > 0) {
        av_extend(fields, value->as.object_fields.count - 1);
      }
      for (i = 0; i < value->as.object_fields.count; i++) {
        gql_ir_object_field_t *field = (gql_ir_object_field_t *)value->as.object_fields.items[i];
        HV *field_hv = gqljs_new_node_hv_sized("ObjectField", 3);
        SV *field_sv;
        SV *field_name_sv = gqljs_new_name_node_sv(aTHX_ field->name);
        hv_stores(field_hv, "name", field_name_sv);
        hv_stores(field_hv, "value", gqljs_build_value_from_ir(aTHX_ ctx, field->value));
        field_sv = newRV_noinc((SV *)field_hv);
        if (ctx) {
          SV *field_loc = gqljs_loc_from_rewritten_pos(aTHX_ ctx, field->start_pos);
          gqljs_set_loc_node(aTHX_ field_sv, field_loc);
          gqljs_set_loc_node(aTHX_ field_name_sv, field_loc);
          SvREFCNT_dec(field_loc);
        }
        av_push(fields, field_sv);
      }
      hv_stores(hv, "fields", newRV_noinc((SV *)fields));
      node_sv = newRV_noinc((SV *)hv);
      break;
    }
  }

  if (ctx && node_sv && node_sv != &PL_sv_undef) {
    gqljs_set_rewritten_loc_node(aTHX_ ctx, node_sv, value->start_pos);
  }
  return node_sv;
}

static AV *
gqljs_build_arguments_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_ptr_array_t *arguments) {
  AV *av = newAV();
  I32 i;

  if (!arguments) {
    return av;
  }
  if (arguments->count > 0) {
    av_extend(av, arguments->count - 1);
  }
  for (i = 0; i < arguments->count; i++) {
    gql_ir_argument_t *argument = (gql_ir_argument_t *)arguments->items[i];
    HV *arg_hv = gqljs_new_node_hv_sized("Argument", 3);
    SV *arg_sv;
    SV *name_sv = gqljs_new_name_node_sv(aTHX_ argument->name);
    hv_stores(arg_hv, "name", name_sv);
    hv_stores(arg_hv, "value", gqljs_build_value_from_ir(aTHX_ ctx, argument->value));
    arg_sv = newRV_noinc((SV *)arg_hv);
    if (ctx) {
      SV *arg_loc = gqljs_loc_from_rewritten_pos(aTHX_ ctx, argument->start_pos);
      gqljs_set_loc_node(aTHX_ arg_sv, arg_loc);
      gqljs_set_loc_node(aTHX_ name_sv, arg_loc);
      SvREFCNT_dec(arg_loc);
    }
    av_push(av, arg_sv);
  }
  return av;
}

static AV *
gqljs_build_directives_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_ptr_array_t *directives) {
  AV *av = newAV();
  I32 i;

  if (!directives) {
    return av;
  }
  if (directives->count > 0) {
    av_extend(av, directives->count - 1);
  }
  for (i = 0; i < directives->count; i++) {
    gql_ir_directive_t *directive = (gql_ir_directive_t *)directives->items[i];
    HV *dir_hv = gqljs_new_node_hv_sized("Directive", 3);
    SV *dir_sv;
    SV *name_sv = gqljs_new_name_node_sv(aTHX_ directive->name);
    hv_stores(dir_hv, "name", name_sv);
    hv_stores(dir_hv, "arguments", newRV_noinc((SV *)gqljs_build_arguments_from_ir(aTHX_ ctx, &directive->arguments)));
    dir_sv = newRV_noinc((SV *)dir_hv);
    if (ctx) {
      gqljs_set_rewritten_loc_node(aTHX_ ctx, dir_sv, directive->start_pos);
      gqljs_set_rewritten_loc_node(aTHX_ ctx, name_sv, directive->name_pos);
    }
    av_push(av, dir_sv);
  }
  return av;
}

static SV *
gqljs_build_selection_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_selection_t *selection) {
  HV *hv;
  SV *node_sv;

  if (!selection) {
    return &PL_sv_undef;
  }
  switch (selection->kind) {
    case GQL_IR_SELECTION_FIELD: {
      gql_ir_field_t *field = selection->as.field;
      hv = gqljs_new_node_hv_sized("Field", 6);
      if (field->alias) {
        SV *alias_sv = gqljs_new_name_node_sv(aTHX_ field->alias);
        hv_stores(hv, "alias", alias_sv);
        if (ctx) {
          gqljs_set_rewritten_loc_node(aTHX_ ctx, alias_sv, field->alias_pos);
        }
      }
      {
        SV *name_sv = gqljs_new_name_node_sv(aTHX_ field->name);
        hv_stores(hv, "name", name_sv);
        if (ctx) {
          gqljs_set_rewritten_loc_node(aTHX_ ctx, name_sv, field->name_pos);
        }
      }
      hv_stores(hv, "arguments", newRV_noinc((SV *)gqljs_build_arguments_from_ir(aTHX_ ctx, &field->arguments)));
      hv_stores(hv, "directives", newRV_noinc((SV *)gqljs_build_directives_from_ir(aTHX_ ctx, &field->directives)));
      if (field->selection_set) {
        hv_stores(hv, "selectionSet", gqljs_build_selection_set_from_ir(aTHX_ ctx, field->selection_set));
      }
      node_sv = newRV_noinc((SV *)hv);
      if (ctx) {
        gqljs_set_rewritten_loc_node(aTHX_ ctx, node_sv, field->start_pos);
      }
      return node_sv;
    }
    case GQL_IR_SELECTION_FRAGMENT_SPREAD: {
      gql_ir_fragment_spread_t *spread = selection->as.fragment_spread;
      hv = gqljs_new_node_hv_sized("FragmentSpread", 3);
      {
        SV *name_sv = gqljs_new_name_node_sv(aTHX_ spread->name);
        hv_stores(hv, "name", name_sv);
        if (ctx) {
          gqljs_set_rewritten_loc_node(aTHX_ ctx, name_sv, spread->name_pos);
        }
      }
      hv_stores(hv, "directives", newRV_noinc((SV *)gqljs_build_directives_from_ir(aTHX_ ctx, &spread->directives)));
      node_sv = newRV_noinc((SV *)hv);
      if (ctx) {
        gqljs_set_rewritten_loc_node(aTHX_ ctx, node_sv, spread->start_pos);
      }
      return node_sv;
    }
    case GQL_IR_SELECTION_INLINE_FRAGMENT: {
      gql_ir_inline_fragment_t *fragment = selection->as.inline_fragment;
      hv = gqljs_new_node_hv_sized("InlineFragment", 4);
      if (fragment->type_condition) {
        SV *type_sv = gqljs_new_named_type_node_sv(aTHX_ fragment->type_condition);
        hv_stores(hv, "typeCondition", type_sv);
        if (ctx) {
          SV *type_name_sv = gqljs_fetch_sv(gqljs_node_hv(type_sv), "name");
          SV *type_loc = gqljs_loc_from_rewritten_pos(aTHX_ ctx, fragment->type_condition_pos);
          gqljs_set_loc_node(aTHX_ type_sv, type_loc);
          gqljs_set_loc_node(aTHX_ type_name_sv, type_loc);
          SvREFCNT_dec(type_loc);
        }
      }
      hv_stores(hv, "directives", newRV_noinc((SV *)gqljs_build_directives_from_ir(aTHX_ ctx, &fragment->directives)));
      hv_stores(hv, "selectionSet", gqljs_build_selection_set_from_ir(aTHX_ ctx, fragment->selection_set));
      node_sv = newRV_noinc((SV *)hv);
      if (ctx) {
        gqljs_set_rewritten_loc_node(aTHX_ ctx, node_sv, fragment->start_pos);
      }
      return node_sv;
    }
  }

  return &PL_sv_undef;
}

static SV *
gqljs_build_selection_set_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_selection_set_t *selection_set) {
  HV *hv = gqljs_new_node_hv_sized("SelectionSet", 2);
  AV *selections = newAV();
  I32 i;
  SV *node_sv;

  if (selection_set && selection_set->selections.count > 0) {
    av_extend(selections, selection_set->selections.count - 1);
  }
  for (i = 0; selection_set && i < selection_set->selections.count; i++) {
    av_push(selections, gqljs_build_selection_from_ir(aTHX_ ctx, (gql_ir_selection_t *)selection_set->selections.items[i]));
  }
  hv_stores(hv, "selections", newRV_noinc((SV *)selections));
  node_sv = newRV_noinc((SV *)hv);
  if (ctx && selection_set) {
    gqljs_set_rewritten_loc_node(aTHX_ ctx, node_sv, selection_set->start_pos);
  }
  return node_sv;
}

static AV *
gqljs_build_variable_definitions_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_ptr_array_t *definitions) {
  AV *av = newAV();
  I32 i;

  if (!definitions) {
    return av;
  }
  if (definitions->count > 0) {
    av_extend(av, definitions->count - 1);
  }
  for (i = 0; i < definitions->count; i++) {
    gql_ir_variable_definition_t *definition = (gql_ir_variable_definition_t *)definitions->items[i];
    HV *def_hv = gqljs_new_node_hv_sized("VariableDefinition", 5);
    SV *def_sv;
    SV *variable_sv = gqljs_new_variable_node_sv(aTHX_ definition->name);
    hv_stores(def_hv, "variable", variable_sv);
    hv_stores(def_hv, "type", gqljs_build_type_from_ir(aTHX_ ctx, definition->type));
    if (definition->default_value) {
      hv_stores(def_hv, "defaultValue", gqljs_build_value_from_ir(aTHX_ ctx, definition->default_value));
    }
    hv_stores(def_hv, "directives", newRV_noinc((SV *)gqljs_build_directives_from_ir(aTHX_ ctx, &definition->directives)));
    def_sv = newRV_noinc((SV *)def_hv);
    if (ctx) {
      SV *variable_name_sv = gqljs_fetch_sv(gqljs_node_hv(variable_sv), "name");
      SV *def_loc = gqljs_loc_from_rewritten_pos(aTHX_ ctx, definition->start_pos);
      gqljs_set_loc_node(aTHX_ def_sv, def_loc);
      gqljs_set_loc_node(aTHX_ variable_sv, def_loc);
      SvREFCNT_dec(def_loc);
      gqljs_set_rewritten_loc_node(aTHX_ ctx, variable_name_sv, definition->name_pos);
    }
    av_push(av, def_sv);
  }
  return av;
}

static SV *
gqljs_build_executable_definition_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_definition_t *definition) {
  HV *hv;
  SV *node_sv;

  if (!definition) {
    return &PL_sv_undef;
  }
  if (definition->kind == GQL_IR_DEFINITION_OPERATION) {
    gql_ir_operation_definition_t *operation = definition->as.operation;
    const char *operation_name =
      operation->operation == GQL_IR_OPERATION_MUTATION ? "mutation" :
      operation->operation == GQL_IR_OPERATION_SUBSCRIPTION ? "subscription" :
      "query";
    hv = gqljs_new_node_hv_sized("OperationDefinition", 6);
    hv_stores(hv, "operation", newSVpv(operation_name, 0));
    if (operation->name) {
      SV *name_sv = gqljs_new_name_node_sv(aTHX_ operation->name);
      hv_stores(hv, "name", name_sv);
      if (ctx) {
        gqljs_set_rewritten_loc_node(aTHX_ ctx, name_sv, operation->name_pos);
      }
    }
    hv_stores(hv, "variableDefinitions",
      newRV_noinc((SV *)gqljs_build_variable_definitions_from_ir(aTHX_ ctx, &operation->variable_definitions)));
    hv_stores(hv, "directives",
      newRV_noinc((SV *)gqljs_build_directives_from_ir(aTHX_ ctx, &operation->directives)));
    hv_stores(hv, "selectionSet", gqljs_build_selection_set_from_ir(aTHX_ ctx, operation->selection_set));
    node_sv = newRV_noinc((SV *)hv);
    if (ctx) {
      gqljs_set_rewritten_loc_node(aTHX_ ctx, node_sv, operation->start_pos);
    }
    return node_sv;
  }

  {
    gql_ir_fragment_definition_t *fragment = definition->as.fragment;
    hv = gqljs_new_node_hv_sized("FragmentDefinition", 5);
    {
      SV *name_sv = gqljs_new_name_node_sv(aTHX_ fragment->name);
      SV *type_sv = gqljs_new_named_type_node_sv(aTHX_ fragment->type_condition);
      hv_stores(hv, "name", name_sv);
      hv_stores(hv, "typeCondition", type_sv);
      if (ctx) {
        SV *type_name_sv = gqljs_fetch_sv(gqljs_node_hv(type_sv), "name");
        SV *type_loc = gqljs_loc_from_rewritten_pos(aTHX_ ctx, fragment->type_condition_pos);
        gqljs_set_rewritten_loc_node(aTHX_ ctx, name_sv, fragment->name_pos);
        gqljs_set_loc_node(aTHX_ type_sv, type_loc);
        gqljs_set_loc_node(aTHX_ type_name_sv, type_loc);
        SvREFCNT_dec(type_loc);
      }
    }
    hv_stores(hv, "directives",
      newRV_noinc((SV *)gqljs_build_directives_from_ir(aTHX_ ctx, &fragment->directives)));
    hv_stores(hv, "selectionSet", gqljs_build_selection_set_from_ir(aTHX_ ctx, fragment->selection_set));
    node_sv = newRV_noinc((SV *)hv);
    if (ctx) {
      gqljs_set_rewritten_loc_node(aTHX_ ctx, node_sv, fragment->start_pos);
    }
    return node_sv;
  }
}

static SV *
gqljs_build_executable_document_from_ir(pTHX_ gqljs_loc_context_t *ctx, gql_ir_document_t *document) {
  HV *hv = gqljs_new_node_hv_sized("Document", 2);
  AV *definitions = newAV();
  I32 i;
  SV *node_sv;

  if (document && document->definitions.count > 0) {
    av_extend(definitions, document->definitions.count - 1);
  }
  for (i = 0; document && i < document->definitions.count; i++) {
    av_push(definitions, gqljs_build_executable_definition_from_ir(aTHX_ ctx, (gql_ir_definition_t *)document->definitions.items[i]));
  }
  hv_stores(hv, "definitions", newRV_noinc((SV *)definitions));
  node_sv = newRV_noinc((SV *)hv);
  if (ctx) {
    SV *doc_loc = gqljs_new_loc_sv(aTHX_ 1, 1);
    gqljs_set_loc_node(aTHX_ node_sv, doc_loc);
    SvREFCNT_dec(doc_loc);
  }
  return node_sv;
}

static SV *
gqlperl_location_from_gqljs_node(pTHX_ SV *node_sv) {
  HV *src_hv;
  HV *loc_hv;
  HV *dst_hv;
  SV *line_sv;
  SV *column_sv;
  SV *loc_sv;

  if (!node_sv || !SvROK(node_sv) || SvTYPE(SvRV(node_sv)) != SVt_PVHV) {
    return &PL_sv_undef;
  }
  src_hv = (HV *)SvRV(node_sv);
  loc_sv = gqljs_fetch_sv(src_hv, "loc");
  if (!loc_sv || !SvROK(loc_sv) || SvTYPE(SvRV(loc_sv)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  loc_hv = (HV *)SvRV(loc_sv);
  line_sv = gqljs_fetch_sv(loc_hv, "line");
  column_sv = gqljs_fetch_sv(loc_hv, "column");
  if (!line_sv || !column_sv) {
    return &PL_sv_undef;
  }

  dst_hv = newHV();
  gql_store_sv(dst_hv, "line", newSViv(SvIV(line_sv)));
  gql_store_sv(dst_hv, "column", newSViv(SvIV(column_sv)));
  return newRV_noinc((SV *)dst_hv);
}

static void
gqlperl_store_location_from_gqljs_node(pTHX_ HV *dst_hv, SV *node_sv) {
  SV *location_sv = gqlperl_location_from_gqljs_node(aTHX_ node_sv);
  if (location_sv && location_sv != &PL_sv_undef) {
    gql_store_sv(dst_hv, "location", location_sv);
  }
}

static SV *
gqlperl_convert_type_from_gqljs(pTHX_ SV *node_sv) {
  HV *src_hv;
  const char *kind;

  if (!node_sv || !SvROK(node_sv) || SvTYPE(SvRV(node_sv)) != SVt_PVHV) {
    return &PL_sv_undef;
  }
  src_hv = (HV *)SvRV(node_sv);
  kind = gqljs_fetch_kind(src_hv);

  if (strEQ(kind, "NamedType")) {
    return newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0);
  }
  if (strEQ(kind, "ListType") || strEQ(kind, "NonNullType")) {
    AV *av = newAV();
    HV *inner_hv = newHV();
    av_push(av, newSVpv(strEQ(kind, "ListType") ? "list" : "non_null", 0));
    gql_store_sv(inner_hv, "type",
      gqlperl_convert_type_from_gqljs(aTHX_ gqljs_fetch_sv(src_hv, "type")));
    av_push(av, newRV_noinc((SV *)inner_hv));
    return newRV_noinc((SV *)av);
  }

  croak("Unsupported graphql-js type node '%s'.", kind);
}

static SV *
gqlperl_convert_value_from_gqljs(pTHX_ SV *node_sv) {
  HV *src_hv;
  const char *kind;
  SV *value_sv;

  if (!node_sv || !SvROK(node_sv) || SvTYPE(SvRV(node_sv)) != SVt_PVHV) {
    return &PL_sv_undef;
  }
  src_hv = (HV *)SvRV(node_sv);
  kind = gqljs_fetch_kind(src_hv);

  if (strEQ(kind, "Variable")) {
    return newRV_noinc(newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
  }
  if (strEQ(kind, "IntValue")) {
    value_sv = gqljs_fetch_sv(src_hv, "value");
    return newSViv(SvIV(value_sv));
  }
  if (strEQ(kind, "FloatValue")) {
    value_sv = gqljs_fetch_sv(src_hv, "value");
    return newSVnv(SvNV(value_sv));
  }
  if (strEQ(kind, "StringValue")) {
    value_sv = gqljs_fetch_sv(src_hv, "value");
    return newSVsv(value_sv);
  }
  if (strEQ(kind, "BooleanValue")) {
    value_sv = gqljs_fetch_sv(src_hv, "value");
    return gql_call_helper1(aTHX_ "GraphQL::Houtou::XS::Parser::_make_bool",
      newSViv(SvTRUE(value_sv) ? 1 : 0));
  }
  if (strEQ(kind, "NullValue")) {
    return newSV(0);
  }
  if (strEQ(kind, "EnumValue")) {
    SV *enum_sv = newSVsv(gqljs_fetch_sv(src_hv, "value"));
    SV *inner_ref = newRV_noinc(enum_sv);
    return newRV_noinc(inner_ref);
  }
  if (strEQ(kind, "ListValue")) {
    AV *src_av = gqljs_fetch_array(src_hv, "values");
    AV *dst_av = newAV();
    I32 i;
    for (i = 0; src_av && i <= av_len(src_av); i++) {
      SV **svp = av_fetch(src_av, i, 0);
      if (svp) {
        av_push(dst_av, gqlperl_convert_value_from_gqljs(aTHX_ *svp));
      }
    }
    return newRV_noinc((SV *)dst_av);
  }
  if (strEQ(kind, "ObjectValue")) {
    AV *fields_av = gqljs_fetch_array(src_hv, "fields");
    HV *dst_hv = newHV();
    I32 i;
    for (i = 0; fields_av && i <= av_len(fields_av); i++) {
      SV **svp = av_fetch(fields_av, i, 0);
      HV *field_hv;
      const char *name;
      if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVHV) {
        continue;
      }
      field_hv = (HV *)SvRV(*svp);
      name = gqljs_name_value(gqljs_fetch_sv(field_hv, "name"));
      gql_store_sv(dst_hv, name,
        gqlperl_convert_value_from_gqljs(aTHX_ gqljs_fetch_sv(field_hv, "value")));
    }
    return newRV_noinc((SV *)dst_hv);
  }

  croak("Unsupported graphql-js value node '%s'.", kind);
}

static SV *
gqlperl_convert_arguments_from_gqljs(pTHX_ AV *av) {
  HV *dst_hv = newHV();
  I32 i;

  if (!av || av_len(av) < 0) {
    SvREFCNT_dec((SV *)dst_hv);
    return &PL_sv_undef;
  }

  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *arg_hv;
    const char *name;
    if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVHV) {
      continue;
    }
    arg_hv = (HV *)SvRV(*svp);
    name = gqljs_name_value(gqljs_fetch_sv(arg_hv, "name"));
    gql_store_sv(dst_hv, name,
      gqlperl_convert_value_from_gqljs(aTHX_ gqljs_fetch_sv(arg_hv, "value")));
  }

  return newRV_noinc((SV *)dst_hv);
}

static SV *
gqlperl_convert_directives_from_gqljs(pTHX_ AV *av) {
  AV *dst_av = newAV();
  I32 i;

  if (!av || av_len(av) < 0) {
    return newRV_noinc((SV *)dst_av);
  }

  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *src_hv;
    HV *dst_hv;
    SV *arguments_sv;
    if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVHV) {
      continue;
    }
    src_hv = (HV *)SvRV(*svp);
    dst_hv = newHV();
    gql_store_sv(dst_hv, "name",
      newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
    arguments_sv = gqlperl_convert_arguments_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "arguments"));
    if (arguments_sv && arguments_sv != &PL_sv_undef) {
      gql_store_sv(dst_hv, "arguments", arguments_sv);
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, *svp);
    av_push(dst_av, newRV_noinc((SV *)dst_hv));
  }

  return newRV_noinc((SV *)dst_av);
}

static AV *
gqlperl_convert_selections_from_gqljs(pTHX_ AV *av) {
  AV *dst_av = newAV();
  I32 i;

  for (i = 0; av && i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    if (svp) {
      av_push(dst_av, gqlperl_convert_selection_from_gqljs(aTHX_ *svp));
    }
  }

  return dst_av;
}

static SV *
gqlperl_convert_selection_from_gqljs(pTHX_ SV *node_sv) {
  HV *src_hv;
  HV *dst_hv;
  const char *kind;
  SV *arguments_sv;
  SV *directives_sv;
  AV *selection_av;

  if (!node_sv || !SvROK(node_sv) || SvTYPE(SvRV(node_sv)) != SVt_PVHV) {
    croak("Unsupported graphql-js selection node");
  }
  src_hv = (HV *)SvRV(node_sv);
  kind = gqljs_fetch_kind(src_hv);
  dst_hv = newHV();

  if (strEQ(kind, "Field")) {
    gql_store_sv(dst_hv, "kind", newSVpv("field", 0));
    gql_store_sv(dst_hv, "name", newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
    if (gqljs_fetch_sv(src_hv, "alias")) {
      gql_store_sv(dst_hv, "alias",
        newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "alias")), 0));
    }
    arguments_sv = gqlperl_convert_arguments_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "arguments"));
    if (arguments_sv && arguments_sv != &PL_sv_undef) {
      gql_store_sv(dst_hv, "arguments", arguments_sv);
    }
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    if (gqljs_fetch_sv(src_hv, "selectionSet")) {
      selection_av = gqlperl_convert_selections_from_gqljs(aTHX_
        gqljs_fetch_array((HV *)SvRV(gqljs_fetch_sv(src_hv, "selectionSet")), "selections"));
      if (av_len(selection_av) >= 0) {
        gql_store_sv(dst_hv, "selections", newRV_noinc((SV *)selection_av));
      } else {
        SvREFCNT_dec((SV *)selection_av);
      }
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  if (strEQ(kind, "FragmentSpread")) {
    gql_store_sv(dst_hv, "kind", newSVpv("fragment_spread", 0));
    gql_store_sv(dst_hv, "name", newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  if (strEQ(kind, "InlineFragment")) {
    gql_store_sv(dst_hv, "kind", newSVpv("inline_fragment", 0));
    if (gqljs_fetch_sv(src_hv, "typeCondition")) {
      gql_store_sv(dst_hv, "on",
        newSVpv(gqljs_name_value(gqljs_fetch_sv((HV *)SvRV(gqljs_fetch_sv(src_hv, "typeCondition")), "name")), 0));
    }
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    selection_av = gqlperl_convert_selections_from_gqljs(aTHX_
      gqljs_fetch_array((HV *)SvRV(gqljs_fetch_sv(src_hv, "selectionSet")), "selections"));
    gql_store_sv(dst_hv, "selections", newRV_noinc((SV *)selection_av));
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  SvREFCNT_dec((SV *)dst_hv);
  croak("Unsupported graphql-js selection node '%s'.", kind);
}

static SV *
gqlperl_convert_variable_definitions_from_gqljs(pTHX_ AV *av) {
  HV *dst_hv = newHV();
  I32 i;

  if (!av || av_len(av) < 0) {
    SvREFCNT_dec((SV *)dst_hv);
    return &PL_sv_undef;
  }

  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *src_hv;
    HV *var_hv;
    HV *dst_var_hv;
    const char *name;
    SV *directives_sv;
    if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVHV) {
      continue;
    }
    src_hv = (HV *)SvRV(*svp);
    var_hv = (HV *)SvRV(gqljs_fetch_sv(src_hv, "variable"));
    name = gqljs_name_value(gqljs_fetch_sv(var_hv, "name"));
    dst_var_hv = newHV();
    gql_store_sv(dst_var_hv, "type",
      gqlperl_convert_type_from_gqljs(aTHX_ gqljs_fetch_sv(src_hv, "type")));
    if (gqljs_fetch_sv(src_hv, "defaultValue")) {
      gql_store_sv(dst_var_hv, "default_value",
        gqlperl_convert_value_from_gqljs(aTHX_ gqljs_fetch_sv(src_hv, "defaultValue")));
    }
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_var_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    gql_store_sv(dst_hv, name, newRV_noinc((SV *)dst_var_hv));
  }

  return newRV_noinc((SV *)dst_hv);
}

static SV *
gqlperl_convert_named_types_from_gqljs(pTHX_ AV *av) {
  AV *out_av = newAV();
  I32 i;

  if (!av) {
    return newRV_noinc((SV *)out_av);
  }

  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *node_hv;
    const char *name;
    if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVHV) {
      continue;
    }
    node_hv = (HV *)SvRV(*svp);
    name = gqljs_name_value(gqljs_fetch_sv(node_hv, "name"));
    av_push(out_av, newSVpv(name, 0));
  }

  return newRV_noinc((SV *)out_av);
}

static SV *
gqlperl_convert_input_value_definitions_from_gqljs(pTHX_ AV *av) {
  HV *out_hv = newHV();
  I32 i;

  if (!av || av_len(av) < 0) {
    SvREFCNT_dec((SV *)out_hv);
    return &PL_sv_undef;
  }

  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *src_hv;
    HV *dst_hv;
    const char *name;
    SV *directives_sv;
    if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVHV) {
      continue;
    }
    src_hv = (HV *)SvRV(*svp);
    name = gqljs_name_value(gqljs_fetch_sv(src_hv, "name"));
    dst_hv = newHV();
    gql_store_sv(dst_hv, "type",
      gqlperl_convert_type_from_gqljs(aTHX_ gqljs_fetch_sv(src_hv, "type")));
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    if (gqljs_fetch_sv(src_hv, "description")) {
      gql_store_sv(dst_hv, "description",
        newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "description")), 0));
    }
    if (gqljs_fetch_sv(src_hv, "defaultValue")) {
      gql_store_sv(dst_hv, "default_value",
        gqlperl_convert_value_from_gqljs(aTHX_ gqljs_fetch_sv(src_hv, "defaultValue")));
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, *svp);
    gql_store_sv(out_hv, name, newRV_noinc((SV *)dst_hv));
  }

  return newRV_noinc((SV *)out_hv);
}

static SV *
gqlperl_convert_field_definitions_from_gqljs(pTHX_ AV *av) {
  HV *out_hv = newHV();
  I32 i;

  if (!av || av_len(av) < 0) {
    SvREFCNT_dec((SV *)out_hv);
    return &PL_sv_undef;
  }

  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *src_hv;
    HV *dst_hv;
    const char *name;
    SV *directives_sv;
    SV *args_sv;
    if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVHV) {
      continue;
    }
    src_hv = (HV *)SvRV(*svp);
    name = gqljs_name_value(gqljs_fetch_sv(src_hv, "name"));
    dst_hv = newHV();
    gql_store_sv(dst_hv, "type",
      gqlperl_convert_type_from_gqljs(aTHX_ gqljs_fetch_sv(src_hv, "type")));
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    if (gqljs_fetch_sv(src_hv, "description")) {
      gql_store_sv(dst_hv, "description",
        newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "description")), 0));
    }
    args_sv = gqlperl_convert_input_value_definitions_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "arguments"));
    if (args_sv && args_sv != &PL_sv_undef) {
      gql_store_sv(dst_hv, "args", args_sv);
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, *svp);
    gql_store_sv(out_hv, name, newRV_noinc((SV *)dst_hv));
  }

  return newRV_noinc((SV *)out_hv);
}

static SV *
gqlperl_convert_enum_values_from_gqljs(pTHX_ AV *av) {
  HV *out_hv = newHV();
  I32 i;

  for (i = 0; av && i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *src_hv;
    HV *dst_hv;
    const char *name;
    SV *directives_sv;
    if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVHV) {
      continue;
    }
    src_hv = (HV *)SvRV(*svp);
    name = gqljs_name_value(gqljs_fetch_sv(src_hv, "name"));
    dst_hv = newHV();
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    if (gqljs_fetch_sv(src_hv, "description")) {
      gql_store_sv(dst_hv, "description",
        newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "description")), 0));
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, *svp);
    gql_store_sv(out_hv, name, newRV_noinc((SV *)dst_hv));
  }

  return newRV_noinc((SV *)out_hv);
}

static SV *
gqlperl_convert_executable_definition_from_gqljs(pTHX_ SV *node_sv) {
  HV *src_hv;
  HV *dst_hv;
  const char *kind;
  SV *directives_sv;
  AV *selections_av;

  if (!node_sv || !SvROK(node_sv) || SvTYPE(SvRV(node_sv)) != SVt_PVHV) {
    return &PL_sv_undef;
  }
  src_hv = (HV *)SvRV(node_sv);
  kind = gqljs_fetch_kind(src_hv);
  dst_hv = newHV();

  if (strEQ(kind, "OperationDefinition")) {
    gql_store_sv(dst_hv, "kind", newSVpv("operation", 0));
    gql_store_sv(dst_hv, "operationType", newSVsv(gqljs_fetch_sv(src_hv, "operation")));
    if (gqljs_fetch_sv(src_hv, "name")) {
      gql_store_sv(dst_hv, "name",
        newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
    }
    if (gqljs_fetch_array(src_hv, "variableDefinitions")) {
      SV *variables_sv = gqlperl_convert_variable_definitions_from_gqljs(aTHX_
        gqljs_fetch_array(src_hv, "variableDefinitions"));
      if (variables_sv && variables_sv != &PL_sv_undef) {
        gql_store_sv(dst_hv, "variables", variables_sv);
      }
    }
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    selections_av = gqlperl_convert_selections_from_gqljs(aTHX_
      gqljs_fetch_array((HV *)SvRV(gqljs_fetch_sv(src_hv, "selectionSet")), "selections"));
    gql_store_sv(dst_hv, "selections", newRV_noinc((SV *)selections_av));
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  if (strEQ(kind, "FragmentDefinition")) {
    gql_store_sv(dst_hv, "kind", newSVpv("fragment", 0));
    gql_store_sv(dst_hv, "name",
      newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
    gql_store_sv(dst_hv, "on",
      newSVpv(gqljs_name_value(gqljs_fetch_sv((HV *)SvRV(gqljs_fetch_sv(src_hv, "typeCondition")), "name")), 0));
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    selections_av = gqlperl_convert_selections_from_gqljs(aTHX_
      gqljs_fetch_array((HV *)SvRV(gqljs_fetch_sv(src_hv, "selectionSet")), "selections"));
    gql_store_sv(dst_hv, "selections", newRV_noinc((SV *)selections_av));
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  SvREFCNT_dec((SV *)dst_hv);
  return &PL_sv_undef;
}

static SV *
gqlperl_convert_definition_from_gqljs(pTHX_ SV *node_sv) {
  HV *src_hv;
  HV *dst_hv;
  const char *kind;
  SV *directives_sv;
  SV *fields_sv;
  SV *args_sv;
  SV *interfaces_sv;
  SV *types_sv;
  AV *locations_av;
  I32 i;

  SV *executable = gqlperl_convert_executable_definition_from_gqljs(aTHX_ node_sv);
  if (executable && executable != &PL_sv_undef) {
    return executable;
  }

  if (!node_sv || !SvROK(node_sv) || SvTYPE(SvRV(node_sv)) != SVt_PVHV) {
    return &PL_sv_undef;
  }
  src_hv = (HV *)SvRV(node_sv);
  kind = gqljs_fetch_kind(src_hv);
  dst_hv = newHV();

  if (strEQ(kind, "SchemaDefinition") || strEQ(kind, "SchemaExtension")) {
    AV *ops_av = gqljs_fetch_array(src_hv, "operationTypes");
    gql_store_sv(dst_hv, "kind", newSVpv("schema", 0));
    for (i = 0; ops_av && i <= av_len(ops_av); i++) {
      SV **svp = av_fetch(ops_av, i, 0);
      HV *op_hv;
      const char *operation;
      const char *type_name;
      SV *operation_sv;
      if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVHV) {
        continue;
      }
      op_hv = (HV *)SvRV(*svp);
      operation_sv = gqljs_fetch_sv(op_hv, "operation");
      operation = SvPV_nolen(operation_sv);
      type_name = gqljs_name_value(gqljs_fetch_sv((HV *)SvRV(gqljs_fetch_sv(op_hv, "type")), "name"));
      gql_store_sv(dst_hv, operation, newSVpv(type_name, 0));
    }
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  if (strEQ(kind, "ScalarTypeDefinition") || strEQ(kind, "ScalarTypeExtension")) {
    gql_store_sv(dst_hv, "kind", newSVpv("scalar", 0));
    gql_store_sv(dst_hv, "name", newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    if (gqljs_fetch_sv(src_hv, "description")) {
      gql_store_sv(dst_hv, "description",
        newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "description")), 0));
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  if (strEQ(kind, "ObjectTypeDefinition") || strEQ(kind, "ObjectTypeExtension")
      || strEQ(kind, "InterfaceTypeDefinition") || strEQ(kind, "InterfaceTypeExtension")) {
    gql_store_sv(dst_hv, "kind",
      newSVpv((strstr(kind, "InterfaceType") == kind) ? "interface" : "type", 0));
    gql_store_sv(dst_hv, "name", newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
    interfaces_sv = gqlperl_convert_named_types_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "interfaces"));
    if (interfaces_sv && SvROK(interfaces_sv) && av_len((AV *)SvRV(interfaces_sv)) >= 0) {
      gql_store_sv(dst_hv, "interfaces", interfaces_sv);
    } else if (interfaces_sv && interfaces_sv != &PL_sv_undef) {
      SvREFCNT_dec(interfaces_sv);
    }
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    if (gqljs_fetch_sv(src_hv, "description")) {
      gql_store_sv(dst_hv, "description",
        newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "description")), 0));
    }
    fields_sv = gqlperl_convert_field_definitions_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "fields"));
    if (fields_sv && fields_sv != &PL_sv_undef) {
      gql_store_sv(dst_hv, "fields", fields_sv);
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  if (strEQ(kind, "UnionTypeDefinition") || strEQ(kind, "UnionTypeExtension")) {
    gql_store_sv(dst_hv, "kind", newSVpv("union", 0));
    gql_store_sv(dst_hv, "name", newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
    types_sv = gqlperl_convert_named_types_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "types"));
    if (types_sv && types_sv != &PL_sv_undef) {
      gql_store_sv(dst_hv, "types", types_sv);
    }
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    if (gqljs_fetch_sv(src_hv, "description")) {
      gql_store_sv(dst_hv, "description",
        newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "description")), 0));
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  if (strEQ(kind, "EnumTypeDefinition") || strEQ(kind, "EnumTypeExtension")) {
    gql_store_sv(dst_hv, "kind", newSVpv("enum", 0));
    gql_store_sv(dst_hv, "name", newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
    gql_store_sv(dst_hv, "values",
      gqlperl_convert_enum_values_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "values")));
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    if (gqljs_fetch_sv(src_hv, "description")) {
      gql_store_sv(dst_hv, "description",
        newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "description")), 0));
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  if (strEQ(kind, "InputObjectTypeDefinition") || strEQ(kind, "InputObjectTypeExtension")) {
    gql_store_sv(dst_hv, "kind", newSVpv("input", 0));
    gql_store_sv(dst_hv, "name", newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
    directives_sv = gqlperl_convert_directives_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "directives"));
    if (directives_sv && SvROK(directives_sv) && av_len((AV *)SvRV(directives_sv)) >= 0) {
      gql_store_sv(dst_hv, "directives", directives_sv);
    } else if (directives_sv && directives_sv != &PL_sv_undef) {
      SvREFCNT_dec(directives_sv);
    }
    if (gqljs_fetch_sv(src_hv, "description")) {
      gql_store_sv(dst_hv, "description",
        newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "description")), 0));
    }
    fields_sv = gqlperl_convert_input_value_definitions_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "fields"));
    if (fields_sv && fields_sv != &PL_sv_undef) {
      gql_store_sv(dst_hv, "fields", fields_sv);
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  if (strEQ(kind, "DirectiveDefinition") || strEQ(kind, "DirectiveExtension")) {
    gql_store_sv(dst_hv, "kind", newSVpv("directive", 0));
    gql_store_sv(dst_hv, "name", newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "name")), 0));
    locations_av = gqljs_fetch_array(src_hv, "locations");
    if (locations_av) {
      AV *out_locations = newAV();
      for (i = 0; i <= av_len(locations_av); i++) {
        SV **svp = av_fetch(locations_av, i, 0);
        if (svp) {
          av_push(out_locations, newSVpv(gqljs_name_value(*svp), 0));
        }
      }
      gql_store_sv(dst_hv, "locations", newRV_noinc((SV *)out_locations));
    }
    args_sv = gqlperl_convert_input_value_definitions_from_gqljs(aTHX_ gqljs_fetch_array(src_hv, "arguments"));
    if (args_sv && args_sv != &PL_sv_undef) {
      gql_store_sv(dst_hv, "args", args_sv);
    }
    if (gqljs_fetch_sv(src_hv, "description")) {
      gql_store_sv(dst_hv, "description",
        newSVpv(gqljs_name_value(gqljs_fetch_sv(src_hv, "description")), 0));
    }
    gqlperl_store_location_from_gqljs_node(aTHX_ dst_hv, node_sv);
    return newRV_noinc((SV *)dst_hv);
  }

  SvREFCNT_dec((SV *)dst_hv);
  return &PL_sv_undef;
}

static SV *
gql_graphqlperl_build_document(pTHX_ SV *doc_sv) {
  HV *doc_hv;
  AV *definitions_av;
  AV *out_av;
  I32 i;

  if (!doc_sv || !SvROK(doc_sv) || SvTYPE(SvRV(doc_sv)) != SVt_PVHV) {
    croak("graphqlperl_build_document_xs expects a document hash reference");
  }
  doc_hv = (HV *)SvRV(doc_sv);
  if (!strEQ(gqljs_fetch_kind(doc_hv), "Document")) {
    croak("graphqlperl_build_document_xs expects a graphql-js Document node");
  }
  definitions_av = gqljs_fetch_array(doc_hv, "definitions");
  if (!definitions_av) {
    croak("graphqlperl_build_document_xs expected document definitions");
  }

  out_av = newAV();
  for (i = 0; i <= av_len(definitions_av); i++) {
    SV **svp = av_fetch(definitions_av, i, 0);
    SV *converted_sv;
    if (!svp) {
      continue;
    }
    converted_sv = gqlperl_convert_definition_from_gqljs(aTHX_ *svp);
    if (!converted_sv || converted_sv == &PL_sv_undef) {
      SvREFCNT_dec((SV *)out_av);
      return &PL_sv_undef;
    }
    av_push(out_av, converted_sv);
  }

  return newRV_noinc((SV *)out_av);
}

static void
gql_skip_ignored(gql_parser_t *p) {
  while (p->pos < p->len) {
    unsigned char c = (unsigned char)p->src[p->pos];
    if (c == 0xEF && p->pos + 2 < p->len &&
        (unsigned char)p->src[p->pos + 1] == 0xBB &&
        (unsigned char)p->src[p->pos + 2] == 0xBF) {
      p->pos += 3;
      continue;
    }
    if (c == ',' || c == ' ' || c == '\t' || c == '\n' || c == '\r') {
      p->pos++;
      continue;
    }
    if (c == '#') {
      while (p->pos < p->len) {
        c = (unsigned char)p->src[p->pos];
        p->pos++;
        if (c == '\n' || c == '\r') {
          break;
        }
      }
      continue;
    }
    break;
  }
}

static void
gql_lex_token(pTHX_ gql_parser_t *p) {
  STRLEN start;
  unsigned char c;
  start = p->pos;
  p->tok_start = start;
  p->tok_end = start;
  p->val_start = start;
  p->val_end = start;
  if (start >= p->len) {
    p->kind = TOK_EOF;
    return;
  }
  c = (unsigned char)p->src[p->pos];
  switch (c) {
    case '!':
      p->kind = TOK_BANG;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case '$':
      p->kind = TOK_DOLLAR;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case '&':
      p->kind = TOK_AMP;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case '(':
      p->kind = TOK_LPAREN;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case ')':
      p->kind = TOK_RPAREN;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case ':':
      p->kind = TOK_COLON;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case '=':
      p->kind = TOK_EQUALS;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case '@':
      p->kind = TOK_AT;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case '[':
      p->kind = TOK_LBRACKET;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case ']':
      p->kind = TOK_RBRACKET;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case '{':
      p->kind = TOK_LBRACE;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case '}':
      p->kind = TOK_RBRACE;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case '|':
      p->kind = TOK_PIPE;
      p->pos++;
      p->tok_end = p->pos;
      return;
    case '.':
      if (p->pos + 2 < p->len && p->src[p->pos + 1] == '.' && p->src[p->pos + 2] == '.') {
        p->kind = TOK_SPREAD;
        p->pos += 3;
        p->tok_end = p->pos;
        return;
      }
      gql_throw(aTHX_ p, p->pos, "Expected \"...\"");
      break;
    case '"':
      if (p->pos + 2 < p->len && p->src[p->pos + 1] == '"' && p->src[p->pos + 2] == '"') {
        STRLEN scan = p->pos + 3;
        p->val_start = scan;
        while (scan < p->len) {
          if (scan + 2 < p->len && p->src[scan] == '"' && p->src[scan + 1] == '"' && p->src[scan + 2] == '"') {
            p->kind = TOK_BLOCK_STRING;
            p->val_end = scan;
            p->pos = scan + 3;
            p->tok_end = p->pos;
            return;
          }
          if ((unsigned char)p->src[scan] < 0x20 &&
              p->src[scan] != '\t' && p->src[scan] != '\n' && p->src[scan] != '\r') {
            gql_throw(aTHX_ p, scan, "Invalid character within block string");
          }
          if (scan + 3 < p->len &&
              p->src[scan] == '\\' &&
              p->src[scan + 1] == '"' &&
              p->src[scan + 2] == '"' &&
              p->src[scan + 3] == '"') {
            scan += 4;
            continue;
          }
          scan++;
        }
        gql_throw(aTHX_ p, p->tok_start, "Unterminated block string");
      } else {
        STRLEN scan = p->pos + 1;
        p->val_start = scan;
        while (scan < p->len) {
          unsigned char sc = (unsigned char)p->src[scan];
          if (p->src[scan] == '"') {
            p->kind = TOK_STRING;
            p->val_end = scan;
            p->pos = scan + 1;
            p->tok_end = p->pos;
            return;
          }
          if (p->src[scan] == '\\') {
            scan++;
            if (scan >= p->len) {
              gql_throw(aTHX_ p, p->tok_start, "Unterminated string");
            }
            if (strchr("\"\\/bfnrt", p->src[scan])) {
              scan++;
              continue;
            }
            if (p->src[scan] == 'u') {
              int i;
              for (i = 0; i < 4; i++) {
                scan++;
                if (scan >= p->len || !isXDIGIT((unsigned char)p->src[scan])) {
                  gql_throw(aTHX_ p, p->tok_start, "Invalid Unicode escape sequence");
                }
              }
              scan++;
              continue;
            }
            gql_throw(aTHX_ p, p->tok_start, "Invalid character escape sequence");
          }
          if (sc == '\n' || sc == '\r') {
            gql_throw(aTHX_ p, p->tok_start, "Unterminated string");
          }
          if (sc == 0x00 || sc < 0x20) {
            gql_throw(aTHX_ p, p->tok_start, "Invalid character within string");
          }
          scan++;
        }
        gql_throw(aTHX_ p, p->tok_start, "Unterminated string");
      }
      break;
    default:
      break;
  }

  if (c == '-' || isDIGIT(c)) {
    STRLEN scan = p->pos;
    bool is_float = 0;
    if (p->src[scan] == '-') {
      scan++;
      if (scan >= p->len || !isDIGIT((unsigned char)p->src[scan])) {
        gql_throw(aTHX_ p, p->tok_start, "Invalid number, expected digit after \"-\"");
      }
    }
    if (p->src[scan] == '0') {
      scan++;
      if (scan < p->len && isDIGIT((unsigned char)p->src[scan])) {
        gql_throw(aTHX_ p, scan, "Invalid number, unexpected digit after 0");
      }
    } else {
      while (scan < p->len && isDIGIT((unsigned char)p->src[scan])) {
        scan++;
      }
    }
    if (scan < p->len && p->src[scan] == '.') {
      is_float = 1;
      scan++;
      if (scan >= p->len || !isDIGIT((unsigned char)p->src[scan])) {
        gql_throw(aTHX_ p, scan - 1, "Invalid number, expected digit after decimal point");
      }
      while (scan < p->len && isDIGIT((unsigned char)p->src[scan])) {
        scan++;
      }
    }
    if (scan < p->len && (p->src[scan] == 'e' || p->src[scan] == 'E')) {
      STRLEN exp_pos = scan;
      bool had_sign = 0;
      is_float = 1;
      scan++;
      if (scan < p->len && (p->src[scan] == '+' || p->src[scan] == '-')) {
        had_sign = 1;
        scan++;
      }
      if (scan >= p->len || !isDIGIT((unsigned char)p->src[scan])) {
        STRLEN err_pos = exp_pos + 1;
        if (!had_sign && scan < p->len &&
            ((p->src[scan] >= 'A' && p->src[scan] <= 'Z') ||
             (p->src[scan] >= 'a' && p->src[scan] <= 'z') ||
             p->src[scan] == '_')) {
          err_pos = exp_pos + 2;
        }
        gql_throw(aTHX_ p, err_pos, "Invalid number, expected digit after exponent indicator");
      }
      while (scan < p->len && isDIGIT((unsigned char)p->src[scan])) {
        scan++;
      }
    }
    p->kind = is_float ? TOK_FLOAT : TOK_INT;
    p->pos = scan;
    p->tok_end = p->pos;
    p->val_start = p->tok_start;
    p->val_end = p->tok_end;
    return;
  }

  if (c == '_' || isALPHA(c)) {
    STRLEN scan = p->pos + 1;
    while (scan < p->len) {
      unsigned char nc = (unsigned char)p->src[scan];
      if (!(nc == '_' || isALNUM(nc))) {
        break;
      }
      scan++;
    }
    p->kind = TOK_NAME;
    p->pos = scan;
    p->tok_end = p->pos;
    p->val_start = p->tok_start;
    p->val_end = p->tok_end;
    return;
  }

  gql_throw_unexpected_character(aTHX_ p, p->pos, c);
}

static void
gql_advance(pTHX_ gql_parser_t *p) {
  if (p->tok_end > 0) {
    p->last_pos = p->tok_end - 1;
  }
  gql_skip_ignored(p);
  gql_lex_token(aTHX_ p);
}

static int
gql_peek_name(gql_parser_t *p, const char *name) {
  STRLEN len = strlen(name);
  return p->kind == TOK_NAME &&
    (p->tok_end - p->tok_start) == len &&
    memEQ(p->src + p->tok_start, name, len);
}

static void
gql_expect(pTHX_ gql_parser_t *p, gql_token_kind_t kind, const char *msg) {
  if (p->kind != kind) {
    if (msg) {
      gql_throw_expected_message(aTHX_ p, p->tok_start, msg);
    }
    gql_throw_expected_token(aTHX_ p, kind);
  }
  gql_advance(aTHX_ p);
}

static SV *
gql_parse_name(pTHX_ gql_parser_t *p, const char *msg) {
  SV *sv;
  if (p->kind != TOK_NAME) {
    gql_throw_expected_message(aTHX_ p, p->tok_start, msg);
  }
  sv = gql_copy_token_sv(aTHX_ p);
  gql_advance(aTHX_ p);
  return sv;
}

static SV *
gql_parse_fragment_name(pTHX_ gql_parser_t *p) {
  if (gql_peek_name(p, "on")) {
    gql_throw(aTHX_ p, p->tok_end, "Unexpected Name \"on\"");
  }
  return gql_parse_name(aTHX_ p, "Expected name");
}

static void
gql_line_column_from_pos(gql_parser_t *p, STRLEN pos, IV *line, IV *column, int one_based) {
  STRLEN i = 0;
  IV current_line = 1;
  STRLEN line_start = 0;
  if (pos == (STRLEN)-1) {
    *line = 1;
    *column = 0;
    return;
  }
  while (i < pos && i < p->len) {
    char c = p->src[i];
    if (c == '\r') {
      current_line++;
      line_start = i + 1;
      if (i + 1 < pos && i + 1 < p->len && p->src[i + 1] == '\n') {
        i++;
        line_start = i + 1;
      }
    } else if (c == '\n') {
      current_line++;
      line_start = i + 1;
    }
    i++;
  }
  *line = current_line;
  *column = (IV)(pos - line_start + (one_based ? 1 : 0));
}

static void
gql_line_column_from_last(gql_parser_t *p, IV *line, IV *column) {
  gql_line_column_from_pos(p, p->last_pos, line, column, 0);
}

static SV *
gql_make_location(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  IV line;
  IV column;
  gql_line_column_from_last(p, &line, &column);
  gql_store_sv(hv, "line", newSViv(line));
  gql_store_sv(hv, "column", newSViv(column));
  return newRV_noinc((SV *)hv);
}

static void
gql_store_location(pTHX_ gql_parser_t *p, HV *hv) {
  gql_store_sv(hv, "location", gql_make_location(aTHX_ p));
}

static SV *
gql_make_current_location(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  IV line;
  IV column;
  if (p->kind == TOK_EOF) {
    if (p->tok_start > p->last_pos + 1) {
      gql_line_column_from_pos(p, p->tok_start, &line, &column, 1);
      gql_store_sv(hv, "line", newSViv(line));
      gql_store_sv(hv, "column", newSViv(column));
      return newRV_noinc((SV *)hv);
    }
    return gql_make_location(aTHX_ p);
  }
  gql_line_column_from_pos(p, p->tok_start, &line, &column, 1);
  gql_store_sv(hv, "line", newSViv(line));
  gql_store_sv(hv, "column", newSViv(column));
  return newRV_noinc((SV *)hv);
}

static void
gql_store_current_location(pTHX_ gql_parser_t *p, HV *hv) {
  gql_store_sv(hv, "location", gql_make_current_location(aTHX_ p));
}

static SV *
gql_make_endline_location(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  IV line;
  IV column;
  gql_line_column_from_last(p, &line, &column);
  gql_store_sv(hv, "line", newSViv(line));
  gql_store_sv(hv, "column", newSViv(0));
  return newRV_noinc((SV *)hv);
}

static void
gql_store_endline_location(pTHX_ gql_parser_t *p, HV *hv) {
  gql_store_sv(hv, "location", gql_make_endline_location(aTHX_ p));
}

static SV *
gql_make_current_or_endline_location(pTHX_ gql_parser_t *p) {
  IV current_line;
  IV current_column;
  IV last_line;
  IV last_column;
  if (p->kind == TOK_EOF) {
    return gql_make_current_location(aTHX_ p);
  }
  gql_line_column_from_pos(p, p->tok_start, &current_line, &current_column, 1);
  gql_line_column_from_last(p, &last_line, &last_column);
  if (current_line == last_line) {
    return gql_make_current_location(aTHX_ p);
  }
  return gql_make_endline_location(aTHX_ p);
}

static void
gql_store_current_or_endline_location(pTHX_ gql_parser_t *p, HV *hv) {
  gql_store_sv(hv, "location", gql_make_current_or_endline_location(aTHX_ p));
}

static SV *
gql_make_type_wrapper(pTHX_ SV *type_sv, const char *kind) {
  AV *av = newAV();
  HV *inner = newHV();
  av_push(av, newSVpv(kind, 0));
  gql_store_sv(inner, "type", type_sv);
  av_push(av, newRV_noinc((SV *)inner));
  return newRV_noinc((SV *)av);
}

static SV *
gql_tokenize_source(pTHX_ SV *source_sv) {
  gql_parser_t p;
  STRLEN len;
  const char *src = SvPV(source_sv, len);
  AV *tokens = newAV();

  p.src = src;
  p.len = len;
  p.pos = 0;
  p.last_pos = (STRLEN)-1;
  p.tok_start = 0;
  p.tok_end = 0;
  p.val_start = 0;
  p.val_end = 0;
  p.kind = TOK_EOF;
  p.is_utf8 = SvUTF8(source_sv) ? 1 : 0;

  gql_advance(aTHX_ &p);
  while (p.kind != TOK_EOF) {
    HV *hv = newHV();
    IV line;
    IV column;
    HV *loc_hv = newHV();

    gql_line_column_from_pos(&p, p.tok_start, &line, &column, 1);
    gql_store_sv(loc_hv, "line", newSViv(line));
    gql_store_sv(loc_hv, "column", newSViv(column));

    gql_store_sv(hv, "kind", newSVpv(gql_token_kind_name(p.kind), 0));
    gql_store_sv(hv, "text", gql_copy_token_sv(aTHX_ &p));
    gql_store_sv(hv, "start", newSVuv((UV)p.tok_start));
    gql_store_sv(hv, "end", newSVuv((UV)p.tok_end));
    gql_store_sv(hv, "loc", newRV_noinc((SV *)loc_hv));
    av_push(tokens, newRV_noinc((SV *)hv));

    gql_advance(aTHX_ &p);
  }

  return newRV_noinc((SV *)tokens);
}

static SV *
gql_graphqlperl_find_legacy_empty_object_location(pTHX_ SV *source_sv) {
  gql_parser_t p;
  STRLEN len;
  const char *src = SvPV(source_sv, len);

  p.src = src;
  p.len = len;
  p.pos = 0;
  p.last_pos = (STRLEN)-1;
  p.tok_start = 0;
  p.tok_end = 0;
  p.val_start = 0;
  p.val_end = 0;
  p.kind = TOK_EOF;
  p.is_utf8 = SvUTF8(source_sv) ? 1 : 0;

  gql_advance(aTHX_ &p);
  while (p.kind != TOK_EOF) {
    if (p.kind == TOK_COLON || p.kind == TOK_EQUALS) {
      gql_advance(aTHX_ &p);
      if (p.kind == TOK_LBRACE) {
        gql_advance(aTHX_ &p);
        if (p.kind == TOK_RBRACE) {
          IV line;
          IV column;
          HV *loc_hv = newHV();
          gql_line_column_from_pos(&p, p.tok_start, &line, &column, 1);
          gql_store_sv(loc_hv, "line", newSViv(line));
          gql_store_sv(loc_hv, "column", newSViv(column));
          return newRV_noinc((SV *)loc_hv);
        }
      }
      continue;
    }
    gql_advance(aTHX_ &p);
  }

  return &PL_sv_undef;
}

static SV *
gql_parse_list_value(pTHX_ gql_parser_t *p, int is_const) {
  AV *av = newAV();
  gql_expect(aTHX_ p, TOK_LBRACKET, NULL);
  while (p->kind != TOK_RBRACKET) {
    av_push(av, gql_parse_value(aTHX_ p, is_const));
  }
  gql_expect(aTHX_ p, TOK_RBRACKET, NULL);
  return newRV_noinc((SV *)av);
}

static SV *
gql_parse_object_value(pTHX_ gql_parser_t *p, int is_const) {
  HV *hv = newHV();
  gql_expect(aTHX_ p, TOK_LBRACE, "Expected name");
  while (p->kind != TOK_RBRACE) {
    SV *name = gql_parse_name(aTHX_ p, "Expected name");
    gql_expect(aTHX_ p, TOK_COLON, NULL);
    gql_store_sv(hv, SvPV_nolen(name), gql_parse_value(aTHX_ p, is_const));
  }
  gql_expect(aTHX_ p, TOK_RBRACE, NULL);
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_value(pTHX_ gql_parser_t *p, int is_const) {
  switch (p->kind) {
    case TOK_DOLLAR: {
      SV *name;
      if (is_const) {
        gql_throw(aTHX_ p, p->tok_start, "Expected name or constant");
      }
      gql_advance(aTHX_ p);
      name = gql_parse_name(aTHX_ p, "Expected name");
      return newRV_noinc(name);
    }
    case TOK_INT: {
      SV *sv = gql_copy_token_sv(aTHX_ p);
      sv_setiv(sv, SvIV(sv));
      gql_advance(aTHX_ p);
      return sv;
    }
    case TOK_FLOAT: {
      SV *sv = gql_copy_token_sv(aTHX_ p);
      sv_setnv(sv, SvNV(sv));
      gql_advance(aTHX_ p);
      return sv;
    }
    case TOK_STRING:
    case TOK_BLOCK_STRING: {
      SV *sv = gql_copy_value_sv(aTHX_ p);
      gql_advance(aTHX_ p);
      return sv;
    }
    case TOK_NAME: {
      if (gql_peek_name(p, "true")) {
        gql_advance(aTHX_ p);
        return gql_call_helper1(aTHX_ "GraphQL::Houtou::XS::Parser::_make_bool", newSViv(1));
      }
      if (gql_peek_name(p, "false")) {
        gql_advance(aTHX_ p);
        return gql_call_helper1(aTHX_ "GraphQL::Houtou::XS::Parser::_make_bool", newSViv(0));
      }
      if (gql_peek_name(p, "null")) {
        gql_advance(aTHX_ p);
        return newSV(0);
      }
      {
        SV *name = gql_copy_token_sv(aTHX_ p);
        SV *ref1 = newRV_noinc(name);
        gql_advance(aTHX_ p);
        return newRV_noinc(ref1);
      }
    }
    case TOK_LBRACKET:
      return gql_parse_list_value(aTHX_ p, is_const);
    case TOK_LBRACE:
      return gql_parse_object_value(aTHX_ p, is_const);
    default:
      gql_throw(aTHX_ p, p->tok_start, is_const ? "Expected name or constant" : "Expected value");
  }
  return &PL_sv_undef;
}

static SV *
gql_parse_arguments(pTHX_ gql_parser_t *p, int is_const) {
  HV *hv = newHV();
  gql_expect(aTHX_ p, TOK_LPAREN, NULL);
  if (p->kind == TOK_RPAREN) {
    gql_throw_expected_message(aTHX_ p, p->tok_start, "Expected name");
  }
  while (p->kind != TOK_RPAREN) {
    SV *name = gql_parse_name(aTHX_ p, "Expected name");
    gql_expect(aTHX_ p, TOK_COLON, NULL);
    gql_store_sv(hv, SvPV_nolen(name), gql_parse_value(aTHX_ p, is_const));
  }
  gql_expect(aTHX_ p, TOK_RPAREN, NULL);
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_directive(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  gql_expect(aTHX_ p, TOK_AT, NULL);
  gql_store_sv(hv, "name", gql_parse_name(aTHX_ p, "Expected name"));
  if (p->kind == TOK_LPAREN) {
    gql_store_sv(hv, "arguments", gql_parse_arguments(aTHX_ p, 0));
  }
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_directives(pTHX_ gql_parser_t *p) {
  AV *av = newAV();
  while (p->kind == TOK_AT) {
    av_push(av, gql_parse_directive(aTHX_ p));
  }
  return newRV_noinc((SV *)av);
}

static SV *
gql_parse_selection_set(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  AV *av = newAV();
  gql_expect(aTHX_ p, TOK_LBRACE, "Expected name");
  if (p->kind == TOK_RBRACE) {
    gql_throw(aTHX_ p, p->tok_start, "Expected name");
  }
  while (p->kind != TOK_RBRACE) {
    av_push(av, gql_parse_selection(aTHX_ p));
  }
  gql_expect(aTHX_ p, TOK_RBRACE, NULL);
  gql_store_sv(hv, "selections", newRV_noinc((SV *)av));
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_field(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  int had_directives = 0;
  int had_selection_set = 0;
  SV *first = gql_parse_name(aTHX_ p, "Expected name");
  if (p->kind == TOK_COLON) {
    gql_store_sv(hv, "alias", first);
    gql_advance(aTHX_ p);
    gql_store_sv(hv, "name", gql_parse_name(aTHX_ p, "Expected name"));
  } else {
    gql_store_sv(hv, "name", first);
  }
  if (p->kind == TOK_LPAREN) {
    gql_store_sv(hv, "arguments", gql_parse_arguments(aTHX_ p, 0));
  }
  if (p->kind == TOK_AT) {
    had_directives = 1;
    gql_store_sv(hv, "directives", gql_parse_directives(aTHX_ p));
  }
  if (p->kind == TOK_LBRACE) {
    had_selection_set = 1;
    SV *sel = gql_parse_selection_set(aTHX_ p);
    HV *selhv = (HV *)SvRV(sel);
    SV **svp = hv_fetch(selhv, "selections", 10, 0);
    gql_store_sv(hv, "selections", newSVsv(*svp));
  }
  gql_store_sv(hv, "kind", newSVpv("field", 0));
  if (had_selection_set) {
    gql_store_current_location(aTHX_ p, hv);
  } else if (had_directives) {
    gql_store_current_or_endline_location(aTHX_ p, hv);
  } else {
    gql_store_current_location(aTHX_ p, hv);
  }
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_selection(pTHX_ gql_parser_t *p) {
  if (p->kind == TOK_SPREAD) {
    HV *hv = newHV();
    gql_advance(aTHX_ p);
    if (gql_peek_name(p, "on")) {
      gql_parser_t lookahead = *p;
      gql_advance(aTHX_ &lookahead);
      if (lookahead.kind != TOK_NAME) {
        gql_throw(aTHX_ p, p->tok_start, "Unexpected Name \"on\"");
      }
      gql_advance(aTHX_ p);
      gql_store_sv(hv, "on", gql_parse_name(aTHX_ p, "Expected name"));
      if (p->kind == TOK_AT) {
        gql_store_sv(hv, "directives", gql_parse_directives(aTHX_ p));
      }
      {
        SV *sel = gql_parse_selection_set(aTHX_ p);
        HV *selhv = (HV *)SvRV(sel);
        SV **svp = hv_fetch(selhv, "selections", 10, 0);
        gql_store_sv(hv, "selections", newSVsv(*svp));
      }
      gql_store_sv(hv, "kind", newSVpv("inline_fragment", 0));
      gql_store_current_location(aTHX_ p, hv);
      return newRV_noinc((SV *)hv);
    }
    if (p->kind == TOK_LBRACE) {
      SV *sel = gql_parse_selection_set(aTHX_ p);
      HV *selhv = (HV *)SvRV(sel);
      SV **svp = hv_fetch(selhv, "selections", 10, 0);
      gql_store_sv(hv, "selections", newSVsv(*svp));
      gql_store_sv(hv, "kind", newSVpv("inline_fragment", 0));
      gql_store_current_location(aTHX_ p, hv);
      return newRV_noinc((SV *)hv);
    }
    if (p->kind == TOK_AT) {
      gql_store_sv(hv, "directives", gql_parse_directives(aTHX_ p));
      {
        SV *sel = gql_parse_selection_set(aTHX_ p);
        HV *selhv = (HV *)SvRV(sel);
        SV **svp = hv_fetch(selhv, "selections", 10, 0);
        gql_store_sv(hv, "selections", newSVsv(*svp));
      }
      gql_store_sv(hv, "kind", newSVpv("inline_fragment", 0));
      gql_store_current_location(aTHX_ p, hv);
      return newRV_noinc((SV *)hv);
    }
    gql_store_sv(hv, "name", gql_parse_fragment_name(aTHX_ p));
    if (p->kind == TOK_AT) {
      gql_store_sv(hv, "directives", gql_parse_directives(aTHX_ p));
      gql_store_sv(hv, "kind", newSVpv("fragment_spread", 0));
      gql_store_current_or_endline_location(aTHX_ p, hv);
      return newRV_noinc((SV *)hv);
    }
    gql_store_sv(hv, "kind", newSVpv("fragment_spread", 0));
    gql_store_current_location(aTHX_ p, hv);
    return newRV_noinc((SV *)hv);
  }
  return gql_parse_field(aTHX_ p);
}

static SV *
gql_parse_variable_definitions(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  gql_expect(aTHX_ p, TOK_LPAREN, NULL);
  if (p->kind == TOK_RPAREN) {
    gql_throw(aTHX_ p, p->tok_start, "Expected $argument: Type");
  }
  while (p->kind != TOK_RPAREN) {
    HV *def = newHV();
    SV *name;
    gql_expect(aTHX_ p, TOK_DOLLAR, NULL);
    name = gql_parse_name(aTHX_ p, "Expected name");
    gql_expect(aTHX_ p, TOK_COLON, NULL);
    gql_store_sv(def, "type", gql_parse_type_reference(aTHX_ p));
    if (p->kind == TOK_EQUALS) {
      gql_advance(aTHX_ p);
      gql_store_sv(def, "default_value", gql_parse_value(aTHX_ p, 1));
    }
    gql_store_sv(hv, SvPV_nolen(name), newRV_noinc((SV *)def));
  }
  gql_expect(aTHX_ p, TOK_RPAREN, NULL);
  {
    HV *wrap = newHV();
    gql_store_sv(wrap, "variables", newRV_noinc((SV *)hv));
    return newRV_noinc((SV *)wrap);
  }
}

static SV *
gql_parse_type_reference(pTHX_ gql_parser_t *p) {
  SV *type_sv;
  if (p->kind == TOK_LBRACKET) {
    gql_advance(aTHX_ p);
    type_sv = gql_parse_type_reference(aTHX_ p);
    gql_expect(aTHX_ p, TOK_RBRACKET, NULL);
    type_sv = gql_make_type_wrapper(aTHX_ type_sv, "list");
  } else {
    type_sv = gql_parse_name(aTHX_ p, "Expected name");
  }
  if (p->kind == TOK_BANG) {
    gql_advance(aTHX_ p);
    type_sv = gql_make_type_wrapper(aTHX_ type_sv, "non_null");
  }
  return type_sv;
}

static SV *
gql_parse_operation_definition(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  if (p->kind == TOK_LBRACE) {
    SV *sel = gql_parse_selection_set(aTHX_ p);
    HV *selhv = (HV *)SvRV(sel);
    SV **svp = hv_fetch(selhv, "selections", 10, 0);
    gql_store_sv(hv, "selections", newSVsv(*svp));
    gql_store_sv(hv, "kind", newSVpv("operation", 0));
    gql_store_current_location(aTHX_ p, hv);
    return newRV_noinc((SV *)hv);
  }
  if (!(gql_peek_name(p, "query") || gql_peek_name(p, "mutation") || gql_peek_name(p, "subscription"))) {
    gql_throw(aTHX_ p, p->tok_start, "Expected executable definition");
  }
  gql_store_sv(hv, "operationType", gql_copy_token_sv(aTHX_ p));
  gql_advance(aTHX_ p);
  if (p->kind == TOK_NAME) {
    gql_store_sv(hv, "name", gql_parse_name(aTHX_ p, "Expected name"));
  }
  if (p->kind == TOK_LPAREN) {
    SV *vars = gql_parse_variable_definitions(aTHX_ p);
    HV *varhv = (HV *)SvRV(vars);
    SV **svp = hv_fetch(varhv, "variables", 9, 0);
    gql_store_sv(hv, "variables", newSVsv(*svp));
  }
  if (p->kind == TOK_AT) {
    gql_store_sv(hv, "directives", gql_parse_directives(aTHX_ p));
  }
  {
    SV *sel = gql_parse_selection_set(aTHX_ p);
    HV *selhv = (HV *)SvRV(sel);
    SV **svp = hv_fetch(selhv, "selections", 10, 0);
    gql_store_sv(hv, "selections", newSVsv(*svp));
  }
  gql_store_sv(hv, "kind", newSVpv("operation", 0));
  gql_store_current_location(aTHX_ p, hv);
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_fragment_definition(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  gql_advance(aTHX_ p);
  gql_store_sv(hv, "name", gql_parse_fragment_name(aTHX_ p));
  if (!gql_peek_name(p, "on")) {
    gql_throw(aTHX_ p, p->tok_start, "Expected \"on\"");
  }
  gql_advance(aTHX_ p);
  gql_store_sv(hv, "on", gql_parse_name(aTHX_ p, "Expected name"));
  if (p->kind == TOK_AT) {
    gql_store_sv(hv, "directives", gql_parse_directives(aTHX_ p));
  }
  {
    SV *sel = gql_parse_selection_set(aTHX_ p);
    HV *selhv = (HV *)SvRV(sel);
    SV **svp = hv_fetch(selhv, "selections", 10, 0);
    gql_store_sv(hv, "selections", newSVsv(*svp));
  }
  gql_store_sv(hv, "kind", newSVpv("fragment", 0));
  gql_store_current_location(aTHX_ p, hv);
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_description(pTHX_ gql_parser_t *p) {
  HV *hv;
  SV *desc;
  if (!(p->kind == TOK_STRING || p->kind == TOK_BLOCK_STRING)) {
    return &PL_sv_undef;
  }
  desc = gql_copy_value_sv(aTHX_ p);
  gql_advance(aTHX_ p);
  hv = newHV();
  gql_store_sv(hv, "description", desc);
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_input_value_definition(pTHX_ gql_parser_t *p) {
  SV *description = gql_parse_description(aTHX_ p);
  HV *def = newHV();
  SV *name = gql_parse_name(aTHX_ p, "Expected name");
  gql_expect(aTHX_ p, TOK_COLON, NULL);
  gql_store_sv(def, "type", gql_parse_type_reference(aTHX_ p));
  if (p->kind == TOK_EQUALS) {
    gql_advance(aTHX_ p);
    gql_store_sv(def, "default_value", gql_parse_value(aTHX_ p, 1));
  }
  if (p->kind == TOK_AT) {
    gql_store_sv(def, "directives", gql_parse_directives(aTHX_ p));
  }
  if (SvOK(description)) {
    HV *dhv = (HV *)SvRV(description);
    SV **svp = hv_fetch(dhv, "description", 11, 0);
    gql_store_sv(def, "description", newSVsv(*svp));
  }
  {
    HV *wrap = newHV();
    gql_store_sv(wrap, SvPV_nolen(name), newRV_noinc((SV *)def));
    return newRV_noinc((SV *)wrap);
  }
}

static SV *
gql_parse_arguments_definition(pTHX_ gql_parser_t *p) {
  HV *args = newHV();
  gql_expect(aTHX_ p, TOK_LPAREN, NULL);
  if (p->kind == TOK_RPAREN) {
    gql_throw_expected_message(aTHX_ p, p->tok_start, "Expected name");
  }
  while (p->kind != TOK_RPAREN) {
    SV *item = gql_parse_input_value_definition(aTHX_ p);
    HV *ihv = (HV *)SvRV(item);
    hv_iterinit(ihv);
    HE *he = hv_iternext(ihv);
    gql_store_sv(args, HeKEY(he), newSVsv(HeVAL(he)));
  }
  gql_expect(aTHX_ p, TOK_RPAREN, NULL);
  {
    HV *wrap = newHV();
    gql_store_sv(wrap, "args", newRV_noinc((SV *)args));
    return newRV_noinc((SV *)wrap);
  }
}

static SV *
gql_parse_field_definition(pTHX_ gql_parser_t *p) {
  SV *description = gql_parse_description(aTHX_ p);
  HV *def = newHV();
  SV *name = gql_parse_name(aTHX_ p, "Expected name");
  if (p->kind == TOK_LPAREN) {
    SV *args = gql_parse_arguments_definition(aTHX_ p);
    HV *ahv = (HV *)SvRV(args);
    SV **svp = hv_fetch(ahv, "args", 4, 0);
    gql_store_sv(def, "args", newSVsv(*svp));
  }
  gql_expect(aTHX_ p, TOK_COLON, NULL);
  gql_store_sv(def, "type", gql_parse_type_reference(aTHX_ p));
  if (p->kind == TOK_AT) {
    gql_store_sv(def, "directives", gql_parse_directives(aTHX_ p));
  }
  if (SvOK(description)) {
    HV *dhv = (HV *)SvRV(description);
    SV **svp = hv_fetch(dhv, "description", 11, 0);
    gql_store_sv(def, "description", newSVsv(*svp));
  }
  {
    HV *wrap = newHV();
    gql_store_sv(wrap, SvPV_nolen(name), newRV_noinc((SV *)def));
    return newRV_noinc((SV *)wrap);
  }
}

static SV *
gql_parse_schema_definition(pTHX_ gql_parser_t *p) {
  return gql_parse_schema_definition_extended(aTHX_ p, 0);
}

static SV *
gql_parse_schema_definition_extended(pTHX_ gql_parser_t *p, int allow_empty_body) {
  HV *hv = newHV();
  int had_directives = 0;
  gql_advance(aTHX_ p);
  if (p->kind == TOK_AT) {
    had_directives = 1;
    gql_store_sv(hv, "directives", gql_parse_directives(aTHX_ p));
  }
  if (allow_empty_body && p->kind != TOK_LBRACE) {
    gql_store_sv(hv, "kind", newSVpv("schema", 0));
    if (had_directives) {
      gql_store_endline_location(aTHX_ p, hv);
    } else {
      gql_store_current_location(aTHX_ p, hv);
    }
    return newRV_noinc((SV *)hv);
  }
  gql_expect(aTHX_ p, TOK_LBRACE, NULL);
  if (p->kind == TOK_RBRACE) {
    gql_throw(aTHX_ p, p->tok_start, "Expected name");
  }
  while (p->kind != TOK_RBRACE) {
    SV *op_name = gql_parse_name(aTHX_ p, "Expected name");
    gql_expect(aTHX_ p, TOK_COLON, NULL);
    gql_store_sv(hv, SvPV_nolen(op_name), gql_parse_name(aTHX_ p, "Expected name"));
  }
  gql_expect(aTHX_ p, TOK_RBRACE, NULL);
  gql_store_sv(hv, "kind", newSVpv("schema", 0));
  gql_store_endline_location(aTHX_ p, hv);
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_scalar_type_definition(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  int had_directives = 0;
  gql_advance(aTHX_ p);
  gql_store_sv(hv, "name", gql_parse_name(aTHX_ p, "Expected name"));
  if (p->kind == TOK_AT) {
    had_directives = 1;
    gql_store_sv(hv, "directives", gql_parse_directives(aTHX_ p));
  }
  gql_store_sv(hv, "kind", newSVpv("scalar", 0));
  if (had_directives) {
    gql_store_endline_location(aTHX_ p, hv);
  } else {
    gql_store_current_location(aTHX_ p, hv);
  }
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_object_type_definition(pTHX_ gql_parser_t *p, const char *kind) {
  HV *hv = newHV();
  int had_directives = 0;
  int had_body = 0;
  gql_advance(aTHX_ p);
  gql_store_sv(hv, "name", gql_parse_name(aTHX_ p, "Expected name"));
  if (strcmp(kind, "type") == 0 && gql_peek_name(p, "implements")) {
    AV *interfaces = newAV();
    gql_advance(aTHX_ p);
    if (p->kind == TOK_AMP) {
      gql_advance(aTHX_ p);
    }
    av_push(interfaces, gql_parse_name(aTHX_ p, "Expected name"));
    while (p->kind == TOK_AMP) {
      gql_advance(aTHX_ p);
      av_push(interfaces, gql_parse_name(aTHX_ p, "Expected name"));
    }
    gql_store_sv(hv, "interfaces", newRV_noinc((SV *)interfaces));
  }
  if (p->kind == TOK_AT) {
    had_directives = 1;
    gql_store_sv(hv, "directives", gql_parse_directives(aTHX_ p));
  }
  {
    HV *fields = newHV();
    if (p->kind == TOK_LBRACE) {
      had_body = 1;
      gql_advance(aTHX_ p);
      if (p->kind == TOK_RBRACE) {
        gql_throw(aTHX_ p, p->tok_start, "Expected name");
      }
      while (p->kind != TOK_RBRACE) {
        SV *item = (strcmp(kind, "input") == 0)
          ? gql_parse_input_value_definition(aTHX_ p)
          : gql_parse_field_definition(aTHX_ p);
        HV *ihv = (HV *)SvRV(item);
        hv_iterinit(ihv);
        HE *he = hv_iternext(ihv);
        gql_store_sv(fields, HeKEY(he), newSVsv(HeVAL(he)));
      }
      gql_expect(aTHX_ p, TOK_RBRACE, NULL);
    }
    gql_store_sv(hv, "fields", newRV_noinc((SV *)fields));
  }
  gql_store_sv(hv, "kind", newSVpv(kind, 0));
  if (had_directives || had_body) {
    gql_store_endline_location(aTHX_ p, hv);
  } else {
    gql_store_current_location(aTHX_ p, hv);
  }
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_union_type_definition(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  AV *types = newAV();
  int had_directives = 0;
  int had_members = 0;
  gql_advance(aTHX_ p);
  gql_store_sv(hv, "name", gql_parse_name(aTHX_ p, "Expected name"));
  if (p->kind == TOK_AT) {
    had_directives = 1;
    gql_store_sv(hv, "directives", gql_parse_directives(aTHX_ p));
  }
  if (p->kind == TOK_EQUALS) {
    had_members = 1;
    gql_advance(aTHX_ p);
    if (p->kind == TOK_PIPE) {
      gql_advance(aTHX_ p);
    }
    if (p->kind != TOK_NAME) {
      gql_throw_expected_message(aTHX_ p, p->tok_start, "Expected name");
    }
    av_push(types, gql_parse_name(aTHX_ p, "Expected name"));
    while (p->kind == TOK_PIPE) {
      gql_advance(aTHX_ p);
      av_push(types, gql_parse_name(aTHX_ p, "Expected name"));
    }
  }
  if (had_members) {
    gql_store_sv(hv, "types", newRV_noinc((SV *)types));
  } else {
    SvREFCNT_dec((SV *)types);
  }
  gql_store_sv(hv, "kind", newSVpv("union", 0));
  if (had_members) {
    gql_store_current_location(aTHX_ p, hv);
  } else if (had_directives) {
    gql_store_endline_location(aTHX_ p, hv);
  } else {
    gql_store_current_location(aTHX_ p, hv);
  }
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_enum_type_definition(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  HV *values = newHV();
  int had_directives = 0;
  int had_body = 0;
  gql_advance(aTHX_ p);
  gql_store_sv(hv, "name", gql_parse_name(aTHX_ p, "Expected name"));
  if (p->kind == TOK_AT) {
    had_directives = 1;
    gql_store_sv(hv, "directives", gql_parse_directives(aTHX_ p));
  }
  if (p->kind == TOK_LBRACE) {
    had_body = 1;
    gql_advance(aTHX_ p);
    if (p->kind == TOK_RBRACE) {
      gql_throw(aTHX_ p, p->tok_start, "Expected name");
    }
    while (p->kind != TOK_RBRACE) {
      SV *description = gql_parse_description(aTHX_ p);
      HV *value_hv = newHV();
      SV *name = gql_parse_name(aTHX_ p, "Expected name");
      const char *name_str = SvPV_nolen(name);
      if (strEQ(name_str, "true") || strEQ(name_str, "false") || strEQ(name_str, "null")) {
        gql_throw(aTHX_ p, p->tok_start > 0 ? p->tok_start - 1 : p->tok_start, "Invalid enum value");
      }
      if (p->kind == TOK_AT) {
        gql_store_sv(value_hv, "directives", gql_parse_directives(aTHX_ p));
      }
      if (SvOK(description)) {
        HV *dhv = (HV *)SvRV(description);
        SV **svp = hv_fetch(dhv, "description", 11, 0);
        gql_store_sv(value_hv, "description", newSVsv(*svp));
      }
      gql_store_sv(values, name_str, newRV_noinc((SV *)value_hv));
    }
    gql_expect(aTHX_ p, TOK_RBRACE, NULL);
  }
  gql_store_sv(hv, "values", newRV_noinc((SV *)values));
  gql_store_sv(hv, "kind", newSVpv("enum", 0));
  if (had_directives || had_body) {
    gql_store_endline_location(aTHX_ p, hv);
  } else {
    gql_store_current_location(aTHX_ p, hv);
  }
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_directive_definition(pTHX_ gql_parser_t *p) {
  HV *hv = newHV();
  AV *locations = newAV();
  gql_advance(aTHX_ p);
  gql_expect(aTHX_ p, TOK_AT, NULL);
  gql_store_sv(hv, "name", gql_parse_name(aTHX_ p, "Expected name"));
  if (p->kind == TOK_LPAREN) {
    SV *args = gql_parse_arguments_definition(aTHX_ p);
    HV *ahv = (HV *)SvRV(args);
    SV **svp = hv_fetch(ahv, "args", 4, 0);
    gql_store_sv(hv, "args", newSVsv(*svp));
  }
  if (!gql_peek_name(p, "on")) {
    gql_throw(aTHX_ p, p->tok_start, "Expected \"on\"");
  }
  gql_advance(aTHX_ p);
  if (p->kind == TOK_PIPE) {
    gql_advance(aTHX_ p);
  }
  if (p->kind != TOK_NAME) {
    gql_throw_expected_message(aTHX_ p, p->tok_start, "Expected name");
  }
  av_push(locations, gql_parse_name(aTHX_ p, "Expected name"));
  while (p->kind == TOK_PIPE) {
    gql_advance(aTHX_ p);
    av_push(locations, gql_parse_name(aTHX_ p, "Expected name"));
  }
  gql_store_sv(hv, "locations", newRV_noinc((SV *)locations));
  gql_store_sv(hv, "kind", newSVpv("directive", 0));
  gql_store_endline_location(aTHX_ p, hv);
  return newRV_noinc((SV *)hv);
}

static SV *
gql_parse_type_system_definition(pTHX_ gql_parser_t *p, SV *description) {
  SV *node;
  int is_extend = 0;
  if (gql_peek_name(p, "extend")) {
    is_extend = 1;
    gql_advance(aTHX_ p);
  }
  if (gql_peek_name(p, "schema")) {
    node = is_extend
      ? gql_parse_schema_definition_extended(aTHX_ p, 1)
      : gql_parse_schema_definition(aTHX_ p);
  } else if (gql_peek_name(p, "scalar")) {
    node = gql_parse_scalar_type_definition(aTHX_ p);
  } else if (gql_peek_name(p, "type")) {
    node = gql_parse_object_type_definition(aTHX_ p, "type");
  } else if (gql_peek_name(p, "interface")) {
    node = gql_parse_object_type_definition(aTHX_ p, "interface");
  } else if (gql_peek_name(p, "input")) {
    node = gql_parse_object_type_definition(aTHX_ p, "input");
  } else if (gql_peek_name(p, "union")) {
    node = gql_parse_union_type_definition(aTHX_ p);
  } else if (gql_peek_name(p, "enum")) {
    node = gql_parse_enum_type_definition(aTHX_ p);
  } else if (gql_peek_name(p, "directive")) {
    node = gql_parse_directive_definition(aTHX_ p);
  } else {
    gql_throw(aTHX_ p, p->tok_start, "Expected type system definition");
    return &PL_sv_undef;
  }
  if (SvOK(description)) {
    HV *node_hv = (HV *)SvRV(node);
    HV *desc_hv = (HV *)SvRV(description);
    SV **svp = hv_fetch(desc_hv, "description", 11, 0);
    gql_store_sv(node_hv, "description", newSVsv(*svp));
  }
  return node;
}

static SV *
gql_parse_definition(pTHX_ gql_parser_t *p) {
  if (p->kind == TOK_LBRACE) {
    return gql_parse_operation_definition(aTHX_ p);
  }
  if (p->kind == TOK_STRING || p->kind == TOK_BLOCK_STRING) {
    SV *description = gql_parse_description(aTHX_ p);
    return gql_parse_type_system_definition(aTHX_ p, description);
  }
  if (gql_peek_name(p, "fragment")) {
    return gql_parse_fragment_definition(aTHX_ p);
  }
  if (gql_peek_name(p, "query") || gql_peek_name(p, "mutation") || gql_peek_name(p, "subscription")) {
    return gql_parse_operation_definition(aTHX_ p);
  }
  return gql_parse_type_system_definition(aTHX_ p, &PL_sv_undef);
}

static AV *
gql_parse_definitions(pTHX_ gql_parser_t *p) {
  AV *av = newAV();
  while (p->kind != TOK_EOF) {
    av_push(av, gql_parse_definition(aTHX_ p));
  }
  return av;
}

static SV *
gql_parse_document(pTHX_ SV *source_sv) {
  gql_parser_t p;
  STRLEN len;
  const char *src = SvPV(source_sv, len);
  p.src = src;
  p.len = len;
  p.pos = 0;
  p.last_pos = (STRLEN)-1;
  p.tok_start = 0;
  p.tok_end = 0;
  p.val_start = 0;
  p.val_end = 0;
  p.kind = TOK_EOF;
  p.is_utf8 = SvUTF8(source_sv) ? 1 : 0;
  gql_advance(aTHX_ &p);
  return newRV_noinc((SV *)gql_parse_definitions(aTHX_ &p));
}

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Parser

SV *
parse_xs(source, no_location = &PL_sv_undef)
    SV *source
    SV *no_location
  CODE:
    RETVAL = gql_parse_document(aTHX_ source);
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
graphqljs_parse_document_xs(source, no_location = &PL_sv_undef)
    SV *source
    SV *no_location
  CODE:
    RETVAL = gql_graphqljs_parse_document(aTHX_ source, no_location);
  OUTPUT:
    RETVAL

SV *
graphqljs_parse_executable_document_xs(source, no_location = &PL_sv_undef)
    SV *source
    SV *no_location
  CODE:
    RETVAL = gql_graphqljs_parse_executable_document(aTHX_ source, no_location);
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
