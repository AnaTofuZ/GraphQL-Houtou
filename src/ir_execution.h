/*
 * Responsibility: prepared executable IR handle ownership and small
 * introspection helpers used as groundwork for future IR-direct execution.
 */
static void
gql_ir_prepared_exec_destroy(gql_ir_prepared_exec_t *prepared) {
  if (!prepared) {
    return;
  }

  if (prepared->document) {
    gql_ir_free_document(prepared->document);
    prepared->document = NULL;
  }
  if (prepared->source_sv) {
    SvREFCNT_dec(prepared->source_sv);
    prepared->source_sv = NULL;
  }

  Safefree(prepared);
}

static SV *
gql_ir_prepare_executable_handle_sv(pTHX_ SV *source_sv) {
  gql_ir_prepared_exec_t *prepared;
  HV *stash;
  SV *inner_sv;
  SV *handle_sv;

  Newxz(prepared, 1, gql_ir_prepared_exec_t);
  prepared->document = gql_ir_parse_executable_document(aTHX_ source_sv);
  prepared->source_sv = newSVsv(source_sv);

  stash = gv_stashpv("GraphQL::Houtou::XS::PreparedIR", GV_ADD);
  inner_sv = newSVuv(PTR2UV(prepared));
  handle_sv = newRV_noinc(inner_sv);
  return sv_bless(handle_sv, stash);
}

static HV *
gql_ir_prepare_executable_stats_hv(pTHX_ gql_ir_prepared_exec_t *prepared) {
  HV *stats_hv;
  UV operation_count = 0;
  UV fragment_count = 0;
  UV i;

  stats_hv = newHV();
  hv_ksplit(stats_hv, 4);

  if (!prepared || !prepared->document) {
    hv_stores(stats_hv, "definitions", newSVuv(0));
    hv_stores(stats_hv, "operations", newSVuv(0));
    hv_stores(stats_hv, "fragments", newSVuv(0));
    return stats_hv;
  }

  for (i = 0; i < (UV)prepared->document->definitions.count; i++) {
    gql_ir_definition_t *definition = (gql_ir_definition_t *)prepared->document->definitions.items[i];
    if (!definition) {
      continue;
    }
    if (definition->kind == GQL_IR_DEFINITION_OPERATION) {
      operation_count++;
    } else if (definition->kind == GQL_IR_DEFINITION_FRAGMENT) {
      fragment_count++;
    }
  }

  hv_stores(stats_hv, "definitions", newSVuv((UV)prepared->document->definitions.count));
  hv_stores(stats_hv, "operations", newSVuv(operation_count));
  hv_stores(stats_hv, "fragments", newSVuv(fragment_count));
  return stats_hv;
}

static const char *
gql_ir_operation_kind_name(gql_ir_operation_kind_t kind) {
  switch (kind) {
    case GQL_IR_OPERATION_MUTATION:
      return "mutation";
    case GQL_IR_OPERATION_SUBSCRIPTION:
      return "subscription";
    case GQL_IR_OPERATION_QUERY:
    default:
      return "query";
  }
}

static gql_ir_operation_definition_t *
gql_ir_prepare_select_operation(pTHX_ gql_ir_prepared_exec_t *prepared, SV *operation_name) {
  gql_ir_operation_definition_t *selected = NULL;
  UV i;
  UV operation_count = 0;

  if (!prepared || !prepared->document) {
    croak("prepared IR handle has no document");
  }

  for (i = 0; i < (UV)prepared->document->definitions.count; i++) {
    gql_ir_definition_t *definition = (gql_ir_definition_t *)prepared->document->definitions.items[i];
    if (!definition || definition->kind != GQL_IR_DEFINITION_OPERATION) {
      continue;
    }

    operation_count++;
    if (!operation_name || operation_name == &PL_sv_undef || !SvOK(operation_name)) {
      if (selected) {
        croak("Must provide operation name if query contains multiple operations.\n");
      }
      selected = definition->as.operation;
      continue;
    }

    if (definition->as.operation->name.start != definition->as.operation->name.end) {
      SV *candidate_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, definition->as.operation->name);
      int matches = sv_eq(candidate_sv, operation_name);
      SvREFCNT_dec(candidate_sv);
      if (matches) {
        selected = definition->as.operation;
      }
    }
  }

  if (!selected) {
    if (operation_count == 0) {
      croak("No operations supplied.\n");
    }
    if (operation_name && operation_name != &PL_sv_undef && SvOK(operation_name)) {
      croak("No operations matching '%s' found.\n", SvPV_nolen(operation_name));
    }
  }

  return selected;
}

static HV *
gql_ir_prepare_executable_plan_hv(pTHX_ gql_ir_prepared_exec_t *prepared, SV *operation_name) {
  HV *plan_hv;
  AV *fragment_names_av;
  gql_ir_operation_definition_t *selected;
  UV fragment_count = 0;
  UV i;

  selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);
  plan_hv = newHV();
  fragment_names_av = newAV();
  hv_ksplit(plan_hv, 8);

  for (i = 0; i < (UV)prepared->document->definitions.count; i++) {
    gql_ir_definition_t *definition = (gql_ir_definition_t *)prepared->document->definitions.items[i];
    if (!definition || definition->kind != GQL_IR_DEFINITION_FRAGMENT) {
      continue;
    }
    fragment_count++;
    av_push(
      fragment_names_av,
      gql_ir_make_sv_from_span(aTHX_ prepared->document, definition->as.fragment->name)
    );
  }

  hv_stores(plan_hv, "operation_type", newSVpv(gql_ir_operation_kind_name(selected->operation), 0));
  if (selected->name.start != selected->name.end) {
    hv_stores(plan_hv, "operation_name", gql_ir_make_sv_from_span(aTHX_ prepared->document, selected->name));
  } else {
    hv_stores(plan_hv, "operation_name", newSV(0));
  }
  hv_stores(plan_hv, "selection_count", newSVuv((UV)selected->selection_set->selections.count));
  hv_stores(plan_hv, "variable_definition_count", newSVuv((UV)selected->variable_definitions.count));
  hv_stores(plan_hv, "directive_count", newSVuv((UV)selected->directives.count));
  hv_stores(plan_hv, "fragment_count", newSVuv(fragment_count));
  hv_stores(plan_hv, "fragment_names", newRV_noinc((SV *)fragment_names_av));
  return plan_hv;
}

static SV *
gql_ir_type_to_string_sv(pTHX_ gql_ir_document_t *document, gql_ir_type_t *type) {
  SV *inner_sv;

  if (!type) {
    return newSV(0);
  }

  switch (type->kind) {
    case GQL_IR_TYPE_NAMED:
      return gql_ir_make_sv_from_span(aTHX_ document, type->name);
    case GQL_IR_TYPE_LIST:
      inner_sv = gql_ir_type_to_string_sv(aTHX_ document, type->inner);
      sv_insert(inner_sv, 0, 0, "[", 1);
      sv_catpvn(inner_sv, "]", 1);
      return inner_sv;
    case GQL_IR_TYPE_NON_NULL:
      inner_sv = gql_ir_type_to_string_sv(aTHX_ document, type->inner);
      sv_catpvn(inner_sv, "!", 1);
      return inner_sv;
    default:
      return newSV(0);
  }
}

static HV *
gql_ir_prepare_executable_frontend_hv(pTHX_ gql_ir_prepared_exec_t *prepared, SV *operation_name) {
  HV *frontend_hv = newHV();
  HV *operation_hv = newHV();
  HV *fragments_hv = newHV();
  HV *variables_hv = newHV();
  gql_ir_operation_definition_t *selected;
  UV i;

  selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);

  hv_stores(operation_hv, "operation_type", newSVpv(gql_ir_operation_kind_name(selected->operation), 0));
  if (selected->name.start != selected->name.end) {
    hv_stores(operation_hv, "operation_name", gql_ir_make_sv_from_span(aTHX_ prepared->document, selected->name));
  } else {
    hv_stores(operation_hv, "operation_name", newSV(0));
  }
  hv_stores(operation_hv, "selection_count", newSVuv((UV)selected->selection_set->selections.count));
  hv_stores(operation_hv, "directive_count", newSVuv((UV)selected->directives.count));

  for (i = 0; i < (UV)selected->variable_definitions.count; i++) {
    gql_ir_variable_definition_t *definition = (gql_ir_variable_definition_t *)selected->variable_definitions.items[i];
    HV *variable_hv;
    SV *name_sv;
    if (!definition) {
      continue;
    }
    variable_hv = newHV();
    name_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, definition->name);
    hv_stores(variable_hv, "type", gql_ir_type_to_string_sv(aTHX_ prepared->document, definition->type));
    hv_stores(variable_hv, "has_default", newSViv(definition->default_value ? 1 : 0));
    hv_stores(variable_hv, "directive_count", newSVuv((UV)definition->directives.count));
    (void)hv_store_ent(variables_hv, name_sv, newRV_noinc((SV *)variable_hv), 0);
  }
  hv_stores(operation_hv, "variables", newRV_noinc((SV *)variables_hv));

  for (i = 0; i < (UV)prepared->document->definitions.count; i++) {
    gql_ir_definition_t *ir_definition = (gql_ir_definition_t *)prepared->document->definitions.items[i];
    gql_ir_fragment_definition_t *fragment;
    HV *fragment_hv;
    SV *fragment_name_sv;

    if (!ir_definition || ir_definition->kind != GQL_IR_DEFINITION_FRAGMENT) {
      continue;
    }

    fragment = ir_definition->as.fragment;
    fragment_hv = newHV();
    fragment_name_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, fragment->name);

    hv_stores(fragment_hv, "type_condition", gql_ir_make_sv_from_span(aTHX_ prepared->document, fragment->type_condition));
    hv_stores(fragment_hv, "selection_count", newSVuv((UV)fragment->selection_set->selections.count));
    hv_stores(fragment_hv, "directive_count", newSVuv((UV)fragment->directives.count));

    (void)hv_store_ent(fragments_hv, fragment_name_sv, newRV_noinc((SV *)fragment_hv), 0);
  }

  hv_stores(frontend_hv, "operation", newRV_noinc((SV *)operation_hv));
  hv_stores(frontend_hv, "fragments", newRV_noinc((SV *)fragments_hv));
  return frontend_hv;
}
