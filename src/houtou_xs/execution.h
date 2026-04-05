/*
 * Responsibility: provide the initial XS execution entrypoint so the public
 * execution facade can prefer XS while the actual execution engine migrates
 * from PP to C incrementally.
 */

static SV *gql_execution_execute_fields(pTHX_ SV *context, SV *parent_type, SV *root_value, SV *path, SV *fields);

static void
gql_execution_require_pp(pTHX) {
  eval_pv("require GraphQL::Houtou::Execution::PP; 1;", TRUE);
}

static SV *
gql_execution_call_graphql_error_coerce(pTHX_ SV *error) {
  dSP;
  int count;
  SV *ret;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(error)));
  PUTBACK;

  count = call_pv("GraphQL::Error::coerce", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Error::coerce did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_try_type_graphql_to_perl(pTHX_ SV *type, SV *value, int *ok) {
  dSP;
  int count;
  SV *ret;

  *ok = 0;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(type)));
  XPUSHs(sv_2mortal(newSVsv(value)));
  PUTBACK;

  count = call_method("graphql_to_perl", G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV) || count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    return &PL_sv_undef;
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  *ok = 1;

  return ret;
}

static SV *
gql_execution_call_pp_variables_apply_defaults(pTHX_ SV *schema, SV *operation_variables, SV *variable_values) {
  dSP;
  int count;
  SV *ret;

  gql_execution_require_pp(aTHX);

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(schema)));
  XPUSHs(sv_2mortal(newSVsv(operation_variables)));
  XPUSHs(sv_2mortal(variable_values ? newSVsv(variable_values) : newSV(0)));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::Execution::PP::_variables_apply_defaults", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::Execution::PP::_variables_apply_defaults did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_call_pp_execute_prepared_context(pTHX_ SV *context) {
  dSP;
  int count;
  SV *ret;

  gql_execution_require_pp(aTHX);

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(context)));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::Execution::PP::execute_prepared_context", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::Execution::PP::execute_prepared_context did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_call_pp_resolve_field_value_or_error(pTHX_ SV *context, SV *field_def, SV *nodes, SV *resolve, SV *root_value, SV *info) {
  dSP;
  int count;
  SV *ret;

  gql_execution_require_pp(aTHX);

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(context)));
  XPUSHs(sv_2mortal(newSVsv(field_def)));
  XPUSHs(sv_2mortal(newSVsv(nodes)));
  XPUSHs(sv_2mortal(newSVsv(resolve)));
  XPUSHs(sv_2mortal(root_value ? newSVsv(root_value) : newSV(0)));
  XPUSHs(sv_2mortal(newSVsv(info)));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::Execution::PP::_resolve_field_value_or_error", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::Execution::PP::_resolve_field_value_or_error did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_call_pp_complete_value_catching_error(pTHX_ SV *context, SV *return_type, SV *nodes, SV *info, SV *path, SV *result) {
  dSP;
  int count;
  SV *ret;

  gql_execution_require_pp(aTHX);

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(context)));
  XPUSHs(sv_2mortal(newSVsv(return_type)));
  XPUSHs(sv_2mortal(newSVsv(nodes)));
  XPUSHs(sv_2mortal(newSVsv(info)));
  XPUSHs(sv_2mortal(newSVsv(path)));
  XPUSHs(sv_2mortal(newSVsv(result)));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::Execution::PP::_complete_value_catching_error", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::Execution::PP::_complete_value_catching_error did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_call_resolver(pTHX_ SV *resolve, SV *root_value, SV *args, SV *context_value, SV *info) {
  dSP;
  int count;
  SV *ret;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(root_value ? root_value : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(args)));
  XPUSHs(sv_2mortal(newSVsv(context_value ? context_value : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(info)));
  PUTBACK;

  count = call_sv(resolve, G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV)) {
    SV *error = newSVsv(ERRSV);
    PUTBACK;
    FREETMPS;
    LEAVE;
    return gql_execution_call_graphql_error_coerce(aTHX_ error);
  }
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("resolver did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_call_pp_get_argument_values(pTHX_ SV *def, SV *node, SV *variable_values) {
  dSP;
  int count;
  SV *ret;

  gql_execution_require_pp(aTHX);

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(def)));
  XPUSHs(sv_2mortal(newSVsv(node)));
  XPUSHs(sv_2mortal(variable_values ? newSVsv(variable_values) : newSV(0)));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::Execution::PP::_get_argument_values_pp", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::Execution::PP::_get_argument_values_pp did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_call_pp_type_will_accept(pTHX_ SV *arg_type, SV *var_type) {
  dSP;
  int count;
  SV *ret;

  gql_execution_require_pp(aTHX);

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(arg_type)));
  XPUSHs(sv_2mortal(newSVsv(var_type)));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::Execution::PP::_type_will_accept", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::Execution::PP::_type_will_accept did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_call_type_perl_to_graphql(pTHX_ SV *type, SV *value, int *ok) {
  dSP;
  int count;
  SV *ret;

  *ok = 0;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(type)));
  XPUSHs(sv_2mortal(newSVsv(value)));
  PUTBACK;

  count = call_method("perl_to_graphql", G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV) || count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    return &PL_sv_undef;
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  *ok = 1;

  return ret;
}

static SV *
gql_execution_call_type_of(pTHX_ SV *type) {
  dSP;
  int count;
  SV *ret;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(type)));
  PUTBACK;

  count = call_method("of", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("type->of did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_call_type_to_string(pTHX_ SV *type) {
  dSP;
  int count;
  SV *ret;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(type)));
  PUTBACK;

  count = call_method("to_string", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("type->to_string did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_call_object_is_type_of(pTHX_ SV *type) {
  dSP;
  int count;
  SV *ret;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(type)));
  PUTBACK;

  count = call_method("is_type_of", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("type->is_type_of did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_call_is_type_of_cb(pTHX_ SV *cb, SV *result, SV *context, SV *info, int *ok) {
  dSP;
  int count;
  SV *ret;
  SV *context_value = &PL_sv_undef;

  *ok = 0;
  if (context && SvROK(context) && SvTYPE(SvRV(context)) == SVt_PVHV) {
    SV **context_value_svp = hv_fetch((HV *)SvRV(context), "context_value", 13, 0);
    if (context_value_svp && SvOK(*context_value_svp)) {
      context_value = *context_value_svp;
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(result ? result : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(context_value)));
  XPUSHs(sv_2mortal(newSVsv(info)));
  PUTBACK;

  count = call_sv(cb, G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV) || count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    return &PL_sv_undef;
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  *ok = 1;
  return ret;
}

static SV *
gql_execution_call_abstract_resolve_type_cb(pTHX_ SV *cb, SV *result, SV *context, SV *info, SV *abstract_type, int *ok) {
  dSP;
  int count;
  SV *ret;
  SV *context_value = &PL_sv_undef;

  *ok = 0;
  if (context && SvROK(context) && SvTYPE(SvRV(context)) == SVt_PVHV) {
    SV **context_value_svp = hv_fetch((HV *)SvRV(context), "context_value", 13, 0);
    if (context_value_svp && SvOK(*context_value_svp)) {
      context_value = *context_value_svp;
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(result ? result : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(context_value)));
  XPUSHs(sv_2mortal(newSVsv(info)));
  XPUSHs(sv_2mortal(newSVsv(abstract_type)));
  PUTBACK;

  count = call_sv(cb, G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV) || count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    return &PL_sv_undef;
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  *ok = 1;
  return ret;
}

static SV *
gql_execution_path_with_index(pTHX_ SV *path, IV index) {
  AV *path_copy_av = newAV();
  SV *ret;

  if (SvROK(path) && SvTYPE(SvRV(path)) == SVt_PVAV) {
    AV *path_av = (AV *)SvRV(path);
    I32 path_len = av_len(path_av);
    I32 path_i;

    for (path_i = 0; path_i <= path_len; path_i++) {
      SV **path_part_svp = av_fetch(path_av, path_i, 0);
      if (path_part_svp) {
        av_push(path_copy_av, newSVsv(*path_part_svp));
      }
    }
  }

  av_push(path_copy_av, newSViv(index));
  ret = newRV_noinc((SV *)path_copy_av);
  return ret;
}

static int
gql_execution_is_leaf_like_type(pTHX_ SV *type) {
  SV *current = newSVsv(type);
  int is_leaf = 0;

  while (sv_derived_from(current, "GraphQL::Houtou::Type::NonNull")
      || sv_derived_from(current, "GraphQL::Type::NonNull")) {
    SV *inner = gql_execution_call_type_of(aTHX_ current);
    SvREFCNT_dec(current);
    current = inner;
  }

  if (sv_does(current, "GraphQL::Houtou::Role::Leaf")
      || sv_does(current, "GraphQL::Role::Leaf")) {
    is_leaf = 1;
  }

  SvREFCNT_dec(current);
  return is_leaf;
}

static int
gql_execution_sv_truthy(pTHX_ SV *value) {
  if (!value || !SvOK(value)) {
    return 0;
  }
  return SvTRUE(value) ? 1 : 0;
}

static int
gql_execution_node_should_include_simple(pTHX_ SV *context, SV *node, int *ok) {
  HV *context_hv;
  HV *node_hv;
  SV **directives_svp;
  HV *variable_values_hv = NULL;
  I32 directive_i;
  I32 directive_len;
  int include_node = 1;

  *ok = 0;
  if (!SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
    return 0;
  }
  if (!SvROK(node) || SvTYPE(SvRV(node)) != SVt_PVHV) {
    return 0;
  }

  context_hv = (HV *)SvRV(context);
  node_hv = (HV *)SvRV(node);
  directives_svp = hv_fetch(node_hv, "directives", 10, 0);
  if (!directives_svp || !SvROK(*directives_svp) || SvTYPE(SvRV(*directives_svp)) != SVt_PVAV) {
    *ok = 1;
    return 1;
  }

  {
    SV **variable_values_svp = hv_fetch(context_hv, "variable_values", 15, 0);
    if (variable_values_svp && SvROK(*variable_values_svp) && SvTYPE(SvRV(*variable_values_svp)) == SVt_PVHV) {
      variable_values_hv = (HV *)SvRV(*variable_values_svp);
    }
  }

  directive_len = av_len((AV *)SvRV(*directives_svp));
  for (directive_i = 0; directive_i <= directive_len; directive_i++) {
    SV **directive_svp = av_fetch((AV *)SvRV(*directives_svp), directive_i, 0);
    HV *directive_hv;
    SV **name_svp;
    SV **arguments_svp;
    SV *if_value = NULL;
    const char *name_pv;
    STRLEN name_len;

    if (!directive_svp || !SvROK(*directive_svp) || SvTYPE(SvRV(*directive_svp)) != SVt_PVHV) {
      return 0;
    }

    directive_hv = (HV *)SvRV(*directive_svp);
    name_svp = hv_fetch(directive_hv, "name", 4, 0);
    arguments_svp = hv_fetch(directive_hv, "arguments", 9, 0);
    if (!name_svp || !SvOK(*name_svp)) {
      return 0;
    }
    if (!arguments_svp || !SvROK(*arguments_svp) || SvTYPE(SvRV(*arguments_svp)) != SVt_PVHV) {
      return 0;
    }

    {
      SV **if_svp = hv_fetch((HV *)SvRV(*arguments_svp), "if", 2, 0);
      if (!if_svp) {
        return 0;
      }
      if_value = *if_svp;
    }

    if (SvROK(if_value)) {
      SV *inner = SvRV(if_value);
      if (SvROK(inner) || !variable_values_hv) {
        return 0;
      }
      {
        STRLEN var_len;
        const char *var_name = SvPV(inner, var_len);
        SV **var_svp = hv_fetch(variable_values_hv, var_name, (I32)var_len, 0);
        if (!var_svp || !SvROK(*var_svp) || SvTYPE(SvRV(*var_svp)) != SVt_PVHV) {
          return 0;
        }
        {
          SV **value_svp = hv_fetch((HV *)SvRV(*var_svp), "value", 5, 0);
          if (!value_svp) {
            return 0;
          }
          if_value = *value_svp;
        }
      }
    }

    name_pv = SvPV(*name_svp, name_len);
    if (name_len == 4 && strEQ(name_pv, "skip")) {
      if (gql_execution_sv_truthy(aTHX_ if_value)) {
        include_node = 0;
      }
      continue;
    }
    if (name_len == 7 && strEQ(name_pv, "include")) {
      if (!gql_execution_sv_truthy(aTHX_ if_value)) {
        include_node = 0;
      }
      continue;
    }

    return 0;
  }

  *ok = 1;
  return include_node;
}

static int
gql_execution_collect_simple_selections(
  pTHX_ SV *context,
  SV *object_type,
  AV *selections_av,
  AV *field_names_av,
  HV *nodes_defs_hv
) {
  I32 selection_i;
  I32 selection_len = av_len(selections_av);

  for (selection_i = 0; selection_i <= selection_len; selection_i++) {
    SV **selection_svp = av_fetch(selections_av, selection_i, 0);
    HV *selection_hv;
    SV **kind_svp;
    STRLEN kind_len;
    const char *kind_pv;

    if (!selection_svp || !SvROK(*selection_svp) || SvTYPE(SvRV(*selection_svp)) != SVt_PVHV) {
      return 0;
    }

    selection_hv = (HV *)SvRV(*selection_svp);
    kind_svp = hv_fetch(selection_hv, "kind", 4, 0);
    if (!kind_svp || !SvOK(*kind_svp)) {
      return 0;
    }
    kind_pv = SvPV(*kind_svp, kind_len);

    {
      int include_ok = 0;
      int should_include = gql_execution_node_should_include_simple(aTHX_ context, *selection_svp, &include_ok);
      if (!include_ok) {
        return 0;
      }
      if (!should_include) {
        continue;
      }
    }

    if (kind_len == 5 && strEQ(kind_pv, "field")) {
      SV **alias_svp = hv_fetch(selection_hv, "alias", 5, 0);
      SV **name_svp = hv_fetch(selection_hv, "name", 4, 0);
      SV *use_name_sv = (alias_svp && SvOK(*alias_svp)) ? *alias_svp : (name_svp ? *name_svp : NULL);
      HE *bucket_he;
      SV *bucket_sv;
      AV *bucket_av;

      if (!use_name_sv || !SvOK(use_name_sv)) {
        return 0;
      }

      bucket_he = hv_fetch_ent(nodes_defs_hv, use_name_sv, 0, 0);
      if (!bucket_he) {
        bucket_av = newAV();
        (void)hv_store_ent(nodes_defs_hv, newSVsv(use_name_sv), newRV_noinc((SV *)bucket_av), 0);
        av_push(field_names_av, newSVsv(use_name_sv));
      } else if ((bucket_sv = HeVAL(bucket_he)) && SvROK(bucket_sv) && SvTYPE(SvRV(bucket_sv)) == SVt_PVAV) {
        bucket_av = (AV *)SvRV(bucket_sv);
      } else {
        return 0;
      }

      av_push(bucket_av, newSVsv(*selection_svp));
      continue;
    }

    if (kind_len == 15 && strEQ(kind_pv, "inline_fragment")) {
      SV **on_svp = hv_fetch(selection_hv, "on", 2, 0);
      SV **selections_svp = hv_fetch(selection_hv, "selections", 10, 0);
      if (on_svp && SvOK(*on_svp)) {
        SV *object_name_sv = gql_execution_call_type_to_string(aTHX_ object_type);
        int same_type = sv_eq(*on_svp, object_name_sv);
        SvREFCNT_dec(object_name_sv);
        if (!same_type) {
          continue;
        }
      }
      if (!selections_svp || !SvROK(*selections_svp) || SvTYPE(SvRV(*selections_svp)) != SVt_PVAV) {
        return 0;
      }
      if (!gql_execution_collect_simple_selections(aTHX_ context, object_type, (AV *)SvRV(*selections_svp), field_names_av, nodes_defs_hv)) {
        return 0;
      }
      continue;
    }

    if (kind_len == 15 && strEQ(kind_pv, "fragment_spread")) {
      HV *context_hv;
      SV **fragments_svp;
      SV **name_svp;
      HE *fragment_he;
      SV *fragment_sv;
      HV *fragment_hv;
      SV **on_svp;
      SV **selections_svp;

      if (!SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
        return 0;
      }
      context_hv = (HV *)SvRV(context);
      fragments_svp = hv_fetch(context_hv, "fragments", 9, 0);
      name_svp = hv_fetch(selection_hv, "name", 4, 0);
      if (!fragments_svp || !SvROK(*fragments_svp) || SvTYPE(SvRV(*fragments_svp)) != SVt_PVHV || !name_svp || !SvOK(*name_svp)) {
        return 0;
      }
      fragment_he = hv_fetch_ent((HV *)SvRV(*fragments_svp), *name_svp, 0, 0);
      fragment_sv = fragment_he ? HeVAL(fragment_he) : NULL;
      if (!fragment_sv || !SvROK(fragment_sv) || SvTYPE(SvRV(fragment_sv)) != SVt_PVHV) {
        return 0;
      }
      fragment_hv = (HV *)SvRV(fragment_sv);
      on_svp = hv_fetch(fragment_hv, "on", 2, 0);
      if (on_svp && SvOK(*on_svp)) {
        SV *object_name_sv = gql_execution_call_type_to_string(aTHX_ object_type);
        int same_type = sv_eq(*on_svp, object_name_sv);
        SvREFCNT_dec(object_name_sv);
        if (!same_type) {
          continue;
        }
      }
      selections_svp = hv_fetch(fragment_hv, "selections", 10, 0);
      if (!selections_svp || !SvROK(*selections_svp) || SvTYPE(SvRV(*selections_svp)) != SVt_PVAV) {
        return 0;
      }
      if (!gql_execution_collect_simple_selections(aTHX_ context, object_type, (AV *)SvRV(*selections_svp), field_names_av, nodes_defs_hv)) {
        return 0;
      }
      continue;
    }

    return 0;
  }

  return 1;
}

static SV *
gql_execution_collect_simple_object_fields(pTHX_ SV *context, SV *object_type, SV *nodes, int *ok) {
  AV *field_names_av = NULL;
  HV *nodes_defs_hv = NULL;
  AV *ret_av = NULL;
  I32 node_i;
  I32 node_len;

  *ok = 0;
  if (!SvROK(nodes) || SvTYPE(SvRV(nodes)) != SVt_PVAV) {
    return &PL_sv_undef;
  }

  field_names_av = newAV();
  nodes_defs_hv = newHV();
  node_len = av_len((AV *)SvRV(nodes));

  for (node_i = 0; node_i <= node_len; node_i++) {
    SV **node_svp = av_fetch((AV *)SvRV(nodes), node_i, 0);
    HV *node_hv;
    SV **selections_svp;

    if (!node_svp || !SvROK(*node_svp) || SvTYPE(SvRV(*node_svp)) != SVt_PVHV) {
      continue;
    }

    node_hv = (HV *)SvRV(*node_svp);
    selections_svp = hv_fetch(node_hv, "selections", 10, 0);
    if (!selections_svp || !SvROK(*selections_svp) || SvTYPE(SvRV(*selections_svp)) != SVt_PVAV) {
      continue;
    }
    if (!gql_execution_collect_simple_selections(
          aTHX_ context,
          object_type,
          (AV *)SvRV(*selections_svp),
          field_names_av,
          nodes_defs_hv
        )) {
      goto fallback;
    }
  }

  ret_av = newAV();
  av_push(ret_av, newRV_noinc((SV *)field_names_av));
  av_push(ret_av, newRV_noinc((SV *)nodes_defs_hv));
  *ok = 1;
  return newRV_noinc((SV *)ret_av);

fallback:
  SvREFCNT_dec((SV *)field_names_av);
  SvREFCNT_dec((SV *)nodes_defs_hv);
  return &PL_sv_undef;
}

static SV *
gql_execution_coerce_ast(pTHX_ SV *document) {
  if (SvROK(document)) {
    return newSVsv(document);
  }

  return gql_parse_document(aTHX_ document, &PL_sv_undef);
}

static SV *
gql_execution_select_operation(pTHX_ AV *operations_av, SV *operation_name) {
  I32 operation_len = av_len(operations_av);
  I32 operation_count = operation_len >= 0 ? operation_len + 1 : 0;
  I32 i;

  if (!operation_name || operation_name == &PL_sv_undef || !SvOK(operation_name)) {
    if (operation_count > 1) {
      croak("Must provide operation name if query contains multiple operations.\n");
    }
    if (operation_count == 0) {
      return &PL_sv_undef;
    }
    {
      SV **first_svp = av_fetch(operations_av, 0, 0);
      return first_svp ? newSVsv(*first_svp) : &PL_sv_undef;
    }
  }

  for (i = 0; i <= operation_len; i++) {
    SV **operation_svp = av_fetch(operations_av, i, 0);
    HV *operation_hv;
    SV **name_svp;

    if (!operation_svp || !SvROK(*operation_svp) || SvTYPE(SvRV(*operation_svp)) != SVt_PVHV) {
      continue;
    }

    operation_hv = (HV *)SvRV(*operation_svp);
    name_svp = hv_fetch(operation_hv, "name", 4, 0);
    if (!name_svp || !SvOK(*name_svp)) {
      continue;
    }

    if (sv_eq(*name_svp, operation_name)) {
      return newSVsv(*operation_svp);
    }
  }

  croak("No operations matching '%s' found.\n", SvPV_nolen(operation_name));
}

static SV *
gql_execution_build_context(pTHX_ SV *schema, SV *ast, SV *root_value, SV *context_value, SV *variable_values, SV *operation_name, SV *field_resolver, SV *promise_code) {
  HV *context_hv = newHV();
  HV *fragments_hv = newHV();
  AV *operations_av = newAV();
  AV *ast_av;
  I32 ast_len;
  I32 i;
  SV *operation_sv;
  HV *operation_hv;
  SV **variables_svp;
  SV *applied_variables_sv;
  SV *empty_variables_sv = NULL;
  SV *runtime_variables_sv = NULL;

  if (!SvROK(ast) || SvTYPE(SvRV(ast)) != SVt_PVAV) {
    croak("Execution AST must be an array reference");
  }

  ast_av = (AV *)SvRV(ast);
  ast_len = av_len(ast_av);

  for (i = 0; i <= ast_len; i++) {
    SV **node_svp = av_fetch(ast_av, i, 0);
    HV *node_hv;
    SV **kind_svp;

    if (!node_svp || !SvROK(*node_svp) || SvTYPE(SvRV(*node_svp)) != SVt_PVHV) {
      continue;
    }

    node_hv = (HV *)SvRV(*node_svp);
    kind_svp = hv_fetch(node_hv, "kind", 4, 0);
    if (!kind_svp || !SvOK(*kind_svp) || !SvPOK(*kind_svp)) {
      continue;
    }

    if (strEQ(SvPV_nolen(*kind_svp), "fragment")) {
      SV **name_svp = hv_fetch(node_hv, "name", 4, 0);
      STRLEN name_len;
      const char *name;
      if (!name_svp || !SvOK(*name_svp)) {
        continue;
      }
      name = SvPV(*name_svp, name_len);
      (void)hv_store(fragments_hv, name, (I32)name_len, newSVsv(*node_svp), 0);
      continue;
    }

    if (strEQ(SvPV_nolen(*kind_svp), "operation")) {
      av_push(operations_av, newSVsv(*node_svp));
      continue;
    }

    SvREFCNT_dec((SV *)context_hv);
    SvREFCNT_dec((SV *)fragments_hv);
    SvREFCNT_dec((SV *)operations_av);
    croak("Can only execute document containing fragments or operations\n");
  }

  if (av_len(operations_av) < 0) {
    SvREFCNT_dec((SV *)context_hv);
    SvREFCNT_dec((SV *)fragments_hv);
    SvREFCNT_dec((SV *)operations_av);
    croak("No operations supplied.\n");
  }

  operation_sv = gql_execution_select_operation(aTHX_ operations_av, operation_name);
  if (!SvROK(operation_sv) || SvTYPE(SvRV(operation_sv)) != SVt_PVHV) {
    SvREFCNT_dec((SV *)context_hv);
    SvREFCNT_dec((SV *)fragments_hv);
    SvREFCNT_dec((SV *)operations_av);
    croak("Selected operation is not a hash reference");
  }

  operation_hv = (HV *)SvRV(operation_sv);
  variables_svp = hv_fetch(operation_hv, "variables", 9, 0);
  if (!variables_svp || !SvOK(*variables_svp)) {
    empty_variables_sv = newRV_noinc((SV *)newHV());
  }
  if (!variable_values || !SvOK(variable_values)) {
    runtime_variables_sv = newRV_noinc((SV *)newHV());
  }

  applied_variables_sv = gql_execution_call_pp_variables_apply_defaults(
    aTHX_ schema,
    (variables_svp && SvOK(*variables_svp)) ? *variables_svp : empty_variables_sv,
    (variable_values && SvOK(variable_values)) ? variable_values : runtime_variables_sv
  );

  gql_store_sv(context_hv, "schema", newSVsv(schema));
  gql_store_sv(context_hv, "fragments", newRV_noinc((SV *)fragments_hv));
  gql_store_sv(context_hv, "root_value", root_value && SvOK(root_value) ? newSVsv(root_value) : newSV(0));
  gql_store_sv(context_hv, "context_value", context_value && SvOK(context_value) ? newSVsv(context_value) : newSV(0));
  gql_store_sv(context_hv, "operation", operation_sv);
  gql_store_sv(context_hv, "variable_values", applied_variables_sv);
  gql_store_sv(context_hv, "field_resolver", field_resolver && SvOK(field_resolver) ? newSVsv(field_resolver) : newSV(0));
  gql_store_sv(context_hv, "promise_code", promise_code && SvOK(promise_code) ? newSVsv(promise_code) : newSV(0));

  if (empty_variables_sv) {
    SvREFCNT_dec(empty_variables_sv);
  }
  if (runtime_variables_sv) {
    SvREFCNT_dec(runtime_variables_sv);
  }
  SvREFCNT_dec((SV *)operations_av);
  return newRV_noinc((SV *)context_hv);
}

static SV *
gql_execution_execute(pTHX_ SV *schema, SV *document, SV *root_value, SV *context_value, SV *variable_values, SV *operation_name, SV *field_resolver, SV *promise_code) {
  SV *ast = NULL;
  SV *context = NULL;
  SV *result = NULL;

  ast = gql_execution_coerce_ast(aTHX_ document);
  context = gql_execution_build_context(
    aTHX_ schema,
    ast,
    root_value,
    context_value,
    variable_values,
    operation_name,
    field_resolver,
    promise_code
  );
  result = gql_execution_call_pp_execute_prepared_context(aTHX_ context);

  /*
   * TODO: the execution path still shares Perl-side structures across the
   * PP/XS boundary. Keep the prepared AST/context alive for now rather than
   * risking premature destruction while the field loop is mid-migration.
   */
  return result;
}

static SV *
gql_execution_complete_value_catching_error_xs_impl(pTHX_ SV *context, SV *return_type, SV *nodes, SV *info, SV *path, SV *result) {
  if (result && SvROK(result) && sv_derived_from(result, "GraphQL::Error")) {
    return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
  }

  if (sv_derived_from(return_type, "GraphQL::Houtou::Type::NonNull")
      || sv_derived_from(return_type, "GraphQL::Type::NonNull")) {
    SV *inner_type = gql_execution_call_type_of(aTHX_ return_type);
    SV *completed = gql_execution_complete_value_catching_error_xs_impl(
      aTHX_ context,
      inner_type,
      nodes,
      info,
      path,
      result
    );

    SvREFCNT_dec(inner_type);
    if (SvROK(completed) && SvTYPE(SvRV(completed)) == SVt_PVHV) {
      HV *completed_hv = (HV *)SvRV(completed);
      SV **data_svp = hv_fetch(completed_hv, "data", 4, 0);
      if (data_svp && !SvOK(*data_svp)) {
        SvREFCNT_dec(completed);
        return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
      }
    }

    return completed;
  }

  if (!result || !SvOK(result)) {
    HV *ret_hv = newHV();
    (void)hv_store(ret_hv, "data", 4, newSV(0), 0);
    return newRV_noinc((SV *)ret_hv);
  }

  if (sv_does(return_type, "GraphQL::Houtou::Role::Leaf")
      || sv_does(return_type, "GraphQL::Role::Leaf")) {
    int ok = 0;
    SV *serialized = gql_execution_call_type_perl_to_graphql(aTHX_ return_type, result, &ok);

    if (!ok) {
      return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
    }

    {
      HV *ret_hv = newHV();
      (void)hv_store(ret_hv, "data", 4, serialized, 0);
      return newRV_noinc((SV *)ret_hv);
    }
  }

  if (sv_derived_from(return_type, "GraphQL::Houtou::Type::List")
      || sv_derived_from(return_type, "GraphQL::Type::List")) {
    SV *item_type = gql_execution_call_type_of(aTHX_ return_type);

    if (SvROK(result) && SvTYPE(SvRV(result)) == SVt_PVAV) {
      AV *result_av = (AV *)SvRV(result);
      I32 result_len = av_len(result_av);
      AV *data_av = newAV();
      AV *errors_av = newAV();
      I32 i;

      for (i = 0; i <= result_len; i++) {
        SV **item_svp = av_fetch(result_av, i, 0);
        SV *item_path_sv = gql_execution_path_with_index(aTHX_ path, (IV)i);
        SV *completed = gql_execution_complete_value_catching_error_xs_impl(
          aTHX_ context,
          item_type,
          nodes,
          info,
          item_path_sv,
          item_svp ? *item_svp : &PL_sv_undef
        );

        if (SvROK(completed) && SvTYPE(SvRV(completed)) == SVt_PVHV) {
          HV *completed_hv = (HV *)SvRV(completed);
          SV **data_svp = hv_fetch(completed_hv, "data", 4, 0);
          SV **item_errors_svp = hv_fetch(completed_hv, "errors", 6, 0);
          if (data_svp) {
            av_push(data_av, newSVsv(*data_svp));
          } else {
            av_push(data_av, newSV(0));
          }
          if (item_errors_svp && SvROK(*item_errors_svp) && SvTYPE(SvRV(*item_errors_svp)) == SVt_PVAV) {
            AV *item_errors_av = (AV *)SvRV(*item_errors_svp);
            I32 err_len = av_len(item_errors_av);
            I32 err_i;
            for (err_i = 0; err_i <= err_len; err_i++) {
              SV **err_svp = av_fetch(item_errors_av, err_i, 0);
              if (err_svp) {
                av_push(errors_av, newSVsv(*err_svp));
              }
            }
          }
        } else {
          SvREFCNT_dec(item_path_sv);
          SvREFCNT_dec(completed);
          SvREFCNT_dec(item_type);
          SvREFCNT_dec((SV *)data_av);
          SvREFCNT_dec((SV *)errors_av);
          return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
        }

        SvREFCNT_dec(item_path_sv);
        SvREFCNT_dec(completed);
      }

      SvREFCNT_dec(item_type);
      {
        HV *ret_hv = newHV();
        (void)hv_store(ret_hv, "data", 4, newRV_noinc((SV *)data_av), 0);
        if (av_len(errors_av) >= 0) {
          (void)hv_store(ret_hv, "errors", 6, newRV_noinc((SV *)errors_av), 0);
        } else {
          SvREFCNT_dec((SV *)errors_av);
        }
        return newRV_noinc((SV *)ret_hv);
      }
    }

    SvREFCNT_dec(item_type);
    return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
  }

  if (sv_derived_from(return_type, "GraphQL::Houtou::Type::Object")
      || sv_derived_from(return_type, "GraphQL::Type::Object")) {
    SV *is_type_of_sv = gql_execution_call_object_is_type_of(aTHX_ return_type);

    if (SvOK(is_type_of_sv)) {
      int type_ok = 0;
      SV *type_match = gql_execution_call_is_type_of_cb(aTHX_ is_type_of_sv, result, context, info, &type_ok);
      SvREFCNT_dec(is_type_of_sv);
      if (!type_ok || !SvTRUE(type_match)) {
        if (type_ok) {
          SvREFCNT_dec(type_match);
        }
        return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
      }
      SvREFCNT_dec(type_match);
    } else {
      int ok = 0;
      SV *subfields = gql_execution_collect_simple_object_fields(aTHX_ context, return_type, nodes, &ok);
      if (ok) {
        SV *ret = gql_execution_execute_fields(aTHX_ context, return_type, result, path, subfields);
        SvREFCNT_dec(subfields);
        return ret;
      }
    }

    {
      int ok = 0;
      SV *subfields = gql_execution_collect_simple_object_fields(aTHX_ context, return_type, nodes, &ok);
      if (ok) {
        SV *ret = gql_execution_execute_fields(aTHX_ context, return_type, result, path, subfields);
        SvREFCNT_dec(subfields);
        return ret;
      }
    }

    return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
  }

  if (sv_does(return_type, "GraphQL::Houtou::Role::Abstract")
      || sv_does(return_type, "GraphQL::Role::Abstract")) {
    dSP;
    int count;
    SV *resolve_type_sv;
    HV *context_hv = (SvROK(context) && SvTYPE(SvRV(context)) == SVt_PVHV) ? (HV *)SvRV(context) : NULL;
    SV **schema_svp = context_hv ? hv_fetch(context_hv, "schema", 6, 0) : NULL;

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVsv(return_type)));
    PUTBACK;
    count = call_method("resolve_type", G_SCALAR);
    SPAGAIN;
    if (count != 1) {
      PUTBACK;
      FREETMPS;
      LEAVE;
      return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
    }
    resolve_type_sv = newSVsv(POPs);
    PUTBACK;
    FREETMPS;
    LEAVE;

    if (SvOK(resolve_type_sv)) {
      int ok = 0;
      SV *runtime_type_or_name = gql_execution_call_abstract_resolve_type_cb(
        aTHX_ resolve_type_sv,
        result,
        context,
        info,
        return_type,
        &ok
      );

      SvREFCNT_dec(resolve_type_sv);
      if (ok && SvOK(runtime_type_or_name)) {
        SV *runtime_type = runtime_type_or_name;

        if (!SvROK(runtime_type_or_name) && schema_svp && SvROK(*schema_svp) && SvTYPE(SvRV(*schema_svp)) == SVt_PVHV) {
          SV **name2type_svp = hv_fetch((HV *)SvRV(*schema_svp), "name2type", 9, 0);
          if (name2type_svp && SvROK(*name2type_svp) && SvTYPE(SvRV(*name2type_svp)) == SVt_PVHV) {
            STRLEN name_len;
            const char *name_pv = SvPV(runtime_type_or_name, name_len);
            HE *runtime_he = hv_fetch_ent((HV *)SvRV(*name2type_svp), runtime_type_or_name, 0, 0);
            (void)name_pv;
            if (runtime_he) {
              runtime_type = HeVAL(runtime_he);
            }
          }
        }

        if (SvROK(runtime_type)
            && (sv_derived_from(runtime_type, "GraphQL::Houtou::Type::Object")
                || sv_derived_from(runtime_type, "GraphQL::Type::Object"))
            && schema_svp
            && SvROK(*schema_svp)
            && SvTYPE(SvRV(*schema_svp)) == SVt_PVHV) {
          dSP;
          int possible_count;
          SV *possible_sv;

          ENTER;
          SAVETMPS;
          PUSHMARK(SP);
          XPUSHs(sv_2mortal(newSVsv(*schema_svp)));
          XPUSHs(sv_2mortal(newSVsv(return_type)));
          XPUSHs(sv_2mortal(newSVsv(runtime_type)));
          PUTBACK;
          possible_count = call_method("is_possible_type", G_SCALAR | G_EVAL);
          SPAGAIN;
          if (!SvTRUE(ERRSV) && possible_count == 1) {
            possible_sv = newSVsv(POPs);
            PUTBACK;
            FREETMPS;
            LEAVE;
            if (SvTRUE(possible_sv)) {
              SV *completed = gql_execution_complete_value_catching_error_xs_impl(
                aTHX_ context,
                runtime_type,
                nodes,
                info,
                path,
                result
              );
              SvREFCNT_dec(possible_sv);
              if (runtime_type != runtime_type_or_name) {
                SvREFCNT_dec(runtime_type_or_name);
              } else {
                SvREFCNT_dec(runtime_type_or_name);
              }
              return completed;
            }
            SvREFCNT_dec(possible_sv);
          } else {
            PUTBACK;
            FREETMPS;
            LEAVE;
          }
        }

        SvREFCNT_dec(runtime_type_or_name);
      } else if (ok) {
        SvREFCNT_dec(runtime_type_or_name);
      }
    } else {
      SvREFCNT_dec(resolve_type_sv);

      if (schema_svp && SvROK(*schema_svp) && SvTYPE(SvRV(*schema_svp)) == SVt_PVHV) {
        dSP;
        int possible_count;
        SV *possible_types_sv;

        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        XPUSHs(sv_2mortal(newSVsv(*schema_svp)));
        XPUSHs(sv_2mortal(newSVsv(return_type)));
        PUTBACK;
        possible_count = call_method("get_possible_types", G_SCALAR | G_EVAL);
        SPAGAIN;
        if (!SvTRUE(ERRSV) && possible_count == 1) {
          I32 possible_i;
          I32 possible_len;

          possible_types_sv = newSVsv(POPs);
          PUTBACK;
          FREETMPS;
          LEAVE;

          if (SvROK(possible_types_sv) && SvTYPE(SvRV(possible_types_sv)) == SVt_PVAV) {
            possible_len = av_len((AV *)SvRV(possible_types_sv));
            for (possible_i = 0; possible_i <= possible_len; possible_i++) {
              SV **possible_svp = av_fetch((AV *)SvRV(possible_types_sv), possible_i, 0);
              if (possible_svp && SvROK(*possible_svp)) {
                SV *possible_type = *possible_svp;
                SV *is_type_of_sv = gql_execution_call_object_is_type_of(aTHX_ possible_type);
                if (SvOK(is_type_of_sv)) {
                  int match_ok = 0;
                  SV *type_match = gql_execution_call_is_type_of_cb(aTHX_ is_type_of_sv, result, context, info, &match_ok);
                  SvREFCNT_dec(is_type_of_sv);
                  if (match_ok && SvTRUE(type_match)) {
                    SV *completed = gql_execution_complete_value_catching_error_xs_impl(
                      aTHX_ context,
                      possible_type,
                      nodes,
                      info,
                      path,
                      result
                    );
                    SvREFCNT_dec(type_match);
                    SvREFCNT_dec(possible_types_sv);
                    return completed;
                  }
                  if (match_ok) {
                    SvREFCNT_dec(type_match);
                  }
                } else {
                  SvREFCNT_dec(is_type_of_sv);
                }
              }
            }
          }

          SvREFCNT_dec(possible_types_sv);
        } else {
          PUTBACK;
          FREETMPS;
          LEAVE;
        }
      }
    }

    return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
  }

  return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
}

static SV *
gql_execution_build_resolve_info(pTHX_ SV *context, SV *parent_type, SV *field_def, SV *path, SV *nodes) {
  HV *info_hv = newHV();
  HV *context_hv;
  AV *nodes_av;
  SV **field_node_svp;
  HV *field_node_hv;
  SV **field_name_svp;
  HV *field_def_hv;
  SV **return_type_svp;
  SV **fragments_svp;
  SV **root_value_svp;
  SV **operation_svp;
  SV **variable_values_svp;
  SV **promise_code_svp;
  SV **schema_svp;

  if (!SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
    croak("context must be a hash reference");
  }
  if (!SvROK(nodes) || SvTYPE(SvRV(nodes)) != SVt_PVAV) {
    croak("nodes must be an array reference");
  }
  if (!SvROK(field_def) || SvTYPE(SvRV(field_def)) != SVt_PVHV) {
    croak("field_def must be a hash reference");
  }

  context_hv = (HV *)SvRV(context);
  nodes_av = (AV *)SvRV(nodes);
  field_node_svp = av_fetch(nodes_av, 0, 0);
  if (!field_node_svp || !SvROK(*field_node_svp) || SvTYPE(SvRV(*field_node_svp)) != SVt_PVHV) {
    croak("nodes must contain field hash references");
  }

  field_node_hv = (HV *)SvRV(*field_node_svp);
  field_name_svp = hv_fetch(field_node_hv, "name", 4, 0);
  if (!field_name_svp || !SvOK(*field_name_svp)) {
    croak("field node has no name");
  }

  field_def_hv = (HV *)SvRV(field_def);
  return_type_svp = hv_fetch(field_def_hv, "type", 4, 0);
  if (!return_type_svp || !SvOK(*return_type_svp)) {
    croak("field definition has no type");
  }

  schema_svp = hv_fetch(context_hv, "schema", 6, 0);
  fragments_svp = hv_fetch(context_hv, "fragments", 9, 0);
  root_value_svp = hv_fetch(context_hv, "root_value", 10, 0);
  operation_svp = hv_fetch(context_hv, "operation", 9, 0);
  variable_values_svp = hv_fetch(context_hv, "variable_values", 15, 0);
  promise_code_svp = hv_fetch(context_hv, "promise_code", 12, 0);

  gql_store_sv(info_hv, "field_name", newSVsv(*field_name_svp));
  gql_store_sv(info_hv, "field_nodes", newSVsv(nodes));
  gql_store_sv(info_hv, "return_type", newSVsv(*return_type_svp));
  gql_store_sv(info_hv, "parent_type", newSVsv(parent_type));
  gql_store_sv(info_hv, "path", newSVsv(path));
  gql_store_sv(info_hv, "schema", (schema_svp && SvOK(*schema_svp)) ? newSVsv(*schema_svp) : newSV(0));
  gql_store_sv(info_hv, "fragments", (fragments_svp && SvOK(*fragments_svp)) ? newSVsv(*fragments_svp) : newSV(0));
  gql_store_sv(info_hv, "root_value", (root_value_svp && SvOK(*root_value_svp)) ? newSVsv(*root_value_svp) : newSV(0));
  gql_store_sv(info_hv, "operation", (operation_svp && SvOK(*operation_svp)) ? newSVsv(*operation_svp) : newSV(0));
  gql_store_sv(info_hv, "variable_values", (variable_values_svp && SvOK(*variable_values_svp)) ? newSVsv(*variable_values_svp) : newSV(0));
  gql_store_sv(info_hv, "promise_code", (promise_code_svp && SvOK(*promise_code_svp)) ? newSVsv(*promise_code_svp) : newSV(0));

  return newRV_noinc((SV *)info_hv);
}

static SV *
gql_execution_get_argument_values_xs_impl(pTHX_ SV *def, SV *node, SV *variable_values) {
  HV *def_hv;
  HV *node_hv;
  HV *variable_values_hv = NULL;
  SV **arg_defs_svp;
  SV **arg_nodes_svp;
  HV *arg_defs_hv;
  HV *arg_nodes_hv = NULL;
  HV *coerced_hv = newHV();
  HE *he;

  if (!SvROK(def) || SvTYPE(SvRV(def)) != SVt_PVHV) {
    SvREFCNT_dec((SV *)coerced_hv);
    return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
  }
  if (!SvROK(node) || SvTYPE(SvRV(node)) != SVt_PVHV) {
    SvREFCNT_dec((SV *)coerced_hv);
    return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
  }

  def_hv = (HV *)SvRV(def);
  node_hv = (HV *)SvRV(node);
  if (variable_values && SvROK(variable_values) && SvTYPE(SvRV(variable_values)) == SVt_PVHV) {
    variable_values_hv = (HV *)SvRV(variable_values);
  }
  arg_defs_svp = hv_fetch(def_hv, "args", 4, 0);
  arg_nodes_svp = hv_fetch(node_hv, "arguments", 9, 0);

  if (!arg_defs_svp || !SvOK(*arg_defs_svp)) {
    return newRV_noinc((SV *)coerced_hv);
  }
  if (!SvROK(*arg_defs_svp) || SvTYPE(SvRV(*arg_defs_svp)) != SVt_PVHV) {
    SvREFCNT_dec((SV *)coerced_hv);
    return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
  }

  arg_defs_hv = (HV *)SvRV(*arg_defs_svp);
  if (HvUSEDKEYS(arg_defs_hv) == 0) {
    return newRV_noinc((SV *)coerced_hv);
  }

  if (arg_nodes_svp && SvOK(*arg_nodes_svp)) {
    if (!SvROK(*arg_nodes_svp) || SvTYPE(SvRV(*arg_nodes_svp)) != SVt_PVHV) {
      SvREFCNT_dec((SV *)coerced_hv);
      return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
    }
    arg_nodes_hv = (HV *)SvRV(*arg_nodes_svp);
  }

  hv_iterinit(arg_defs_hv);
  while ((he = hv_iternext(arg_defs_hv))) {
    SV *name_sv = hv_iterkeysv(he);
    SV *arg_def_sv = hv_iterval(arg_defs_hv, he);
    HV *arg_def_hv;
    SV **default_svp;
    SV **type_svp;
    HE *arg_node_he = NULL;
    SV *arg_node_sv = NULL;

    if (!SvROK(arg_def_sv) || SvTYPE(SvRV(arg_def_sv)) != SVt_PVHV) {
      SvREFCNT_dec((SV *)coerced_hv);
      return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
    }

    arg_def_hv = (HV *)SvRV(arg_def_sv);
    default_svp = hv_fetch(arg_def_hv, "default_value", 13, 0);
    type_svp = hv_fetch(arg_def_hv, "type", 4, 0);
    if (arg_nodes_hv) {
      arg_node_he = hv_fetch_ent(arg_nodes_hv, name_sv, 0, 0);
    }

    if (default_svp && SvOK(*default_svp)) {
      if (!arg_node_he) {
        (void)hv_store_ent(coerced_hv, name_sv, newSVsv(*default_svp), 0);
        continue;
      }
    }

    if (!arg_node_he) {
      if (type_svp && SvOK(*type_svp)
          && (sv_derived_from(*type_svp, "GraphQL::Houtou::Type::NonNull")
              || sv_derived_from(*type_svp, "GraphQL::Type::NonNull"))) {
        SvREFCNT_dec((SV *)coerced_hv);
        return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
      }
      continue;
    }

    arg_node_sv = HeVAL(arg_node_he);
    if (SvROK(arg_node_sv)) {
      SV *inner = SvRV(arg_node_sv);

      if (!SvROK(inner) && variable_values_hv) {
        STRLEN var_len;
        const char *var_name = SvPV(inner, var_len);
        SV **var_svp = hv_fetch(variable_values_hv, var_name, (I32)var_len, 0);

        if (var_svp && SvROK(*var_svp) && SvTYPE(SvRV(*var_svp)) == SVt_PVHV) {
          HV *var_hv = (HV *)SvRV(*var_svp);
          SV **value_svp = hv_fetch(var_hv, "value", 5, 0);
          SV **var_type_svp = hv_fetch(var_hv, "type", 4, 0);
          SV *type_ok_sv;

          if (!value_svp || !var_type_svp || !SvOK(*var_type_svp)) {
            SvREFCNT_dec((SV *)coerced_hv);
            return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
          }

          type_ok_sv = gql_execution_call_pp_type_will_accept(aTHX_ *type_svp, *var_type_svp);
          if (!SvTRUE(type_ok_sv)) {
            SvREFCNT_dec(type_ok_sv);
            SvREFCNT_dec((SV *)coerced_hv);
            return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
          }

          SvREFCNT_dec(type_ok_sv);
          (void)hv_store_ent(coerced_hv, name_sv, newSVsv(*value_svp), 0);
          continue;
        }

        if (default_svp && SvOK(*default_svp)) {
          (void)hv_store_ent(coerced_hv, name_sv, newSVsv(*default_svp), 0);
          continue;
        }

        SvREFCNT_dec((SV *)coerced_hv);
        return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
      }

      SvREFCNT_dec((SV *)coerced_hv);
      return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
    }

    if (!type_svp || !SvOK(*type_svp)) {
      SvREFCNT_dec((SV *)coerced_hv);
      return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
    }

    {
      int ok = 0;
      SV *parsed = gql_execution_try_type_graphql_to_perl(aTHX_ *type_svp, arg_node_sv, &ok);
      if (!ok) {
        SvREFCNT_dec((SV *)coerced_hv);
        return gql_execution_call_pp_get_argument_values(aTHX_ def, node, variable_values);
      }
      (void)hv_store_ent(coerced_hv, name_sv, parsed, 0);
      continue;
    }
  }

  return newRV_noinc((SV *)coerced_hv);
}

static SV *
gql_execution_merge_hash(pTHX_ AV *keys_av, AV *values_av, AV *errors_av) {
  HV *result_hv = newHV();
  HV *data_hv = newHV();
  AV *all_errors_av = newAV();
  I32 value_len = av_len(values_av);
  I32 error_len = av_len(errors_av);
  I32 i;

  for (i = 0; i <= error_len; i++) {
    SV **error_svp = av_fetch(errors_av, i, 0);
    if (error_svp) {
      av_push(all_errors_av, newSVsv(*error_svp));
    }
  }

  for (i = value_len; i >= 0; i--) {
    SV **key_svp = av_fetch(keys_av, i, 0);
    SV **value_svp = av_fetch(values_av, i, 0);
    HV *value_hv;
    SV **data_svp;
    SV **child_errors_svp;
    AV *child_errors_av;
    I32 child_error_len;
    I32 j;
    STRLEN key_len;
    const char *key;

    if (!key_svp || !value_svp || !SvROK(*value_svp) || SvTYPE(SvRV(*value_svp)) != SVt_PVHV) {
      continue;
    }

    value_hv = (HV *)SvRV(*value_svp);
    data_svp = hv_fetch(value_hv, "data", 4, 0);
    if (key_svp && SvOK(*key_svp) && data_svp) {
      key = SvPV(*key_svp, key_len);
      (void)hv_store(data_hv, key, (I32)key_len, newSVsv(*data_svp), 0);
    }

    child_errors_svp = hv_fetch(value_hv, "errors", 6, 0);
    if (child_errors_svp && SvROK(*child_errors_svp) && SvTYPE(SvRV(*child_errors_svp)) == SVt_PVAV) {
      child_errors_av = (AV *)SvRV(*child_errors_svp);
      child_error_len = av_len(child_errors_av);
      for (j = 0; j <= child_error_len; j++) {
        SV **child_error_svp = av_fetch(child_errors_av, j, 0);
        if (child_error_svp) {
          av_push(all_errors_av, newSVsv(*child_error_svp));
        }
      }
    }
  }

  if (HvUSEDKEYS(data_hv) > 0) {
    gql_store_sv(result_hv, "data", newRV_noinc((SV *)data_hv));
  } else {
    SvREFCNT_dec((SV *)data_hv);
  }

  if (av_len(all_errors_av) >= 0) {
    gql_store_sv(result_hv, "errors", newRV_noinc((SV *)all_errors_av));
  } else {
    SvREFCNT_dec((SV *)all_errors_av);
  }

  return newRV_noinc((SV *)result_hv);
}

static SV *
gql_execution_get_field_def(pTHX_ SV *schema, SV *parent_type, SV *field_name) {
  HV *schema_hv;
  SV **query_svp;
  HV *parent_type_hv;
  SV **fields_svp;
  HV *fields_hv;
  HE *field_he;
  const char *name;
  STRLEN name_len;

  if (!SvROK(schema) || SvTYPE(SvRV(schema)) != SVt_PVHV) {
    if (sv_derived_from(schema, "GraphQL::Houtou::Schema") || sv_derived_from(schema, "GraphQL::Schema")) {
      dSP;
      int count;
      SV *ret;

      ENTER;
      SAVETMPS;
      PUSHMARK(SP);
      XPUSHs(sv_2mortal(newSVsv(schema)));
      XPUSHs(sv_2mortal(newSVsv(parent_type)));
      XPUSHs(sv_2mortal(newSVsv(field_name)));
      PUTBACK;
      count = call_pv("GraphQL::Houtou::Execution::PP::_get_field_def", G_SCALAR);
      SPAGAIN;
      if (count != 1) {
        PUTBACK;
        FREETMPS;
        LEAVE;
        croak("GraphQL::Houtou::Execution::PP::_get_field_def did not return a scalar");
      }
      ret = newSVsv(POPs);
      PUTBACK;
      FREETMPS;
      LEAVE;
      return ret;
    }
    return &PL_sv_undef;
  }

  schema_hv = (HV *)SvRV(schema);
  query_svp = hv_fetch(schema_hv, "query", 5, 0);
  name = SvPV(field_name, name_len);

  if (strEQ(name, "__typename")) {
    GV *gv = gv_fetchpv("GraphQL::Houtou::Introspection::TYPE_NAME_META_FIELD_DEF", GV_ADD, SVt_PV);
    return newSVsv(GvSV(gv));
  }

  if (query_svp && sv_eq(*query_svp, parent_type)) {
    if (strEQ(name, "__schema")) {
      GV *gv = gv_fetchpv("GraphQL::Houtou::Introspection::SCHEMA_META_FIELD_DEF", GV_ADD, SVt_PV);
      return newSVsv(GvSV(gv));
    }
    if (strEQ(name, "__type")) {
      GV *gv = gv_fetchpv("GraphQL::Houtou::Introspection::TYPE_META_FIELD_DEF", GV_ADD, SVt_PV);
      return newSVsv(GvSV(gv));
    }
  }

  if (!SvROK(parent_type) || SvTYPE(SvRV(parent_type)) != SVt_PVHV) {
    dSP;
    int count;
    SV *ret;

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVsv(parent_type)));
    PUTBACK;
    count = call_method("fields", G_SCALAR);
    SPAGAIN;
    if (count != 1) {
      PUTBACK;
      FREETMPS;
      LEAVE;
      croak("parent_type->fields did not return a scalar");
    }
    ret = newSVsv(POPs);
    PUTBACK;
    FREETMPS;
    LEAVE;
    if (!SvROK(ret) || SvTYPE(SvRV(ret)) != SVt_PVHV) {
      SvREFCNT_dec(ret);
      return &PL_sv_undef;
    }
    fields_hv = (HV *)SvRV(ret);
    field_he = hv_fetch_ent(fields_hv, field_name, 0, 0);
    if (!field_he) {
      SvREFCNT_dec(ret);
      return &PL_sv_undef;
    }
    {
      SV *field_ret = newSVsv(HeVAL(field_he));
      SvREFCNT_dec(ret);
      return field_ret;
    }
  }

  parent_type_hv = (HV *)SvRV(parent_type);
  fields_svp = hv_fetch(parent_type_hv, "fields", 6, 0);
  if (!fields_svp || !SvROK(*fields_svp) || SvTYPE(SvRV(*fields_svp)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  fields_hv = (HV *)SvRV(*fields_svp);
  field_he = hv_fetch_ent(fields_hv, field_name, 0, 0);
  if (!field_he) {
    return &PL_sv_undef;
  }

  return newSVsv(HeVAL(field_he));
}

static SV *
gql_execution_execute_fields(pTHX_ SV *context, SV *parent_type, SV *root_value, SV *path, SV *fields) {
  HV *context_hv;
  SV **schema_svp;
  AV *field_names_av;
  HV *nodes_defs_hv;
  AV *keys_av = newAV();
  AV *values_av = newAV();
  AV *errors_av = newAV();
  AV *fields_av;
  I32 field_len;
  I32 i;

  if (!SvROK(fields) || SvTYPE(SvRV(fields)) != SVt_PVAV) {
    SvREFCNT_dec((SV *)keys_av);
    SvREFCNT_dec((SV *)values_av);
    SvREFCNT_dec((SV *)errors_av);
    croak("fields must be an array reference");
  }

  if (!SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
    SvREFCNT_dec((SV *)keys_av);
    SvREFCNT_dec((SV *)values_av);
    SvREFCNT_dec((SV *)errors_av);
    croak("context must be a hash reference");
  }

  context_hv = (HV *)SvRV(context);
  schema_svp = hv_fetch(context_hv, "schema", 6, 0);
  if (!schema_svp || !SvOK(*schema_svp)) {
    SvREFCNT_dec((SV *)keys_av);
    SvREFCNT_dec((SV *)values_av);
    SvREFCNT_dec((SV *)errors_av);
    croak("execution context has no schema");
  }

  fields_av = (AV *)SvRV(fields);
  if (av_len(fields_av) != 1) {
    SvREFCNT_dec((SV *)keys_av);
    SvREFCNT_dec((SV *)values_av);
    SvREFCNT_dec((SV *)errors_av);
    croak("fields must contain names and node definitions");
  }

  {
    SV **field_names_svp = av_fetch(fields_av, 0, 0);
    SV **nodes_defs_svp = av_fetch(fields_av, 1, 0);

    if (!field_names_svp || !SvROK(*field_names_svp) || SvTYPE(SvRV(*field_names_svp)) != SVt_PVAV ||
        !nodes_defs_svp || !SvROK(*nodes_defs_svp) || SvTYPE(SvRV(*nodes_defs_svp)) != SVt_PVHV) {
      SvREFCNT_dec((SV *)keys_av);
      SvREFCNT_dec((SV *)values_av);
      SvREFCNT_dec((SV *)errors_av);
      croak("fields structure is invalid");
    }

    field_names_av = (AV *)SvRV(*field_names_svp);
    nodes_defs_hv = (HV *)SvRV(*nodes_defs_svp);
  }

  field_len = av_len(field_names_av);
  for (i = 0; i <= field_len; i++) {
    SV **result_name_svp = av_fetch(field_names_av, i, 0);
    HE *nodes_he;
    SV *nodes_sv;
    AV *nodes_av;
    SV **field_node_svp;
    HV *field_node_hv;
    SV **field_name_svp;
    SV *field_def_sv;
    HV *field_def_hv;
    SV **resolve_svp;
    SV *resolve_sv;
    AV *path_copy_av;
    SV *path_copy_sv;
    SV *info_sv;
    SV *result_sv;
    SV *completed_sv;
    SV *args_sv;
    SV **context_value_svp;
    SV **variable_values_svp;
    SV **type_svp;

    if (!result_name_svp || !SvOK(*result_name_svp)) {
      continue;
    }

    nodes_he = hv_fetch_ent(nodes_defs_hv, *result_name_svp, 0, 0);
    if (!nodes_he) {
      continue;
    }

    nodes_sv = HeVAL(nodes_he);
    if (!SvROK(nodes_sv) || SvTYPE(SvRV(nodes_sv)) != SVt_PVAV) {
      continue;
    }

    nodes_av = (AV *)SvRV(nodes_sv);
    field_node_svp = av_fetch(nodes_av, 0, 0);
    if (!field_node_svp || !SvROK(*field_node_svp) || SvTYPE(SvRV(*field_node_svp)) != SVt_PVHV) {
      continue;
    }

    field_node_hv = (HV *)SvRV(*field_node_svp);
    field_name_svp = hv_fetch(field_node_hv, "name", 4, 0);
    if (!field_name_svp || !SvOK(*field_name_svp)) {
      continue;
    }

    field_def_sv = gql_execution_get_field_def(aTHX_ *schema_svp, parent_type, *field_name_svp);
    if (!SvOK(field_def_sv) || field_def_sv == &PL_sv_undef) {
      if (field_def_sv != &PL_sv_undef) {
        SvREFCNT_dec(field_def_sv);
      }
      continue;
    }

    if (!SvROK(field_def_sv) || SvTYPE(SvRV(field_def_sv)) != SVt_PVHV) {
      SvREFCNT_dec(field_def_sv);
      continue;
    }

    field_def_hv = (HV *)SvRV(field_def_sv);
    resolve_svp = hv_fetch(field_def_hv, "resolve", 7, 0);
    if (resolve_svp && SvOK(*resolve_svp)) {
      resolve_sv = newSVsv(*resolve_svp);
    } else {
      SV **field_resolver_svp = hv_fetch(context_hv, "field_resolver", 14, 0);
      resolve_sv = (field_resolver_svp && SvOK(*field_resolver_svp))
        ? newSVsv(*field_resolver_svp)
        : newSV(0);
    }

    path_copy_av = newAV();
    if (SvROK(path) && SvTYPE(SvRV(path)) == SVt_PVAV) {
      AV *path_av = (AV *)SvRV(path);
      I32 path_len = av_len(path_av);
      I32 path_i;
      for (path_i = 0; path_i <= path_len; path_i++) {
        SV **path_part_svp = av_fetch(path_av, path_i, 0);
        if (path_part_svp) {
          av_push(path_copy_av, newSVsv(*path_part_svp));
        }
      }
    }
    av_push(path_copy_av, newSVsv(*result_name_svp));
    path_copy_sv = newRV_noinc((SV *)path_copy_av);

    info_sv = gql_execution_build_resolve_info(aTHX_ context, parent_type, field_def_sv, path_copy_sv, nodes_sv);
    context_value_svp = hv_fetch(context_hv, "context_value", 13, 0);
    variable_values_svp = hv_fetch(context_hv, "variable_values", 15, 0);
    args_sv = gql_execution_get_argument_values_xs_impl(
      aTHX_ field_def_sv,
      *field_node_svp,
      (variable_values_svp && SvOK(*variable_values_svp)) ? *variable_values_svp : &PL_sv_undef
    );
    result_sv = gql_execution_call_resolver(
      aTHX_ resolve_sv,
      root_value,
      args_sv,
      (context_value_svp && SvOK(*context_value_svp)) ? *context_value_svp : &PL_sv_undef,
      info_sv
    );
    type_svp = hv_fetch(field_def_hv, "type", 4, 0);
    if (!type_svp || !SvOK(*type_svp)) {
      SvREFCNT_dec(info_sv);
      SvREFCNT_dec(result_sv);
      SvREFCNT_dec(resolve_sv);
      SvREFCNT_dec(path_copy_sv);
      SvREFCNT_dec(field_def_sv);
      continue;
    }

    completed_sv = gql_execution_complete_value_catching_error_xs_impl(
      aTHX_ context,
      *type_svp,
      nodes_sv,
      info_sv,
      path_copy_sv,
      result_sv
    );

    av_push(keys_av, newSVsv(*result_name_svp));
    av_push(values_av, completed_sv);

    SvREFCNT_dec(info_sv);
    SvREFCNT_dec(args_sv);
    SvREFCNT_dec(result_sv);
    SvREFCNT_dec(resolve_sv);
    SvREFCNT_dec(path_copy_sv);
    SvREFCNT_dec(field_def_sv);
  }

  {
    SV *ret = gql_execution_merge_hash(aTHX_ keys_av, values_av, errors_av);
    SvREFCNT_dec((SV *)keys_av);
    SvREFCNT_dec((SV *)values_av);
    SvREFCNT_dec((SV *)errors_av);
    return ret;
  }
}
