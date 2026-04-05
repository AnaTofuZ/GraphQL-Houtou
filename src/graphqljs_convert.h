/*
 * Responsibility: graphql-js AST construction helpers and conversion
 * routines between legacy graphql-perl nodes and graphql-js nodes.
 */
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
gqljs_convert_legacy_empty_selection_set(pTHX) {
  AV *empty_av = newAV();
  SV *selection_set_sv = gqljs_convert_legacy_selection_set_av(aTHX_ empty_av);
  SvREFCNT_dec((SV *)empty_av);
  return selection_set_sv;
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
        : gqljs_convert_legacy_empty_selection_set(aTHX));
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
        : gqljs_convert_legacy_empty_selection_set(aTHX));
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
        : gqljs_convert_legacy_empty_selection_set(aTHX));
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
gql_graphqljs_parse_document(pTHX_ SV *source_sv, SV *no_location_sv, SV *lazy_location_sv, SV *compact_location_sv) {
  SV *meta_sv;
  HV *meta_hv;
  SV **rewritten_svp;
  SV *legacy_sv;
  SV *doc_sv;

  if (gql_graphqljs_looks_like_executable_source(aTHX_ source_sv)) {
    return gql_graphqljs_parse_executable_document(aTHX_ source_sv, no_location_sv, lazy_location_sv, compact_location_sv);
  }

  meta_sv = gql_graphqljs_preprocess(aTHX_ source_sv);
  if (!meta_sv || !SvROK(meta_sv) || SvTYPE(SvRV(meta_sv)) != SVt_PVHV) {
    return &PL_sv_undef;
  }
  meta_hv = (HV *)SvRV(meta_sv);
  rewritten_svp = hv_fetch(meta_hv, "rewritten_source", 16, 0);
  if (!rewritten_svp) {
    SvREFCNT_dec(meta_sv);
    return &PL_sv_undef;
  }

  legacy_sv = gql_parse_document(aTHX_ *rewritten_svp, no_location_sv);
  if (!legacy_sv || !SvROK(legacy_sv) || SvTYPE(SvRV(legacy_sv)) != SVt_PVAV) {
    SvREFCNT_dec(meta_sv);
    return &PL_sv_undef;
  }

  if (gqljs_legacy_document_is_executable(legacy_sv)) {
    doc_sv = gql_graphqljs_build_executable_document(aTHX_ legacy_sv);
  } else {
    doc_sv = gql_graphqljs_build_document(aTHX_ legacy_sv);
  }
  if (!doc_sv || !SvOK(doc_sv) || doc_sv == &PL_sv_undef) {
    SvREFCNT_dec(meta_sv);
    return &PL_sv_undef;
  }

  gqljs_materialize_operation_variable_directives(aTHX_ meta_hv);
  doc_sv = gql_graphqljs_patch_document(aTHX_ doc_sv, meta_sv);
  SvREFCNT_dec(meta_sv);
  if (SvTRUE(no_location_sv)) {
    return doc_sv;
  }
  if (SvTRUE(lazy_location_sv) || SvTRUE(compact_location_sv)) {
    return &PL_sv_undef;
  }

  return gql_graphqljs_apply_executable_loc(aTHX_ doc_sv, source_sv);
}
