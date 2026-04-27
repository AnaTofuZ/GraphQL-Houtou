/*
 * Responsibility: provide the initial XS validation entrypoint so the public
 * validation facade can route through XS while rule implementations migrate
 * from PP to C incrementally.
 */

static SV *
gql_validation_parse_ast(pTHX_ SV *document, SV *options) {
  dSP;
  int count;
  SV *ret;
  HV *opts_hv;

  if (document && SvROK(document)) {
    return newSVsv(document);
  }

  eval_pv("require GraphQL::Houtou; 1;", TRUE);

  opts_hv = newHV();
  if (options && SvROK(options) && SvTYPE(SvRV(options)) == SVt_PVHV) {
    SV **no_location_svp = hv_fetch((HV *)SvRV(options), "no_location", 11, 0);
    if (!no_location_svp) {
      no_location_svp = hv_fetch((HV *)SvRV(options), "noLocation", 10, 0);
    }
    if (no_location_svp && SvOK(*no_location_svp)) {
      gql_store_sv(opts_hv, "no_location", newSVsv(*no_location_svp));
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(document)));
  XPUSHs(sv_2mortal(newRV_noinc((SV *)opts_hv)));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::parse_with_options", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::parse_with_options did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_validation_schema_name2type_sv(pTHX_ SV *schema) {
  dSP;
  int count;
  SV *ret;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(schema)));
  PUTBACK;

  count = call_method("name2type", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("schema->name2type did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_validation_lookup_type_sv(pTHX_ SV *schema, SV *type_ref) {
  dSP;
  int count;
  SV *ret;
  SV *name2type_sv;

  eval_pv("require GraphQL::Houtou::Schema; 1;", TRUE);
  name2type_sv = gql_validation_schema_name2type_sv(aTHX_ schema);

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(type_ref)));
  XPUSHs(sv_2mortal(name2type_sv));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::Schema::lookup_type", G_SCALAR | G_EVAL);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::Schema::lookup_type did not return a scalar");
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

  keys = gql_parser_sorted_hash_keys(aTHX_ fragments_hv, &fragment_count);
  if (!keys) {
    SvREFCNT_dec((SV *)state_hv);
    return;
  }

  for (i = 0; i < fragment_count; i++) {
    gql_validation_visit_fragment_cycles(aTHX_ errors_av, fragments_hv, state_hv, keys[i]);
  }

  gql_parser_free_sorted_hash_keys(keys, fragment_count);
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

static HV *
gql_validation_compiled_hv_from_sv(SV *compiled_sv) {
  if (!compiled_sv || !SvROK(compiled_sv) || SvTYPE(SvRV(compiled_sv)) != SVt_PVHV) {
    return NULL;
  }
  return (HV *)SvRV(compiled_sv);
}

static HV *
gql_validation_compiled_type_hv(pTHX_ SV *compiled_sv, SV *type_name_sv) {
  HV *compiled_hv = gql_validation_compiled_hv_from_sv(compiled_sv);
  SV **types_svp;
  HE *type_he;

  if (!compiled_hv || !type_name_sv || !SvOK(type_name_sv)) {
    return NULL;
  }

  types_svp = hv_fetch(compiled_hv, "types", 5, 0);
  if (!types_svp || !SvROK(*types_svp) || SvTYPE(SvRV(*types_svp)) != SVt_PVHV) {
    return NULL;
  }

  type_he = hv_fetch_ent((HV *)SvRV(*types_svp), type_name_sv, 0, 0);
  if (!type_he || !SvROK(HeVAL(type_he)) || SvTYPE(SvRV(HeVAL(type_he))) != SVt_PVHV) {
    return NULL;
  }

  return (HV *)SvRV(HeVAL(type_he));
}

static SV *
gql_validation_named_type_name_sv(SV *type_ref_sv) {
  HV *type_ref_hv;
  SV **kind_svp;
  SV **name_svp;
  SV **of_svp;

  if (!type_ref_sv || !SvROK(type_ref_sv) || SvTYPE(SvRV(type_ref_sv)) != SVt_PVHV) {
    return NULL;
  }

  type_ref_hv = (HV *)SvRV(type_ref_sv);
  kind_svp = hv_fetch(type_ref_hv, "kind", 4, 0);
  if (kind_svp && SvOK(*kind_svp) && SvPOK(*kind_svp) && strEQ(SvPV_nolen(*kind_svp), "NAMED")) {
    name_svp = hv_fetch(type_ref_hv, "name", 4, 0);
    return name_svp ? *name_svp : NULL;
  }

  of_svp = hv_fetch(type_ref_hv, "of", 2, 0);
  return of_svp ? gql_validation_named_type_name_sv(*of_svp) : NULL;
}

static int
gql_validation_type_is_non_null(SV *type_ref_sv) {
  HV *type_ref_hv;
  SV **kind_svp;

  if (!type_ref_sv || !SvROK(type_ref_sv) || SvTYPE(SvRV(type_ref_sv)) != SVt_PVHV) {
    return 0;
  }

  type_ref_hv = (HV *)SvRV(type_ref_sv);
  kind_svp = hv_fetch(type_ref_hv, "kind", 4, 0);
  return kind_svp && SvOK(*kind_svp) && SvPOK(*kind_svp) && strEQ(SvPV_nolen(*kind_svp), "NON_NULL");
}

static void
gql_validation_add_possible_object_names(pTHX_ HV *out_hv, SV *compiled_sv, SV *type_name_sv) {
  HV *type_hv = gql_validation_compiled_type_hv(aTHX_ compiled_sv, type_name_sv);
  SV **kind_svp;

  if (!type_hv) {
    return;
  }

  kind_svp = hv_fetch(type_hv, "kind", 4, 0);
  if (!kind_svp || !SvOK(*kind_svp) || !SvPOK(*kind_svp)) {
    return;
  }

  if (strEQ(SvPV_nolen(*kind_svp), "OBJECT")) {
    STRLEN len;
    const char *name = SvPV(type_name_sv, len);
    (void)hv_store(out_hv, name, (I32)len, newSViv(1), 0);
    return;
  }

  if (strEQ(SvPV_nolen(*kind_svp), "INTERFACE") || strEQ(SvPV_nolen(*kind_svp), "UNION")) {
    HV *compiled_hv = gql_validation_compiled_hv_from_sv(compiled_sv);
    SV **possible_types_svp;
    HE *possible_he;
    AV *possible_av;
    I32 i;

    if (!compiled_hv) {
      return;
    }

    possible_types_svp = hv_fetch(compiled_hv, "possible_types", 14, 0);
    if (!possible_types_svp || !SvROK(*possible_types_svp) || SvTYPE(SvRV(*possible_types_svp)) != SVt_PVHV) {
      return;
    }

    possible_he = hv_fetch_ent((HV *)SvRV(*possible_types_svp), type_name_sv, 0, 0);
    if (!possible_he || !SvROK(HeVAL(possible_he)) || SvTYPE(SvRV(HeVAL(possible_he))) != SVt_PVAV) {
      return;
    }

    possible_av = (AV *)SvRV(HeVAL(possible_he));
    for (i = 0; i <= av_len(possible_av); i++) {
      SV **possible_name_svp = av_fetch(possible_av, i, 0);
      if (possible_name_svp && SvOK(*possible_name_svp)) {
        gql_validation_add_possible_object_names(aTHX_ out_hv, compiled_sv, *possible_name_svp);
      }
    }
  }
}

static int
gql_validation_selection_types_overlap(pTHX_ SV *compiled_sv, SV *left_name_sv, SV *right_name_sv) {
  HV *left_objects_hv = newHV();
  int overlap = 0;
  HV *right_objects_hv = newHV();
  HE *he;

  if (!left_name_sv || !right_name_sv || !SvOK(left_name_sv) || !SvOK(right_name_sv)) {
    SvREFCNT_dec((SV *)left_objects_hv);
    SvREFCNT_dec((SV *)right_objects_hv);
    return 0;
  }

  if (sv_eq(left_name_sv, right_name_sv)) {
    SvREFCNT_dec((SV *)left_objects_hv);
    SvREFCNT_dec((SV *)right_objects_hv);
    return 1;
  }

  gql_validation_add_possible_object_names(aTHX_ left_objects_hv, compiled_sv, left_name_sv);
  gql_validation_add_possible_object_names(aTHX_ right_objects_hv, compiled_sv, right_name_sv);

  hv_iterinit(right_objects_hv);
  while ((he = hv_iternext(right_objects_hv))) {
    STRLEN key_len;
    const char *key = HePV(he, key_len);
    if (hv_exists(left_objects_hv, key, (I32)key_len)) {
      overlap = 1;
      break;
    }
  }

  SvREFCNT_dec((SV *)left_objects_hv);
  SvREFCNT_dec((SV *)right_objects_hv);
  return overlap;
}

static void gql_validation_validate_value(
  pTHX_ AV *errors_av,
  SV *schema,
  SV *compiled_sv,
  SV *value_sv,
  SV *expected_type_sv,
  HV *variables_hv,
  SV *location_sv
);

static void
gql_validation_validate_arguments(
  pTHX_ AV *errors_av,
  SV *schema,
  SV *compiled_sv,
  HV *arguments_hv,
  HV *argument_defs_hv,
  HV *variables_hv,
  SV *location_sv
) {
  I32 argument_count = 0;
  SV **argument_keys;
  I32 i;

  argument_keys = gql_parser_sorted_hash_keys(aTHX_ arguments_hv, &argument_count);
  if (argument_keys) {
    for (i = 0; i < argument_count; i++) {
      HE *arg_he = hv_fetch_ent(arguments_hv, argument_keys[i], 0, 0);
      HE *def_he = hv_fetch_ent(argument_defs_hv, argument_keys[i], 0, 0);
      if (!def_he) {
        SV *message = newSVpvf("Unknown argument '%s'.", SvPV_nolen(argument_keys[i]));
        av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_sv));
        SvREFCNT_dec(message);
        continue;
      }
      if (arg_he && SvROK(HeVAL(def_he)) && SvTYPE(SvRV(HeVAL(def_he))) == SVt_PVHV) {
        SV **type_svp = hv_fetch((HV *)SvRV(HeVAL(def_he)), "type", 4, 0);
        gql_validation_validate_value(
          aTHX_ errors_av,
          schema,
          compiled_sv,
          HeVAL(arg_he),
          type_svp ? *type_svp : NULL,
          variables_hv,
          location_sv
        );
      }
    }
    gql_parser_free_sorted_hash_keys(argument_keys, argument_count);
  }

  argument_keys = gql_parser_sorted_hash_keys(aTHX_ argument_defs_hv, &argument_count);
  if (argument_keys) {
    for (i = 0; i < argument_count; i++) {
      HE *def_he = hv_fetch_ent(argument_defs_hv, argument_keys[i], 0, 0);
      HV *def_hv;
      SV **type_svp;
      SV **has_default_svp;
      if (hv_fetch_ent(arguments_hv, argument_keys[i], 0, 0) || !def_he || !SvROK(HeVAL(def_he)) || SvTYPE(SvRV(HeVAL(def_he))) != SVt_PVHV) {
        continue;
      }
      def_hv = (HV *)SvRV(HeVAL(def_he));
      type_svp = hv_fetch(def_hv, "type", 4, 0);
      has_default_svp = hv_fetch(def_hv, "has_default_value", 17, 0);
      if (type_svp && gql_validation_type_is_non_null(*type_svp)
          && !(has_default_svp && SvOK(*has_default_svp) && SvTRUE(*has_default_svp))) {
        SV *message = newSVpvf("Required argument '%s' was not provided.", SvPV_nolen(argument_keys[i]));
        av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_sv));
        SvREFCNT_dec(message);
      }
    }
    gql_parser_free_sorted_hash_keys(argument_keys, argument_count);
  }
}

static void
gql_validation_validate_value(
  pTHX_ AV *errors_av,
  SV *schema,
  SV *compiled_sv,
  SV *value_sv,
  SV *expected_type_sv,
  HV *variables_hv,
  SV *location_sv
) {
  if (!value_sv || !SvROK(value_sv)) {
    return;
  }

  if (SvTYPE(SvRV(value_sv)) == SVt_PVAV) {
    AV *value_av = (AV *)SvRV(value_sv);
    SV *item_type_sv = expected_type_sv;
    if (expected_type_sv && SvROK(expected_type_sv) && SvTYPE(SvRV(expected_type_sv)) == SVt_PVHV) {
      SV **kind_svp = hv_fetch((HV *)SvRV(expected_type_sv), "kind", 4, 0);
      if (kind_svp && SvOK(*kind_svp) && SvPOK(*kind_svp) && strEQ(SvPV_nolen(*kind_svp), "LIST")) {
        SV **of_svp = hv_fetch((HV *)SvRV(expected_type_sv), "of", 2, 0);
        if (of_svp) {
          item_type_sv = *of_svp;
        }
      }
    }
    for (I32 i = 0; i <= av_len(value_av); i++) {
      SV **item_svp = av_fetch(value_av, i, 0);
      if (item_svp) {
        gql_validation_validate_value(aTHX_ errors_av, schema, compiled_sv, *item_svp, item_type_sv, variables_hv, location_sv);
      }
    }
    return;
  }

  if (SvTYPE(SvRV(value_sv)) == SVt_PVHV) {
    HV *value_hv = (HV *)SvRV(value_sv);
    SV *named_type_name_sv = gql_validation_named_type_name_sv(expected_type_sv);
    HV *named_type_hv = gql_validation_compiled_type_hv(aTHX_ compiled_sv, named_type_name_sv);
    SV **kind_svp;
    if (!named_type_hv) {
      return;
    }
    kind_svp = hv_fetch(named_type_hv, "kind", 4, 0);
    if (!kind_svp || !SvOK(*kind_svp) || !SvPOK(*kind_svp) || !strEQ(SvPV_nolen(*kind_svp), "INPUT_OBJECT")) {
      return;
    }
    {
      SV **fields_svp = hv_fetch(named_type_hv, "fields", 6, 0);
      HV *fields_hv = (fields_svp && SvROK(*fields_svp) && SvTYPE(SvRV(*fields_svp)) == SVt_PVHV) ? (HV *)SvRV(*fields_svp) : NULL;
      I32 count = 0;
      SV **keys = gql_parser_sorted_hash_keys(aTHX_ value_hv, &count);
      I32 i;
      if (keys) {
        for (i = 0; i < count; i++) {
          HE *field_he = fields_hv ? hv_fetch_ent(fields_hv, keys[i], 0, 0) : NULL;
          HE *value_he = hv_fetch_ent(value_hv, keys[i], 0, 0);
          if (!field_he) {
            SV *message = newSVpvf(
              "Input field '%s' is not defined on type '%s'.",
              SvPV_nolen(keys[i]),
              named_type_name_sv ? SvPV_nolen(named_type_name_sv) : ""
            );
            av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_sv));
            SvREFCNT_dec(message);
            continue;
          }
          if (value_he && SvROK(HeVAL(field_he)) && SvTYPE(SvRV(HeVAL(field_he))) == SVt_PVHV) {
            SV **field_type_svp = hv_fetch((HV *)SvRV(HeVAL(field_he)), "type", 4, 0);
            gql_validation_validate_value(aTHX_ errors_av, schema, compiled_sv, HeVAL(value_he), field_type_svp ? *field_type_svp : NULL, variables_hv, location_sv);
          }
        }
        gql_parser_free_sorted_hash_keys(keys, count);
      }
      if (fields_hv) {
        keys = gql_parser_sorted_hash_keys(aTHX_ fields_hv, &count);
        if (keys) {
          for (i = 0; i < count; i++) {
            HE *field_he = hv_fetch_ent(fields_hv, keys[i], 0, 0);
            HV *field_hv;
            SV **field_type_svp;
            SV **has_default_svp;
            if (hv_fetch_ent(value_hv, keys[i], 0, 0) || !field_he || !SvROK(HeVAL(field_he)) || SvTYPE(SvRV(HeVAL(field_he))) != SVt_PVHV) {
              continue;
            }
            field_hv = (HV *)SvRV(HeVAL(field_he));
            field_type_svp = hv_fetch(field_hv, "type", 4, 0);
            has_default_svp = hv_fetch(field_hv, "has_default_value", 17, 0);
            if (field_type_svp && gql_validation_type_is_non_null(*field_type_svp)
                && !(has_default_svp && SvOK(*has_default_svp) && SvTRUE(*has_default_svp))) {
              SV *message = newSVpvf(
                "Required input field '%s' was not provided for type '%s'.",
                SvPV_nolen(keys[i]),
                named_type_name_sv ? SvPV_nolen(named_type_name_sv) : ""
              );
              av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_sv));
              SvREFCNT_dec(message);
            }
          }
          gql_parser_free_sorted_hash_keys(keys, count);
        }
      }
    }
    return;
  }

  {
    SV *inner_sv = SvRV(value_sv);
    if (!SvROK(inner_sv)) {
      STRLEN name_len;
      const char *name = SvPV(inner_sv, name_len);
      if (!variables_hv || !hv_exists(variables_hv, name, (I32)name_len)) {
        SV *message = newSVpvf("Variable '$%s' is used but not defined.", name);
        av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_sv));
        SvREFCNT_dec(message);
      }
      return;
    }
  }
}

static void gql_validation_validate_selections(
  pTHX_ AV *errors_av,
  SV *schema,
  SV *compiled_sv,
  AV *selections_av,
  SV *parent_type_name_sv,
  HV *variables_hv,
  HV *fragments_hv
);

static void
gql_validation_validate_field_selection(
  pTHX_ AV *errors_av,
  SV *schema,
  SV *compiled_sv,
  HV *selection_hv,
  HV *parent_type_hv,
  HV *variables_hv,
  HV *fragments_hv
) {
  SV **field_name_svp = hv_fetch(selection_hv, "name", 4, 0);
  SV **location_svp = hv_fetch(selection_hv, "location", 8, 0);
  SV **parent_name_svp = hv_fetch(parent_type_hv, "name", 4, 0);
  SV **fields_svp = hv_fetch(parent_type_hv, "fields", 6, 0);
  HE *field_he = NULL;

  if (!field_name_svp || !SvOK(*field_name_svp)) {
    return;
  }

  if (fields_svp && SvROK(*fields_svp) && SvTYPE(SvRV(*fields_svp)) == SVt_PVHV) {
    field_he = hv_fetch_ent((HV *)SvRV(*fields_svp), *field_name_svp, 0, 0);
  }

  if (!field_he) {
    if (!strEQ(SvPV_nolen(*field_name_svp), "__typename")) {
      SV *message = newSVpvf(
        "Field '%s' does not exist on type '%s'.",
        SvPV_nolen(*field_name_svp),
        (parent_name_svp && SvOK(*parent_name_svp)) ? SvPV_nolen(*parent_name_svp) : ""
      );
      av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_svp ? *location_svp : NULL));
      SvREFCNT_dec(message);
    }
    return;
  }

  if (SvROK(HeVAL(field_he)) && SvTYPE(SvRV(HeVAL(field_he))) == SVt_PVHV) {
    HV *field_hv = (HV *)SvRV(HeVAL(field_he));
    SV **arguments_svp = hv_fetch(selection_hv, "arguments", 9, 0);
    SV **arg_defs_svp = hv_fetch(field_hv, "args", 4, 0);
    HV *arguments_hv = (arguments_svp && SvROK(*arguments_svp) && SvTYPE(SvRV(*arguments_svp)) == SVt_PVHV) ? (HV *)SvRV(*arguments_svp) : newHV();
    HV *arg_defs_hv = (arg_defs_svp && SvROK(*arg_defs_svp) && SvTYPE(SvRV(*arg_defs_svp)) == SVt_PVHV) ? (HV *)SvRV(*arg_defs_svp) : newHV();
    SV **selections_svp = hv_fetch(selection_hv, "selections", 10, 0);
    SV **type_svp = hv_fetch(field_hv, "type", 4, 0);

    gql_validation_validate_arguments(aTHX_ errors_av, schema, compiled_sv, arguments_hv, arg_defs_hv, variables_hv, location_svp ? *location_svp : NULL);
    if ((!arguments_svp || arguments_hv != (HV *)SvRV(*arguments_svp))) {
      SvREFCNT_dec((SV *)arguments_hv);
    }
    if ((!arg_defs_svp || arg_defs_hv != (HV *)SvRV(*arg_defs_svp))) {
      SvREFCNT_dec((SV *)arg_defs_hv);
    }

    if (selections_svp && SvROK(*selections_svp) && SvTYPE(SvRV(*selections_svp)) == SVt_PVAV && type_svp) {
      SV *next_type_name_sv = gql_validation_named_type_name_sv(*type_svp);
      if (next_type_name_sv) {
        gql_validation_validate_selections(
          aTHX_ errors_av,
          schema,
          compiled_sv,
          (AV *)SvRV(*selections_svp),
          next_type_name_sv,
          variables_hv,
          fragments_hv
        );
      }
    }
  }
}

static void
gql_validation_validate_selections(
  pTHX_ AV *errors_av,
  SV *schema,
  SV *compiled_sv,
  AV *selections_av,
  SV *parent_type_name_sv,
  HV *variables_hv,
  HV *fragments_hv
) {
  HV *parent_type_hv = gql_validation_compiled_type_hv(aTHX_ compiled_sv, parent_type_name_sv);
  I32 i;

  if (!parent_type_hv || !selections_av) {
    return;
  }

  for (i = 0; i <= av_len(selections_av); i++) {
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
      gql_validation_validate_field_selection(aTHX_ errors_av, schema, compiled_sv, selection_hv, parent_type_hv, variables_hv, fragments_hv);
      continue;
    }
    if (strEQ(SvPV_nolen(*kind_svp), "fragment_spread")) {
      SV **name_svp = hv_fetch(selection_hv, "name", 4, 0);
      SV **location_svp = hv_fetch(selection_hv, "location", 8, 0);
      HE *fragment_he = name_svp ? hv_fetch_ent(fragments_hv, *name_svp, 0, 0) : NULL;
      if (!fragment_he) {
        if (name_svp && SvOK(*name_svp)) {
          SV *message = newSVpvf("Unknown fragment '%s'.", SvPV_nolen(*name_svp));
          av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_svp ? *location_svp : NULL));
          SvREFCNT_dec(message);
        }
        continue;
      }
      if (SvROK(HeVAL(fragment_he)) && SvTYPE(SvRV(HeVAL(fragment_he))) == SVt_PVHV) {
        HV *fragment_hv = (HV *)SvRV(HeVAL(fragment_he));
        SV **on_svp = hv_fetch(fragment_hv, "on", 2, 0);
        if (on_svp && SvOK(*on_svp) && gql_validation_compiled_type_hv(aTHX_ compiled_sv, *on_svp)
            && !gql_validation_selection_types_overlap(aTHX_ compiled_sv, parent_type_name_sv, *on_svp)) {
          SV *message = newSVpvf(
            "Fragment '%s' cannot be spread here because type '%s' can never apply to '%s'.",
            name_svp ? SvPV_nolen(*name_svp) : "",
            SvPV_nolen(*on_svp),
            SvPV_nolen(parent_type_name_sv)
          );
          av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_svp ? *location_svp : NULL));
          SvREFCNT_dec(message);
        }
      }
      continue;
    }
    if (strEQ(SvPV_nolen(*kind_svp), "inline_fragment")) {
      SV **on_svp = hv_fetch(selection_hv, "on", 2, 0);
      SV **nested_svp = hv_fetch(selection_hv, "selections", 10, 0);
      SV **location_svp = hv_fetch(selection_hv, "location", 8, 0);
      SV *target_type_name_sv = (on_svp && SvOK(*on_svp)) ? *on_svp : parent_type_name_sv;
      if (!gql_validation_compiled_type_hv(aTHX_ compiled_sv, target_type_name_sv)) {
        SV *message = newSVpvf("Inline fragment references unknown type '%s'.", SvPV_nolen(target_type_name_sv));
        av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_svp ? *location_svp : NULL));
        SvREFCNT_dec(message);
        continue;
      }
      if (!gql_validation_selection_types_overlap(aTHX_ compiled_sv, parent_type_name_sv, target_type_name_sv)) {
        SV *message = newSVpvf(
          "Inline fragment on '%s' cannot be used where type '%s' is expected.",
          SvPV_nolen(target_type_name_sv),
          SvPV_nolen(parent_type_name_sv)
        );
        av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_svp ? *location_svp : NULL));
        SvREFCNT_dec(message);
        continue;
      }
      if (nested_svp && SvROK(*nested_svp) && SvTYPE(SvRV(*nested_svp)) == SVt_PVAV) {
        gql_validation_validate_selections(aTHX_ errors_av, schema, compiled_sv, (AV *)SvRV(*nested_svp), target_type_name_sv, variables_hv, fragments_hv);
      }
    }
  }
}

static void
gql_validation_validate_variable_definitions(
  pTHX_ AV *errors_av,
  SV *schema,
  HV *variables_hv,
  SV *location_sv
) {
  I32 count = 0;
  SV **keys = gql_parser_sorted_hash_keys(aTHX_ variables_hv, &count);
  I32 i;

  if (!keys) {
    return;
  }

  for (i = 0; i < count; i++) {
    HE *he = hv_fetch_ent(variables_hv, keys[i], 0, 0);
    SV *type_sv = NULL;
    int has_error = 0;
    if (!he) {
      continue;
    }
    type_sv = gql_validation_lookup_type_sv(aTHX_ schema, HeVAL(he));
    if (SvTRUE(ERRSV)) {
      has_error = 1;
      sv_setsv(ERRSV, &PL_sv_undef);
    }
    if (has_error || !type_sv || !SvOK(type_sv)) {
      SV *message = newSVpvf("Variable '$%s' has an invalid type.", SvPV_nolen(keys[i]));
      av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_sv));
      SvREFCNT_dec(message);
      if (type_sv) {
        SvREFCNT_dec(type_sv);
      }
      continue;
    }
    {
      int is_input = sv_does(type_sv, "GraphQL::Houtou::Role::Input") || sv_does(type_sv, "GraphQL::Role::Input");
      if (!is_input) {
        dSP;
        int count_call;
        SV *type_string_sv;
        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        XPUSHs(sv_2mortal(newSVsv(type_sv)));
        PUTBACK;
        count_call = call_method("to_string", G_SCALAR);
        SPAGAIN;
        type_string_sv = count_call == 1 ? newSVsv(POPs) : newSVpv("", 0);
        PUTBACK;
        FREETMPS;
        LEAVE;
        {
          SV *message = newSVpvf(
            "Variable '$%s' is type '%s' which cannot be used as an input type.",
            SvPV_nolen(keys[i]),
            SvPV_nolen(type_string_sv)
          );
          av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_sv));
          SvREFCNT_dec(message);
        }
        SvREFCNT_dec(type_string_sv);
      }
    }
    SvREFCNT_dec(type_sv);
  }

  gql_parser_free_sorted_hash_keys(keys, count);
}

static void
gql_validation_validate_fragments(pTHX_ AV *errors_av, SV *compiled_sv, HV *fragments_hv) {
  I32 count = 0;
  SV **keys = gql_parser_sorted_hash_keys(aTHX_ fragments_hv, &count);
  I32 i;
  if (!keys) {
    return;
  }
  for (i = 0; i < count; i++) {
    HE *fragment_he = hv_fetch_ent(fragments_hv, keys[i], 0, 0);
    HV *fragment_hv;
    SV **on_svp;
    HV *type_hv;
    SV **kind_svp;
    if (!fragment_he || !SvROK(HeVAL(fragment_he)) || SvTYPE(SvRV(HeVAL(fragment_he))) != SVt_PVHV) {
      continue;
    }
    fragment_hv = (HV *)SvRV(HeVAL(fragment_he));
    on_svp = hv_fetch(fragment_hv, "on", 2, 0);
    type_hv = on_svp ? gql_validation_compiled_type_hv(aTHX_ compiled_sv, *on_svp) : NULL;
    if (!type_hv) {
      SV **location_svp = hv_fetch(fragment_hv, "location", 8, 0);
      SV *message = newSVpvf(
        "Fragment '%s' references unknown type '%s'.",
        SvPV_nolen(keys[i]),
        (on_svp && SvOK(*on_svp)) ? SvPV_nolen(*on_svp) : ""
      );
      av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_svp ? *location_svp : NULL));
      SvREFCNT_dec(message);
      continue;
    }
    kind_svp = hv_fetch(type_hv, "kind", 4, 0);
    if (kind_svp && SvOK(*kind_svp) && SvPOK(*kind_svp)
        && !strEQ(SvPV_nolen(*kind_svp), "OBJECT")
        && !strEQ(SvPV_nolen(*kind_svp), "INTERFACE")
        && !strEQ(SvPV_nolen(*kind_svp), "UNION")) {
      SV **location_svp = hv_fetch(fragment_hv, "location", 8, 0);
      SV *message = newSVpvf(
        "Fragment '%s' cannot target non-composite type '%s'.",
        SvPV_nolen(keys[i]),
        (on_svp && SvOK(*on_svp)) ? SvPV_nolen(*on_svp) : ""
      );
      av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_svp ? *location_svp : NULL));
      SvREFCNT_dec(message);
      continue;
    }
    {
      SV **selections_svp = hv_fetch(fragment_hv, "selections", 10, 0);
      if (selections_svp && SvROK(*selections_svp) && SvTYPE(SvRV(*selections_svp)) == SVt_PVAV) {
        gql_validation_validate_selections(aTHX_ errors_av, NULL, compiled_sv, (AV *)SvRV(*selections_svp), *on_svp, NULL, fragments_hv);
      }
    }
  }
  gql_parser_free_sorted_hash_keys(keys, count);
}

static void
gql_validation_validate_operation(
  pTHX_ AV *errors_av,
  SV *schema,
  SV *compiled_sv,
  HV *operation_hv,
  HV *fragments_hv
) {
  HV *compiled_hv = gql_validation_compiled_hv_from_sv(compiled_sv);
  SV **operation_type_svp = hv_fetch(operation_hv, "operationType", 13, 0);
  const char *operation_type = (operation_type_svp && SvOK(*operation_type_svp)) ? SvPV_nolen(*operation_type_svp) : "query";
  SV **roots_svp = compiled_hv ? hv_fetch(compiled_hv, "roots", 5, 0) : NULL;
  SV *root_type_name_sv = NULL;
  HV *variables_hv = NULL;

  if (roots_svp && SvROK(*roots_svp) && SvTYPE(SvRV(*roots_svp)) == SVt_PVHV) {
    SV **root_type_svp = hv_fetch((HV *)SvRV(*roots_svp), operation_type, (I32)strlen(operation_type), 0);
    if (root_type_svp) {
      root_type_name_sv = *root_type_svp;
    }
  }

  if (!root_type_name_sv || !SvOK(root_type_name_sv)) {
    SV **location_svp = hv_fetch(operation_hv, "location", 8, 0);
    SV *message = newSVpvf("Schema does not define a root type for '%s'.", operation_type);
    av_push(errors_av, gql_validation_error(aTHX_ SvPV_nolen(message), location_svp ? *location_svp : NULL));
    SvREFCNT_dec(message);
    return;
  }

  {
    SV **variables_svp = hv_fetch(operation_hv, "variables", 9, 0);
    if (variables_svp && SvROK(*variables_svp) && SvTYPE(SvRV(*variables_svp)) == SVt_PVHV) {
      variables_hv = (HV *)SvRV(*variables_svp);
      gql_validation_validate_variable_definitions(
        aTHX_ errors_av,
        schema,
        variables_hv,
        (hv_fetch(operation_hv, "location", 8, 0) ? *hv_fetch(operation_hv, "location", 8, 0) : NULL)
      );
    }
  }

  {
    SV **selections_svp = hv_fetch(operation_hv, "selections", 10, 0);
    if (selections_svp && SvROK(*selections_svp) && SvTYPE(SvRV(*selections_svp)) == SVt_PVAV) {
      gql_validation_validate_selections(aTHX_ errors_av, schema, compiled_sv, (AV *)SvRV(*selections_svp), root_type_name_sv, variables_hv, fragments_hv);
    }
  }
}

static SV *
gql_validation_validate(pTHX_ SV *schema, SV *document, SV *options) {
  SV *ast_sv = gql_validation_parse_ast(aTHX_ document, options);
  SV *compiled_sv = gql_schema_compile_schema(aTHX_ schema);
  AV *operations_av = newAV();
  AV *errors_av = newAV();
  HV *fragments_hv;
  AV *operation_errors_av = newAV();
  AV *fragment_cycle_errors_av = newAV();
  AV *ast_av;
  I32 ast_len;
  I32 i;
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
  gql_validation_validate_fragments(aTHX_ errors_av, compiled_sv, fragments_hv);

  {
    I32 fragment_len = av_len(fragment_cycle_errors_av);
    for (i = 0; i <= fragment_len; i++) {
      SV **err_svp = av_fetch(fragment_cycle_errors_av, i, 0);
      if (err_svp && SvOK(*err_svp)) {
        av_push(errors_av, newSVsv(*err_svp));
      }
    }
  }

  for (i = 0; i <= av_len(operations_av); i++) {
    SV **operation_svp = av_fetch(operations_av, i, 0);
    if (operation_svp && SvROK(*operation_svp) && SvTYPE(SvRV(*operation_svp)) == SVt_PVHV) {
      SV **seed_svp = av_fetch(operation_errors_av, i, 0);
      if (seed_svp && SvROK(*seed_svp) && SvTYPE(SvRV(*seed_svp)) == SVt_PVAV) {
        AV *seed_av = (AV *)SvRV(*seed_svp);
        I32 j;
        for (j = 0; j <= av_len(seed_av); j++) {
          SV **err_svp = av_fetch(seed_av, j, 0);
          if (err_svp && SvOK(*err_svp)) {
            av_push(errors_av, newSVsv(*err_svp));
          }
        }
      }
      gql_validation_validate_operation(aTHX_ errors_av, schema, compiled_sv, (HV *)SvRV(*operation_svp), fragments_hv);
    }
  }

  ret = newRV_noinc((SV *)errors_av);

  SvREFCNT_dec((SV *)operations_av);
  SvREFCNT_dec((SV *)fragments_hv);
  SvREFCNT_dec((SV *)operation_errors_av);
  SvREFCNT_dec((SV *)fragment_cycle_errors_av);
  SvREFCNT_dec(ast_sv);
  SvREFCNT_dec(compiled_sv);

  return ret;
}
