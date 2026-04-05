/*
 * Responsibility: provide the initial XS execution entrypoint so the public
 * execution facade can prefer XS while the actual execution engine migrates
 * from PP to C incrementally.
 */

static void
gql_execution_require_pp(pTHX) {
  eval_pv("require GraphQL::Houtou::Execution::PP; 1;", TRUE);
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

  if (!SvOK(operation_name) || operation_name == &PL_sv_undef) {
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

  SvREFCNT_dec(ast);
  SvREFCNT_dec(context);
  return result;
}
