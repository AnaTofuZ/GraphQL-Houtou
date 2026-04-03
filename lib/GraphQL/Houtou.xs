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
} gql_parser_t;

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
static SV *gqljs_clone_with_loc(pTHX_ SV *value, SV *loc_sv);
static int gqljs_sv_eq_pv(SV *sv, const char *literal);
static const char *gqljs_definition_source_kind(SV *kind_sv);
static const char *gqljs_extension_kind_name(const char *source_kind);
static SV *gql_graphqljs_patch_document(pTHX_ SV *doc_sv, SV *meta_sv);
static SV *gql_graphqljs_apply_executable_loc(pTHX_ SV *doc_sv, SV *source_sv);
static void gqljs_set_loc_node(pTHX_ SV *node_sv, SV *loc_sv);
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
static HV *gqljs_new_node_hv(const char *kind);
static SV *gqljs_new_node_ref(const char *kind);
static SV *gqljs_new_name_node_sv(pTHX_ SV *value_sv);
static SV *gqljs_convert_legacy_type_sv(pTHX_ SV *type_sv);
static SV *gqljs_convert_legacy_value_sv(pTHX_ SV *value_sv);
static AV *gqljs_convert_legacy_arguments_hv(pTHX_ HV *hv);
static AV *gqljs_convert_legacy_directives_av(pTHX_ AV *av);
static SV *gqljs_convert_legacy_selection_sv(pTHX_ SV *selection_sv);
static SV *gqljs_convert_legacy_selection_set_av(pTHX_ AV *av);
static AV *gqljs_convert_legacy_variable_definitions_hv(pTHX_ HV *hv);
static SV *gqljs_convert_legacy_executable_definition_sv(pTHX_ SV *definition_sv);
static int gqljs_cmp_sv_ptrs(const void *a, const void *b);
static SV **gqljs_sorted_hash_keys(pTHX_ HV *hv, I32 *count_out);
static void gqljs_free_sorted_hash_keys(SV **keys, I32 count);

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
  hv_store((HV *)SvRV(node_sv), "loc", 3, newSVsv(loc_sv), 0);
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
gqljs_new_node_hv(const char *kind) {
  HV *hv = newHV();
  gql_store_sv(hv, "kind", newSVpv(kind, 0));
  return hv;
}

static SV *
gqljs_new_node_ref(const char *kind) {
  return newRV_noinc((SV *)gqljs_new_node_hv(kind));
}

static SV *
gqljs_new_name_node_sv(pTHX_ SV *value_sv) {
  HV *hv = gqljs_new_node_hv("Name");
  gql_store_sv(hv, "value", newSVsv(value_sv));
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
parse_directives_xs(source)
    SV *source
  CODE:
    RETVAL = gql_parse_directives_only(aTHX_ source);
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
graphqljs_apply_executable_loc_xs(doc, source)
    SV *doc
    SV *source
  CODE:
    RETVAL = gql_graphqljs_apply_executable_loc(aTHX_ doc, source);
  OUTPUT:
    RETVAL
