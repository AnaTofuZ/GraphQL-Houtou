/*
 * Responsibility: provide the initial XS execution entrypoint so the public
 * execution facade can prefer XS while the actual execution engine migrates
 * from PP to C incrementally.
 */

typedef struct gql_execution_lazy_resolve_info {
  SV *context_sv;
  SV *parent_type_sv;
  SV *field_def_sv;
  SV *nodes_sv;
  SV *base_path_sv;
  SV *result_name_sv;
  SV *path_sv;
  SV *info_sv;
} gql_execution_lazy_resolve_info_t;

static SV *gql_execution_execute_fields(pTHX_ SV *context, SV *parent_type, SV *root_value, SV *path, SV *fields);
static SV *gql_execution_execute_field_plan(pTHX_ SV *context, SV *parent_type, SV *root_value, SV *path, SV *field_plan);
static SV *gql_execution_collect_fields_xs(pTHX_ SV *context, SV *object_type, SV *selections);
static SV *gql_execution_try_type_graphql_to_perl(pTHX_ SV *type, SV *value, int *ok);
static SV *gql_execution_call_graphql_error_but(pTHX_ SV *error, SV *locations, SV *path);
static SV *gql_execution_call_type_to_string(pTHX_ SV *type);
static SV *gql_execution_call_type_perl_to_graphql(pTHX_ SV *type, SV *value, int *ok);
static SV *gql_execution_call_type_of(pTHX_ SV *type);
static SV *gql_execution_get_field_def(pTHX_ SV *schema, SV *parent_type, SV *field_name);
static HV *gql_execution_schema_runtime_cache_hv(pTHX_ SV *schema);
static HV *gql_execution_context_or_schema_runtime_cache_hv(pTHX_ SV *context);
static SV *gql_execution_call_schema_root_type(pTHX_ SV *schema, const char *op_type);
static SV *gql_execution_schema_possible_types_sv(pTHX_ SV *schema, SV *abstract_type);
static SV *gql_execution_type_name_sv(pTHX_ SV *type);
static SV *gql_execution_runtime_cache_type_callback_sv(pTHX_ HV *runtime_cache_hv, SV *type, const char *map_key, I32 map_key_len);
static SV *gql_execution_collect_concrete_compiled_object_fields(pTHX_ SV *object_type, SV *nodes, int *ok);
static SV *gql_execution_collect_single_node_concrete_field_plan(pTHX_ SV *object_type, SV *nodes, int *ok);
static gql_ir_compiled_root_field_plan_t *gql_execution_collect_single_node_concrete_native_field_plan(pTHX_ SV *object_type, SV *nodes);
static SV *gql_execution_build_field_plan_from_compiled_fields(pTHX_ SV *schema, SV *parent_type, SV *compiled_fields_sv);
static SV *gql_execution_get_object_is_type_of_sv(pTHX_ SV *context, SV *type);
static SV *gql_execution_call_abstract_resolve_type(pTHX_ SV *type);
static SV *gql_execution_get_abstract_resolve_type_sv(pTHX_ SV *context, SV *type);
static gql_execution_context_fast_cache_t *gql_execution_context_fast_cache(pTHX_ SV *context);
static SV *gql_execution_lazy_path_materialize(pTHX_ struct gql_execution_lazy_resolve_info *lazy_info);
static SV *gql_execution_lazy_resolve_info_materialize(pTHX_ struct gql_execution_lazy_resolve_info *lazy_info);
static SV *gql_ir_execute_native_field_plan(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan
);
static SV *gql_execution_complete_field_value_catching_error_xs_impl(
  pTHX_ SV *context,
  SV *parent_type,
  SV *field_def,
  SV *nodes,
  struct gql_execution_lazy_resolve_info *lazy_info,
  SV *result
);
static int gql_execution_try_typename_meta_field_fast(pTHX_ SV *parent_type, SV *field_name_sv, SV *return_type, SV **completed_out);
static int gql_execution_is_default_field_resolver(pTHX_ SV *resolve);
static int gql_execution_try_default_field_resolve_fast(pTHX_ SV *root_value, SV *field_name_sv, SV **result_out);
static int gql_execution_try_complete_trivial_value_fast(pTHX_ SV *return_type, SV *result, SV **completed_out);
static void gql_ir_attach_compiled_field_defs_to_selections(pTHX_ SV *schema, SV *parent_type, AV *selections_av, SV *fragments_sv);
static void gql_ir_attach_compiled_field_defs_to_fragments(pTHX_ SV *schema, SV *fragments_sv);
static int gql_execution_possible_type_match_simple(
  pTHX_ SV *context,
  SV *schema,
  SV *abstract_type,
  SV *abstract_name_sv,
  SV *possible_type,
  SV *possible_name_sv,
  int *ok
);

typedef struct {
  UV variables_apply_defaults_calls;
  UV execute_prepared_context_calls;
  UV resolve_field_value_or_error_calls;
  UV complete_value_catching_error_calls;
  UV get_argument_values_calls;
  UV type_will_accept_calls;
} gql_execution_pp_bridge_profile_t;

static int gql_execution_pp_bridge_profile_enabled = -1;
static gql_execution_pp_bridge_profile_t gql_execution_pp_bridge_profile_counts;

static int
gql_execution_pp_bridge_profile_is_enabled(void) {
  if (gql_execution_pp_bridge_profile_enabled < 0) {
    const char *value = getenv("HOUTOU_PROFILE_PP_BRIDGE");
    gql_execution_pp_bridge_profile_enabled = (value && *value && strNE(value, "0")) ? 1 : 0;
  }
  return gql_execution_pp_bridge_profile_enabled;
}

static void
gql_execution_pp_bridge_profile_reset(void) {
  Zero(&gql_execution_pp_bridge_profile_counts, 1, gql_execution_pp_bridge_profile_t);
}

static void
gql_execution_pp_bridge_profile_report(pTHX_ const char *label) {
  if (!gql_execution_pp_bridge_profile_is_enabled()) {
    return;
  }

  PerlIO_printf(
    PerlIO_stderr(),
    "[houtou][pp-bridge] %s variables_apply_defaults=%" UVuf
    " execute_prepared_context=%" UVuf
    " resolve_field_value_or_error=%" UVuf
    " complete_value_catching_error=%" UVuf
    " get_argument_values=%" UVuf
    " type_will_accept=%" UVuf
    "\n",
    label,
    gql_execution_pp_bridge_profile_counts.variables_apply_defaults_calls,
    gql_execution_pp_bridge_profile_counts.execute_prepared_context_calls,
    gql_execution_pp_bridge_profile_counts.resolve_field_value_or_error_calls,
    gql_execution_pp_bridge_profile_counts.complete_value_catching_error_calls,
    gql_execution_pp_bridge_profile_counts.get_argument_values_calls,
    gql_execution_pp_bridge_profile_counts.type_will_accept_calls
  );
}

static int
gql_execution_context_fast_cache_magic_free(pTHX_ SV *sv, MAGIC *mg) {
  gql_execution_context_fast_cache_t *cache = (mg && mg->mg_ptr)
    ? INT2PTR(gql_execution_context_fast_cache_t *, mg->mg_ptr)
    : NULL;

  if (cache) {
    Safefree(cache);
    mg->mg_ptr = NULL;
  }
  return 0;
}

static MGVTBL gql_execution_context_fast_cache_vtbl = {
  NULL,
  NULL,
  NULL,
  NULL,
  gql_execution_context_fast_cache_magic_free
#if PERL_VERSION_GE(5, 15, 0)
  ,NULL
  ,NULL
  ,NULL
#endif
};

static gql_execution_context_fast_cache_t *
gql_execution_context_fast_cache(pTHX_ SV *context) {
  MAGIC *mg;
  HV *context_hv;
  gql_execution_context_fast_cache_t *cache;
  SV **svp;

  if (!context || !SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
    return NULL;
  }

  mg = mg_findext(SvRV(context), PERL_MAGIC_ext, &gql_execution_context_fast_cache_vtbl);
  if (mg && mg->mg_ptr) {
    return INT2PTR(gql_execution_context_fast_cache_t *, mg->mg_ptr);
  }

  context_hv = (HV *)SvRV(context);
  Newxz(cache, 1, gql_execution_context_fast_cache_t);
  svp = hv_fetch(context_hv, "schema", 6, 0);
  cache->schema_sv = (svp && SvOK(*svp)) ? *svp : NULL;
  svp = hv_fetch(context_hv, "fragments", 9, 0);
  cache->fragments_sv = (svp && SvOK(*svp)) ? *svp : NULL;
  svp = hv_fetch(context_hv, "root_value", 10, 0);
  cache->root_value_sv = (svp && SvOK(*svp)) ? *svp : NULL;
  svp = hv_fetch(context_hv, "context_value", 13, 0);
  cache->context_value_sv = (svp && SvOK(*svp)) ? *svp : NULL;
  svp = hv_fetch(context_hv, "operation", 9, 0);
  cache->operation_sv = (svp && SvOK(*svp)) ? *svp : NULL;
  svp = hv_fetch(context_hv, "variable_values", 15, 0);
  cache->variable_values_sv = (svp && SvOK(*svp)) ? *svp : NULL;
  svp = hv_fetch(context_hv, "field_resolver", 14, 0);
  cache->field_resolver_sv = (svp && SvOK(*svp)) ? *svp : NULL;
  svp = hv_fetch(context_hv, "promise_code", 12, 0);
  cache->promise_code_sv = (svp && SvOK(*svp)) ? *svp : NULL;
  svp = hv_fetch(context_hv, "empty_args", 10, 0);
  cache->empty_args_sv = (svp && SvOK(*svp)) ? *svp : NULL;
  svp = hv_fetch(context_hv, "compiled_root_field_defs", 24, 0);
  cache->compiled_root_field_defs_sv = (svp && SvOK(*svp)) ? *svp : NULL;
  svp = hv_fetch(context_hv, "resolve_info_base", 17, 0);
  cache->resolve_info_base_hv = (svp && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVHV)
    ? (HV *)SvRV(*svp)
    : NULL;

  sv_magicext(SvRV(context), NULL, PERL_MAGIC_ext, &gql_execution_context_fast_cache_vtbl, NULL, 0);
  mg = mg_findext(SvRV(context), PERL_MAGIC_ext, &gql_execution_context_fast_cache_vtbl);
  if (!mg) {
    Safefree(cache);
    croak("failed to attach execution context fast cache");
  }
  mg->mg_ptr = (char *)PTR2IV(cache);
  return cache;
}

static void
gql_execution_attach_ast_execution_metadata(pTHX_ SV *schema, SV *operation_sv, HV *fragments_hv, const char *op_type) {
  HV *operation_hv;
  SV **ready_svp;
  SV *root_type_sv;
  SV **selections_svp;
  SV *fragments_sv;

  if (!schema
      || !SvOK(schema)
      || !operation_sv
      || !SvROK(operation_sv)
      || SvTYPE(SvRV(operation_sv)) != SVt_PVHV
      || !fragments_hv
      || !op_type
      || !*op_type) {
    return;
  }

  operation_hv = (HV *)SvRV(operation_sv);
  ready_svp = hv_fetch(operation_hv, "_houtou_exec_meta_ready", 23, 0);
  if (ready_svp && SvTRUE(*ready_svp)) {
    return;
  }

  root_type_sv = gql_execution_call_schema_root_type(aTHX_ schema, op_type);
  if (!root_type_sv || !SvOK(root_type_sv)) {
    if (root_type_sv) {
      SvREFCNT_dec(root_type_sv);
    }
    return;
  }

  fragments_sv = newRV_inc((SV *)fragments_hv);
  gql_ir_attach_compiled_field_defs_to_fragments(aTHX_ schema, fragments_sv);

  selections_svp = hv_fetch(operation_hv, "selections", 10, 0);
  if (selections_svp
      && SvROK(*selections_svp)
      && SvTYPE(SvRV(*selections_svp)) == SVt_PVAV) {
    gql_ir_attach_compiled_field_defs_to_selections(
      aTHX_
      schema,
      root_type_sv,
      (AV *)SvRV(*selections_svp),
      fragments_sv
    );
  }

  (void)hv_store(operation_hv, "_houtou_exec_meta_ready", 23, newSViv(1), 0);
  SvREFCNT_dec(fragments_sv);
  SvREFCNT_dec(root_type_sv);
}

static SV *
gql_execution_context_promise_code(SV *context) {
  HV *context_hv;
  SV **promise_code_svp;

  if (!context || !SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  context_hv = (HV *)SvRV(context);
  promise_code_svp = hv_fetch(context_hv, "promise_code", 12, 0);
  if (!promise_code_svp || !SvOK(*promise_code_svp)) {
    return &PL_sv_undef;
  }

  return *promise_code_svp;
}


static HV *
gql_promise_code_hv(SV *promise_code) {
  if (!promise_code || !SvOK(promise_code) || !SvROK(promise_code) || SvTYPE(SvRV(promise_code)) != SVt_PVHV) {
    return NULL;
  }
  return (HV *)SvRV(promise_code);
}

static SV *
gql_promise_get_hook(pTHX_ SV *promise_code, const char *name, I32 name_len) {
  HV *promise_hv = gql_promise_code_hv(promise_code);
  SV **hook_svp;

  if (!promise_hv) {
    return &PL_sv_undef;
  }

  hook_svp = hv_fetch(promise_hv, name, name_len, 0);
  if (!hook_svp || !SvOK(*hook_svp)) {
    return &PL_sv_undef;
  }

  return *hook_svp;
}

static SV *
gql_promise_call_is_promise(pTHX_ SV *promise_code, SV *value) {
  dSP;
  SV *hook = gql_promise_get_hook(aTHX_ promise_code, "is_promise", 10);
  int count;
  SV *ret;

  if (!SvOK(hook)) {
    return &PL_sv_no;
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(value)));
  PUTBACK;
  count = call_sv(hook, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("promise is_promise hook did not return a scalar");
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_promise_call_all(pTHX_ SV *promise_code, AV *values_av) {
  dSP;
  SV *hook = gql_promise_get_hook(aTHX_ promise_code, "all", 3);
  I32 i;
  I32 len = av_len(values_av);
  int count;
  SV *ret;

  if (!SvOK(hook)) {
    croak("promise all hook is not configured");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  EXTEND(SP, len + 1);
  for (i = 0; i <= len; i++) {
    SV **svp = av_fetch(values_av, i, 0);
    XPUSHs(sv_2mortal(svp ? newSVsv(*svp) : newSV(0)));
  }
  PUTBACK;
  count = call_sv(hook, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("promise all hook did not return a scalar");
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_promise_call_then(pTHX_ SV *promise_code, SV *promise, SV *on_fulfilled, SV *on_rejected) {
  dSP;
  SV *hook = gql_promise_get_hook(aTHX_ promise_code, "then", 4);
  int count;
  SV *ret;

  if (!SvOK(hook)) {
    croak("promise then hook is not configured");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(promise)));
  XPUSHs(sv_2mortal(newSVsv(on_fulfilled)));
  XPUSHs(sv_2mortal(on_rejected ? newSVsv(on_rejected) : newSV(0)));
  PUTBACK;
  count = call_sv(hook, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("promise then hook did not return a scalar");
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_promise_call_resolve(pTHX_ SV *promise_code, SV *value) {
  dSP;
  SV *hook = gql_promise_get_hook(aTHX_ promise_code, "resolve", 7);
  int count;
  SV *ret;

  if (!SvOK(hook)) {
    croak("promise resolve hook is not configured");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(value)));
  PUTBACK;
  count = call_sv(hook, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("promise resolve hook did not return a scalar");
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_promise_call_reject(pTHX_ SV *promise_code, SV *value) {
  dSP;
  SV *hook = gql_promise_get_hook(aTHX_ promise_code, "reject", 6);
  int count;
  SV *ret;

  if (!SvOK(hook)) {
    croak("promise reject hook is not configured");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(value)));
  PUTBACK;
  count = call_sv(hook, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("promise reject hook did not return a scalar");
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_execution_merge_completed_list(pTHX_ AV *list_av) {
  HV *ret_hv = newHV();
  AV *data_av = newAV();
  AV *errors_av = newAV();
  I32 len = av_len(list_av);
  I32 i;

  for (i = 0; i <= len; i++) {
    SV **item_svp = av_fetch(list_av, i, 0);
    HV *item_hv;
    SV **data_svp;
    SV **item_errors_svp;

    if (!item_svp || !SvROK(*item_svp) || SvTYPE(SvRV(*item_svp)) != SVt_PVHV) {
      av_push(data_av, newSV(0));
      continue;
    }

    item_hv = (HV *)SvRV(*item_svp);
    data_svp = hv_fetch(item_hv, "data", 4, 0);
    av_push(data_av, data_svp ? newSVsv(*data_svp) : newSV(0));

    item_errors_svp = hv_fetch(item_hv, "errors", 6, 0);
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
  }

  gql_store_sv(ret_hv, "data", newRV_noinc((SV *)data_av));
  if (av_len(errors_av) >= 0) {
    gql_store_sv(ret_hv, "errors", newRV_noinc((SV *)errors_av));
  } else {
    SvREFCNT_dec((SV *)errors_av);
  }

  return newRV_noinc((SV *)ret_hv);
}

static SV *
gql_execution_build_response_xs(pTHX_ SV *result, int force_data) {
  HV *out_hv = newHV();
  HV *result_hv = NULL;
  SV **errors_svp;

  if (!SvROK(result) || SvTYPE(SvRV(result)) != SVt_PVHV) {
    SvREFCNT_dec((SV *)out_hv);
    croak("result must be a hash reference");
  }

  result_hv = (HV *)SvRV(result);

  if (force_data && !hv_exists(result_hv, "data", 4)) {
    gql_store_sv(out_hv, "data", newSV(0));
  }

  if (hv_exists(result_hv, "data", 4)) {
    SV **data_svp = hv_fetch(result_hv, "data", 4, 0);
    if (data_svp) {
      gql_store_sv(out_hv, "data", newSVsv(*data_svp));
    }
  }

  errors_svp = hv_fetch(result_hv, "errors", 6, 0);
  if (errors_svp && SvROK(*errors_svp) && SvTYPE(SvRV(*errors_svp)) == SVt_PVAV) {
    AV *errors_av = (AV *)SvRV(*errors_svp);
    AV *json_errors_av = newAV();
    I32 len = av_len(errors_av);
    I32 i;

    for (i = 0; i <= len; i++) {
      SV **error_svp = av_fetch(errors_av, i, 0);
      dSP;
      int count;
      SV *json_sv;

      if (!error_svp) {
        continue;
      }

      ENTER;
      SAVETMPS;
      PUSHMARK(SP);
      XPUSHs(sv_2mortal(newSVsv(*error_svp)));
      PUTBACK;
      count = call_method("to_json", G_SCALAR);
      SPAGAIN;
      if (count != 1) {
        PUTBACK;
        FREETMPS;
        LEAVE;
        SvREFCNT_dec((SV *)json_errors_av);
        SvREFCNT_dec((SV *)out_hv);
        croak("GraphQL::Error->to_json did not return a scalar");
      }
      json_sv = newSVsv(POPs);
      PUTBACK;
      FREETMPS;
      LEAVE;
      av_push(json_errors_av, json_sv);
    }

    if (av_len(json_errors_av) >= 0) {
      gql_store_sv(out_hv, "errors", newRV_noinc((SV *)json_errors_av));
    } else {
      SvREFCNT_dec((SV *)json_errors_av);
    }
  }

  return newRV_noinc((SV *)out_hv);
}

static SV *
gql_execution_wrap_error_xs(pTHX_ SV *error) {
  dSP;
  HV *ret_hv;
  AV *errors_av;
  int count;
  SV *coerced;

  if (SvROK(error) && SvTYPE(SvRV(error)) == SVt_PVHV) {
    HV *error_hv = (HV *)SvRV(error);
    SV **errors_svp = hv_fetch(error_hv, "errors", 6, 0);
    if (errors_svp && SvROK(*errors_svp) && SvTYPE(SvRV(*errors_svp)) == SVt_PVAV) {
      return newSVsv(error);
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVpv("GraphQL::Error", 0)));
  XPUSHs(sv_2mortal(newSVsv(error)));
  PUTBACK;
  count = call_method("coerce", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Error::coerce did not return a scalar");
  }
  coerced = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  ret_hv = newHV();
  errors_av = newAV();
  av_push(errors_av, coerced);
  gql_store_sv(ret_hv, "errors", newRV_noinc((SV *)errors_av));
  return newRV_noinc((SV *)ret_hv);
}

static SV *
gql_execution_located_error_xs(pTHX_ SV *error, SV *nodes, SV *path) {
  dSP;
  int count;
  SV *coerced;
  AV *locations_av;
  AV *nodes_av;
  I32 len;
  I32 i;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVpv("GraphQL::Error", 0)));
  XPUSHs(sv_2mortal(newSVsv(error)));
  PUTBACK;
  count = call_method("coerce", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Error::coerce did not return a scalar");
  }
  coerced = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  if (SvROK(coerced)) {
    dSP;
    int has_locations;

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVsv(coerced)));
    PUTBACK;
    has_locations = call_method("locations", G_SCALAR);
    SPAGAIN;
    if (has_locations == 1) {
      SV *locations_sv = newSVsv(POPs);
      PUTBACK;
      FREETMPS;
      LEAVE;
      if (SvOK(locations_sv)) {
        SvREFCNT_dec(locations_sv);
        return coerced;
      }
      SvREFCNT_dec(locations_sv);
    } else {
      PUTBACK;
      FREETMPS;
      LEAVE;
    }
  }

  if (!SvROK(nodes) || SvTYPE(SvRV(nodes)) != SVt_PVAV) {
    return coerced;
  }

  locations_av = newAV();
  nodes_av = (AV *)SvRV(nodes);
  len = av_len(nodes_av);
  for (i = 0; i <= len; i++) {
    SV **node_svp = av_fetch(nodes_av, i, 0);
    if (node_svp && SvROK(*node_svp) && SvTYPE(SvRV(*node_svp)) == SVt_PVHV) {
      SV **location_svp = hv_fetch((HV *)SvRV(*node_svp), "location", 8, 0);
      if (location_svp && SvOK(*location_svp)) {
        av_push(locations_av, newSVsv(*location_svp));
      }
    }
  }

  {
    SV *locations_rv = newRV_noinc((SV *)locations_av);
    SV *located = gql_execution_call_graphql_error_but(
      aTHX_ coerced,
      locations_rv,
      path
    );
    SvREFCNT_dec(locations_rv);
    SvREFCNT_dec(coerced);
    return located;
  }
}


static void
gql_execution_require_pp(pTHX) {
  /*
   * Cached per-process. This optimization assumes a single interpreter
   * lifetime; it is not intended to survive ithreads interpreter cloning.
   */
  static int pp_loaded = 0;

  if (!pp_loaded) {
    eval_pv("require GraphQL::Houtou::Execution::PP; 1;", TRUE);
    pp_loaded = 1;
  }
}

static CV *
gql_execution_pp_cv(pTHX_ const char *name) {
  /*
   * Cached per-process. This assumes the PP symbol table remains stable
   * for the interpreter lifetime and is not intended to survive ithreads
   * interpreter cloning or explicit undef of the target subroutine.
   */
  CV *cv = get_cv(name, 0);
  if (!cv) {
    gql_execution_require_pp(aTHX);
    cv = get_cv(name, 0);
  }
  if (!cv) {
    croak("Unable to resolve %s", name);
  }
  return cv;
}

static SV *
gql_execution_call_graphql_error_coerce(pTHX_ SV *error) {
  dSP;
  int count;
  SV *ret;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVpv("GraphQL::Error", 0)));
  XPUSHs(sv_2mortal(newSVsv(error)));
  PUTBACK;

  count = call_method("coerce", G_SCALAR);
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
gql_execution_mortal_sv_ref(SV *value) {
  /*
   * NOTE: this passes the original SV with a temporary refcount bump rather
   * than copying via newSVsv(). PP bridge functions must not assign to @_.
   */
  return value ? sv_2mortal(SvREFCNT_inc_simple_NN(value)) : &PL_sv_undef;
}

static SV *
gql_execution_share_or_copy_sv(SV *value) {
  if (!value || !SvOK(value)) {
    return newSV(0);
  }
  if (SvROK(value)) {
    return SvREFCNT_inc_simple_NN(value);
  }
  return newSVsv(value);
}

static SV *
gql_execution_call_graphql_error_but(pTHX_ SV *error, SV *locations, SV *path) {
  dSP;
  int count;
  SV *ret;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(gql_execution_mortal_sv_ref(error));
  XPUSHs(sv_2mortal(newSVpvs("locations")));
  XPUSHs(gql_execution_mortal_sv_ref(locations));
  XPUSHs(sv_2mortal(newSVpvs("path")));
  XPUSHs(gql_execution_mortal_sv_ref(path));
  PUTBACK;

  count = call_method("but", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Error->but did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_collect_node_locations(pTHX_ SV *nodes) {
  AV *locations_av = newAV();

  if (SvROK(nodes) && SvTYPE(SvRV(nodes)) == SVt_PVAV) {
    AV *nodes_av = (AV *)SvRV(nodes);
    I32 node_len = av_len(nodes_av);
    I32 i;
    for (i = 0; i <= node_len; i++) {
      SV **node_svp = av_fetch(nodes_av, i, 0);
      if (node_svp && SvROK(*node_svp) && SvTYPE(SvRV(*node_svp)) == SVt_PVHV) {
        SV **location_svp = hv_fetch((HV *)SvRV(*node_svp), "location", 8, 0);
        av_push(locations_av, location_svp ? newSVsv(*location_svp) : newSV(0));
      }
    }
  }

  return newRV_noinc((SV *)locations_av);
}

static SV *
gql_execution_make_error_result(pTHX_ SV *message, SV *nodes, SV *path) {
  HV *ret_hv = newHV();
  AV *errors_av = newAV();
  SV *error = gql_execution_call_graphql_error_coerce(aTHX_ message);
  SV *locations = gql_execution_collect_node_locations(aTHX_ nodes);
  SV *located = gql_execution_call_graphql_error_but(aTHX_ error, locations, path);

  av_push(errors_av, located);
  (void)hv_store(ret_hv, "data", 4, newSV(0), 0);
  (void)hv_store(ret_hv, "errors", 6, newRV_noinc((SV *)errors_av), 0);
  SvREFCNT_dec(error);
  SvREFCNT_dec(locations);
  return newRV_noinc((SV *)ret_hv);
}

typedef enum {
  GQL_EXECUTION_BUILTIN_SCALAR_NONE = 0,
  GQL_EXECUTION_BUILTIN_SCALAR_INT,
  GQL_EXECUTION_BUILTIN_SCALAR_FLOAT,
  GQL_EXECUTION_BUILTIN_SCALAR_STRING,
  GQL_EXECUTION_BUILTIN_SCALAR_BOOLEAN,
  GQL_EXECUTION_BUILTIN_SCALAR_ID
} gql_execution_builtin_scalar_kind_t;

static gql_execution_builtin_scalar_kind_t
gql_execution_builtin_scalar_kind_from_type(SV *type) {
  SV **kind_svp;
  const char *kind_pv;
  STRLEN kind_len;
  HV *type_hv;

  if (!type || !SvROK(type) || SvTYPE(SvRV(type)) != SVt_PVHV) {
    return GQL_EXECUTION_BUILTIN_SCALAR_NONE;
  }

  if (!sv_derived_from(type, "GraphQL::Houtou::Type::Scalar")) {
    return GQL_EXECUTION_BUILTIN_SCALAR_NONE;
  }

  type_hv = (HV *)SvRV(type);
  kind_svp = hv_fetch(type_hv, "_builtin_kind", 13, 0);
  if (!kind_svp || !SvOK(*kind_svp)) {
    return GQL_EXECUTION_BUILTIN_SCALAR_NONE;
  }

  kind_pv = SvPV(*kind_svp, kind_len);
  if (kind_len == 3 && memEQ(kind_pv, "Int", 3)) {
    return GQL_EXECUTION_BUILTIN_SCALAR_INT;
  }
  if (kind_len == 5 && memEQ(kind_pv, "Float", 5)) {
    return GQL_EXECUTION_BUILTIN_SCALAR_FLOAT;
  }
  if (kind_len == 6 && memEQ(kind_pv, "String", 6)) {
    return GQL_EXECUTION_BUILTIN_SCALAR_STRING;
  }
  if (kind_len == 7 && memEQ(kind_pv, "Boolean", 7)) {
    return GQL_EXECUTION_BUILTIN_SCALAR_BOOLEAN;
  }
  if (kind_len == 2 && memEQ(kind_pv, "ID", 2)) {
    return GQL_EXECUTION_BUILTIN_SCALAR_ID;
  }

  return GQL_EXECUTION_BUILTIN_SCALAR_NONE;
}

static int
gql_execution_builtin_scalar_is_nonref_defined(SV *value) {
  return value && SvOK(value) && !SvROK(value);
}

static int
gql_execution_builtin_scalar_is_int32(SV *value, IV *out) {
  IV iv;

  if (!gql_execution_builtin_scalar_is_nonref_defined(value) || !looks_like_number(value)) {
    return 0;
  }

  iv = SvIV(value);
  if (SvNV(value) != (NV)iv) {
    return 0;
  }
  if (iv < (-2147483647 - 1) || iv > 2147483647) {
    return 0;
  }

  if (out) {
    *out = iv;
  }
  return 1;
}

static int
gql_execution_builtin_scalar_is_num(SV *value, NV *out) {
  NV nv;

  if (!gql_execution_builtin_scalar_is_nonref_defined(value) || !looks_like_number(value)) {
    return 0;
  }

  nv = SvNV(value);
  if (out) {
    *out = nv;
  }
  return 1;
}

static int
gql_execution_builtin_scalar_is_boolish(SV *value, int *truthy) {
  if (!value || !SvOK(value)) {
    return 0;
  }

  if (sv_isa(value, "JSON::PP::Boolean")) {
    if (truthy) {
      *truthy = SvTRUE(value) ? 1 : 0;
    }
    return 1;
  }

  if (!gql_execution_builtin_scalar_is_nonref_defined(value) || !looks_like_number(value)) {
    return 0;
  }

  if (!(SvIV(value) == 0 || SvIV(value) == 1) || SvNV(value) != (NV)SvIV(value)) {
    return 0;
  }

  if (truthy) {
    *truthy = SvTRUE(value) ? 1 : 0;
  }
  return 1;
}

static SV *
gql_execution_builtin_scalar_json_boolean_sv(pTHX_ int truthy) {
  return newRV_noinc(newSViv(truthy ? 1 : 0));
}

static SV *
gql_execution_builtin_scalar_graphql_to_perl(pTHX_ gql_execution_builtin_scalar_kind_t kind, SV *value, int *ok) {
  IV iv;
  NV nv;
  int truthy;

  *ok = 0;

  if (!value || !SvOK(value)) {
    *ok = 1;
    return newSV(0);
  }

  switch (kind) {
    case GQL_EXECUTION_BUILTIN_SCALAR_INT:
      if (!gql_execution_builtin_scalar_is_int32(value, &iv)) {
        return &PL_sv_undef;
      }
      *ok = 1;
      return newSViv(iv);
    case GQL_EXECUTION_BUILTIN_SCALAR_FLOAT:
      if (!gql_execution_builtin_scalar_is_num(value, &nv)) {
        return &PL_sv_undef;
      }
      *ok = 1;
      return newSVnv(nv);
    case GQL_EXECUTION_BUILTIN_SCALAR_STRING:
      if (!gql_execution_builtin_scalar_is_nonref_defined(value)) {
        return &PL_sv_undef;
      }
      *ok = 1;
      return newSVsv(value);
    case GQL_EXECUTION_BUILTIN_SCALAR_ID:
      if (!gql_execution_builtin_scalar_is_nonref_defined(value)) {
        return &PL_sv_undef;
      }
      *ok = 1;
      return newSVsv(value);
    case GQL_EXECUTION_BUILTIN_SCALAR_BOOLEAN:
      if (!gql_execution_builtin_scalar_is_boolish(value, &truthy)) {
        return &PL_sv_undef;
      }
      *ok = 1;
      return newSViv(truthy ? 1 : 0);
    default:
      return &PL_sv_undef;
  }
}

static SV *
gql_execution_builtin_scalar_perl_to_graphql(pTHX_ gql_execution_builtin_scalar_kind_t kind, SV *value, int *ok) {
  IV iv;
  NV nv;
  STRLEN len;
  const char *pv;
  int truthy;

  *ok = 0;

  if (!value || !SvOK(value)) {
    *ok = 1;
    return newSV(0);
  }

  switch (kind) {
    case GQL_EXECUTION_BUILTIN_SCALAR_INT:
      if (!gql_execution_builtin_scalar_is_int32(value, &iv)) {
        return &PL_sv_undef;
      }
      *ok = 1;
      return newSViv(iv);
    case GQL_EXECUTION_BUILTIN_SCALAR_FLOAT:
      if (!gql_execution_builtin_scalar_is_num(value, &nv)) {
        return &PL_sv_undef;
      }
      *ok = 1;
      return newSVnv(nv);
    case GQL_EXECUTION_BUILTIN_SCALAR_STRING:
      if (!gql_execution_builtin_scalar_is_nonref_defined(value)) {
        return &PL_sv_undef;
      }
      *ok = 1;
      pv = SvPV(value, len);
      return newSVpvn(pv, len);
    case GQL_EXECUTION_BUILTIN_SCALAR_ID:
      if (!gql_execution_builtin_scalar_is_nonref_defined(value)) {
        return &PL_sv_undef;
      }
      *ok = 1;
      pv = SvPV(value, len);
      return newSVpvn(pv, len);
    case GQL_EXECUTION_BUILTIN_SCALAR_BOOLEAN:
      if (!gql_execution_builtin_scalar_is_boolish(value, &truthy)) {
        return &PL_sv_undef;
      }
      *ok = 1;
      return gql_execution_builtin_scalar_json_boolean_sv(aTHX_ truthy ? 1 : 0);
    default:
      return &PL_sv_undef;
  }
}

static int
gql_execution_is_houtou_enum_type(SV *type) {
  return type
    && SvROK(type)
    && sv_derived_from(type, "GraphQL::Houtou::Type::Enum");
}

static int
gql_execution_is_houtou_input_object_type(SV *type) {
  return type
    && SvROK(type)
    && sv_derived_from(type, "GraphQL::Houtou::Type::InputObject");
}

static SV *
gql_execution_enum_graphql_to_perl(pTHX_ SV *type, SV *value, int *ok) {
  HV *type_hv;
  SV **values_svp;
  HV *values_hv;
  SV *lookup_value = value;
  HE *entry_he;
  HV *entry_hv;
  SV **mapped_svp;

  *ok = 0;

  if (!value || !SvOK(value)) {
    *ok = 1;
    return newSV(0);
  }

  if (SvROK(value) && SvTYPE(SvRV(value)) < SVt_PVAV) {
    lookup_value = SvRV(value);
  }

  if (!SvROK(type) || SvTYPE(SvRV(type)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  type_hv = (HV *)SvRV(type);
  values_svp = hv_fetch(type_hv, "values", 6, 0);
  if (!values_svp || !SvROK(*values_svp) || SvTYPE(SvRV(*values_svp)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  values_hv = (HV *)SvRV(*values_svp);
  entry_he = hv_fetch_ent(values_hv, lookup_value, 0, 0);
  if (!entry_he || !SvROK(HeVAL(entry_he)) || SvTYPE(SvRV(HeVAL(entry_he))) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  entry_hv = (HV *)SvRV(HeVAL(entry_he));
  mapped_svp = hv_fetch(entry_hv, "value", 5, 0);
  if (!mapped_svp) {
    return &PL_sv_undef;
  }

  *ok = 1;
  return newSVsv(*mapped_svp);
}

static SV *
gql_execution_enum_perl_to_graphql(pTHX_ SV *type, SV *value, int *ok) {
  HV *type_hv;
  SV **value2name_svp;
  HV *value2name_hv;
  HE *entry;
  SV **values_svp;
  HV *values_hv;

  *ok = 0;

  if (!value || !SvOK(value)) {
    *ok = 1;
    return newSV(0);
  }

  if (!SvROK(type) || SvTYPE(SvRV(type)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  type_hv = (HV *)SvRV(type);
  value2name_svp = hv_fetch(type_hv, "_value2name", 11, 0);
  if (value2name_svp && SvROK(*value2name_svp) && SvTYPE(SvRV(*value2name_svp)) == SVt_PVHV) {
    HE *name_he = hv_fetch_ent((HV *)SvRV(*value2name_svp), value, 0, 0);
    if (name_he) {
      *ok = 1;
      return newSVsv(HeVAL(name_he));
    }
  }

  values_svp = hv_fetch(type_hv, "values", 6, 0);
  if (!values_svp || !SvROK(*values_svp) || SvTYPE(SvRV(*values_svp)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  values_hv = (HV *)SvRV(*values_svp);
  (void)hv_iterinit(values_hv);
  while ((entry = hv_iternext(values_hv))) {
    SV *entry_sv = hv_iterval(values_hv, entry);
    SV *name_sv = hv_iterkeysv(entry);
    HV *entry_hv;
    SV **mapped_svp;

    if (!SvROK(entry_sv) || SvTYPE(SvRV(entry_sv)) != SVt_PVHV) {
      continue;
    }

    entry_hv = (HV *)SvRV(entry_sv);
    mapped_svp = hv_fetch(entry_hv, "value", 5, 0);
    if (mapped_svp && sv_eq(*mapped_svp, value)) {
      *ok = 1;
      return newSVsv(name_sv);
    }
  }

  return &PL_sv_undef;
}

static SV *
gql_execution_input_object_graphql_to_perl(pTHX_ SV *type, SV *value, int *ok) {
  HV *type_hv;
  HV *item_hv;
  SV **fields_svp;
  HV *fields_hv;
  HV *result_hv;
  HE *entry;

  *ok = 0;

  if (!value || !SvOK(value)) {
    *ok = 1;
    return newSV(0);
  }

  if (!SvROK(value) || SvTYPE(SvRV(value)) != SVt_PVHV) {
    return &PL_sv_undef;
  }
  if (!SvROK(type) || SvTYPE(SvRV(type)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  type_hv = (HV *)SvRV(type);
  item_hv = (HV *)SvRV(value);
  fields_svp = hv_fetch(type_hv, "fields", 6, 0);
  if (!fields_svp || !SvROK(*fields_svp) || SvTYPE(SvRV(*fields_svp)) != SVt_PVHV) {
    return &PL_sv_undef;
  }
  fields_hv = (HV *)SvRV(*fields_svp);
  result_hv = newHV();

  (void)hv_iterinit(item_hv);
  while ((entry = hv_iternext(item_hv))) {
    SV *name_sv = hv_iterkeysv(entry);
    SV *item_value = hv_iterval(item_hv, entry);
    HE *field_def_he = hv_fetch_ent(fields_hv, name_sv, 0, 0);
    HV *field_def_hv;
    SV **field_type_svp;
    SV **field_default_svp;
    SV *coerce_value = item_value;
    SV *parsed;
    int field_ok = 0;

    if (!field_def_he || !SvROK(HeVAL(field_def_he)) || SvTYPE(SvRV(HeVAL(field_def_he))) != SVt_PVHV) {
      SvREFCNT_dec((SV *)result_hv);
      return &PL_sv_undef;
    }

    field_def_hv = (HV *)SvRV(HeVAL(field_def_he));
    field_type_svp = hv_fetch(field_def_hv, "type", 4, 0);
    if (!field_type_svp || !SvOK(*field_type_svp)) {
      SvREFCNT_dec((SV *)result_hv);
      return &PL_sv_undef;
    }

    field_default_svp = hv_fetch(field_def_hv, "default_value", 13, 0);
    if ((!coerce_value || !SvOK(coerce_value))
        && field_default_svp
        && SvOK(*field_default_svp)) {
      coerce_value = *field_default_svp;
    }

    parsed = gql_execution_try_type_graphql_to_perl(aTHX_ *field_type_svp, coerce_value, &field_ok);
    if (!field_ok) {
      SvREFCNT_dec((SV *)result_hv);
      return &PL_sv_undef;
    }

    (void)hv_store_ent(result_hv, name_sv, parsed, 0);
  }

  *ok = 1;
  return newRV_noinc((SV *)result_hv);
}

static SV *
gql_execution_try_type_graphql_to_perl(pTHX_ SV *type, SV *value, int *ok) {
  dSP;
  int count;
  SV *ret;
  gql_execution_builtin_scalar_kind_t builtin_kind;

  *ok = 0;

  builtin_kind = gql_execution_builtin_scalar_kind_from_type(type);
  if (builtin_kind != GQL_EXECUTION_BUILTIN_SCALAR_NONE) {
    return gql_execution_builtin_scalar_graphql_to_perl(aTHX_ builtin_kind, value, ok);
  }
  if (gql_execution_is_houtou_enum_type(type)) {
    return gql_execution_enum_graphql_to_perl(aTHX_ type, value, ok);
  }
  if (gql_execution_is_houtou_input_object_type(type)) {
    return gql_execution_input_object_graphql_to_perl(aTHX_ type, value, ok);
  }

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
  static CV *cv = NULL;

  if (gql_execution_pp_bridge_profile_is_enabled()) {
    gql_execution_pp_bridge_profile_counts.variables_apply_defaults_calls++;
  }
  if (!cv) {
    cv = gql_execution_pp_cv(aTHX_ "GraphQL::Houtou::Execution::PP::_variables_apply_defaults");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(gql_execution_mortal_sv_ref(schema));
  XPUSHs(gql_execution_mortal_sv_ref(operation_variables));
  XPUSHs(gql_execution_mortal_sv_ref(variable_values));
  PUTBACK;

  count = call_sv((SV *)cv, G_SCALAR);
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
  static CV *cv = NULL;

  if (gql_execution_pp_bridge_profile_is_enabled()) {
    gql_execution_pp_bridge_profile_counts.execute_prepared_context_calls++;
  }
  if (!cv) {
    cv = gql_execution_pp_cv(aTHX_ "GraphQL::Houtou::Execution::PP::execute_prepared_context");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(gql_execution_mortal_sv_ref(context));
  PUTBACK;

  count = call_sv((SV *)cv, G_SCALAR);
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
  static CV *cv = NULL;

  if (gql_execution_pp_bridge_profile_is_enabled()) {
    gql_execution_pp_bridge_profile_counts.resolve_field_value_or_error_calls++;
  }
  if (!cv) {
    cv = gql_execution_pp_cv(aTHX_ "GraphQL::Houtou::Execution::PP::_resolve_field_value_or_error");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(gql_execution_mortal_sv_ref(context));
  XPUSHs(gql_execution_mortal_sv_ref(field_def));
  XPUSHs(gql_execution_mortal_sv_ref(nodes));
  XPUSHs(gql_execution_mortal_sv_ref(resolve));
  XPUSHs(gql_execution_mortal_sv_ref(root_value));
  XPUSHs(gql_execution_mortal_sv_ref(info));
  PUTBACK;

  count = call_sv((SV *)cv, G_SCALAR);
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
  static CV *cv = NULL;

  if (gql_execution_pp_bridge_profile_is_enabled()) {
    gql_execution_pp_bridge_profile_counts.complete_value_catching_error_calls++;
  }
  if (!cv) {
    cv = gql_execution_pp_cv(aTHX_ "GraphQL::Houtou::Execution::PP::_complete_value_catching_error");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(gql_execution_mortal_sv_ref(context));
  XPUSHs(gql_execution_mortal_sv_ref(return_type));
  XPUSHs(gql_execution_mortal_sv_ref(nodes));
  XPUSHs(gql_execution_mortal_sv_ref(info));
  XPUSHs(gql_execution_mortal_sv_ref(path));
  XPUSHs(gql_execution_mortal_sv_ref(result));
  PUTBACK;

  count = call_sv((SV *)cv, G_SCALAR);
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
  XPUSHs(gql_execution_mortal_sv_ref(root_value));
  XPUSHs(gql_execution_mortal_sv_ref(args));
  XPUSHs(gql_execution_mortal_sv_ref(context_value));
  XPUSHs(gql_execution_mortal_sv_ref(info));
  PUTBACK;

  count = call_sv(resolve, G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV)) {
    SV *error = newSVsv(ERRSV);
    SV *coerced;
    PUTBACK;
    FREETMPS;
    LEAVE;
    coerced = gql_execution_call_graphql_error_coerce(aTHX_ error);
    SvREFCNT_dec(error);
    return coerced;
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
  static CV *cv = NULL;

  if (gql_execution_pp_bridge_profile_is_enabled()) {
    gql_execution_pp_bridge_profile_counts.get_argument_values_calls++;
  }
  if (!cv) {
    cv = gql_execution_pp_cv(aTHX_ "GraphQL::Houtou::Execution::PP::_get_argument_values_pp");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(gql_execution_mortal_sv_ref(def));
  XPUSHs(gql_execution_mortal_sv_ref(node));
  XPUSHs(gql_execution_mortal_sv_ref(variable_values));
  PUTBACK;

  count = call_sv((SV *)cv, G_SCALAR);
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
  static CV *cv = NULL;

  if (gql_execution_pp_bridge_profile_is_enabled()) {
    gql_execution_pp_bridge_profile_counts.type_will_accept_calls++;
  }
  if (!cv) {
    cv = gql_execution_pp_cv(aTHX_ "GraphQL::Houtou::Execution::PP::_type_will_accept");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(gql_execution_mortal_sv_ref(arg_type));
  XPUSHs(gql_execution_mortal_sv_ref(var_type));
  PUTBACK;

  count = call_sv((SV *)cv, G_SCALAR);
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
gql_execution_call_pp_execute_fields(pTHX_ SV *context, SV *parent_type, SV *root_value, SV *path, SV *fields) {
  dSP;
  int count;
  SV *ret;
  static CV *cv = NULL;

  if (!cv) {
    cv = gql_execution_pp_cv(aTHX_ "GraphQL::Houtou::Execution::PP::_execute_fields");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  EXTEND(SP, 5);
  XPUSHs(gql_execution_mortal_sv_ref(context));
  XPUSHs(gql_execution_mortal_sv_ref(parent_type));
  XPUSHs(gql_execution_mortal_sv_ref(root_value));
  XPUSHs(gql_execution_mortal_sv_ref(path));
  XPUSHs(gql_execution_mortal_sv_ref(fields));
  PUTBACK;
  count = call_sv((SV *)cv, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("_execute_fields did not return a scalar");
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_execution_call_xs_then_complete_value(pTHX_ SV *context, SV *return_type, SV *nodes, SV *info, SV *path, SV *promise) {
  dSP;
  int count;
  SV *ret;
  static CV *cv = NULL;

  if (!cv) {
    cv = get_cv("GraphQL::Houtou::XS::Execution::_then_complete_value_xs", 0);
    if (!cv) {
      croak("unable to resolve GraphQL::Houtou::XS::Execution::_then_complete_value_xs");
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  EXTEND(SP, 6);
  XPUSHs(gql_execution_mortal_sv_ref(context));
  XPUSHs(gql_execution_mortal_sv_ref(return_type));
  XPUSHs(gql_execution_mortal_sv_ref(nodes));
  XPUSHs(gql_execution_mortal_sv_ref(info));
  XPUSHs(gql_execution_mortal_sv_ref(path));
  XPUSHs(gql_execution_mortal_sv_ref(promise));
  PUTBACK;
  count = call_sv((SV *)cv, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("_then_complete_value_xs did not return a scalar");
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_execution_call_xs_then_merge_completed_list(pTHX_ SV *promise_code, SV *promise) {
  dSP;
  int count;
  SV *ret;
  static CV *cv = NULL;

  if (!cv) {
    cv = get_cv("GraphQL::Houtou::XS::Execution::_then_merge_completed_list_xs", 0);
    if (!cv) {
      croak("unable to resolve GraphQL::Houtou::XS::Execution::_then_merge_completed_list_xs");
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  EXTEND(SP, 2);
  XPUSHs(gql_execution_mortal_sv_ref(promise_code));
  XPUSHs(gql_execution_mortal_sv_ref(promise));
  PUTBACK;
  count = call_sv((SV *)cv, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("_then_merge_completed_list_xs did not return a scalar");
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_execution_call_xs_then_resolve_operation_error(pTHX_ SV *promise_code, SV *promise) {
  dSP;
  int count;
  SV *ret;
  static CV *cv = NULL;

  if (!cv) {
    cv = get_cv("GraphQL::Houtou::XS::Execution::_then_resolve_operation_error_xs", 0);
    if (!cv) {
      croak("unable to resolve GraphQL::Houtou::XS::Execution::_then_resolve_operation_error_xs");
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  EXTEND(SP, 2);
  XPUSHs(gql_execution_mortal_sv_ref(promise_code));
  XPUSHs(gql_execution_mortal_sv_ref(promise));
  PUTBACK;
  count = call_sv((SV *)cv, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("_then_resolve_operation_error_xs did not return a scalar");
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_execution_call_xs_then_build_response(pTHX_ SV *promise_code, SV *promise, int force_data) {
  dSP;
  /* Cached per-process for the active interpreter; not safe to share across ithreads interpreters. */
  static CV *cv = NULL;
  int count;
  SV *ret;

  if (!cv) {
    cv = get_cv("GraphQL::Houtou::XS::Execution::_then_build_response_xs", 0);
    if (!cv) {
      croak("unable to resolve GraphQL::Houtou::XS::Execution::_then_build_response_xs");
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(gql_execution_mortal_sv_ref(promise_code));
  XPUSHs(gql_execution_mortal_sv_ref(promise));
  XPUSHs(sv_2mortal(newSViv(force_data ? 1 : 0)));
  PUTBACK;
  count = call_sv((SV *)cv, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("_then_build_response_xs did not return a scalar");
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_execution_call_xs_then_merge_hash(pTHX_ SV *promise_code, AV *keys_av, SV *promise, AV *errors_av) {
  dSP;
  int count;
  SV *ret;
  static CV *cv = NULL;

  if (!cv) {
    cv = get_cv("GraphQL::Houtou::XS::Execution::_then_merge_hash_xs", 0);
    if (!cv) {
      croak("unable to resolve GraphQL::Houtou::XS::Execution::_then_merge_hash_xs");
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  EXTEND(SP, 4);
  XPUSHs(gql_execution_mortal_sv_ref(promise_code));
  XPUSHs(sv_2mortal(newRV_inc((SV *)keys_av)));
  XPUSHs(gql_execution_mortal_sv_ref(promise));
  XPUSHs(sv_2mortal(newRV_inc((SV *)errors_av)));
  PUTBACK;
  count = call_sv((SV *)cv, G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("_then_merge_hash_xs did not return a scalar");
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret;
}

static SV *
gql_execution_default_field_resolver_sv(pTHX) {
  static CV *cv = NULL;

  gql_execution_require_pp(aTHX);
  if (!cv) {
    cv = gql_execution_pp_cv(aTHX_ "GraphQL::Houtou::Execution::PP::_default_field_resolver");
  }

  return newRV_inc((SV *)cv);
}

static int
gql_execution_try_typename_meta_field_fast(pTHX_ SV *parent_type, SV *field_name_sv, SV *return_type, SV **completed_out) {
  STRLEN field_name_len;
  const char *field_name_pv;
  SV *type_name_sv;
  int ok = 0;

  if (completed_out) {
    *completed_out = NULL;
  }
  if (!completed_out || !field_name_sv || !SvOK(field_name_sv) || !return_type || !SvOK(return_type)) {
    return 0;
  }

  field_name_pv = SvPV(field_name_sv, field_name_len);
  if (!(field_name_len == 10 && memEQ(field_name_pv, "__typename", 10))) {
    return 0;
  }

  type_name_sv = gql_execution_type_name_sv(aTHX_ parent_type);
  if (!gql_execution_try_complete_trivial_value_fast(aTHX_ return_type, type_name_sv, completed_out)) {
    SvREFCNT_dec(type_name_sv);
    return 0;
  }
  SvREFCNT_dec(type_name_sv);
  return 1;
}

static int
gql_execution_is_default_field_resolver(pTHX_ SV *resolve) {
  static CV *cv = NULL;

  if (!resolve || !SvROK(resolve) || SvTYPE(SvRV(resolve)) != SVt_PVCV) {
    return 0;
  }

  gql_execution_require_pp(aTHX);
  if (!cv) {
    cv = gql_execution_pp_cv(aTHX_ "GraphQL::Houtou::Execution::PP::_default_field_resolver");
  }

  return (CV *)SvRV(resolve) == cv ? 1 : 0;
}

static int
gql_execution_try_default_field_resolve_fast(pTHX_ SV *root_value, SV *field_name_sv, SV **result_out) {
  HE *property_he;
  SV *property_sv;

  if (result_out) {
    *result_out = NULL;
  }
  if (!result_out || !field_name_sv || !SvOK(field_name_sv)) {
    return 0;
  }

  if (!root_value || !SvOK(root_value)) {
    *result_out = newSV(0);
    return 1;
  }

  if (!SvROK(root_value)) {
    *result_out = gql_execution_share_or_copy_sv(root_value);
    return 1;
  }

  if (sv_isobject(root_value) || SvTYPE(SvRV(root_value)) != SVt_PVHV) {
    return 0;
  }

  property_he = hv_fetch_ent((HV *)SvRV(root_value), field_name_sv, 0, 0);
  property_sv = property_he ? HeVAL(property_he) : &PL_sv_undef;
  if (property_sv
      && SvOK(property_sv)
      && SvROK(property_sv)
      && (SvTYPE(SvRV(property_sv)) == SVt_PVCV || sv_isobject(property_sv))) {
    return 0;
  }

  *result_out = gql_execution_share_or_copy_sv(property_sv);
  return 1;
}

static int
gql_execution_try_complete_trivial_value_fast(pTHX_ SV *return_type, SV *result, SV **completed_out) {
  SV *type = return_type;
  SV *inner_type = NULL;
  SV *serialized;
  HV *ret_hv;
  int ok = 0;

  if (completed_out) {
    *completed_out = NULL;
  }
  if (!completed_out || !return_type || !SvOK(return_type)) {
    return 0;
  }

  if (sv_derived_from(return_type, "GraphQL::Houtou::Type::NonNull")
      || sv_derived_from(return_type, "GraphQL::Type::NonNull")) {
    if (!result || !SvOK(result)) {
      return 0;
    }
    inner_type = gql_execution_call_type_of(aTHX_ return_type);
    type = inner_type;
  } else if (!result || !SvOK(result)) {
    ret_hv = newHV();
    (void)hv_store(ret_hv, "data", 4, newSV(0), 0);
    *completed_out = newRV_noinc((SV *)ret_hv);
    return 1;
  }

  if (!(sv_does(type, "GraphQL::Houtou::Role::Leaf")
        || sv_does(type, "GraphQL::Role::Leaf")
        || sv_derived_from(type, "GraphQL::Houtou::Type::Scalar")
        || sv_derived_from(type, "GraphQL::Type::Scalar")
        || sv_derived_from(type, "GraphQL::Houtou::Type::Enum")
        || sv_derived_from(type, "GraphQL::Type::Enum"))) {
    if (inner_type) {
      SvREFCNT_dec(inner_type);
    }
    return 0;
  }

  serialized = gql_execution_call_type_perl_to_graphql(aTHX_ type, result, &ok);
  if (inner_type) {
    SvREFCNT_dec(inner_type);
  }
  if (!ok) {
    return 0;
  }

  ret_hv = newHV();
  (void)hv_store(ret_hv, "data", 4, serialized, 0);
  *completed_out = newRV_noinc((SV *)ret_hv);
  return 1;
}

static HV *
gql_execution_schema_runtime_cache_hv(pTHX_ SV *schema) {
  HV *schema_hv;
  SV **cache_svp;
  dSP;
  int count;
  SV *ret;

  if (!schema || !SvROK(schema) || SvTYPE(SvRV(schema)) != SVt_PVHV) {
    return NULL;
  }

  schema_hv = (HV *)SvRV(schema);
  cache_svp = hv_fetch(schema_hv, "_runtime_cache", 14, 0);
  if (cache_svp && SvROK(*cache_svp) && SvTYPE(SvRV(*cache_svp)) == SVt_PVHV) {
    return (HV *)SvRV(*cache_svp);
  }

  if (!(sv_derived_from(schema, "GraphQL::Houtou::Schema") || sv_derived_from(schema, "GraphQL::Schema"))) {
    return NULL;
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(gql_execution_mortal_sv_ref(schema));
  PUTBACK;
  count = call_method("_runtime_cache", G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV) || count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    return NULL;
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  if (!SvROK(ret) || SvTYPE(SvRV(ret)) != SVt_PVHV) {
    SvREFCNT_dec(ret);
    return NULL;
  }

  SvREFCNT_dec(ret);
  cache_svp = hv_fetch(schema_hv, "_runtime_cache", 14, 0);
  if (cache_svp && SvROK(*cache_svp) && SvTYPE(SvRV(*cache_svp)) == SVt_PVHV) {
    return (HV *)SvRV(*cache_svp);
  }

  return NULL;
}

static HV *
gql_execution_context_runtime_cache_hv(SV *context) {
  HV *context_hv;
  SV **runtime_cache_svp;

  if (!context || !SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
    return NULL;
  }

  context_hv = (HV *)SvRV(context);
  runtime_cache_svp = hv_fetch(context_hv, "runtime_cache", 13, 0);
  if (!runtime_cache_svp || !SvROK(*runtime_cache_svp) || SvTYPE(SvRV(*runtime_cache_svp)) != SVt_PVHV) {
    return NULL;
  }

  return (HV *)SvRV(*runtime_cache_svp);
}

static HV *
gql_execution_context_or_schema_runtime_cache_hv(pTHX_ SV *context) {
  HV *context_hv;
  HV *runtime_cache_hv;
  SV **schema_svp;

  runtime_cache_hv = gql_execution_context_runtime_cache_hv(context);
  if (runtime_cache_hv) {
    return runtime_cache_hv;
  }

  if (!context || !SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
    return NULL;
  }

  context_hv = (HV *)SvRV(context);
  schema_svp = hv_fetch(context_hv, "schema", 6, 0);
  if (!schema_svp || !SvOK(*schema_svp)) {
    return NULL;
  }

  return gql_execution_schema_runtime_cache_hv(aTHX_ *schema_svp);
}

static SV *
gql_execution_runtime_cache_type_callback_sv(pTHX_ HV *runtime_cache_hv, SV *type, const char *map_key, I32 map_key_len) {
  SV **map_svp;
  SV *type_name_sv = NULL;
  HE *callback_he;
  int owned_type_name_sv = 0;

  if (!runtime_cache_hv || !type) {
    return newSV(0);
  }

  map_svp = hv_fetch(runtime_cache_hv, map_key, map_key_len, 0);
  if (!map_svp || !SvROK(*map_svp) || SvTYPE(SvRV(*map_svp)) != SVt_PVHV) {
    return newSV(0);
  }

  if (SvROK(type)
      && SvTYPE(SvRV(type)) == SVt_PVHV
      && (sv_derived_from(type, "GraphQL::Houtou::Type")
          || sv_derived_from(type, "GraphQL::Type"))) {
    HV *type_hv = (HV *)SvRV(type);
    SV **name_svp = hv_fetch(type_hv, "name", 4, 0);
    if (name_svp && SvOK(*name_svp)) {
      type_name_sv = *name_svp;
    }
  }

  if (!type_name_sv) {
    type_name_sv = gql_execution_type_name_sv(aTHX_ type);
    owned_type_name_sv = 1;
  }

  callback_he = hv_fetch_ent((HV *)SvRV(*map_svp), type_name_sv, 0, 0);
  if (owned_type_name_sv) {
    SvREFCNT_dec(type_name_sv);
  }

  if (!callback_he || !SvOK(HeVAL(callback_he))) {
    return newSV(0);
  }

  return gql_execution_share_or_copy_sv(HeVAL(callback_he));
}

static SV *
gql_execution_call_schema_root_type(pTHX_ SV *schema, const char *op_type) {
  HV *runtime_cache_hv;
  SV **root_types_svp;
  SV **root_type_svp;
  dSP;
  int count;
  SV *ret;
  STRLEN op_type_len = strlen(op_type);

  runtime_cache_hv = gql_execution_schema_runtime_cache_hv(aTHX_ schema);
  if (runtime_cache_hv) {
    root_types_svp = hv_fetch(runtime_cache_hv, "root_types", 10, 0);
    if (root_types_svp && SvROK(*root_types_svp) && SvTYPE(SvRV(*root_types_svp)) == SVt_PVHV) {
      root_type_svp = hv_fetch((HV *)SvRV(*root_types_svp), op_type, (I32)op_type_len, 0);
      if (root_type_svp && SvOK(*root_type_svp)) {
        return gql_execution_share_or_copy_sv(*root_type_svp);
      }
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(gql_execution_mortal_sv_ref(schema));
  PUTBACK;
  count = call_method(op_type, G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV)) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak_sv(sv_2mortal(newSVsv(ERRSV)));
  }
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("schema root type method %s did not return a scalar", op_type);
  }
  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  if (op_type_len == 0) {
    croak("operation type must not be empty");
  }

  return ret;
}

static SV *
gql_execution_schema_possible_types_sv(pTHX_ SV *schema, SV *abstract_type) {
  HV *runtime_cache_hv;
  SV **possible_types_svp;
  STRLEN type_name_len;
  SV *type_name_sv;
  SV *ret = &PL_sv_undef;
  dSP;
  int count;

  runtime_cache_hv = gql_execution_schema_runtime_cache_hv(aTHX_ schema);
  if (runtime_cache_hv) {
    possible_types_svp = hv_fetch(runtime_cache_hv, "possible_types", 14, 0);
    if (possible_types_svp && SvROK(*possible_types_svp) && SvTYPE(SvRV(*possible_types_svp)) == SVt_PVHV) {
      HE *possible_he;

      type_name_sv = gql_execution_call_type_to_string(aTHX_ abstract_type);
      (void)SvPV(type_name_sv, type_name_len);
      possible_he = hv_fetch_ent((HV *)SvRV(*possible_types_svp), type_name_sv, 0, 0);
      if (possible_he && SvOK(HeVAL(possible_he))) {
        ret = gql_execution_share_or_copy_sv(HeVAL(possible_he));
      }
      SvREFCNT_dec(type_name_sv);
      if (ret != &PL_sv_undef) {
        return ret;
      }
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(gql_execution_mortal_sv_ref(schema));
  XPUSHs(gql_execution_mortal_sv_ref(abstract_type));
  PUTBACK;
  count = call_method("get_possible_types", G_SCALAR | G_EVAL);
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
  return ret;
}

static SV *
gql_execution_execute_prepared_context_xs_impl(pTHX_ SV *context) {
  HV *context_hv;
  SV **field_resolver_svp;
  SV **operation_svp;
  SV **root_value_svp;
  SV **schema_svp;
  SV **promise_code_svp;
  SV *promise_code_sv = &PL_sv_undef;
  SV *operation_sv;
  HV *operation_hv;
  SV **op_type_svp;
  const char *op_type = "query";
  SV *type_sv;
  SV **selections_svp;
  SV *fields_sv;
  SV *path_sv;
  SV *result_sv;

  if (!context || !SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
    croak("context must be a hash reference");
  }

  context_hv = (HV *)SvRV(context);
  field_resolver_svp = hv_fetch(context_hv, "field_resolver", 14, 0);
  if (!field_resolver_svp || !SvOK(*field_resolver_svp)) {
    gql_store_sv(context_hv, "field_resolver", gql_execution_default_field_resolver_sv(aTHX));
    field_resolver_svp = hv_fetch(context_hv, "field_resolver", 14, 0);
  }

  operation_svp = hv_fetch(context_hv, "operation", 9, 0);
  root_value_svp = hv_fetch(context_hv, "root_value", 10, 0);
  schema_svp = hv_fetch(context_hv, "schema", 6, 0);
  promise_code_svp = hv_fetch(context_hv, "promise_code", 12, 0);
  if (!operation_svp || !SvOK(*operation_svp) || !schema_svp || !SvOK(*schema_svp)) {
    croak("execution context is missing operation or schema");
  }

  if (promise_code_svp && SvOK(*promise_code_svp)) {
    promise_code_sv = *promise_code_svp;
  }

  operation_sv = *operation_svp;
  if (!SvROK(operation_sv) || SvTYPE(SvRV(operation_sv)) != SVt_PVHV) {
    croak("operation must be a hash reference");
  }
  operation_hv = (HV *)SvRV(operation_sv);
  op_type_svp = hv_fetch(operation_hv, "operationType", 13, 0);
  if (op_type_svp && SvOK(*op_type_svp)) {
    op_type = SvPV_nolen(*op_type_svp);
  }

  type_sv = gql_execution_call_schema_root_type(aTHX_ *schema_svp, op_type);
  if (!SvOK(type_sv) || type_sv == &PL_sv_undef) {
    SV *msg = newSVpvf("No %s in schema", op_type);
    SV *error_result = gql_execution_wrap_error_xs(aTHX_ msg);
    SvREFCNT_dec(msg);
    if (type_sv != &PL_sv_undef) {
      SvREFCNT_dec(type_sv);
    }
    return error_result;
  }

  selections_svp = hv_fetch(operation_hv, "selections", 10, 0);
  if (!selections_svp || !SvOK(*selections_svp)) {
    SvREFCNT_dec(type_sv);
    croak("operation has no selections");
  }

  fields_sv = gql_execution_collect_fields_xs(aTHX_ context, type_sv, *selections_svp);
  if (!fields_sv || fields_sv == &PL_sv_undef) {
    SvREFCNT_dec(type_sv);
    croak("collect_fields failed");
  }
  path_sv = newRV_noinc((SV *)newAV());
  result_sv = gql_execution_execute_fields(
    aTHX_ context,
    type_sv,
    (root_value_svp && SvOK(*root_value_svp)) ? *root_value_svp : &PL_sv_undef,
    path_sv,
    fields_sv
  );

  SvREFCNT_dec(path_sv);
  SvREFCNT_dec(fields_sv);
  SvREFCNT_dec(type_sv);

  if (SvOK(promise_code_sv) && result_sv && SvROK(result_sv)) {
    SV *is_promise_sv = gql_promise_call_is_promise(aTHX_ promise_code_sv, result_sv);
    int is_promise = SvTRUE(is_promise_sv);

    SvREFCNT_dec(is_promise_sv);
    if (is_promise) {
      SV *wrapped = gql_execution_call_xs_then_resolve_operation_error(aTHX_ promise_code_sv, result_sv);
      SvREFCNT_dec(result_sv);
      return wrapped;
    }
  }

  return result_sv;
}

static SV *
gql_execution_call_type_perl_to_graphql(pTHX_ SV *type, SV *value, int *ok) {
  dSP;
  int count;
  SV *ret;
  gql_execution_builtin_scalar_kind_t builtin_kind;

  *ok = 0;

  builtin_kind = gql_execution_builtin_scalar_kind_from_type(type);
  if (builtin_kind != GQL_EXECUTION_BUILTIN_SCALAR_NONE) {
    return gql_execution_builtin_scalar_perl_to_graphql(aTHX_ builtin_kind, value, ok);
  }
  if (gql_execution_is_houtou_enum_type(type)) {
    return gql_execution_enum_perl_to_graphql(aTHX_ type, value, ok);
  }

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
  HV *type_hv;
  SV **name_svp;

  if (SvROK(type)
      && SvTYPE(SvRV(type)) == SVt_PVHV
      && (sv_derived_from(type, "GraphQL::Houtou::Type")
          || sv_derived_from(type, "GraphQL::Houtou::Directive"))) {
    type_hv = (HV *)SvRV(type);
    name_svp = hv_fetch(type_hv, "name", 4, 0);
    if (name_svp && SvOK(*name_svp)) {
      return newSVsv(*name_svp);
    }
  }

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
gql_execution_type_name_sv(pTHX_ SV *type) {
  HV *type_hv;
  SV **name_svp;

  if (type
      && SvROK(type)
      && SvTYPE(SvRV(type)) == SVt_PVHV
      && (sv_derived_from(type, "GraphQL::Houtou::Type")
          || sv_derived_from(type, "GraphQL::Type")
          || sv_derived_from(type, "GraphQL::Houtou::Directive")
          || sv_derived_from(type, "GraphQL::Directive"))) {
    type_hv = (HV *)SvRV(type);
    name_svp = hv_fetch(type_hv, "name", 4, 0);
    if (name_svp && SvOK(*name_svp)) {
      return newSVsv(*name_svp);
    }
  }

  return gql_execution_call_type_to_string(aTHX_ type);
}

static int
gql_execution_possible_type_match_simple(
  pTHX_ SV *context,
  SV *schema,
  SV *abstract_type,
  SV *abstract_name_sv,
  SV *possible_type,
  SV *possible_name_sv,
  int *ok
) {
  HV *runtime_cache_hv;
  SV **possible_type_map_svp;

  *ok = 0;
  if (!schema || !SvROK(schema) || SvTYPE(SvRV(schema)) != SVt_PVHV) {
    return 0;
  }

  runtime_cache_hv = gql_execution_context_or_schema_runtime_cache_hv(aTHX_ context);
  if (!runtime_cache_hv) {
    return 0;
  }

  possible_type_map_svp = hv_fetch(runtime_cache_hv, "possible_type_map", 17, 0);
  if (possible_type_map_svp && SvROK(*possible_type_map_svp) && SvTYPE(SvRV(*possible_type_map_svp)) == SVt_PVHV) {
    HE *map_he = hv_fetch_ent((HV *)SvRV(*possible_type_map_svp), abstract_name_sv, 0, 0);
    if (map_he && SvROK(HeVAL(map_he)) && SvTYPE(SvRV(HeVAL(map_he))) == SVt_PVHV) {
      HE *possible_he = hv_fetch_ent((HV *)SvRV(HeVAL(map_he)), possible_name_sv, 0, 0);
      *ok = 1;
      return (possible_he && SvTRUE(HeVAL(possible_he))) ? 1 : 0;
    }
  }

  {
    dSP;
    int count;
    SV *ret;

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(gql_execution_mortal_sv_ref(schema));
    XPUSHs(gql_execution_mortal_sv_ref(abstract_type));
    XPUSHs(gql_execution_mortal_sv_ref(possible_type));
    PUTBACK;
    count = call_method("is_possible_type", G_SCALAR | G_EVAL);
    SPAGAIN;
    if (SvTRUE(ERRSV) || count != 1) {
      PUTBACK;
      FREETMPS;
      LEAVE;
      return 0;
    }
    ret = newSVsv(POPs);
    PUTBACK;
    FREETMPS;
    LEAVE;
    *ok = 1;
    {
      int matched = SvTRUE(ret) ? 1 : 0;
      SvREFCNT_dec(ret);
      return matched;
    }
  }
}

static SV *
gql_execution_fragment_condition_matches_simple(pTHX_ SV *context, SV *object_type, SV *condition_name, int *ok) {
  HV *runtime_cache_hv;
  SV **possible_type_map_svp;
  SV *object_name_sv;

  *ok = 0;
  if (!condition_name || !SvOK(condition_name)) {
    *ok = 1;
    return newSViv(1);
  }
  if (!SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
    return newSViv(0);
  }

  object_name_sv = gql_execution_type_name_sv(aTHX_ object_type);
  if (sv_eq(condition_name, object_name_sv)) {
    SvREFCNT_dec(object_name_sv);
    *ok = 1;
    return newSViv(1);
  }

  runtime_cache_hv = gql_execution_context_or_schema_runtime_cache_hv(aTHX_ context);
  if (!runtime_cache_hv) {
    SvREFCNT_dec(object_name_sv);
    return newSViv(0);
  }

  possible_type_map_svp = hv_fetch(runtime_cache_hv, "possible_type_map", 17, 0);
  if (!possible_type_map_svp || !SvROK(*possible_type_map_svp) || SvTYPE(SvRV(*possible_type_map_svp)) != SVt_PVHV) {
    SvREFCNT_dec(object_name_sv);
    return newSViv(0);
  }

  *ok = 1;
  {
    HE *condition_he = hv_fetch_ent((HV *)SvRV(*possible_type_map_svp), condition_name, 0, 0);
    if (condition_he && SvROK(HeVAL(condition_he)) && SvTYPE(SvRV(HeVAL(condition_he))) == SVt_PVHV) {
      HE *possible_he = hv_fetch_ent((HV *)SvRV(HeVAL(condition_he)), object_name_sv, 0, 0);
      SvREFCNT_dec(object_name_sv);
      return newSViv((possible_he && SvTRUE(HeVAL(possible_he))) ? 1 : 0);
    }
  }
  SvREFCNT_dec(object_name_sv);
  return newSViv(0);
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
gql_execution_get_object_is_type_of_sv(pTHX_ SV *context, SV *type) {
  HV *runtime_cache_hv = gql_execution_context_or_schema_runtime_cache_hv(aTHX_ context);
  SV *cached = gql_execution_runtime_cache_type_callback_sv(aTHX_ runtime_cache_hv, type, "is_type_of_map", 14);

  if (SvOK(cached)) {
    return cached;
  }

  SvREFCNT_dec(cached);
  return gql_execution_call_object_is_type_of(aTHX_ type);
}

static SV *
gql_execution_call_abstract_resolve_type(pTHX_ SV *type) {
  dSP;
  int count;
  SV *ret;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(type)));
  PUTBACK;

  count = call_method("resolve_type", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("type->resolve_type did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}

static SV *
gql_execution_get_abstract_resolve_type_sv(pTHX_ SV *context, SV *type) {
  HV *runtime_cache_hv = gql_execution_context_or_schema_runtime_cache_hv(aTHX_ context);
  SV *cached = gql_execution_runtime_cache_type_callback_sv(aTHX_ runtime_cache_hv, type, "resolve_type_map", 16);

  if (SvOK(cached)) {
    return cached;
  }

  SvREFCNT_dec(cached);
  return gql_execution_call_abstract_resolve_type(aTHX_ type);
}

static SV *
gql_execution_call_is_type_of_cb(pTHX_ SV *cb, SV *result, SV *context, SV *info, int *ok, SV **error_out) {
  dSP;
  int count;
  SV *ret;
  SV *context_value = &PL_sv_undef;

  *ok = 0;
  if (error_out) {
    *error_out = NULL;
  }
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
    if (SvTRUE(ERRSV) && error_out) {
      *error_out = newSVsv(ERRSV);
    }
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
gql_execution_call_abstract_resolve_type_cb(pTHX_ SV *cb, SV *result, SV *context, SV *info, SV *abstract_type, int *ok, SV **error_out) {
  dSP;
  int count;
  SV *ret;
  SV *context_value = &PL_sv_undef;

  *ok = 0;
  if (error_out) {
    *error_out = NULL;
  }
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
    if (SvTRUE(ERRSV) && error_out) {
      *error_out = newSVsv(ERRSV);
    }
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

static SV *
gql_execution_path_with_key(pTHX_ SV *path, SV *key_sv) {
  AV *path_copy_av = newAV();
  SV *ret;

  if (SvROK(path) && SvTYPE(SvRV(path)) == SVt_PVAV) {
    AV *path_av = (AV *)SvRV(path);
    I32 path_len = av_len(path_av);
    I32 path_i;

    if (path_len >= 0) {
      av_extend(path_copy_av, path_len + 1);
    }
    for (path_i = 0; path_i <= path_len; path_i++) {
      SV **path_part_svp = av_fetch(path_av, path_i, 0);
      if (path_part_svp) {
        av_push(path_copy_av, newSVsv(*path_part_svp));
      }
    }
  }

  av_push(path_copy_av, newSVsv(key_sv));
  ret = newRV_noinc((SV *)path_copy_av);
  return ret;
}

static int
gql_execution_path_is_root(SV *path) {
  if (!path || !SvOK(path)) {
    return 1;
  }

  if (!SvROK(path) || SvTYPE(SvRV(path)) != SVt_PVAV) {
    return 0;
  }

  return av_len((AV *)SvRV(path)) < 0;
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
gql_execution_merge_compiled_field_bucket_table_into(
  pTHX_ AV *field_names_av,
  HV *nodes_defs_hv,
  gql_ir_compiled_field_bucket_table_t *bucket_table
) {
  UV field_i;

  if (!bucket_table) {
    return 0;
  }

  for (field_i = 0; field_i < bucket_table->count; field_i++) {
    gql_ir_compiled_field_bucket_entry_t *entry = &bucket_table->entries[field_i];
    HE *target_he;
    AV *target_bucket;
    AV *source_bucket;
    I32 bucket_i;
    I32 bucket_len;

    if (!entry->result_name_sv || !entry->nodes_sv
        || !SvOK(entry->result_name_sv)
        || !SvROK(entry->nodes_sv)
        || SvTYPE(SvRV(entry->nodes_sv)) != SVt_PVAV) {
      return 0;
    }

    source_bucket = (AV *)SvRV(entry->nodes_sv);
    target_he = hv_fetch_ent(nodes_defs_hv, entry->result_name_sv, 0, 0);
    if (!target_he) {
      SV *name_key_sv;
      target_bucket = newAV();
      name_key_sv = newSVsv(entry->result_name_sv);
      (void)hv_store_ent(nodes_defs_hv, name_key_sv, newRV_noinc((SV *)target_bucket), 0);
      SvREFCNT_dec(name_key_sv);
      av_push(field_names_av, SvREFCNT_inc_simple_NN(entry->result_name_sv));
    } else if (SvROK(HeVAL(target_he)) && SvTYPE(SvRV(HeVAL(target_he))) == SVt_PVAV) {
      target_bucket = (AV *)SvRV(HeVAL(target_he));
    } else {
      return 0;
    }

    bucket_len = av_len(source_bucket);
    for (bucket_i = 0; bucket_i <= bucket_len; bucket_i++) {
      SV **bucket_node_svp = av_fetch(source_bucket, bucket_i, 0);
      if (bucket_node_svp && SvOK(*bucket_node_svp)) {
        av_push(target_bucket, SvREFCNT_inc_simple_NN(*bucket_node_svp));
      }
    }
  }

  return 1;
}

static int
gql_execution_merge_compiled_fields_into(
  pTHX_ AV *field_names_av,
  HV *nodes_defs_hv,
  SV *compiled_fields_sv
) {
  AV *compiled_av;
  SV **compiled_names_svp;
  SV **compiled_defs_svp;
  AV *compiled_names_av;
  HV *compiled_defs_hv;
  I32 name_i;
  I32 name_len;

  gql_ir_compiled_field_bucket_table_t *bucket_table = gql_ir_get_compiled_field_bucket_table(aTHX_ compiled_fields_sv);
  if (bucket_table) {
    return gql_execution_merge_compiled_field_bucket_table_into(aTHX_ field_names_av, nodes_defs_hv, bucket_table);
  }

  if (!compiled_fields_sv || !SvROK(compiled_fields_sv) || SvTYPE(SvRV(compiled_fields_sv)) != SVt_PVAV) {
    return 0;
  }

  compiled_av = (AV *)SvRV(compiled_fields_sv);
  if (av_len(compiled_av) != 1) {
    return 0;
  }

  compiled_names_svp = av_fetch(compiled_av, 0, 0);
  compiled_defs_svp = av_fetch(compiled_av, 1, 0);
  if (!compiled_names_svp || !compiled_defs_svp
      || !SvROK(*compiled_names_svp) || SvTYPE(SvRV(*compiled_names_svp)) != SVt_PVAV
      || !SvROK(*compiled_defs_svp) || SvTYPE(SvRV(*compiled_defs_svp)) != SVt_PVHV) {
    return 0;
  }

  compiled_names_av = (AV *)SvRV(*compiled_names_svp);
  compiled_defs_hv = (HV *)SvRV(*compiled_defs_svp);
  name_len = av_len(compiled_names_av);

  for (name_i = 0; name_i <= name_len; name_i++) {
    SV **name_svp = av_fetch(compiled_names_av, name_i, 0);
    HE *compiled_he;
    HE *target_he;
    AV *target_bucket;
    AV *source_bucket;
    I32 bucket_i;
    I32 bucket_len;

    if (!name_svp || !SvOK(*name_svp)) {
      continue;
    }

    compiled_he = hv_fetch_ent(compiled_defs_hv, *name_svp, 0, 0);
    if (!compiled_he || !SvROK(HeVAL(compiled_he)) || SvTYPE(SvRV(HeVAL(compiled_he))) != SVt_PVAV) {
      return 0;
    }
    source_bucket = (AV *)SvRV(HeVAL(compiled_he));

    target_he = hv_fetch_ent(nodes_defs_hv, *name_svp, 0, 0);
    if (!target_he) {
      SV *name_key_sv;
      target_bucket = newAV();
      name_key_sv = newSVsv(*name_svp);
      (void)hv_store_ent(nodes_defs_hv, name_key_sv, newRV_noinc((SV *)target_bucket), 0);
      SvREFCNT_dec(name_key_sv);
      av_push(field_names_av, SvREFCNT_inc_simple_NN(*name_svp));
    } else if (SvROK(HeVAL(target_he)) && SvTYPE(SvRV(HeVAL(target_he))) == SVt_PVAV) {
      target_bucket = (AV *)SvRV(HeVAL(target_he));
    } else {
      return 0;
    }

    bucket_len = av_len(source_bucket);
    for (bucket_i = 0; bucket_i <= bucket_len; bucket_i++) {
      SV **bucket_node_svp = av_fetch(source_bucket, bucket_i, 0);
      if (bucket_node_svp && SvOK(*bucket_node_svp)) {
        av_push(target_bucket, SvREFCNT_inc_simple_NN(*bucket_node_svp));
      }
    }
  }

  return 1;
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
        SV *name_key_sv;
        bucket_av = newAV();
        name_key_sv = newSVsv(use_name_sv);
        (void)hv_store_ent(nodes_defs_hv, name_key_sv, newRV_noinc((SV *)bucket_av), 0);
        SvREFCNT_dec(name_key_sv);
        av_push(field_names_av, SvREFCNT_inc_simple_NN(use_name_sv));
      } else if ((bucket_sv = HeVAL(bucket_he)) && SvROK(bucket_sv) && SvTYPE(SvRV(bucket_sv)) == SVt_PVAV) {
        bucket_av = (AV *)SvRV(bucket_sv);
      } else {
        return 0;
      }

      av_push(bucket_av, SvREFCNT_inc_simple_NN(*selection_svp));
      continue;
    }

    if (kind_len == 15 && strEQ(kind_pv, "inline_fragment")) {
      SV **on_svp = hv_fetch(selection_hv, "on", 2, 0);
      SV **compiled_fields_svp = hv_fetch(selection_hv, "compiled_fields", 15, 0);
      SV **selections_svp = hv_fetch(selection_hv, "selections", 10, 0);
      if (on_svp && SvOK(*on_svp)) {
        int match_ok = 0;
        SV *matches = gql_execution_fragment_condition_matches_simple(aTHX_ context, object_type, *on_svp, &match_ok);
        if (!match_ok) {
          SvREFCNT_dec(matches);
          return 0;
        }
        if (!SvTRUE(matches)) {
          SvREFCNT_dec(matches);
          continue;
        }
        SvREFCNT_dec(matches);
      }
      {
        gql_ir_compiled_field_bucket_table_t *bucket_table = gql_ir_get_compiled_field_bucket_table(aTHX_ *selection_svp);
        if (bucket_table) {
          if (!gql_execution_merge_compiled_field_bucket_table_into(aTHX_ field_names_av, nodes_defs_hv, bucket_table)) {
            return 0;
          }
          continue;
        }
      }
      if (compiled_fields_svp && SvOK(*compiled_fields_svp)) {
        if (!gql_execution_merge_compiled_fields_into(aTHX_ field_names_av, nodes_defs_hv, *compiled_fields_svp)) {
          return 0;
        }
        continue;
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
      SV **compiled_fields_svp;
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
        int match_ok = 0;
        SV *matches = gql_execution_fragment_condition_matches_simple(aTHX_ context, object_type, *on_svp, &match_ok);
        if (!match_ok) {
          SvREFCNT_dec(matches);
          return 0;
        }
        if (!SvTRUE(matches)) {
          SvREFCNT_dec(matches);
          continue;
        }
        SvREFCNT_dec(matches);
      }
      {
        gql_ir_compiled_field_bucket_table_t *bucket_table = gql_ir_get_compiled_field_bucket_table(aTHX_ fragment_sv);
        if (bucket_table) {
          if (!gql_execution_merge_compiled_field_bucket_table_into(aTHX_ field_names_av, nodes_defs_hv, bucket_table)) {
            return 0;
          }
          continue;
        }
      }
      compiled_fields_svp = hv_fetch(fragment_hv, "compiled_fields", 15, 0);
      if (compiled_fields_svp && SvOK(*compiled_fields_svp)) {
        if (!gql_execution_merge_compiled_fields_into(aTHX_ field_names_av, nodes_defs_hv, *compiled_fields_svp)) {
          return 0;
        }
        continue;
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
gql_execution_collect_compiled_object_fields(pTHX_ SV *nodes, int *ok) {
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
    gql_ir_compiled_field_bucket_table_t *bucket_table;
    SV **compiled_fields_svp;
    if (!node_svp || !SvROK(*node_svp) || SvTYPE(SvRV(*node_svp)) != SVt_PVHV) {
      continue;
    }

    bucket_table = gql_ir_get_compiled_field_bucket_table(aTHX_ *node_svp);
    if (bucket_table) {
      if (!gql_execution_merge_compiled_field_bucket_table_into(aTHX_ field_names_av, nodes_defs_hv, bucket_table)) {
        goto fallback;
      }
      continue;
    }

    node_hv = (HV *)SvRV(*node_svp);
    compiled_fields_svp = hv_fetch(node_hv, "compiled_fields", 15, 0);
    if (!compiled_fields_svp || !SvOK(*compiled_fields_svp)) {
      goto fallback;
    }
    if (!gql_execution_merge_compiled_fields_into(aTHX_ field_names_av, nodes_defs_hv, *compiled_fields_svp)) {
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
gql_execution_collect_concrete_compiled_object_fields(pTHX_ SV *object_type, SV *nodes, int *ok) {
  SV *type_name_sv;
  AV *field_names_av = NULL;
  HV *nodes_defs_hv = NULL;
  AV *ret_av = NULL;
  I32 node_i;
  I32 node_len;

  *ok = 0;
  if (!SvROK(nodes) || SvTYPE(SvRV(nodes)) != SVt_PVAV) {
    return &PL_sv_undef;
  }

  type_name_sv = gql_execution_type_name_sv(aTHX_ object_type);
  if (!type_name_sv || !SvOK(type_name_sv)) {
    return &PL_sv_undef;
  }

  field_names_av = newAV();
  nodes_defs_hv = newHV();
  node_len = av_len((AV *)SvRV(nodes));

  for (node_i = 0; node_i <= node_len; node_i++) {
    SV **node_svp = av_fetch((AV *)SvRV(nodes), node_i, 0);
    HV *node_hv;
    gql_ir_compiled_concrete_plan_table_t *compiled_plan_table;
    SV **compiled_concrete_svp;
    HE *compiled_he;
    UV plan_i;

    if (!node_svp || !SvROK(*node_svp) || SvTYPE(SvRV(*node_svp)) != SVt_PVHV) {
      continue;
    }

    compiled_plan_table = gql_ir_get_concrete_field_plan_table(aTHX_ *node_svp);
    if (compiled_plan_table) {
      int found = 0;
      for (plan_i = 0; plan_i < compiled_plan_table->count; plan_i++) {
        gql_ir_compiled_concrete_plan_entry_t *entry = &compiled_plan_table->entries[plan_i];

        if (!entry->possible_type_sv || !entry->compiled_fields_sv) {
          continue;
        }
        if (object_type == entry->possible_type_sv
            || (SvROK(object_type)
                && SvROK(entry->possible_type_sv)
                && SvRV(object_type) == SvRV(entry->possible_type_sv))) {
          if (!gql_execution_merge_compiled_fields_into(aTHX_ field_names_av, nodes_defs_hv, entry->compiled_fields_sv)) {
            goto fallback;
          }
          found = 1;
          break;
        }
      }
      if (found) {
        continue;
      }
    }

    node_hv = (HV *)SvRV(*node_svp);
    compiled_concrete_svp = hv_fetch(node_hv, "compiled_concrete_subfields", 27, 0);
    if (!compiled_concrete_svp
        || !SvROK(*compiled_concrete_svp)
        || SvTYPE(SvRV(*compiled_concrete_svp)) != SVt_PVHV) {
      goto fallback;
    }

    compiled_he = hv_fetch_ent((HV *)SvRV(*compiled_concrete_svp), type_name_sv, 0, 0);
    if (!compiled_he || !SvOK(HeVAL(compiled_he))) {
      goto fallback;
    }

    if (!gql_execution_merge_compiled_fields_into(aTHX_ field_names_av, nodes_defs_hv, HeVAL(compiled_he))) {
      goto fallback;
    }
  }

  ret_av = newAV();
  av_push(ret_av, newRV_noinc((SV *)field_names_av));
  av_push(ret_av, newRV_noinc((SV *)nodes_defs_hv));
  SvREFCNT_dec(type_name_sv);
  *ok = 1;
  return newRV_noinc((SV *)ret_av);

fallback:
  SvREFCNT_dec(type_name_sv);
  SvREFCNT_dec((SV *)field_names_av);
  SvREFCNT_dec((SV *)nodes_defs_hv);
  return &PL_sv_undef;
}

static SV *
gql_execution_collect_single_node_concrete_field_plan(pTHX_ SV *object_type, SV *nodes, int *ok) {
  AV *nodes_av;
  SV **node_svp;
  HV *node_hv;
  gql_ir_compiled_concrete_plan_table_t *compiled_plan_table;
  SV **compiled_plans_svp;
  SV *type_name_sv;
  HE *plan_he;
  UV plan_i;

  *ok = 0;
  if (!SvROK(nodes) || SvTYPE(SvRV(nodes)) != SVt_PVAV) {
    return &PL_sv_undef;
  }

  nodes_av = (AV *)SvRV(nodes);
  if (av_len(nodes_av) != 0) {
    return &PL_sv_undef;
  }

  node_svp = av_fetch(nodes_av, 0, 0);
  if (!node_svp || !SvROK(*node_svp) || SvTYPE(SvRV(*node_svp)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  compiled_plan_table = gql_ir_get_concrete_field_plan_table(aTHX_ *node_svp);
  if (compiled_plan_table) {
    for (plan_i = 0; plan_i < compiled_plan_table->count; plan_i++) {
      gql_ir_compiled_concrete_plan_entry_t *entry = &compiled_plan_table->entries[plan_i];

      if (!entry->possible_type_sv || !entry->field_plan_sv) {
        continue;
      }
      if (object_type == entry->possible_type_sv
          || (SvROK(object_type)
              && SvROK(entry->possible_type_sv)
              && SvRV(object_type) == SvRV(entry->possible_type_sv))) {
        *ok = 1;
        return gql_execution_share_or_copy_sv(entry->field_plan_sv);
      }
    }
  }

  node_hv = (HV *)SvRV(*node_svp);
  compiled_plans_svp = hv_fetch(node_hv, "compiled_concrete_field_plans", 28, 0);
  if (!compiled_plans_svp
      || !SvROK(*compiled_plans_svp)
      || SvTYPE(SvRV(*compiled_plans_svp)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  type_name_sv = gql_execution_type_name_sv(aTHX_ object_type);
  if (!type_name_sv || !SvOK(type_name_sv)) {
    return &PL_sv_undef;
  }

  plan_he = hv_fetch_ent((HV *)SvRV(*compiled_plans_svp), type_name_sv, 0, 0);
  SvREFCNT_dec(type_name_sv);
  if (!plan_he || !SvOK(HeVAL(plan_he))) {
    return &PL_sv_undef;
  }

  *ok = 1;
  return gql_execution_share_or_copy_sv(HeVAL(plan_he));
}

static gql_ir_compiled_root_field_plan_t *
gql_execution_collect_single_node_concrete_native_field_plan(pTHX_ SV *object_type, SV *nodes) {
  AV *nodes_av;
  SV **node_svp;
  gql_ir_compiled_concrete_plan_table_t *compiled_plan_table;
  UV plan_i;

  if (!SvROK(nodes) || SvTYPE(SvRV(nodes)) != SVt_PVAV) {
    return NULL;
  }

  nodes_av = (AV *)SvRV(nodes);
  if (av_len(nodes_av) != 0) {
    return NULL;
  }

  node_svp = av_fetch(nodes_av, 0, 0);
  if (!node_svp || !SvROK(*node_svp) || SvTYPE(SvRV(*node_svp)) != SVt_PVHV) {
    return NULL;
  }

  compiled_plan_table = gql_ir_get_concrete_field_plan_table(aTHX_ *node_svp);
  if (!compiled_plan_table) {
    return NULL;
  }

  for (plan_i = 0; plan_i < compiled_plan_table->count; plan_i++) {
    gql_ir_compiled_concrete_plan_entry_t *entry = &compiled_plan_table->entries[plan_i];

    if (!entry->possible_type_sv || !entry->native_field_plan) {
      continue;
    }
    if (object_type == entry->possible_type_sv
        || (SvROK(object_type)
            && SvROK(entry->possible_type_sv)
            && SvRV(object_type) == SvRV(entry->possible_type_sv))) {
      return entry->native_field_plan;
    }
  }

  return NULL;
}

static SV *
gql_execution_build_field_plan_from_compiled_fields(pTHX_ SV *schema, SV *parent_type, SV *compiled_fields_sv) {
  AV *compiled_av;
  SV **compiled_names_svp;
  SV **compiled_defs_svp;
  AV *compiled_names_av;
  HV *compiled_defs_hv;
  HV *result_hv;
  AV *field_order_av;
  HV *fields_hv;
  I32 name_i;
  I32 name_len;

  if (!compiled_fields_sv || !SvROK(compiled_fields_sv) || SvTYPE(SvRV(compiled_fields_sv)) != SVt_PVAV) {
    return &PL_sv_undef;
  }

  compiled_av = (AV *)SvRV(compiled_fields_sv);
  if (av_len(compiled_av) != 1) {
    return &PL_sv_undef;
  }

  compiled_names_svp = av_fetch(compiled_av, 0, 0);
  compiled_defs_svp = av_fetch(compiled_av, 1, 0);
  if (!compiled_names_svp || !compiled_defs_svp
      || !SvROK(*compiled_names_svp) || SvTYPE(SvRV(*compiled_names_svp)) != SVt_PVAV
      || !SvROK(*compiled_defs_svp) || SvTYPE(SvRV(*compiled_defs_svp)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  compiled_names_av = (AV *)SvRV(*compiled_names_svp);
  compiled_defs_hv = (HV *)SvRV(*compiled_defs_svp);
  result_hv = newHV();
  field_order_av = newAV();
  fields_hv = newHV();
  name_len = av_len(compiled_names_av);

  for (name_i = 0; name_i <= name_len; name_i++) {
    SV **result_name_svp = av_fetch(compiled_names_av, name_i, 0);
    HE *compiled_he;
    AV *nodes_av;
    SV **field_node_svp;
    HV *field_node_hv;
    SV **field_name_svp;
    SV **compiled_field_def_svp;
    SV *field_def_sv;
    HV *field_plan_hv;

    if (!result_name_svp || !SvOK(*result_name_svp)) {
      continue;
    }

    compiled_he = hv_fetch_ent(compiled_defs_hv, *result_name_svp, 0, 0);
    if (!compiled_he || !SvROK(HeVAL(compiled_he)) || SvTYPE(SvRV(HeVAL(compiled_he))) != SVt_PVAV) {
      goto fallback;
    }

    nodes_av = (AV *)SvRV(HeVAL(compiled_he));
    field_node_svp = av_fetch(nodes_av, 0, 0);
    if (!field_node_svp || !SvROK(*field_node_svp) || SvTYPE(SvRV(*field_node_svp)) != SVt_PVHV) {
      goto fallback;
    }

    field_node_hv = (HV *)SvRV(*field_node_svp);
    field_name_svp = hv_fetch(field_node_hv, "name", 4, 0);
    if (!field_name_svp || !SvOK(*field_name_svp)) {
      goto fallback;
    }

    compiled_field_def_svp = hv_fetch(field_node_hv, "compiled_field_def", 18, 0);
    if (compiled_field_def_svp && SvOK(*compiled_field_def_svp)) {
      field_def_sv = gql_execution_share_or_copy_sv(*compiled_field_def_svp);
    } else {
      field_def_sv = gql_execution_get_field_def(aTHX_ schema, parent_type, *field_name_svp);
      if (!SvOK(field_def_sv) || field_def_sv == &PL_sv_undef) {
        if (field_def_sv != &PL_sv_undef) {
          SvREFCNT_dec(field_def_sv);
        }
        goto fallback;
      }
    }

    field_plan_hv = newHV();
    gql_store_sv(field_plan_hv, "result_name", newSVsv(*result_name_svp));
    gql_store_sv(field_plan_hv, "field_name", gql_execution_share_or_copy_sv(*field_name_svp));
    gql_store_sv(field_plan_hv, "field_def", field_def_sv);
    gql_store_sv(field_plan_hv, "nodes", gql_execution_share_or_copy_sv(HeVAL(compiled_he)));
    av_push(field_order_av, SvREFCNT_inc_simple_NN(*result_name_svp));
    (void)hv_store_ent(fields_hv, newSVsv(*result_name_svp), newRV_noinc((SV *)field_plan_hv), 0);
  }

  gql_store_sv(result_hv, "field_order", newRV_noinc((SV *)field_order_av));
  gql_store_sv(result_hv, "fields", newRV_noinc((SV *)fields_hv));
  return newRV_noinc((SV *)result_hv);

fallback:
  SvREFCNT_dec((SV *)field_order_av);
  SvREFCNT_dec((SV *)fields_hv);
  SvREFCNT_dec((SV *)result_hv);
  return &PL_sv_undef;
}

static SV *
gql_execution_collect_simple_object_fields(pTHX_ SV *context, SV *object_type, SV *nodes, int *ok) {
  SV *concrete_compiled_ret = gql_execution_collect_concrete_compiled_object_fields(aTHX_ object_type, nodes, ok);
  if (*ok) {
    return concrete_compiled_ret;
  }

  SV *compiled_ret = gql_execution_collect_compiled_object_fields(aTHX_ nodes, ok);
  if (*ok) {
    return compiled_ret;
  }

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
gql_execution_collect_fields_xs(pTHX_ SV *context, SV *object_type, SV *selections) {
  AV *field_names_av = NULL;
  HV *nodes_defs_hv = NULL;
  AV *ret_av = NULL;

  if (!SvROK(selections) || SvTYPE(SvRV(selections)) != SVt_PVAV) {
    return &PL_sv_undef;
  }

  field_names_av = newAV();
  nodes_defs_hv = newHV();

  if (!gql_execution_collect_simple_selections(
        aTHX_ context,
        object_type,
        (AV *)SvRV(selections),
        field_names_av,
        nodes_defs_hv
      )) {
    SvREFCNT_dec((SV *)field_names_av);
    SvREFCNT_dec((SV *)nodes_defs_hv);
    return &PL_sv_undef;
  }

  ret_av = newAV();
  av_push(ret_av, newRV_noinc((SV *)field_names_av));
  av_push(ret_av, newRV_noinc((SV *)nodes_defs_hv));
  return newRV_noinc((SV *)ret_av);
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
  HV *resolve_info_base_hv = newHV();
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

    SvREFCNT_dec((SV *)resolve_info_base_hv);
    SvREFCNT_dec((SV *)context_hv);
    SvREFCNT_dec((SV *)fragments_hv);
    SvREFCNT_dec((SV *)operations_av);
    croak("Can only execute document containing fragments or operations\n");
  }

  if (av_len(operations_av) < 0) {
    SvREFCNT_dec((SV *)resolve_info_base_hv);
    SvREFCNT_dec((SV *)context_hv);
    SvREFCNT_dec((SV *)fragments_hv);
    SvREFCNT_dec((SV *)operations_av);
    croak("No operations supplied.\n");
  }

  operation_sv = gql_execution_select_operation(aTHX_ operations_av, operation_name);
  if (!SvROK(operation_sv) || SvTYPE(SvRV(operation_sv)) != SVt_PVHV) {
    SvREFCNT_dec((SV *)resolve_info_base_hv);
    SvREFCNT_dec((SV *)context_hv);
    SvREFCNT_dec((SV *)fragments_hv);
    SvREFCNT_dec((SV *)operations_av);
    croak("Selected operation is not a hash reference");
  }

  operation_hv = (HV *)SvRV(operation_sv);
  variables_svp = hv_fetch(operation_hv, "variables", 9, 0);
  {
    SV **op_type_svp = hv_fetch(operation_hv, "operationType", 13, 0);
    const char *op_type = (op_type_svp && SvOK(*op_type_svp)) ? SvPV_nolen(*op_type_svp) : "query";
    gql_execution_attach_ast_execution_metadata(aTHX_ schema, operation_sv, fragments_hv, op_type);
  }
  if (!variables_svp || !SvOK(*variables_svp)) {
    empty_variables_sv = newRV_noinc((SV *)newHV());
  }
  if (!variable_values || !SvOK(variable_values)) {
    runtime_variables_sv = newRV_noinc((SV *)newHV());
  }

  {
    SV *operation_variables_sv = (variables_svp && SvOK(*variables_svp)) ? *variables_svp : empty_variables_sv;
    HV *operation_variables_hv = NULL;

    if (operation_variables_sv
        && SvROK(operation_variables_sv)
        && SvTYPE(SvRV(operation_variables_sv)) == SVt_PVHV) {
      operation_variables_hv = (HV *)SvRV(operation_variables_sv);
    }

    if (operation_variables_hv && HvUSEDKEYS(operation_variables_hv) == 0) {
      applied_variables_sv = newRV_noinc((SV *)newHV());
    } else {
      applied_variables_sv = gql_execution_call_pp_variables_apply_defaults(
        aTHX_ schema,
        operation_variables_sv,
        (variable_values && SvOK(variable_values)) ? variable_values : runtime_variables_sv
      );
    }
  }

  gql_store_sv(context_hv, "schema", gql_execution_share_or_copy_sv(schema));
  {
    HV *runtime_cache_hv = gql_execution_schema_runtime_cache_hv(aTHX_ schema);
    if (runtime_cache_hv) {
      gql_store_sv(context_hv, "runtime_cache", newRV_inc((SV *)runtime_cache_hv));
    }
  }
  gql_store_sv(context_hv, "fragments", newRV_noinc((SV *)fragments_hv));
  gql_store_sv(context_hv, "root_value", gql_execution_share_or_copy_sv(root_value));
  gql_store_sv(context_hv, "context_value", gql_execution_share_or_copy_sv(context_value));
  gql_store_sv(context_hv, "operation", operation_sv);
  gql_store_sv(context_hv, "variable_values", applied_variables_sv);
  gql_store_sv(context_hv, "field_resolver", gql_execution_share_or_copy_sv(field_resolver));
  gql_store_sv(context_hv, "promise_code", gql_execution_share_or_copy_sv(promise_code));
  gql_store_sv(context_hv, "empty_args", newRV_noinc((SV *)newHV()));

  gql_store_sv(resolve_info_base_hv, "schema", gql_execution_share_or_copy_sv(schema));
  gql_store_sv(resolve_info_base_hv, "fragments", newRV_inc((SV *)fragments_hv));
  gql_store_sv(resolve_info_base_hv, "root_value", gql_execution_share_or_copy_sv(root_value));
  gql_store_sv(resolve_info_base_hv, "operation", gql_execution_share_or_copy_sv(operation_sv));
  gql_store_sv(resolve_info_base_hv, "variable_values", gql_execution_share_or_copy_sv(applied_variables_sv));
  gql_store_sv(resolve_info_base_hv, "promise_code", gql_execution_share_or_copy_sv(promise_code));
  gql_store_sv(context_hv, "resolve_info_base", newRV_noinc((SV *)resolve_info_base_hv));

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

  if (gql_execution_pp_bridge_profile_is_enabled()) {
    gql_execution_pp_bridge_profile_reset();
  }

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
  result = gql_execution_execute_prepared_context_xs_impl(aTHX_ context);
  gql_execution_pp_bridge_profile_report(aTHX_ "execute");

  /*
   * TODO: the execution path still shares Perl-side structures across the
   * PP/XS boundary. Keep the prepared AST/context alive for now rather than
   * risking premature destruction while the field loop is mid-migration.
   */
  return result;
}

static SV *
gql_execution_complete_value_catching_error_xs_lazy_impl(
  pTHX_ SV *context,
  SV *parent_type,
  SV *field_def,
  SV *return_type,
  SV *nodes,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *result
) {
  SV *promise_code = gql_execution_context_promise_code(context);

  if (result && SvROK(result) && sv_derived_from(result, "GraphQL::Error")) {
    SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
    SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
    return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
  }

  if (SvOK(promise_code) && result && SvROK(result)) {
    SV *is_promise_sv = gql_promise_call_is_promise(aTHX_ promise_code, result);
    int is_promise = SvTRUE(is_promise_sv);

    SvREFCNT_dec(is_promise_sv);
    if (is_promise) {
      SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
      SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
      return gql_execution_call_xs_then_complete_value(aTHX_ context, return_type, nodes, info, path, result);
    }
  }

  if (sv_derived_from(return_type, "GraphQL::Houtou::Type::NonNull")
      || sv_derived_from(return_type, "GraphQL::Type::NonNull")) {
    SV *inner_type = gql_execution_call_type_of(aTHX_ return_type);
    SV *completed = gql_execution_complete_value_catching_error_xs_lazy_impl(
      aTHX_ context,
      parent_type,
      field_def,
      inner_type,
      nodes,
      lazy_info,
      result
    );

    SvREFCNT_dec(inner_type);
    if (SvROK(completed) && SvTYPE(SvRV(completed)) == SVt_PVHV) {
      HV *completed_hv = (HV *)SvRV(completed);
      SV **data_svp = hv_fetch(completed_hv, "data", 4, 0);
      if (data_svp && !SvOK(*data_svp)) {
        SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
        SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
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
      || sv_does(return_type, "GraphQL::Role::Leaf")
      || sv_derived_from(return_type, "GraphQL::Houtou::Type::Scalar")
      || sv_derived_from(return_type, "GraphQL::Type::Scalar")
      || sv_derived_from(return_type, "GraphQL::Houtou::Type::Enum")
      || sv_derived_from(return_type, "GraphQL::Type::Enum")) {
    int ok = 0;
    SV *serialized = gql_execution_call_type_perl_to_graphql(aTHX_ return_type, result, &ok);

    if (!ok) {
      SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
      SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
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
      AV *completed_values_av = newAV();
      AV *data_av = newAV();
      AV *errors_av = newAV();
      I32 i;
      int promise_present = 0;

      for (i = 0; i <= result_len; i++) {
        SV **item_svp = av_fetch(result_av, i, 0);
        SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
        SV *item_path_sv = gql_execution_path_with_index(aTHX_ path, (IV)i);
        gql_execution_lazy_resolve_info_t item_lazy_info = *lazy_info;
        SV *completed;
        item_lazy_info.base_path_sv = NULL;
        item_lazy_info.result_name_sv = NULL;
        item_lazy_info.path_sv = item_path_sv;
        completed = gql_execution_complete_value_catching_error_xs_lazy_impl(
          aTHX_ context,
          parent_type,
          field_def,
          item_type,
          nodes,
          &item_lazy_info,
          item_svp ? *item_svp : &PL_sv_undef
        );

        if (SvOK(promise_code) && completed && SvROK(completed)) {
          SV *is_completed_promise_sv = gql_promise_call_is_promise(aTHX_ promise_code, completed);
          int is_completed_promise = SvTRUE(is_completed_promise_sv);

          SvREFCNT_dec(is_completed_promise_sv);
          if (is_completed_promise) {
            promise_present = 1;
            av_push(completed_values_av, completed);
            completed = NULL;
          }
        }

        if (completed && SvROK(completed) && SvTYPE(SvRV(completed)) == SVt_PVHV) {
          av_push(completed_values_av, completed);
          completed = NULL;
        } else if (!promise_present) {
          SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
          SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
          SvREFCNT_dec(item_path_sv);
          SvREFCNT_dec((SV *)completed_values_av);
          if (completed) {
            SvREFCNT_dec(completed);
          }
          SvREFCNT_dec(item_type);
          SvREFCNT_dec((SV *)data_av);
          SvREFCNT_dec((SV *)errors_av);
          return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
        } else if (completed) {
          SvREFCNT_dec(completed);
        }

        SvREFCNT_dec(item_path_sv);
      }

      if (promise_present) {
        SV *aggregate = gql_promise_call_all(aTHX_ promise_code, completed_values_av);
        SV *ret = gql_execution_call_xs_then_merge_completed_list(aTHX_ promise_code, aggregate);

        SvREFCNT_dec(aggregate);
        SvREFCNT_dec(item_type);
        SvREFCNT_dec((SV *)completed_values_av);
        SvREFCNT_dec((SV *)data_av);
        SvREFCNT_dec((SV *)errors_av);
        return ret;
      }

      for (i = 0; i <= av_len(completed_values_av); i++) {
        SV **completed_svp = av_fetch(completed_values_av, i, 0);
        HV *completed_hv;
        SV **data_svp;
        SV **item_errors_svp;

        if (!completed_svp || !SvROK(*completed_svp) || SvTYPE(SvRV(*completed_svp)) != SVt_PVHV) {
          continue;
        }

        completed_hv = (HV *)SvRV(*completed_svp);
        data_svp = hv_fetch(completed_hv, "data", 4, 0);
        item_errors_svp = hv_fetch(completed_hv, "errors", 6, 0);
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
      }

      SvREFCNT_dec(item_type);
      SvREFCNT_dec((SV *)completed_values_av);
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
    {
      SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
      SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
      return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
    }
  }

  if (sv_derived_from(return_type, "GraphQL::Houtou::Type::Object")
      || sv_derived_from(return_type, "GraphQL::Type::Object")) {
    SV *is_type_of_sv = gql_execution_get_object_is_type_of_sv(aTHX_ context, return_type);

    if (SvOK(is_type_of_sv)) {
      int type_ok = 0;
      SV *type_error = NULL;
      SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
      SV *type_match = gql_execution_call_is_type_of_cb(aTHX_ is_type_of_sv, result, context, info, &type_ok, &type_error);
      SvREFCNT_dec(is_type_of_sv);
      if (!type_ok || !SvTRUE(type_match)) {
        if (type_ok) {
          if (!SvTRUE(type_match)) {
            STRLEN type_len;
            STRLEN result_len;
            SV *type_name = gql_execution_call_type_to_string(aTHX_ return_type);
            const char *type_pv = SvPV(type_name, type_len);
            const char *result_pv;
            if (SvROK(result)) {
              result_pv = sv_reftype(SvRV(result), 0);
              result_len = strlen(result_pv);
            } else {
              result_pv = SvPV(result, result_len);
            }
            SV *message = newSVpvf(
              "Expected a value of type '%s' but received: '%s'.",
              type_pv,
              result_pv
            );
            SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
            SV *error_result = gql_execution_make_error_result(aTHX_ message, nodes, path);
            SvREFCNT_dec(type_name);
            SvREFCNT_dec(message);
            SvREFCNT_dec(type_match);
            return error_result;
          }
          SvREFCNT_dec(type_match);
        }
        if (type_error) {
          SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
          SV *error_result = gql_execution_make_error_result(aTHX_ type_error, nodes, path);
          SvREFCNT_dec(type_error);
          return error_result;
        }
        {
          SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
        return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
        }
      }
      SvREFCNT_dec(type_match);
    } else {
      int ok = 0;
      SV *subfields = gql_execution_collect_simple_object_fields(aTHX_ context, return_type, nodes, &ok);
      if (ok) {
        SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
        SV *ret = gql_execution_execute_fields(aTHX_ context, return_type, result, path, subfields);
        SvREFCNT_dec(subfields);
        return ret;
      }
    }

    {
      SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
      SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
      return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
    }
  }

  if (sv_does(return_type, "GraphQL::Houtou::Role::Abstract")
      || sv_does(return_type, "GraphQL::Role::Abstract")) {
    SV *resolve_type_sv;
    HV *context_hv = (SvROK(context) && SvTYPE(SvRV(context)) == SVt_PVHV) ? (HV *)SvRV(context) : NULL;
    SV **schema_svp = context_hv ? hv_fetch(context_hv, "schema", 6, 0) : NULL;
    resolve_type_sv = gql_execution_get_abstract_resolve_type_sv(aTHX_ context, return_type);

    if (SvOK(resolve_type_sv)) {
      int ok = 0;
      SV *resolve_error = NULL;
      SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
      SV *runtime_type_or_name = gql_execution_call_abstract_resolve_type_cb(
        aTHX_ resolve_type_sv,
        result,
        context,
        info,
        return_type,
        &ok,
        &resolve_error
      );

      SvREFCNT_dec(resolve_type_sv);
      if (ok && SvOK(runtime_type_or_name)) {
        SV *runtime_type = runtime_type_or_name;

        if (!SvROK(runtime_type_or_name) && schema_svp && SvROK(*schema_svp) && SvTYPE(SvRV(*schema_svp)) == SVt_PVHV) {
          HV *runtime_cache_hv = gql_execution_context_runtime_cache_hv(context);
          if (!runtime_cache_hv) {
            runtime_cache_hv = gql_execution_schema_runtime_cache_hv(aTHX_ *schema_svp);
          }
          SV **name2type_svp = runtime_cache_hv
            ? hv_fetch(runtime_cache_hv, "name2type", 9, 0)
            : hv_fetch((HV *)SvRV(*schema_svp), "name2type", 9, 0);
          if (name2type_svp && SvROK(*name2type_svp) && SvTYPE(SvRV(*name2type_svp)) == SVt_PVHV) {
            HE *runtime_he = hv_fetch_ent((HV *)SvRV(*name2type_svp), runtime_type_or_name, 0, 0);
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
          int possible_ok = 0;
          SV *condition_name_sv = gql_execution_type_name_sv(aTHX_ return_type);
          SV *runtime_name_sv = gql_execution_type_name_sv(aTHX_ runtime_type);
          int possible_match = gql_execution_possible_type_match_simple(
            aTHX_
            context,
            *schema_svp,
            return_type,
            condition_name_sv,
            runtime_type,
            runtime_name_sv,
            &possible_ok
          );
          SvREFCNT_dec(runtime_name_sv);
          SvREFCNT_dec(condition_name_sv);

          if (possible_ok && possible_match) {
            gql_ir_compiled_root_field_plan_t *native_field_plan
              = gql_execution_collect_single_node_concrete_native_field_plan(aTHX_ runtime_type, nodes);
            int plan_ok = 0;
            if (native_field_plan) {
              SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
              SV *completed = gql_ir_execute_native_field_plan(aTHX_ context, runtime_type, result, path, native_field_plan);
              SvREFCNT_dec(runtime_type_or_name);
              if (completed != &PL_sv_undef) {
                return completed;
              }
            } else {
              SV *field_plan_sv = gql_execution_collect_single_node_concrete_field_plan(aTHX_ runtime_type, nodes, &plan_ok);
              if (plan_ok) {
                SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
                SV *completed = gql_execution_execute_field_plan(aTHX_ context, runtime_type, result, path, field_plan_sv);
                SvREFCNT_dec(field_plan_sv);
                SvREFCNT_dec(runtime_type_or_name);
                if (completed != &PL_sv_undef) {
                  return completed;
                }
              }
            }
            {
              int object_ok = 0;
              SV *subfields = gql_execution_collect_simple_object_fields(aTHX_ context, runtime_type, nodes, &object_ok);
              if (object_ok) {
                SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
                SV *completed = gql_execution_execute_fields(aTHX_ context, runtime_type, result, path, subfields);
                SvREFCNT_dec(subfields);
                SvREFCNT_dec(runtime_type_or_name);
                return completed;
              }
            }

            SvREFCNT_dec(runtime_type_or_name);
            {
              SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
            return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
            }
          }
        }

        SvREFCNT_dec(runtime_type_or_name);
      } else if (ok) {
        SvREFCNT_dec(runtime_type_or_name);
      } else if (resolve_error) {
        SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
        SV *error_result = gql_execution_make_error_result(aTHX_ resolve_error, nodes, path);
        SvREFCNT_dec(resolve_error);
        return error_result;
      }
    } else {
      SvREFCNT_dec(resolve_type_sv);

      if (schema_svp && SvROK(*schema_svp) && SvTYPE(SvRV(*schema_svp)) == SVt_PVHV) {
        SV *possible_types_sv = gql_execution_schema_possible_types_sv(aTHX_ *schema_svp, return_type);
        if (possible_types_sv != &PL_sv_undef) {
          I32 possible_i;
          I32 possible_len;

          if (SvROK(possible_types_sv) && SvTYPE(SvRV(possible_types_sv)) == SVt_PVAV) {
            possible_len = av_len((AV *)SvRV(possible_types_sv));
            for (possible_i = 0; possible_i <= possible_len; possible_i++) {
              SV **possible_svp = av_fetch((AV *)SvRV(possible_types_sv), possible_i, 0);
              if (possible_svp && SvROK(*possible_svp)) {
                SV *possible_type = *possible_svp;
                SV *is_type_of_sv = gql_execution_get_object_is_type_of_sv(aTHX_ context, possible_type);
                if (SvOK(is_type_of_sv)) {
                  int match_ok = 0;
                  SV *match_error = NULL;
                  SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
                  SV *type_match = gql_execution_call_is_type_of_cb(aTHX_ is_type_of_sv, result, context, info, &match_ok, &match_error);
                  SvREFCNT_dec(is_type_of_sv);
                  if (match_ok && SvTRUE(type_match)) {
                    gql_ir_compiled_root_field_plan_t *native_field_plan
                      = gql_execution_collect_single_node_concrete_native_field_plan(aTHX_ possible_type, nodes);
                    int plan_ok = 0;
                    if (native_field_plan) {
                      SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
                      SV *completed = gql_ir_execute_native_field_plan(aTHX_ context, possible_type, result, path, native_field_plan);
                      SvREFCNT_dec(type_match);
                      SvREFCNT_dec(possible_types_sv);
                      if (completed != &PL_sv_undef) {
                        return completed;
                      }
                    } else {
                      SV *field_plan_sv = gql_execution_collect_single_node_concrete_field_plan(aTHX_ possible_type, nodes, &plan_ok);
                      if (plan_ok) {
                        SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
                        SV *completed = gql_execution_execute_field_plan(aTHX_ context, possible_type, result, path, field_plan_sv);
                        SvREFCNT_dec(field_plan_sv);
                        SvREFCNT_dec(type_match);
                        SvREFCNT_dec(possible_types_sv);
                        if (completed != &PL_sv_undef) {
                          return completed;
                        }
                      }
                    }
                    {
                      int object_ok = 0;
                      SV *subfields = gql_execution_collect_simple_object_fields(aTHX_ context, possible_type, nodes, &object_ok);
                      if (object_ok) {
                        SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
                        SV *completed = gql_execution_execute_fields(aTHX_ context, possible_type, result, path, subfields);
                        SvREFCNT_dec(subfields);
                        SvREFCNT_dec(type_match);
                        SvREFCNT_dec(possible_types_sv);
                        return completed;
                      }
                    }

                    SvREFCNT_dec(type_match);
                    SvREFCNT_dec(possible_types_sv);
                    {
                      SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
                    return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
                    }
                  }
                  if (match_ok) {
                    SvREFCNT_dec(type_match);
                  } else if (match_error) {
                    SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
                    SV *error_result = gql_execution_make_error_result(aTHX_ match_error, nodes, path);
                    SvREFCNT_dec(match_error);
                    SvREFCNT_dec(possible_types_sv);
                    return error_result;
                  }
                } else {
                  SvREFCNT_dec(is_type_of_sv);
                }
              }
            }
          }

          SvREFCNT_dec(possible_types_sv);
        }
      }
    }

    {
      SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
      SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
      return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
    }
  }

  {
    SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
    SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
    return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, return_type, nodes, info, path, result);
  }
}

static SV *
gql_execution_complete_field_value_catching_error_xs_impl(
  pTHX_ SV *context,
  SV *parent_type,
  SV *field_def,
  SV *nodes,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *result
) {
  HV *field_def_hv;
  SV **type_svp;
  SV *return_type;

  if (!field_def || !SvROK(field_def) || SvTYPE(SvRV(field_def)) != SVt_PVHV) {
    SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
    SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
    return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, field_def, nodes, info, path, result);
  }

  field_def_hv = (HV *)SvRV(field_def);
  type_svp = hv_fetch(field_def_hv, "type", 4, 0);
  if (!type_svp || !SvOK(*type_svp)) {
    SV *info = gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
    SV *path = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
    return gql_execution_call_pp_complete_value_catching_error(aTHX_ context, field_def, nodes, info, path, result);
  }
  return_type = *type_svp;

  return gql_execution_complete_value_catching_error_xs_lazy_impl(
    aTHX_
    context,
    parent_type,
    field_def,
    return_type,
    nodes,
    lazy_info,
    result
  );
}

static SV *
gql_execution_complete_value_catching_error_xs_impl(pTHX_ SV *context, SV *return_type, SV *nodes, SV *info, SV *path, SV *result) {
  gql_execution_lazy_resolve_info_t lazy_info;

  Zero(&lazy_info, 1, gql_execution_lazy_resolve_info_t);
  lazy_info.context_sv = context;
  lazy_info.nodes_sv = nodes;
  lazy_info.path_sv = path;
  lazy_info.info_sv = info;

  return gql_execution_complete_value_catching_error_xs_lazy_impl(
    aTHX_
    context,
    &PL_sv_undef,
    &PL_sv_undef,
    return_type,
    nodes,
    &lazy_info,
    result
  );
}

static SV *
gql_execution_build_resolve_info(pTHX_ SV *context, SV *parent_type, SV *field_def, SV *path, SV *nodes) {
  HV *info_hv = newHV();
  HV *context_hv;
  gql_execution_context_fast_cache_t *context_cache;
  HV *resolve_info_base_hv = NULL;
  AV *nodes_av;
  SV **field_node_svp;
  HV *field_node_hv;
  SV **field_name_svp;
  HV *field_def_hv;
  SV **return_type_svp;
  SV **resolve_info_base_svp;
  SV **schema_svp = NULL;
  SV **fragments_svp = NULL;
  SV **root_value_svp = NULL;
  SV **operation_svp = NULL;
  SV **variable_values_svp = NULL;
  SV **promise_code_svp = NULL;

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
  context_cache = gql_execution_context_fast_cache(aTHX_ context);
  if (context_cache && context_cache->resolve_info_base_hv) {
    resolve_info_base_hv = context_cache->resolve_info_base_hv;
  }
  resolve_info_base_svp = hv_fetch(context_hv, "resolve_info_base", 17, 0);
  if (!resolve_info_base_hv
      && resolve_info_base_svp
      && SvROK(*resolve_info_base_svp)
      && SvTYPE(SvRV(*resolve_info_base_svp)) == SVt_PVHV) {
    resolve_info_base_hv = (HV *)SvRV(*resolve_info_base_svp);
  }
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

  if (resolve_info_base_hv) {
    schema_svp = hv_fetch(resolve_info_base_hv, "schema", 6, 0);
    fragments_svp = hv_fetch(resolve_info_base_hv, "fragments", 9, 0);
    root_value_svp = hv_fetch(resolve_info_base_hv, "root_value", 10, 0);
    operation_svp = hv_fetch(resolve_info_base_hv, "operation", 9, 0);
    variable_values_svp = hv_fetch(resolve_info_base_hv, "variable_values", 15, 0);
    promise_code_svp = hv_fetch(resolve_info_base_hv, "promise_code", 12, 0);
  } else {
    if (context_cache) {
      schema_svp = context_cache->schema_sv ? &context_cache->schema_sv : NULL;
      fragments_svp = context_cache->fragments_sv ? &context_cache->fragments_sv : NULL;
      root_value_svp = context_cache->root_value_sv ? &context_cache->root_value_sv : NULL;
      operation_svp = context_cache->operation_sv ? &context_cache->operation_sv : NULL;
      variable_values_svp = context_cache->variable_values_sv ? &context_cache->variable_values_sv : NULL;
      promise_code_svp = context_cache->promise_code_sv ? &context_cache->promise_code_sv : NULL;
    } else {
      schema_svp = hv_fetch(context_hv, "schema", 6, 0);
      fragments_svp = hv_fetch(context_hv, "fragments", 9, 0);
      root_value_svp = hv_fetch(context_hv, "root_value", 10, 0);
      operation_svp = hv_fetch(context_hv, "operation", 9, 0);
      variable_values_svp = hv_fetch(context_hv, "variable_values", 15, 0);
      promise_code_svp = hv_fetch(context_hv, "promise_code", 12, 0);
    }
  }

  gql_store_sv(info_hv, "schema", (schema_svp && SvOK(*schema_svp)) ? gql_execution_share_or_copy_sv(*schema_svp) : newSV(0));
  gql_store_sv(info_hv, "fragments", (fragments_svp && SvOK(*fragments_svp)) ? gql_execution_share_or_copy_sv(*fragments_svp) : newSV(0));
  gql_store_sv(info_hv, "root_value", (root_value_svp && SvOK(*root_value_svp)) ? gql_execution_share_or_copy_sv(*root_value_svp) : newSV(0));
  gql_store_sv(info_hv, "operation", (operation_svp && SvOK(*operation_svp)) ? gql_execution_share_or_copy_sv(*operation_svp) : newSV(0));
  gql_store_sv(info_hv, "variable_values", (variable_values_svp && SvOK(*variable_values_svp)) ? gql_execution_share_or_copy_sv(*variable_values_svp) : newSV(0));
  gql_store_sv(info_hv, "promise_code", (promise_code_svp && SvOK(*promise_code_svp)) ? gql_execution_share_or_copy_sv(*promise_code_svp) : newSV(0));
  gql_store_sv(info_hv, "field_name", newSVsv(*field_name_svp));
  gql_store_sv(info_hv, "field_nodes", gql_execution_share_or_copy_sv(nodes));
  gql_store_sv(info_hv, "return_type", gql_execution_share_or_copy_sv(*return_type_svp));
  gql_store_sv(info_hv, "parent_type", gql_execution_share_or_copy_sv(parent_type));
  gql_store_sv(info_hv, "path", gql_execution_share_or_copy_sv(path));

  return newRV_noinc((SV *)info_hv);
}

static SV *
gql_execution_lazy_path_materialize(pTHX_ gql_execution_lazy_resolve_info_t *lazy_info) {
  if (!lazy_info) {
    croak("lazy path is required");
  }
  if (!lazy_info->path_sv) {
    if (lazy_info->base_path_sv && lazy_info->result_name_sv) {
      lazy_info->path_sv = gql_execution_path_with_key(aTHX_ lazy_info->base_path_sv, lazy_info->result_name_sv);
    } else if (lazy_info->base_path_sv) {
      lazy_info->path_sv = SvREFCNT_inc_simple_NN(lazy_info->base_path_sv);
    } else {
      lazy_info->path_sv = newRV_noinc((SV *)newAV());
    }
  }
  return lazy_info->path_sv;
}

static SV *
gql_execution_lazy_resolve_info_materialize(pTHX_ gql_execution_lazy_resolve_info_t *lazy_info) {
  if (!lazy_info) {
    croak("lazy resolve info is required");
  }
  if (!lazy_info->info_sv) {
    SV *path_sv = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
    lazy_info->info_sv = gql_execution_build_resolve_info(
      aTHX_
      lazy_info->context_sv,
      lazy_info->parent_type_sv,
      lazy_info->field_def_sv,
      path_sv,
      lazy_info->nodes_sv
    );
  }
  return lazy_info->info_sv;
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
  HV *runtime_cache_hv;
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
      static CV *cv = NULL;

      if (!cv) {
        cv = gql_execution_pp_cv(aTHX_ "GraphQL::Houtou::Execution::PP::_get_field_def");
      }

      ENTER;
      SAVETMPS;
      PUSHMARK(SP);
      XPUSHs(sv_2mortal(newSVsv(schema)));
      XPUSHs(sv_2mortal(newSVsv(parent_type)));
      XPUSHs(sv_2mortal(newSVsv(field_name)));
      PUTBACK;
      count = call_sv((SV *)cv, G_SCALAR);
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
  runtime_cache_hv = gql_execution_schema_runtime_cache_hv(aTHX_ schema);
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
  if (runtime_cache_hv) {
    SV **field_maps_svp = hv_fetch(runtime_cache_hv, "field_maps", 10, 0);
    if (field_maps_svp && SvROK(*field_maps_svp) && SvTYPE(SvRV(*field_maps_svp)) == SVt_PVHV) {
      SV **type_name_svp = hv_fetch(parent_type_hv, "name", 4, 0);
      if (type_name_svp && SvOK(*type_name_svp)) {
        HE *type_fields_he = hv_fetch_ent((HV *)SvRV(*field_maps_svp), *type_name_svp, 0, 0);
        if (type_fields_he && SvROK(HeVAL(type_fields_he)) && SvTYPE(SvRV(HeVAL(type_fields_he))) == SVt_PVHV) {
          field_he = hv_fetch_ent((HV *)SvRV(HeVAL(type_fields_he)), field_name, 0, 0);
          if (field_he) {
            return newSVsv(HeVAL(field_he));
          }
          return &PL_sv_undef;
        }
      }
    }
  }

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
  gql_execution_context_fast_cache_t *context_cache;
  SV **schema_svp;
  SV **context_value_svp;
  SV **variable_values_svp;
  SV **empty_args_svp;
  SV **field_resolver_svp;
  SV **promise_code_svp;
  SV **compiled_root_field_defs_svp;
  SV *promise_code_sv = &PL_sv_undef;
  AV *field_names_av;
  HV *nodes_defs_hv;
  AV *result_keys_av = newAV();
  AV *result_values_av = newAV();
  AV *all_errors_av = newAV();
  AV *fields_av;
  I32 field_len;
  I32 i;
  int promise_present = 0;

  if (!SvROK(fields) || SvTYPE(SvRV(fields)) != SVt_PVAV) {
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)all_errors_av);
    croak("fields must be an array reference");
  }

  if (!SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)all_errors_av);
    croak("context must be a hash reference");
  }

  context_hv = (HV *)SvRV(context);
  context_cache = gql_execution_context_fast_cache(aTHX_ context);
  if (context_cache) {
    schema_svp = context_cache->schema_sv ? &context_cache->schema_sv : NULL;
    context_value_svp = context_cache->context_value_sv ? &context_cache->context_value_sv : NULL;
    variable_values_svp = context_cache->variable_values_sv ? &context_cache->variable_values_sv : NULL;
    empty_args_svp = context_cache->empty_args_sv ? &context_cache->empty_args_sv : NULL;
    field_resolver_svp = context_cache->field_resolver_sv ? &context_cache->field_resolver_sv : NULL;
    promise_code_svp = context_cache->promise_code_sv ? &context_cache->promise_code_sv : NULL;
    compiled_root_field_defs_svp = context_cache->compiled_root_field_defs_sv ? &context_cache->compiled_root_field_defs_sv : NULL;
  } else {
    schema_svp = hv_fetch(context_hv, "schema", 6, 0);
    context_value_svp = hv_fetch(context_hv, "context_value", 13, 0);
    variable_values_svp = hv_fetch(context_hv, "variable_values", 15, 0);
    empty_args_svp = hv_fetch(context_hv, "empty_args", 10, 0);
    field_resolver_svp = hv_fetch(context_hv, "field_resolver", 14, 0);
    promise_code_svp = hv_fetch(context_hv, "promise_code", 12, 0);
    compiled_root_field_defs_svp = hv_fetch(context_hv, "compiled_root_field_defs", 24, 0);
  }
  if (promise_code_svp && SvOK(*promise_code_svp)) {
    promise_code_sv = *promise_code_svp;
  }
  if (!schema_svp || !SvOK(*schema_svp)) {
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)all_errors_av);
    croak("execution context has no schema");
  }

  fields_av = (AV *)SvRV(fields);
  if (av_len(fields_av) != 1) {
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)all_errors_av);
    croak("fields must contain names and node definitions");
  }

  {
    SV **field_names_svp = av_fetch(fields_av, 0, 0);
    SV **nodes_defs_svp = av_fetch(fields_av, 1, 0);

    if (!field_names_svp || !SvROK(*field_names_svp) || SvTYPE(SvRV(*field_names_svp)) != SVt_PVAV ||
        !nodes_defs_svp || !SvROK(*nodes_defs_svp) || SvTYPE(SvRV(*nodes_defs_svp)) != SVt_PVHV) {
      SvREFCNT_dec((SV *)result_keys_av);
      SvREFCNT_dec((SV *)result_values_av);
      SvREFCNT_dec((SV *)all_errors_av);
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
    SV *path_copy_sv = NULL;
    SV *info_sv = NULL;
    SV *result_sv = NULL;
    SV *completed_sv = NULL;
    SV *args_sv = NULL;
    gql_execution_lazy_resolve_info_t lazy_info;
    SV **type_svp;
    SV **field_args_svp;
    SV **node_args_svp;
    int used_fast_default_resolve = 0;
    int is_completed_promise = 0;
    int owns_field_def_sv = 0;
    int owns_resolve_sv = 0;
    int owns_args_sv = 0;

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

    {
      SV **compiled_field_def_svp = hv_fetch(field_node_hv, "compiled_field_def", 18, 0);
      if (compiled_field_def_svp && SvOK(*compiled_field_def_svp)) {
        field_def_sv = *compiled_field_def_svp;
      } else if (compiled_root_field_defs_svp
        && SvOK(*compiled_root_field_defs_svp)
        && gql_execution_path_is_root(path)
        && SvROK(*compiled_root_field_defs_svp)
        && SvTYPE(SvRV(*compiled_root_field_defs_svp)) == SVt_PVHV) {
        HE *compiled_field_he = hv_fetch_ent((HV *)SvRV(*compiled_root_field_defs_svp), *result_name_svp, 0, 0);
        if (compiled_field_he
            && SvROK(HeVAL(compiled_field_he))
            && SvTYPE(SvRV(HeVAL(compiled_field_he))) == SVt_PVHV) {
          HV *compiled_field_hv = (HV *)SvRV(HeVAL(compiled_field_he));
          SV **compiled_root_field_def_svp = hv_fetch(compiled_field_hv, "field_def", 9, 0);
          field_def_sv = (compiled_root_field_def_svp && SvOK(*compiled_root_field_def_svp))
            ? *compiled_root_field_def_svp
            : &PL_sv_undef;
        } else {
          field_def_sv = gql_execution_get_field_def(aTHX_ *schema_svp, parent_type, *field_name_svp);
          owns_field_def_sv = 1;
        }
      } else {
        field_def_sv = gql_execution_get_field_def(aTHX_ *schema_svp, parent_type, *field_name_svp);
        owns_field_def_sv = 1;
      }
    }
    if (!SvOK(field_def_sv) || field_def_sv == &PL_sv_undef) {
      if (owns_field_def_sv && field_def_sv != &PL_sv_undef) {
        SvREFCNT_dec(field_def_sv);
      }
      continue;
    }

    if (!SvROK(field_def_sv) || SvTYPE(SvRV(field_def_sv)) != SVt_PVHV) {
      if (owns_field_def_sv) {
        SvREFCNT_dec(field_def_sv);
      }
      continue;
    }

    field_def_hv = (HV *)SvRV(field_def_sv);
    type_svp = hv_fetch(field_def_hv, "type", 4, 0);
    if (!type_svp || !SvOK(*type_svp)) {
      if (owns_field_def_sv) {
        SvREFCNT_dec(field_def_sv);
      }
      continue;
    }
    Zero(&lazy_info, 1, gql_execution_lazy_resolve_info_t);
    lazy_info.context_sv = context;
    lazy_info.parent_type_sv = parent_type;
    lazy_info.field_def_sv = field_def_sv;
    lazy_info.nodes_sv = nodes_sv;
    lazy_info.base_path_sv = path;
    lazy_info.result_name_sv = *result_name_svp;
    lazy_info.base_path_sv = path;
    lazy_info.result_name_sv = *result_name_svp;
    if (gql_execution_try_typename_meta_field_fast(aTHX_ parent_type, *field_name_svp, *type_svp, &completed_sv)) {
      goto have_completed;
    }
    resolve_svp = hv_fetch(field_def_hv, "resolve", 7, 0);
    if (resolve_svp && SvOK(*resolve_svp)) {
      resolve_sv = *resolve_svp;
    } else {
      resolve_sv = (field_resolver_svp && SvOK(*field_resolver_svp))
        ? *field_resolver_svp
        : newSV(0);
      owns_resolve_sv = !(field_resolver_svp && SvOK(*field_resolver_svp));
    }

    if (gql_execution_is_default_field_resolver(aTHX_ resolve_sv)
        && gql_execution_try_default_field_resolve_fast(aTHX_ root_value, *field_name_svp, &result_sv)) {
      used_fast_default_resolve = 1;
      if (gql_execution_try_complete_trivial_value_fast(aTHX_ *type_svp, result_sv, &completed_sv)) {
        goto have_completed;
      }
    }

    if (!used_fast_default_resolve) {
      info_sv = gql_execution_lazy_resolve_info_materialize(aTHX_ &lazy_info);
      field_args_svp = hv_fetch(field_def_hv, "args", 4, 0);
      node_args_svp = hv_fetch(field_node_hv, "arguments", 9, 0);
      if ((!field_args_svp || !SvOK(*field_args_svp)
           || (SvROK(*field_args_svp) && SvTYPE(SvRV(*field_args_svp)) == SVt_PVHV && HvUSEDKEYS((HV *)SvRV(*field_args_svp)) == 0))
          && (!node_args_svp || !SvOK(*node_args_svp)
              || (SvROK(*node_args_svp) && SvTYPE(SvRV(*node_args_svp)) == SVt_PVHV && HvUSEDKEYS((HV *)SvRV(*node_args_svp)) == 0))) {
        if (empty_args_svp && SvOK(*empty_args_svp)) {
          args_sv = *empty_args_svp;
        } else {
          args_sv = newRV_noinc((SV *)newHV());
          owns_args_sv = 1;
        }
      } else {
        args_sv = gql_execution_get_argument_values_xs_impl(
          aTHX_ field_def_sv,
          *field_node_svp,
          (variable_values_svp && SvOK(*variable_values_svp)) ? *variable_values_svp : &PL_sv_undef
        );
        owns_args_sv = 1;
      }

      result_sv = gql_execution_call_resolver(
        aTHX_ resolve_sv,
        root_value,
        args_sv,
        (context_value_svp && SvOK(*context_value_svp)) ? *context_value_svp : &PL_sv_undef,
        info_sv
      );
    }

    completed_sv = gql_execution_complete_field_value_catching_error_xs_impl(
      aTHX_ context,
      parent_type,
      field_def_sv,
      nodes_sv,
      &lazy_info,
      result_sv
    );

have_completed:
    if (SvOK(promise_code_sv) && completed_sv && SvROK(completed_sv)) {
      SV *is_completed_promise_sv = gql_promise_call_is_promise(aTHX_ promise_code_sv, completed_sv);
      is_completed_promise = SvTRUE(is_completed_promise_sv);

      SvREFCNT_dec(is_completed_promise_sv);
      if (is_completed_promise) {
        promise_present = 1;
      }
    }

    if (SvROK(completed_sv) && (SvTYPE(SvRV(completed_sv)) == SVt_PVHV || is_completed_promise)) {
      av_push(result_keys_av, SvREFCNT_inc_simple_NN(*result_name_svp));
      av_push(result_values_av, completed_sv);
      completed_sv = NULL;
    }

    if (lazy_info.info_sv) {
      SvREFCNT_dec(lazy_info.info_sv);
    }
    if (owns_args_sv) {
      SvREFCNT_dec(args_sv);
    }
    if (result_sv) {
      SvREFCNT_dec(result_sv);
    }
    if (owns_resolve_sv) {
      SvREFCNT_dec(resolve_sv);
    }
    if (lazy_info.path_sv) {
      path_copy_sv = lazy_info.path_sv;
    }
    if (path_copy_sv) {
      SvREFCNT_dec(path_copy_sv);
    }
    if (owns_field_def_sv) {
      SvREFCNT_dec(field_def_sv);
    }
    if (completed_sv) {
      SvREFCNT_dec(completed_sv);
    }
  }

  if (promise_present) {
    SV *aggregate = gql_promise_call_all(aTHX_ promise_code_sv, result_values_av);
    SV *ret = gql_execution_call_xs_then_merge_hash(aTHX_ promise_code_sv, result_keys_av, aggregate, all_errors_av);

    SvREFCNT_dec(aggregate);
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)all_errors_av);
    return ret;
  }

  {
    SV *ret = gql_execution_merge_hash(aTHX_ result_keys_av, result_values_av, all_errors_av);
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)all_errors_av);
    return ret;
  }
}

static SV *
gql_execution_execute_field_plan(pTHX_ SV *context, SV *parent_type, SV *root_value, SV *path, SV *field_plan) {
  HV *context_hv;
  HV *field_plan_hv;
  gql_execution_context_fast_cache_t *context_cache;
  SV **context_value_svp;
  SV **variable_values_svp;
  SV **empty_args_svp;
  SV **field_resolver_svp;
  SV **promise_code_svp;
  SV **field_order_svp;
  SV **fields_svp;
  SV *promise_code_sv = &PL_sv_undef;
  AV *field_order_av;
  HV *fields_hv;
  AV *result_keys_av = newAV();
  AV *result_values_av = newAV();
  AV *all_errors_av = newAV();
  I32 field_len;
  I32 i;
  int promise_present = 0;

  if (!field_plan || !SvROK(field_plan) || SvTYPE(SvRV(field_plan)) != SVt_PVHV) {
    goto fallback;
  }
  if (!context || !SvROK(context) || SvTYPE(SvRV(context)) != SVt_PVHV) {
    goto fallback;
  }

  context_hv = (HV *)SvRV(context);
  field_plan_hv = (HV *)SvRV(field_plan);
  context_cache = gql_execution_context_fast_cache(aTHX_ context);
  if (context_cache) {
    context_value_svp = context_cache->context_value_sv ? &context_cache->context_value_sv : NULL;
    variable_values_svp = context_cache->variable_values_sv ? &context_cache->variable_values_sv : NULL;
    empty_args_svp = context_cache->empty_args_sv ? &context_cache->empty_args_sv : NULL;
    field_resolver_svp = context_cache->field_resolver_sv ? &context_cache->field_resolver_sv : NULL;
    promise_code_svp = context_cache->promise_code_sv ? &context_cache->promise_code_sv : NULL;
  } else {
    context_value_svp = hv_fetch(context_hv, "context_value", 13, 0);
    variable_values_svp = hv_fetch(context_hv, "variable_values", 15, 0);
    empty_args_svp = hv_fetch(context_hv, "empty_args", 10, 0);
    field_resolver_svp = hv_fetch(context_hv, "field_resolver", 14, 0);
    promise_code_svp = hv_fetch(context_hv, "promise_code", 12, 0);
  }
  field_order_svp = hv_fetch(field_plan_hv, "field_order", 11, 0);
  fields_svp = hv_fetch(field_plan_hv, "fields", 6, 0);

  if (promise_code_svp && SvOK(*promise_code_svp)) {
    promise_code_sv = *promise_code_svp;
  }
  if (!field_order_svp
      || !SvROK(*field_order_svp)
      || SvTYPE(SvRV(*field_order_svp)) != SVt_PVAV
      || !fields_svp
      || !SvROK(*fields_svp)
      || SvTYPE(SvRV(*fields_svp)) != SVt_PVHV) {
    goto fallback;
  }

  field_order_av = (AV *)SvRV(*field_order_svp);
  fields_hv = (HV *)SvRV(*fields_svp);
  field_len = av_len(field_order_av);

  for (i = 0; i <= field_len; i++) {
    SV **result_name_svp = av_fetch(field_order_av, i, 0);
    HE *field_plan_he;
    HV *entry_hv;
    SV **field_def_svp;
    SV **nodes_svp;
    SV *field_def_sv;
    HV *field_def_hv;
    SV *nodes_sv;
    AV *nodes_av;
    SV **field_node_svp;
    HV *field_node_hv;
    SV **field_name_svp;
    SV **resolve_svp;
    SV *resolve_sv;
    SV *path_copy_sv = NULL;
    SV *info_sv = NULL;
    SV *args_sv = NULL;
    gql_execution_lazy_resolve_info_t lazy_info;
    SV **type_svp;
    SV **node_args_svp;
    SV **field_args_svp;
    SV *result_sv = NULL;
    SV *completed_sv = NULL;
    int used_fast_default_resolve = 0;
    int is_completed_promise = 0;
    int owns_resolve_sv = 0;
    int owns_args_sv = 0;

    if (!result_name_svp || !SvOK(*result_name_svp)) {
      continue;
    }

    field_plan_he = hv_fetch_ent(fields_hv, *result_name_svp, 0, 0);
    if (!field_plan_he || !SvROK(HeVAL(field_plan_he)) || SvTYPE(SvRV(HeVAL(field_plan_he))) != SVt_PVHV) {
      goto fallback;
    }

    entry_hv = (HV *)SvRV(HeVAL(field_plan_he));
    field_def_svp = hv_fetch(entry_hv, "field_def", 9, 0);
    nodes_svp = hv_fetch(entry_hv, "nodes", 5, 0);
    if (!field_def_svp || !SvOK(*field_def_svp) || !nodes_svp || !SvOK(*nodes_svp)) {
      goto fallback;
    }

    field_def_sv = *field_def_svp;
    nodes_sv = *nodes_svp;
    if (!SvROK(field_def_sv) || SvTYPE(SvRV(field_def_sv)) != SVt_PVHV || !SvROK(nodes_sv) || SvTYPE(SvRV(nodes_sv)) != SVt_PVAV) {
      goto fallback;
    }

    nodes_av = (AV *)SvRV(nodes_sv);
    field_node_svp = av_fetch(nodes_av, 0, 0);
    if (!field_node_svp || !SvROK(*field_node_svp) || SvTYPE(SvRV(*field_node_svp)) != SVt_PVHV) {
      goto fallback;
    }
    field_node_hv = (HV *)SvRV(*field_node_svp);
    field_name_svp = hv_fetch(field_node_hv, "name", 4, 0);
    if (!field_name_svp || !SvOK(*field_name_svp)) {
      goto fallback;
    }
    field_def_hv = (HV *)SvRV(field_def_sv);
    type_svp = hv_fetch(field_def_hv, "type", 4, 0);
    if (!type_svp || !SvOK(*type_svp)) {
      goto fallback;
    }
    Zero(&lazy_info, 1, gql_execution_lazy_resolve_info_t);
    lazy_info.context_sv = context;
    lazy_info.parent_type_sv = parent_type;
    lazy_info.field_def_sv = field_def_sv;
    lazy_info.nodes_sv = nodes_sv;
    if (gql_execution_try_typename_meta_field_fast(aTHX_ parent_type, *field_name_svp, *type_svp, &completed_sv)) {
      goto have_completed;
    }

    resolve_svp = hv_fetch(field_def_hv, "resolve", 7, 0);
    if (resolve_svp && SvOK(*resolve_svp)) {
      resolve_sv = *resolve_svp;
    } else {
      resolve_sv = (field_resolver_svp && SvOK(*field_resolver_svp)) ? *field_resolver_svp : newSV(0);
      owns_resolve_sv = !(field_resolver_svp && SvOK(*field_resolver_svp));
    }

    if (gql_execution_is_default_field_resolver(aTHX_ resolve_sv)
        && gql_execution_try_default_field_resolve_fast(aTHX_ root_value, *field_name_svp, &result_sv)) {
      used_fast_default_resolve = 1;
      if (gql_execution_try_complete_trivial_value_fast(aTHX_ *type_svp, result_sv, &completed_sv)) {
        goto have_completed;
      }
    }

    if (!used_fast_default_resolve) {
      info_sv = gql_execution_lazy_resolve_info_materialize(aTHX_ &lazy_info);
      field_args_svp = hv_fetch(field_def_hv, "args", 4, 0);
      node_args_svp = hv_fetch(field_node_hv, "arguments", 9, 0);
      if ((!field_args_svp || !SvOK(*field_args_svp)
           || (SvROK(*field_args_svp) && SvTYPE(SvRV(*field_args_svp)) == SVt_PVHV && HvUSEDKEYS((HV *)SvRV(*field_args_svp)) == 0))
          && (!node_args_svp || !SvOK(*node_args_svp)
              || (SvROK(*node_args_svp) && SvTYPE(SvRV(*node_args_svp)) == SVt_PVHV && HvUSEDKEYS((HV *)SvRV(*node_args_svp)) == 0))) {
        if (empty_args_svp && SvOK(*empty_args_svp)) {
          args_sv = *empty_args_svp;
        } else {
          args_sv = newRV_noinc((SV *)newHV());
          owns_args_sv = 1;
        }
      } else {
        args_sv = gql_execution_get_argument_values_xs_impl(
          aTHX_ field_def_sv,
          *field_node_svp,
          (variable_values_svp && SvOK(*variable_values_svp)) ? *variable_values_svp : &PL_sv_undef
        );
        owns_args_sv = 1;
      }

      result_sv = gql_execution_call_resolver(
        aTHX_
        resolve_sv,
        root_value,
        args_sv,
        (context_value_svp && SvOK(*context_value_svp)) ? *context_value_svp : &PL_sv_undef,
        info_sv
      );
    }

    completed_sv = gql_execution_complete_field_value_catching_error_xs_impl(
      aTHX_
      context,
      parent_type,
      field_def_sv,
      nodes_sv,
      &lazy_info,
      result_sv
    );

have_completed:
    if (SvOK(promise_code_sv) && completed_sv && SvROK(completed_sv)) {
      SV *is_completed_promise_sv = gql_promise_call_is_promise(aTHX_ promise_code_sv, completed_sv);
      is_completed_promise = SvTRUE(is_completed_promise_sv);
      SvREFCNT_dec(is_completed_promise_sv);
      if (is_completed_promise) {
        promise_present = 1;
      }
    }

    if (SvROK(completed_sv) && (SvTYPE(SvRV(completed_sv)) == SVt_PVHV || is_completed_promise)) {
      av_push(result_keys_av, SvREFCNT_inc_simple_NN(*result_name_svp));
      av_push(result_values_av, completed_sv);
      completed_sv = NULL;
    }

    if (lazy_info.info_sv) {
      SvREFCNT_dec(lazy_info.info_sv);
    }
    if (owns_args_sv) {
      SvREFCNT_dec(args_sv);
    }
    if (result_sv) {
      SvREFCNT_dec(result_sv);
    }
    if (owns_resolve_sv) {
      SvREFCNT_dec(resolve_sv);
    }
    if (lazy_info.path_sv) {
      path_copy_sv = lazy_info.path_sv;
    }
    if (path_copy_sv) {
      SvREFCNT_dec(path_copy_sv);
    }
    if (completed_sv) {
      SvREFCNT_dec(completed_sv);
    }
  }

  if (promise_present) {
    SV *aggregate = gql_promise_call_all(aTHX_ promise_code_sv, result_values_av);
    SV *ret = gql_execution_call_xs_then_merge_hash(aTHX_ promise_code_sv, result_keys_av, aggregate, all_errors_av);

    SvREFCNT_dec(aggregate);
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)all_errors_av);
    return ret;
  }

  {
    SV *ret = gql_execution_merge_hash(aTHX_ result_keys_av, result_values_av, all_errors_av);
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)all_errors_av);
    return ret;
  }

fallback:
  SvREFCNT_dec((SV *)result_keys_av);
  SvREFCNT_dec((SV *)result_values_av);
  SvREFCNT_dec((SV *)all_errors_av);
  return &PL_sv_undef;
}
