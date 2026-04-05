/*
 * Responsibility: provide the initial XS validation entrypoint so the public
 * validation facade can route through XS while rule implementations migrate
 * from PP to C incrementally.
 */

static void
gql_validation_require_pp(pTHX) {
  eval_pv("require GraphQL::Houtou::Validation::PP; 1;", TRUE);
}

static SV *
gql_validation_call_pp_validate_prepared(pTHX_ SV *schema, SV *ast, SV *compiled, SV *options) {
  dSP;
  int count;
  SV *ret;

  gql_validation_require_pp(aTHX);

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(schema)));
  XPUSHs(sv_2mortal(newSVsv(ast)));
  XPUSHs(sv_2mortal(newSVsv(compiled)));
  XPUSHs(sv_2mortal(options ? newSVsv(options) : newSV(0)));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::Validation::PP::validate_prepared", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::Validation::PP::validate_prepared did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_validation_coerce_ast(pTHX_ SV *document, SV *options) {
  dSP;
  int count;
  SV *ret;

  gql_validation_require_pp(aTHX);

  if (SvROK(document)) {
    return newSVsv(document);
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(document)));
  XPUSHs(sv_2mortal(options ? newSVsv(options) : newSV(0)));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::Validation::PP::_coerce_ast", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::Validation::PP::_coerce_ast did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_validation_error(pTHX_ const char *message, SV *location) {
  HV *error_hv = newHV();
  gql_store_sv(error_hv, "message", newSVpv(message, 0));
  if (location && SvOK(location)) {
    AV *locations_av = newAV();
    av_push(locations_av, newSVsv(location));
    gql_store_sv(error_hv, "locations", newRV_noinc((SV *)locations_av));
  }
  return newRV_noinc((SV *)error_hv);
}

static void
gql_validation_push_operation_errors(pTHX_ AV *errors_av, AV *operations_av) {
  HV *seen_hv = newHV();
  I32 operation_len = av_len(operations_av);
  I32 i;
  int operation_count = operation_len >= 0 ? operation_len + 1 : 0;

  if (operation_count == 0) {
    av_push(errors_av, gql_validation_error(aTHX_ "No operations supplied.", NULL));
    SvREFCNT_dec((SV *)seen_hv);
    return;
  }

  for (i = 0; i <= operation_len; i++) {
    SV **operation_svp = av_fetch(operations_av, i, 0);
    HV *operation_hv;
    SV **name_svp;
    SV **location_svp;
    STRLEN name_len;
    const char *name;

    if (!operation_svp || !SvROK(*operation_svp) || SvTYPE(SvRV(*operation_svp)) != SVt_PVHV) {
      continue;
    }

    operation_hv = (HV *)SvRV(*operation_svp);
    location_svp = hv_fetch(operation_hv, "location", 8, 0);
    name_svp = hv_fetch(operation_hv, "name", 4, 0);

    if (!name_svp || !SvOK(*name_svp)) {
      if (operation_count > 1) {
        av_push(
          errors_av,
          gql_validation_error(
            aTHX_ "Anonymous operations must be the only operation in the document.",
            location_svp ? *location_svp : NULL
          )
        );
      }
      continue;
    }

    name = SvPV(*name_svp, name_len);
    if (hv_exists(seen_hv, name, (I32)name_len)) {
      SV *message = newSVpvf("Operation '%s' is defined more than once.", name);
      av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_svp ? *location_svp : NULL));
      SvREFCNT_dec(message);
      continue;
    }

    (void)hv_store(seen_hv, name, (I32)name_len, newSViv(1), 0);
  }

  SvREFCNT_dec((SV *)seen_hv);
}

static HV *
gql_validation_build_fragments_map(pTHX_ AV *ast_av) {
  HV *fragments_hv = newHV();
  I32 ast_len = av_len(ast_av);
  I32 i;

  for (i = 0; i <= ast_len; i++) {
    SV **node_svp = av_fetch(ast_av, i, 0);
    HV *node_hv;
    SV **kind_svp;
    SV **name_svp;
    STRLEN name_len;
    const char *name;

    if (!node_svp || !SvROK(*node_svp) || SvTYPE(SvRV(*node_svp)) != SVt_PVHV) {
      continue;
    }

    node_hv = (HV *)SvRV(*node_svp);
    kind_svp = hv_fetch(node_hv, "kind", 4, 0);
    if (!kind_svp || !SvOK(*kind_svp) || !SvPOK(*kind_svp) || !strEQ(SvPV_nolen(*kind_svp), "fragment")) {
      continue;
    }

    name_svp = hv_fetch(node_hv, "name", 4, 0);
    if (!name_svp || !SvOK(*name_svp)) {
      continue;
    }

    name = SvPV(*name_svp, name_len);
    (void)hv_store(fragments_hv, name, (I32)name_len, newSVsv(*node_svp), 0);
  }

  return fragments_hv;
}

static void
gql_validation_collect_subscription_fields(pTHX_ AV *names_av, SV *selections_sv, HV *fragments_hv, HV *visited_hv) {
  AV *selections_av;
  I32 selection_len;
  I32 i;

  if (!selections_sv || !SvROK(selections_sv) || SvTYPE(SvRV(selections_sv)) != SVt_PVAV) {
    return;
  }

  selections_av = (AV *)SvRV(selections_sv);
  selection_len = av_len(selections_av);
  for (i = 0; i <= selection_len; i++) {
    SV **selection_svp = av_fetch(selections_av, i, 0);
    HV *selection_hv;
    SV **kind_svp;

    if (!selection_svp || !SvROK(*selection_svp) || SvTYPE(SvRV(*selection_svp)) != SVt_PVHV) {
      continue;
    }

    selection_hv = (HV *)SvRV(*selection_svp);
    kind_svp = hv_fetch(selection_hv, "kind", 4, 0);
    if (!kind_svp || !SvOK(*kind_svp) || !SvPOK(*kind_svp)) {
      continue;
    }

    if (strEQ(SvPV_nolen(*kind_svp), "field")) {
      SV **name_svp = hv_fetch(selection_hv, "name", 4, 0);
      if (name_svp && SvOK(*name_svp)) {
        av_push(names_av, newSVsv(*name_svp));
      }
      continue;
    }

    if (strEQ(SvPV_nolen(*kind_svp), "fragment_spread")) {
      SV **name_svp = hv_fetch(selection_hv, "name", 4, 0);
      STRLEN name_len;
      const char *name;
      HE *fragment_he;
      SV *fragment_sv;
      HV *fragment_hv;
      SV **fragment_selections_svp;

      if (!name_svp || !SvOK(*name_svp)) {
        continue;
      }

      name = SvPV(*name_svp, name_len);
      if (hv_exists(visited_hv, name, (I32)name_len)) {
        continue;
      }

      fragment_he = hv_fetch_ent(fragments_hv, *name_svp, 0, 0);
      if (!fragment_he) {
        continue;
      }

      fragment_sv = HeVAL(fragment_he);
      if (!SvROK(fragment_sv) || SvTYPE(SvRV(fragment_sv)) != SVt_PVHV) {
        continue;
      }

      (void)hv_store(visited_hv, name, (I32)name_len, newSViv(1), 0);
      fragment_hv = (HV *)SvRV(fragment_sv);
      fragment_selections_svp = hv_fetch(fragment_hv, "selections", 10, 0);
      gql_validation_collect_subscription_fields(
        aTHX_ names_av,
        fragment_selections_svp ? *fragment_selections_svp : NULL,
        fragments_hv,
        visited_hv
      );
      (void)hv_delete(visited_hv, name, (I32)name_len, G_DISCARD);
      continue;
    }

    if (strEQ(SvPV_nolen(*kind_svp), "inline_fragment")) {
      SV **nested_svp = hv_fetch(selection_hv, "selections", 10, 0);
      gql_validation_collect_subscription_fields(
        aTHX_ names_av,
        nested_svp ? *nested_svp : NULL,
        fragments_hv,
        visited_hv
      );
    }
  }
}

static void
gql_validation_collect_fragment_spreads(pTHX_ AV *names_av, SV *selections_sv) {
  AV *selections_av;
  I32 selection_len;
  I32 i;

  if (!selections_sv || !SvROK(selections_sv) || SvTYPE(SvRV(selections_sv)) != SVt_PVAV) {
    return;
  }

  selections_av = (AV *)SvRV(selections_sv);
  selection_len = av_len(selections_av);
  for (i = 0; i <= selection_len; i++) {
    SV **selection_svp = av_fetch(selections_av, i, 0);
    HV *selection_hv;
    SV **kind_svp;

    if (!selection_svp || !SvROK(*selection_svp) || SvTYPE(SvRV(*selection_svp)) != SVt_PVHV) {
      continue;
    }

    selection_hv = (HV *)SvRV(*selection_svp);
    kind_svp = hv_fetch(selection_hv, "kind", 4, 0);
    if (!kind_svp || !SvOK(*kind_svp) || !SvPOK(*kind_svp)) {
      continue;
    }

    if (strEQ(SvPV_nolen(*kind_svp), "fragment_spread")) {
      SV **name_svp = hv_fetch(selection_hv, "name", 4, 0);
      if (name_svp && SvOK(*name_svp)) {
        av_push(names_av, newSVsv(*name_svp));
      }
      continue;
    }

    if (strEQ(SvPV_nolen(*kind_svp), "field") || strEQ(SvPV_nolen(*kind_svp), "inline_fragment")) {
      SV **nested_svp = hv_fetch(selection_hv, "selections", 10, 0);
      gql_validation_collect_fragment_spreads(aTHX_ names_av, nested_svp ? *nested_svp : NULL);
    }
  }
}

static void
gql_validation_visit_fragment_cycles(pTHX_ AV *errors_av, HV *fragments_hv, HV *state_hv, SV *name_key_sv) {
  STRLEN name_len;
  const char *name;
  HE *fragment_he;
  SV *fragment_sv;
  HV *fragment_hv;
  HE *state_he;
  const char *state;
  SV **selections_svp;
  AV *spreads_av = newAV();
  I32 spread_len;
  I32 i;
  SV **location_svp;

  if (!name_key_sv || !SvOK(name_key_sv)) {
    SvREFCNT_dec((SV *)spreads_av);
    return;
  }

  name = SvPV(name_key_sv, name_len);
  fragment_he = hv_fetch_ent(fragments_hv, name_key_sv, 0, 0);
  if (!fragment_he) {
    SvREFCNT_dec((SV *)spreads_av);
    return;
  }

  state_he = hv_fetch_ent(state_hv, name_key_sv, 0, 0);
  if (state_he && SvOK(HeVAL(state_he))) {
    state = SvPV_nolen(HeVAL(state_he));
    if (strEQ(state, "done")) {
      SvREFCNT_dec((SV *)spreads_av);
      return;
    }
    if (strEQ(state, "visiting")) {
      fragment_sv = HeVAL(fragment_he);
      if (SvROK(fragment_sv) && SvTYPE(SvRV(fragment_sv)) == SVt_PVHV) {
        fragment_hv = (HV *)SvRV(fragment_sv);
        location_svp = hv_fetch(fragment_hv, "location", 8, 0);
        {
          SV *message = newSVpvf("Fragment '%s' participates in a cycle.", name);
          av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_svp ? *location_svp : NULL));
          SvREFCNT_dec(message);
        }
      }
      SvREFCNT_dec((SV *)spreads_av);
      return;
    }
  }

  (void)hv_store(state_hv, name, (I32)name_len, newSVpv("visiting", 0), 0);
  fragment_sv = HeVAL(fragment_he);
  if (!SvROK(fragment_sv) || SvTYPE(SvRV(fragment_sv)) != SVt_PVHV) {
    (void)hv_store(state_hv, name, (I32)name_len, newSVpv("done", 0), 0);
    SvREFCNT_dec((SV *)spreads_av);
    return;
  }

  fragment_hv = (HV *)SvRV(fragment_sv);
  selections_svp = hv_fetch(fragment_hv, "selections", 10, 0);
  gql_validation_collect_fragment_spreads(aTHX_ spreads_av, selections_svp ? *selections_svp : NULL);

  spread_len = av_len(spreads_av);
  for (i = 0; i <= spread_len; i++) {
    SV **spread_name_svp = av_fetch(spreads_av, i, 0);
    if (!spread_name_svp || !SvOK(*spread_name_svp)) {
      continue;
    }
    gql_validation_visit_fragment_cycles(aTHX_ errors_av, fragments_hv, state_hv, *spread_name_svp);
  }

  (void)hv_store(state_hv, name, (I32)name_len, newSVpv("done", 0), 0);
  SvREFCNT_dec((SV *)spreads_av);
}

static void
gql_validation_push_fragment_cycle_errors(pTHX_ AV *errors_av, HV *fragments_hv) {
  I32 fragment_count;
  I32 i;
  SV **keys;
  HV *state_hv = newHV();

  keys = gqljs_sorted_hash_keys(aTHX_ fragments_hv, &fragment_count);
  if (!keys) {
    SvREFCNT_dec((SV *)state_hv);
    return;
  }

  for (i = 0; i < fragment_count; i++) {
    gql_validation_visit_fragment_cycles(aTHX_ errors_av, fragments_hv, state_hv, keys[i]);
  }

  gqljs_free_sorted_hash_keys(keys, fragment_count);
  SvREFCNT_dec((SV *)state_hv);
}

static void
gql_validation_push_subscription_errors(pTHX_ AV *operation_errors_av, AV *operations_av, HV *fragments_hv) {
  I32 operation_len = av_len(operations_av);
  I32 i;

  for (i = 0; i <= operation_len; i++) {
    SV **operation_svp = av_fetch(operations_av, i, 0);
    AV *errors_av = newAV();
    HV *operation_hv;
    SV **operation_type_svp;

    av_push(operation_errors_av, newRV_noinc((SV *)errors_av));

    if (!operation_svp || !SvROK(*operation_svp) || SvTYPE(SvRV(*operation_svp)) != SVt_PVHV) {
      continue;
    }

    operation_hv = (HV *)SvRV(*operation_svp);
    operation_type_svp = hv_fetch(operation_hv, "operationType", 13, 0);
    if (operation_type_svp && SvOK(*operation_type_svp) && SvPOK(*operation_type_svp)
        && strEQ(SvPV_nolen(*operation_type_svp), "subscription")) {
      AV *field_names_av = newAV();
      HV *visited_hv = newHV();
      SV **selections_svp = hv_fetch(operation_hv, "selections", 10, 0);
      SV **location_svp = hv_fetch(operation_hv, "location", 8, 0);
      I32 field_len;

      gql_validation_collect_subscription_fields(
        aTHX_ field_names_av,
        selections_svp ? *selections_svp : NULL,
        fragments_hv,
        visited_hv
      );
      field_len = av_len(field_names_av);
      if (field_len != 0) {
        SV *message = newSVpv("Subscription needs to have only one field; got (", 0);
        I32 j;
        for (j = 0; j <= field_len; j++) {
          SV **name_svp = av_fetch(field_names_av, j, 0);
          if (!name_svp || !SvOK(*name_svp)) {
            continue;
          }
          if (j > 0) {
            sv_catpvn(message, " ", 1);
          }
          sv_catsv(message, *name_svp);
        }
        sv_catpvn(message, ")", 1);
        av_push(
          errors_av,
          gql_validation_error(aTHX_ SvPV_nolen(message), location_svp ? *location_svp : NULL)
        );
        SvREFCNT_dec(message);
      }

      SvREFCNT_dec((SV *)visited_hv);
      SvREFCNT_dec((SV *)field_names_av);
    }
  }
}

static SV *
gql_validation_options_with_xs_skips(pTHX_ SV *options, SV *seed_errors, SV *seed_operation_errors, SV *seed_fragment_cycle_errors) {
  HV *options_hv;
  SV *out_sv;

  if (options && SvROK(options) && SvTYPE(SvRV(options)) == SVt_PVHV) {
    out_sv = gql_schema_clone_hashref_shallow(aTHX_ options);
  } else {
    out_sv = newRV_noinc((SV *)newHV());
  }

  options_hv = (HV *)SvRV(out_sv);
  gql_store_sv(options_hv, "skip_no_operations", newSViv(1));
  gql_store_sv(options_hv, "skip_operation_name_uniqueness", newSViv(1));
  gql_store_sv(options_hv, "skip_lone_anonymous_operation", newSViv(1));
  gql_store_sv(options_hv, "skip_subscription_single_root_field", newSViv(1));
  gql_store_sv(options_hv, "skip_fragment_cycles", newSViv(1));
  gql_store_sv(options_hv, "seed_errors", seed_errors ? newSVsv(seed_errors) : newRV_noinc((SV *)newAV()));
  gql_store_sv(
    options_hv,
    "seed_operation_errors",
    seed_operation_errors ? newSVsv(seed_operation_errors) : newRV_noinc((SV *)newAV())
  );
  gql_store_sv(
    options_hv,
    "seed_fragment_cycle_errors",
    seed_fragment_cycle_errors ? newSVsv(seed_fragment_cycle_errors) : newRV_noinc((SV *)newAV())
  );

  return out_sv;
}

static SV *
gql_validation_validate(pTHX_ SV *schema, SV *document, SV *options) {
  SV *ast_sv = gql_validation_coerce_ast(aTHX_ document, options);
  SV *compiled_sv = gql_schema_compile_schema(aTHX_ schema);
  AV *operations_av = newAV();
  AV *errors_av = newAV();
  SV *seed_errors_sv;
  HV *fragments_hv;
  AV *operation_errors_av = newAV();
  SV *seed_operation_errors_sv;
  AV *fragment_cycle_errors_av = newAV();
  SV *seed_fragment_cycle_errors_sv;
  AV *ast_av;
  I32 ast_len;
  I32 i;
  SV *pp_options_sv;
  SV *ret;

  if (!SvROK(ast_sv) || SvTYPE(SvRV(ast_sv)) != SVt_PVAV) {
    SvREFCNT_dec(ast_sv);
    SvREFCNT_dec(compiled_sv);
    croak("Validation AST must be an array reference");
  }

  ast_av = (AV *)SvRV(ast_sv);
  ast_len = av_len(ast_av);
  if (ast_len >= 0) {
    av_extend(operations_av, ast_len);
  }

  for (i = 0; i <= ast_len; i++) {
    SV **node_svp = av_fetch(ast_av, i, 0);
    HV *node_hv;
    SV **kind_svp;

    if (!node_svp || !SvROK(*node_svp) || SvTYPE(SvRV(*node_svp)) != SVt_PVHV) {
      continue;
    }

    node_hv = (HV *)SvRV(*node_svp);
    kind_svp = hv_fetch(node_hv, "kind", 4, 0);
    if (!kind_svp || !SvOK(*kind_svp) || !SvPOK(*kind_svp) || !strEQ(SvPV_nolen(*kind_svp), "operation")) {
      continue;
    }

    av_push(operations_av, newSVsv(*node_svp));
  }

  fragments_hv = gql_validation_build_fragments_map(aTHX_ ast_av);
  gql_validation_push_operation_errors(aTHX_ errors_av, operations_av);
  gql_validation_push_subscription_errors(aTHX_ operation_errors_av, operations_av, fragments_hv);
  gql_validation_push_fragment_cycle_errors(aTHX_ fragment_cycle_errors_av, fragments_hv);
  SvREFCNT_dec((SV *)operations_av);
  SvREFCNT_dec((SV *)fragments_hv);

  seed_errors_sv = newRV_noinc((SV *)errors_av);
  seed_operation_errors_sv = newRV_noinc((SV *)operation_errors_av);
  seed_fragment_cycle_errors_sv = newRV_noinc((SV *)fragment_cycle_errors_av);
  pp_options_sv = gql_validation_options_with_xs_skips(
    aTHX_ options,
    seed_errors_sv,
    seed_operation_errors_sv,
    seed_fragment_cycle_errors_sv
  );
  ret = gql_validation_call_pp_validate_prepared(aTHX_ schema, ast_sv, compiled_sv, pp_options_sv);

  SvREFCNT_dec(seed_errors_sv);
  SvREFCNT_dec(seed_operation_errors_sv);
  SvREFCNT_dec(seed_fragment_cycle_errors_sv);
  SvREFCNT_dec(pp_options_sv);
  SvREFCNT_dec(ast_sv);
  SvREFCNT_dec(compiled_sv);

  return ret;
}
