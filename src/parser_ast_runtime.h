/*
 * Parser compatibility layer only.
 *
 * Responsibility: graphql-js-shaped parser AST helpers for lazy arrays,
 * location context management, and token-driven AST node location assignment.
 *
 * This header is not part of the runtime/VM mainline. It exists only because
 * the public parser surface still returns graphql-perl-compatible AST while
 * some parser internals continue to use graphql-js-shaped node helpers.
 */
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
  AV *av;
  MAGIC *mg;
  if (!sv || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVAV) {
    return NULL;
  }
  av = (AV *)SvRV(sv);
  mg = mg_find((SV *)av, PERL_MAGIC_tied);
  if (mg && mg->mg_obj) {
    HV *tied_hv = NULL;
    SV *data_sv = NULL;
    SV *state_sv = NULL;
    SV *ptr_sv = NULL;
    SV *kind_sv = NULL;

    if (SvROK(mg->mg_obj) && SvTYPE(SvRV(mg->mg_obj)) == SVt_PVHV) {
      tied_hv = (HV *)SvRV(mg->mg_obj);
      /* These hash keys are part of the XS fast-path contract with
       * GraphQL::Houtou::XS::LazyArray::*::TIEARRAY. Keep tests in sync if
       * they ever change. */
      data_sv = gqljs_fetch_sv(tied_hv, "data");
      if (data_sv && SvROK(data_sv) && SvTYPE(SvRV(data_sv)) == SVt_PVAV) {
        return (AV *)SvRV(data_sv);
      }
      state_sv = gqljs_fetch_sv(tied_hv, "state");
      ptr_sv = gqljs_fetch_sv(tied_hv, "ptr");
      kind_sv = gqljs_fetch_sv(tied_hv, "kind");
      if (state_sv && ptr_sv && kind_sv && SvIOK(ptr_sv) && SvIOK(kind_sv)) {
        AV *materialized_av = gqljs_materialize_lazy_array(aTHX_ state_sv, SvUV(ptr_sv), SvIV(kind_sv));
        hv_stores(tied_hv, "data", newRV_noinc((SV *)materialized_av));
        return materialized_av;
      }
    }
    {
      dSP;
      SV *materialized_sv;

      ENTER;
      SAVETMPS;
      PUSHMARK(SP);
      XPUSHs(sv_2mortal(newSVsv(mg->mg_obj)));
      PUTBACK;
      call_method("_materialize", G_SCALAR);
      SPAGAIN;
      materialized_sv = newSVsv(POPs);
      PUTBACK;
      FREETMPS;
      LEAVE;

      if (!materialized_sv || !SvROK(materialized_sv) || SvTYPE(SvRV(materialized_sv)) != SVt_PVAV) {
        SvREFCNT_dec(materialized_sv);
        croak("graphql-js lazy array materialization returned a non-array reference");
      }
      av = (AV *)SvRV(materialized_sv);
      SvREFCNT_dec(materialized_sv);
    }
  }
  return av;
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
gqljs_find_named_node_sv(AV *av, SV *name_sv) {
  STRLEN len;
  const char *name;

  if (!name_sv) {
    return NULL;
  }
  name = SvPV(name_sv, len);
  return gqljs_find_named_node(av, name);
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
gqljs_find_variable_definition_sv(AV *av, SV *name_sv) {
  STRLEN len;
  const char *name;

  if (!name_sv) {
    return NULL;
  }
  name = SvPV(name_sv, len);
  return gqljs_find_variable_definition(av, name);
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
gqljs_new_lazy_loc_sv(pTHX_ UV start) {
  AV *loc_av = newAV();
  HV *stash = gv_stashpv("GraphQL::Houtou::XS::LazyLoc", GV_ADD);
  SV *loc_sv;

  av_push(loc_av, newSVuv(start));
  loc_sv = newRV_noinc((SV *)loc_av);
  return sv_bless(loc_sv, stash);
}

static int
gqljs_magic_free_state(pTHX_ SV *sv, MAGIC *mg) {
  SV *state_sv = mg && mg->mg_ptr ? (SV *)mg->mg_ptr : NULL;

  if (state_sv) {
    SvREFCNT_dec(state_sv);
    mg->mg_ptr = NULL;
  }
  return 0;
}

static MGVTBL gqljs_lazy_state_vtbl = {
  NULL,
  NULL,
  NULL,
  NULL,
  gqljs_magic_free_state
#if PERL_VERSION_GE(5, 15, 0)
  ,NULL
  ,NULL
  ,NULL
#endif
};

static void
gqljs_attach_magic_state(pTHX_ SV *sv, SV *state_sv) {
  MAGIC *mg;

  if (!sv || !state_sv) {
    return;
  }

  sv_magicext(sv, NULL, PERL_MAGIC_ext, &gqljs_lazy_state_vtbl, NULL, 0);
  mg = mg_findext(sv, PERL_MAGIC_ext, &gqljs_lazy_state_vtbl);
  if (!mg) {
    croak("failed to attach graphql-js lazy state");
  }
  mg->mg_ptr = (char *)SvREFCNT_inc_simple_NN(state_sv);
}

static void
gqljs_lazy_state_destroy(gqljs_lazy_state_t *state) {
  if (!state) {
    return;
  }
  if (state->source_sv) {
    SvREFCNT_dec(state->source_sv);
    state->source_sv = NULL;
  }
  if (state->has_ctx) {
    gqljs_loc_context_destroy(&state->ctx);
    state->has_ctx = 0;
  }
  if (state->document) {
    gql_ir_free_document(state->document);
    state->document = NULL;
  }
  Safefree(state);
}

static SV *
gqljs_new_lazy_state_sv(pTHX_ gql_ir_document_t *document, SV *source_sv, int with_locations, SV *lazy_location_sv, SV *compact_location_sv) {
  SV *state_sv;
  HV *stash = gv_stashpv("GraphQL::Houtou::XS::LazyState", GV_ADD);
  gqljs_lazy_state_t *state;
  STRLEN source_len;

  Newxz(state, 1, gqljs_lazy_state_t);
  state->document = document;
  if (source_sv) {
    state->source_sv = newSVsv(source_sv);
    document->src = SvPV(state->source_sv, source_len);
    document->len = source_len;
    document->is_utf8 = SvUTF8(state->source_sv) ? 1 : 0;
    if (with_locations) {
      gqljs_loc_context_init(aTHX_ &state->ctx, state->source_sv, NULL);
      state->ctx.lazy_location = SvTRUE(lazy_location_sv) ? 1 : 0;
      state->ctx.compact_location = SvTRUE(compact_location_sv) ? 1 : 0;
      state->has_ctx = 1;
    }
  }

  state_sv = newSVuv(PTR2UV(state));
  return sv_bless(newRV_noinc(state_sv), stash);
}

static gqljs_lazy_state_t *
gqljs_lazy_state_from_sv(SV *state_sv) {
  SV *inner_sv;

  if (!state_sv || !SvROK(state_sv)) {
    croak("expected GraphQL::Houtou::XS::LazyState object");
  }
  inner_sv = SvRV(state_sv);
  if (!SvIOK(inner_sv)) {
    croak("invalid GraphQL::Houtou::XS::LazyState payload");
  }
  return INT2PTR(gqljs_lazy_state_t *, SvUV(inner_sv));
}

static AV *
gqljs_materialize_lazy_array(pTHX_ SV *state_sv, UV ptr, IV kind) {
  gqljs_lazy_state_t *lazy_state = gqljs_lazy_state_from_sv(state_sv);
  gqljs_loc_context_t *ctx = lazy_state->has_ctx ? &lazy_state->ctx : NULL;

  switch (kind) {
    case GQLJS_LAZY_ARRAY_ARGUMENTS:
      return gqljs_build_arguments_from_ir(
        aTHX_ ctx,
        lazy_state->document,
        INT2PTR(gql_ir_ptr_array_t *, ptr),
        state_sv
      );
    case GQLJS_LAZY_ARRAY_DIRECTIVES:
      return gqljs_build_directives_from_ir(
        aTHX_ ctx,
        lazy_state->document,
        INT2PTR(gql_ir_ptr_array_t *, ptr),
        state_sv
      );
    case GQLJS_LAZY_ARRAY_VARIABLE_DEFINITIONS:
      return gqljs_build_variable_definitions_from_ir(
        aTHX_ ctx,
        lazy_state->document,
        INT2PTR(gql_ir_ptr_array_t *, ptr),
        state_sv
      );
    case GQLJS_LAZY_ARRAY_OBJECT_FIELDS:
      return gqljs_build_object_fields_from_ir(
        aTHX_ ctx,
        lazy_state->document,
        INT2PTR(gql_ir_ptr_array_t *, ptr),
        state_sv
      );
  }

  croak("Unknown graphql-js lazy array kind %" IVdf, kind);
  return NULL;
}

static SV *
gqljs_new_lazy_arguments_sv(pTHX_ SV *state_sv, gql_ir_ptr_array_t *arguments) {
  dSP;
  SV *ret_sv;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(state_sv)));
  XPUSHs(sv_2mortal(newSVuv(PTR2UV(arguments))));
  PUTBACK;
  call_pv("GraphQL::Houtou::XS::LazyArray::Arguments::_new", G_SCALAR);
  SPAGAIN;
  ret_sv = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret_sv;
}

static SV *
gqljs_new_lazy_directives_sv(pTHX_ SV *state_sv, gql_ir_ptr_array_t *directives) {
  dSP;
  SV *ret_sv;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(state_sv)));
  XPUSHs(sv_2mortal(newSVuv(PTR2UV(directives))));
  PUTBACK;
  call_pv("GraphQL::Houtou::XS::LazyArray::Directives::_new", G_SCALAR);
  SPAGAIN;
  ret_sv = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret_sv;
}

static SV *
gqljs_new_lazy_variable_definitions_sv(pTHX_ SV *state_sv, gql_ir_ptr_array_t *definitions) {
  dSP;
  SV *ret_sv;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(state_sv)));
  XPUSHs(sv_2mortal(newSVuv(PTR2UV(definitions))));
  PUTBACK;
  call_pv("GraphQL::Houtou::XS::LazyArray::VariableDefinitions::_new", G_SCALAR);
  SPAGAIN;
  ret_sv = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret_sv;
}

static SV *
gqljs_new_lazy_object_fields_sv(pTHX_ SV *state_sv, gql_ir_ptr_array_t *fields) {
  dSP;
  SV *ret_sv;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(state_sv)));
  XPUSHs(sv_2mortal(newSVuv(PTR2UV(fields))));
  PUTBACK;
  call_pv("GraphQL::Houtou::XS::LazyArray::ObjectFields::_new", G_SCALAR);
  SPAGAIN;
  ret_sv = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret_sv;
}

static UV
gqljs_original_pos_from_rewritten_pos(gqljs_loc_context_t *ctx, UV rewritten_pos) {
  UV original_pos = rewritten_pos;

  if (!ctx) {
    return rewritten_pos;
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

  return original_pos;
}

static SV *
gqljs_loc_from_rewritten_pos(pTHX_ gqljs_loc_context_t *ctx, UV rewritten_pos) {
  UV original_pos;
  I32 line_index;
  SV *loc_sv;

  if (!ctx) {
    return &PL_sv_undef;
  }

  original_pos = gqljs_original_pos_from_rewritten_pos(ctx, rewritten_pos);

  if (ctx->num_lines <= 0) {
    return ctx->lazy_location
      ? gqljs_new_lazy_loc_sv(aTHX_ original_pos)
      : gqljs_new_loc_sv(aTHX_ 1, (IV)(original_pos + 1));
  }

  if (ctx->has_last_line_index
      && original_pos >= ctx->line_starts[ctx->last_line_index]
      && (ctx->last_line_index + 1 >= ctx->num_lines
          || original_pos < ctx->line_starts[ctx->last_line_index + 1])) {
    line_index = ctx->last_line_index;
  } else if (ctx->has_last_line_index && original_pos >= ctx->last_original_pos) {
    line_index = ctx->last_line_index;
    while (line_index + 1 < ctx->num_lines && ctx->line_starts[line_index + 1] <= original_pos) {
      line_index++;
    }
  } else {
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
  ctx->last_original_pos = original_pos;
  ctx->last_line_index = line_index;
  ctx->has_last_line_index = 1;

  if (ctx->lazy_location) {
    loc_sv = gqljs_new_lazy_loc_sv(aTHX_ original_pos);
  } else {
    loc_sv = gqljs_new_loc_sv(
      aTHX_
      (IV)(line_index + 1),
      (IV)(original_pos - ctx->line_starts[line_index] + 1)
    );
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
  ctx->rewrite_index = NULL;
  ctx->rewrite_index_count = 0;
  ctx->last_original_pos = 0;
  ctx->last_line_index = 0;
  ctx->has_last_line_index = 0;
  ctx->lazy_location = 0;
  ctx->compact_location = 0;

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
  if (ctx->line_starts) {
    Safefree(ctx->line_starts);
  }
  if (ctx->rewrite_index) {
    Safefree(ctx->rewrite_index);
  }
  ctx->line_starts = NULL;
  ctx->num_lines = 0;
  ctx->rewrite_index = NULL;
  ctx->rewrite_index_count = 0;
  ctx->last_original_pos = 0;
  ctx->last_line_index = 0;
  ctx->has_last_line_index = 0;
  ctx->lazy_location = 0;
  ctx->compact_location = 0;
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
      SV *name_sv = sv_2mortal(newSVpvn(p->src + p->tok_start, p->tok_end - p->tok_start));
      SV *field_sv = gqljs_find_named_node_sv(av, name_sv);
      HV *field_hv;
      SV *field_loc;
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
    SV *name_sv = sv_2mortal(newSVpvn(p->src + p->tok_start, p->tok_end - p->tok_start));
    SV *node_sv = gqljs_find_named_node_sv(av, name_sv);
    HV *node_hv;
    SV *loc;
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
    {
      SV *name_sv = sv_2mortal(newSVpvn(p->src + p->tok_start, p->tok_end - p->tok_start));
      node_sv = gqljs_find_variable_definition_sv(av, name_sv);
    }
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

static void
gqljs_locate_input_value_definitions_nodes(pTHX_ gql_parser_t *p, AV *av) {
  while (p->kind != TOK_RBRACE && p->kind != TOK_RPAREN) {
    SV *description_loc = NULL;
    SV *name_sv;
    SV *node_sv;
    HV *node_hv;
    SV *description_sv;

    if (p->kind == TOK_STRING || p->kind == TOK_BLOCK_STRING) {
      description_loc = sv_2mortal(gql_make_current_location(aTHX_ p));
      gql_advance(aTHX_ p);
    }
    if (p->kind != TOK_NAME) {
      gql_throw_expected_token(aTHX_ p, TOK_NAME);
    }
    name_sv = sv_2mortal(newSVpvn(p->src + p->tok_start, p->tok_end - p->tok_start));
    node_sv = gqljs_find_named_node_sv(av, name_sv);
    if (!node_sv) {
      croak("Missing input value node");
    }
    node_hv = gqljs_node_hv(node_sv);
    gqljs_set_loc_node(aTHX_ node_sv, description_loc ? description_loc : sv_2mortal(gql_make_current_location(aTHX_ p)));
    description_sv = gqljs_fetch_sv(node_hv, "description");
    if (description_sv && description_loc) {
      gqljs_set_loc_node(aTHX_ description_sv, description_loc);
    }
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(node_hv, "name"));
    gql_expect(aTHX_ p, TOK_COLON, NULL);
    gqljs_locate_type_node(aTHX_ p, gqljs_fetch_sv(node_hv, "type"));
    if (gqljs_fetch_sv(node_hv, "defaultValue")) {
      gql_expect(aTHX_ p, TOK_EQUALS, NULL);
      gqljs_locate_value_node(aTHX_ p, gqljs_fetch_sv(node_hv, "defaultValue"));
    }
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(node_hv, "directives"));
  }
}

static void
gqljs_locate_arguments_definition_nodes(pTHX_ gql_parser_t *p, AV *av) {
  if (!av || av_len(av) < 0) {
    return;
  }
  gql_expect(aTHX_ p, TOK_LPAREN, NULL);
  gqljs_locate_input_value_definitions_nodes(aTHX_ p, av);
  gql_expect(aTHX_ p, TOK_RPAREN, NULL);
}

static void
gqljs_locate_field_definitions_nodes(pTHX_ gql_parser_t *p, AV *av) {
  if (!av || av_len(av) < 0) {
    return;
  }
  gql_expect(aTHX_ p, TOK_LBRACE, NULL);
  while (p->kind != TOK_RBRACE) {
    SV *description_loc = NULL;
    SV *name_sv;
    SV *node_sv;
    HV *node_hv;
    SV *description_sv;

    if (p->kind == TOK_STRING || p->kind == TOK_BLOCK_STRING) {
      description_loc = sv_2mortal(gql_make_current_location(aTHX_ p));
      gql_advance(aTHX_ p);
    }
    if (p->kind != TOK_NAME) {
      gql_throw_expected_token(aTHX_ p, TOK_NAME);
    }
    name_sv = sv_2mortal(newSVpvn(p->src + p->tok_start, p->tok_end - p->tok_start));
    node_sv = gqljs_find_named_node_sv(av, name_sv);
    if (!node_sv) {
      croak("Missing field definition node");
    }
    node_hv = gqljs_node_hv(node_sv);
    gqljs_set_loc_node(aTHX_ node_sv, description_loc ? description_loc : sv_2mortal(gql_make_current_location(aTHX_ p)));
    description_sv = gqljs_fetch_sv(node_hv, "description");
    if (description_sv && description_loc) {
      gqljs_set_loc_node(aTHX_ description_sv, description_loc);
    }
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(node_hv, "name"));
    gqljs_locate_arguments_definition_nodes(aTHX_ p, gqljs_fetch_array(node_hv, "arguments"));
    gql_expect(aTHX_ p, TOK_COLON, NULL);
    gqljs_locate_type_node(aTHX_ p, gqljs_fetch_sv(node_hv, "type"));
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(node_hv, "directives"));
  }
  gql_expect(aTHX_ p, TOK_RBRACE, NULL);
}

static void
gqljs_locate_enum_values_nodes(pTHX_ gql_parser_t *p, AV *av) {
  if (!av || av_len(av) < 0) {
    return;
  }
  gql_expect(aTHX_ p, TOK_LBRACE, NULL);
  while (p->kind != TOK_RBRACE) {
    SV *description_loc = NULL;
    SV *name_sv;
    SV *node_sv;
    HV *node_hv;
    SV *description_sv;

    if (p->kind == TOK_STRING || p->kind == TOK_BLOCK_STRING) {
      description_loc = sv_2mortal(gql_make_current_location(aTHX_ p));
      gql_advance(aTHX_ p);
    }
    if (p->kind != TOK_NAME) {
      gql_throw_expected_token(aTHX_ p, TOK_NAME);
    }
    name_sv = sv_2mortal(newSVpvn(p->src + p->tok_start, p->tok_end - p->tok_start));
    node_sv = gqljs_find_named_node_sv(av, name_sv);
    if (!node_sv) {
      croak("Missing enum value node");
    }
    node_hv = gqljs_node_hv(node_sv);
    gqljs_set_loc_node(aTHX_ node_sv, description_loc ? description_loc : sv_2mortal(gql_make_current_location(aTHX_ p)));
    description_sv = gqljs_fetch_sv(node_hv, "description");
    if (description_sv && description_loc) {
      gqljs_set_loc_node(aTHX_ description_sv, description_loc);
    }
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(node_hv, "name"));
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(node_hv, "directives"));
  }
  gql_expect(aTHX_ p, TOK_RBRACE, NULL);
}

static SV *
gqljs_find_operation_type_definition(AV *av, const char *operation) {
  I32 i;
  if (!av || !operation) {
    return NULL;
  }
  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    HV *hv;
    SV *op_sv;
    STRLEN len;
    const char *value;
    if (!svp) {
      continue;
    }
    hv = gqljs_node_hv(*svp);
    if (!hv) {
      continue;
    }
    op_sv = gqljs_fetch_sv(hv, "operation");
    if (!op_sv) {
      continue;
    }
    value = SvPV(op_sv, len);
    if (strcmp(value, operation) == 0) {
      return *svp;
    }
  }
  return NULL;
}

static void
gqljs_locate_operation_types_nodes(pTHX_ gql_parser_t *p, AV *av) {
  if (!av || av_len(av) < 0) {
    return;
  }
  gql_expect(aTHX_ p, TOK_LBRACE, NULL);
  while (p->kind != TOK_RBRACE) {
    SV *operation_sv;
    SV *node_sv;
    HV *node_hv;
    SV *loc;

    if (p->kind != TOK_NAME) {
      gql_throw_expected_token(aTHX_ p, TOK_NAME);
    }
    operation_sv = sv_2mortal(newSVpvn(p->src + p->tok_start, p->tok_end - p->tok_start));
    node_sv = gqljs_find_operation_type_definition(av, SvPV_nolen(operation_sv));
    if (!node_sv) {
      croak("Missing operation type node");
    }
    node_hv = gqljs_node_hv(node_sv);
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gql_expect(aTHX_ p, TOK_COLON, NULL);
    gqljs_locate_type_node(aTHX_ p, gqljs_fetch_sv(node_hv, "type"));
  }
  gql_expect(aTHX_ p, TOK_RBRACE, NULL);
}

static void
gqljs_locate_interfaces_nodes(pTHX_ gql_parser_t *p, AV *av) {
  if (!av || av_len(av) < 0) {
    return;
  }
  gql_expect(aTHX_ p, TOK_NAME, NULL);
  if (p->kind == TOK_AMP) {
    gql_advance(aTHX_ p);
  }
  while (p->kind == TOK_NAME) {
    SV *name_sv = sv_2mortal(newSVpvn(p->src + p->tok_start, p->tok_end - p->tok_start));
    SV *node_sv = gqljs_find_named_node_sv(av, name_sv);
    HV *node_hv;
    SV *loc;
    if (!node_sv) {
      croak("Missing interface node");
    }
    node_hv = gqljs_node_hv(node_sv);
    loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(node_hv, "name"));
    if (p->kind == TOK_AMP) {
      gql_advance(aTHX_ p);
    }
  }
}

static void
gqljs_locate_union_types_nodes(pTHX_ gql_parser_t *p, AV *av) {
  I32 i;
  if (!av || av_len(av) < 0) {
    return;
  }
  gql_expect(aTHX_ p, TOK_EQUALS, NULL);
  if (p->kind == TOK_PIPE) {
    gql_advance(aTHX_ p);
  }
  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    if (!svp) {
      continue;
    }
    gqljs_locate_type_node(aTHX_ p, *svp);
    if (p->kind == TOK_PIPE) {
      gql_advance(aTHX_ p);
    }
  }
}

static void
gqljs_locate_directive_locations_nodes(pTHX_ gql_parser_t *p, AV *av) {
  I32 i;
  if (!av || av_len(av) < 0) {
    return;
  }
  gql_expect(aTHX_ p, TOK_NAME, NULL);
  if (p->kind == TOK_PIPE) {
    gql_advance(aTHX_ p);
  }
  for (i = 0; i <= av_len(av); i++) {
    SV **svp = av_fetch(av, i, 0);
    if (!svp) {
      continue;
    }
    gqljs_locate_name_node(aTHX_ p, *svp);
    if (p->kind == TOK_PIPE) {
      gql_advance(aTHX_ p);
    }
  }
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
gqljs_locate_definition(pTHX_ gql_parser_t *p, SV *node_sv) {
  HV *hv = gqljs_node_hv(node_sv);
  const char *kind = gqljs_fetch_kind(hv);
  SV *loc;
  SV *description_loc = NULL;
  int is_extension = 0;

  if (!kind) {
    croak("graphqljs loc expected definition node");
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

  if (p->kind == TOK_STRING || p->kind == TOK_BLOCK_STRING) {
    description_loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    gql_advance(aTHX_ p);
    if (gqljs_fetch_sv(hv, "description")) {
      gqljs_set_loc_node(aTHX_ gqljs_fetch_sv(hv, "description"), description_loc);
    }
  }

  {
    STRLEN kind_len = strlen(kind);
    static const char *suffix = "Extension";
    STRLEN suffix_len = strlen(suffix);
    if (kind_len >= suffix_len && strcmp(kind + kind_len - suffix_len, suffix) == 0) {
      is_extension = 1;
      loc = description_loc ? description_loc : sv_2mortal(gql_make_current_location(aTHX_ p));
      gql_expect(aTHX_ p, TOK_NAME, NULL);
    } else {
      loc = description_loc;
    }
  }

  if (strcmp(kind, "SchemaDefinition") == 0 || strcmp(kind, "SchemaExtension") == 0) {
    if (!loc) {
      loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    }
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(hv, "directives"));
    gqljs_locate_operation_types_nodes(aTHX_ p, gqljs_fetch_array(hv, "operationTypes"));
    return 1;
  }

  if (strcmp(kind, "ScalarTypeDefinition") == 0 || strcmp(kind, "ScalarTypeExtension") == 0) {
    if (!loc) {
      loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    }
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(hv, "directives"));
    return 1;
  }

  if (strcmp(kind, "ObjectTypeDefinition") == 0 || strcmp(kind, "ObjectTypeExtension") == 0 ||
      strcmp(kind, "InterfaceTypeDefinition") == 0 || strcmp(kind, "InterfaceTypeExtension") == 0) {
    if (!loc) {
      loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    }
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_interfaces_nodes(aTHX_ p, gqljs_fetch_array(hv, "interfaces"));
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(hv, "directives"));
    gqljs_locate_field_definitions_nodes(aTHX_ p, gqljs_fetch_array(hv, "fields"));
    return 1;
  }

  if (strcmp(kind, "UnionTypeDefinition") == 0 || strcmp(kind, "UnionTypeExtension") == 0) {
    if (!loc) {
      loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    }
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(hv, "directives"));
    gqljs_locate_union_types_nodes(aTHX_ p, gqljs_fetch_array(hv, "types"));
    return 1;
  }

  if (strcmp(kind, "EnumTypeDefinition") == 0 || strcmp(kind, "EnumTypeExtension") == 0) {
    if (!loc) {
      loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    }
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(hv, "directives"));
    gqljs_locate_enum_values_nodes(aTHX_ p, gqljs_fetch_array(hv, "values"));
    return 1;
  }

  if (strcmp(kind, "InputObjectTypeDefinition") == 0 || strcmp(kind, "InputObjectTypeExtension") == 0) {
    AV *fields_av;
    if (!loc) {
      loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    }
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_directives_nodes(aTHX_ p, gqljs_fetch_array(hv, "directives"));
    fields_av = gqljs_fetch_array(hv, "fields");
    if (fields_av && av_len(fields_av) >= 0) {
      gql_expect(aTHX_ p, TOK_LBRACE, NULL);
      gqljs_locate_input_value_definitions_nodes(aTHX_ p, fields_av);
      gql_expect(aTHX_ p, TOK_RBRACE, NULL);
    }
    return 1;
  }

  if (strcmp(kind, "DirectiveDefinition") == 0 || strcmp(kind, "DirectiveExtension") == 0) {
    SV *repeatable_sv;
    if (!loc) {
      loc = sv_2mortal(gql_make_current_location(aTHX_ p));
    }
    gql_expect(aTHX_ p, TOK_NAME, NULL);
    gql_expect(aTHX_ p, TOK_AT, NULL);
    gqljs_locate_name_node(aTHX_ p, gqljs_fetch_sv(hv, "name"));
    gqljs_set_loc_node(aTHX_ node_sv, loc);
    gqljs_locate_arguments_definition_nodes(aTHX_ p, gqljs_fetch_array(hv, "arguments"));
    repeatable_sv = gqljs_fetch_sv(hv, "repeatable");
    if (repeatable_sv && SvTRUE(repeatable_sv)) {
      gql_expect(aTHX_ p, TOK_NAME, NULL);
    }
    gqljs_locate_directive_locations_nodes(aTHX_ p, gqljs_fetch_array(hv, "locations"));
    return 1;
  }

  if (is_extension) {
    croak("Unsupported graphqljs extension loc node %s", kind);
  }
  croak("Unsupported graphqljs loc definition node %s", kind);
}

static SV *
gql_parser_apply_executable_loc(pTHX_ SV *doc_sv, SV *source_sv) {
  HV *doc_hv;
  AV *definitions;
  gql_parser_t p;
  I32 i;
  HV *loc_hv;

  if (!SvROK(doc_sv) || SvTYPE(SvRV(doc_sv)) != SVt_PVHV) {
    croak("parser executable loc applicator expects a document hash reference");
  }
  doc_hv = (HV *)SvRV(doc_sv);
  definitions = gqljs_fetch_array(doc_hv, "definitions");
  if (!definitions) {
    croak("parser executable loc applicator expected document definitions");
  }

  ENTER;
  SAVETMPS;
  gql_parser_init(aTHX_ &p, source_sv, 0);
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
    if (!gqljs_locate_definition(aTHX_ &p, *svp)) {
      gql_parser_invalidate(&p);
      FREETMPS;
      LEAVE;
      return &PL_sv_undef;
    }
  }

  if (p.kind != TOK_EOF) {
    gql_throw_expected_token(aTHX_ &p, TOK_EOF);
  }

  gql_parser_invalidate(&p);
  FREETMPS;
  LEAVE;
  return newSVsv(doc_sv);
}
