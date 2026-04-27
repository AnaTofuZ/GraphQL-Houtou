/*
 * Responsibility: low-level parser utilities, source preprocessing,
 * graphql-js metadata patching, and document-level location helpers.
 */
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
gql_unescape_string_sv(pTHX_ SV *raw) {
  STRLEN len;
  const char *src = SvPV(raw, len);
  SV *out = newSVpvn("", 0);
  char *dst;
  STRLEN i;
  STRLEN out_len = 0;
  int needs_utf8 = SvUTF8(raw) ? 1 : 0;

  SvGROW(out, len + 1);
  dst = SvPVX(out);

  for (i = 0; i < len; i++) {
    if (src[i] == '\\' && i + 1 < len) {
      char decoded = '\0';
      switch (src[i + 1]) {
        case '"': decoded = '"'; break;
        case '\\': decoded = '\\'; break;
        case '/': decoded = '/'; break;
        case 'b': decoded = '\b'; break;
        case 'f': decoded = '\f'; break;
        case 'n': decoded = '\n'; break;
        case 'r': decoded = '\r'; break;
        case 't': decoded = '\t'; break;
        case 'u': {
          UV codepoint = 0;
          U8 *utf8_end;

          if (i + 5 < len) {
            if (!gql_hex4_to_uv(src + i + 2, &codepoint)) {
              croak("Invalid Unicode escape sequence");
            }

            if (codepoint >= 0xD800 && codepoint <= 0xDBFF &&
                i + 11 < len &&
                src[i + 6] == '\\' &&
                src[i + 7] == 'u') {
              UV low = 0;
              if (!gql_hex4_to_uv(src + i + 8, &low)) {
                croak("Invalid Unicode escape sequence");
              }
              if (low >= 0xDC00 && low <= 0xDFFF) {
                codepoint = 0x10000 + (((codepoint - 0xD800) << 10) | (low - 0xDC00));
                i += 6;
              }
            }

            utf8_end = uvchr_to_utf8((U8 *)(dst + out_len), codepoint);
            out_len += (STRLEN)(utf8_end - (U8 *)(dst + out_len));
            needs_utf8 = 1;
            i += 5;
            continue;
          }
          break;
        }
        default: break;
      }
      if (decoded != '\0') {
        dst[out_len++] = decoded;
        i++;
        continue;
      }
    }
    dst[out_len++] = src[i];
  }

  dst[out_len] = '\0';
  SvCUR_set(out, out_len);

  if (needs_utf8) {
    SvUTF8_on(out);
  }
  return out;
}

static int
gql_hex4_to_uv(const char *src, UV *value) {
  UV parsed = 0;
  I32 i;

  for (i = 0; i < 4; i++) {
    parsed <<= 4;
    if (src[i] >= '0' && src[i] <= '9') {
      parsed |= (UV)(src[i] - '0');
    } else if (src[i] >= 'A' && src[i] <= 'F') {
      parsed |= (UV)(src[i] - 'A' + 10);
    } else if (src[i] >= 'a' && src[i] <= 'f') {
      parsed |= (UV)(src[i] - 'a' + 10);
    } else {
      return 0;
    }
  }

  *value = parsed;
  return 1;
}

static SV *
gql_copy_value_sv(pTHX_ gql_parser_t *p) {
  SV *raw = gql_make_string_sv(aTHX_ p, p->val_start, p->val_end);
  SV *ret;
  if (p->kind == TOK_BLOCK_STRING) {
    ret = gql_call_helper1(aTHX_ "GraphQL::Houtou::XS::Parser::_block_string_value", raw);
  } else {
    ret = gql_unescape_string_sv(aTHX_ raw);
  }
  SvREFCNT_dec(raw);
  return ret;
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
  XPUSHs(sv_2mortal(source));
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
  char msg[64];

  my_snprintf(msg, sizeof(msg), "Expected %s", gql_expected_token_label(kind));
  gql_throw_expected_message(aTHX_ p, p->tok_start, msg);
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
gql_parser_preprocess_document(pTHX_ SV *source_sv) {
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
  SvREFCNT_dec((SV *)definition_counts);
  return newRV_noinc((SV *)meta);
}

static SV *
gql_parse_directives_only(pTHX_ SV *source_sv) {
  gql_parser_t p;
  SV *directives;

  ENTER;
  SAVETMPS;
  gql_parser_init(aTHX_ &p, source_sv, 0);
  gql_advance(aTHX_ &p);
  directives = gql_parse_directives(aTHX_ &p);
  if (p.kind != TOK_EOF) {
    gql_throw(aTHX_ &p, p.tok_start, "Expected directive");
  }
  gql_parser_invalidate(&p);
  FREETMPS;
  LEAVE;
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
gql_parser_patch_document(pTHX_ SV *doc_sv, SV *meta_sv) {
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
    croak("parser document patcher expects hash references");
  }

  doc_hv = (HV *)SvRV(doc_sv);
  meta_hv = (HV *)SvRV(meta_sv);

  {
    SV **svp = hv_fetch(doc_hv, "definitions", 11, 0);
    if (!svp || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVAV) {
      croak("parser document patcher expected document definitions");
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

static void
gqljs_set_shared_rewritten_loc_nodes(pTHX_ gqljs_loc_context_t *ctx, UV rewritten_pos, SV *left_sv, SV *right_sv) {
  SV *loc_sv;

  if (!ctx || !left_sv || !right_sv) {
    return;
  }
  loc_sv = gqljs_loc_from_rewritten_pos(aTHX_ ctx, rewritten_pos);
  gqljs_set_loc_node(aTHX_ left_sv, loc_sv);
  gqljs_set_loc_node(aTHX_ right_sv, loc_sv);
  SvREFCNT_dec(loc_sv);
}
