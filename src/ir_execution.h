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
  if (prepared->cached_operation_name_sv) {
    SvREFCNT_dec(prepared->cached_operation_name_sv);
    prepared->cached_operation_name_sv = NULL;
  }
  if (prepared->cached_operation_legacy_sv) {
    SvREFCNT_dec(prepared->cached_operation_legacy_sv);
    prepared->cached_operation_legacy_sv = NULL;
  }
  if (prepared->cached_fragments_legacy_sv) {
    SvREFCNT_dec(prepared->cached_fragments_legacy_sv);
    prepared->cached_fragments_legacy_sv = NULL;
  }
  if (prepared->cached_root_legacy_fields_sv) {
    SvREFCNT_dec(prepared->cached_root_legacy_fields_sv);
    prepared->cached_root_legacy_fields_sv = NULL;
  }

  Safefree(prepared);
}

static const char *gql_ir_operation_kind_name(gql_ir_operation_kind_t kind);
static gql_ir_operation_definition_t *gql_ir_prepare_select_operation(pTHX_ gql_ir_prepared_exec_t *prepared, SV *operation_name);
static SV *gql_ir_prepare_executable_root_legacy_fields_sv(pTHX_ SV *schema, gql_ir_prepared_exec_t *prepared, SV *operation_name);
static AV *gql_ir_prepare_executable_root_selection_plan_av(pTHX_ gql_ir_prepared_exec_t *prepared, SV *operation_name);
static HV *gql_ir_prepare_executable_root_field_plan_hv(pTHX_ SV *schema, gql_ir_prepared_exec_t *prepared, SV *operation_name);
static gql_ir_fragment_definition_t *gql_ir_prepare_find_fragment_by_name(pTHX_ gql_ir_prepared_exec_t *prepared, const char *name, STRLEN name_len);
static int gql_ir_prepare_type_condition_matches_root(pTHX_ gql_ir_prepared_exec_t *prepared, SV *root_type, gql_ir_span_t type_condition);
static int gql_ir_prepare_collect_root_field_nodes_into(pTHX_ gql_ir_prepared_exec_t *prepared, SV *root_type, gql_ir_selection_set_t *selection_set, SV *target_result_name_sv, AV *nodes_av);
static SV *gql_ir_prepare_executable_root_field_nodes_sv(pTHX_ gql_ir_prepared_exec_t *prepared, SV *root_type, SV *operation_name, SV *target_result_name_sv);
static void gql_ir_compiled_attach_root_field_runtime_data(pTHX_ SV *root_field_plan_sv, SV *root_fields_sv);
static gql_ir_compiled_root_field_plan_t *gql_ir_compiled_root_field_plan_from_sv(pTHX_ SV *root_field_plan_sv);
static void gql_ir_compiled_root_field_plan_destroy(gql_ir_compiled_root_field_plan_t *plan);
static void gql_ir_compiled_concrete_plan_table_destroy(gql_ir_compiled_concrete_plan_table_t *table);
static void gql_ir_attach_concrete_field_plan_table(pTHX_ SV *sv, gql_ir_compiled_concrete_plan_table_t *table);
static gql_ir_compiled_field_bucket_table_t *gql_ir_compiled_field_bucket_table_from_sv(pTHX_ SV *compiled_fields_sv);
static void gql_ir_compiled_field_bucket_table_destroy(gql_ir_compiled_field_bucket_table_t *table);
static void gql_ir_attach_compiled_field_bucket_table(pTHX_ SV *sv, gql_ir_compiled_field_bucket_table_t *table);
static void gql_ir_compiled_strip_legacy_buckets_from_nodes(pTHX_ SV *nodes_sv);
static void gql_ir_compiled_strip_legacy_buckets_from_node(pTHX_ SV *node_sv);
static void gql_ir_compiled_strip_legacy_buckets_from_fragments(pTHX_ SV *fragments_sv);
static SV *gql_ir_compiled_root_selection_plan_sv(pTHX_ gql_ir_compiled_exec_t *compiled);
static SV *gql_ir_compiled_root_field_plan_legacy_sv(pTHX_ gql_ir_compiled_exec_t *compiled);
static gql_ir_prepared_exec_t *gql_ir_compiled_prepared_exec(gql_ir_compiled_exec_t *compiled);
static SV *gql_ir_compiled_operation_legacy_sv(pTHX_ gql_ir_compiled_exec_t *compiled);
static SV *gql_ir_compiled_fragments_legacy_sv(pTHX_ gql_ir_compiled_exec_t *compiled);
static SV *gql_ir_compiled_root_legacy_fields_sv(pTHX_ gql_ir_compiled_exec_t *compiled);
static SV *gql_ir_execute_compiled_root_field_plan(pTHX_ gql_ir_compiled_exec_t *compiled, SV *context_sv, SV *root_value, SV *path_sv);
static SV *gql_ir_selection_to_legacy_sv(pTHX_ gql_ir_document_t *document, gql_ir_selection_t *selection);
static AV *gql_ir_selections_to_legacy_av(pTHX_ gql_ir_document_t *document, gql_ir_selection_set_t *selection_set);
static SV *gql_ir_value_to_legacy_sv(pTHX_ gql_ir_document_t *document, gql_ir_value_t *value);
static SV *gql_ir_directives_to_legacy_sv(pTHX_ gql_ir_document_t *document, gql_ir_ptr_array_t *directives);
static int gql_ir_selection_set_is_plain_fields(gql_ir_selection_set_t *selection_set);
static SV *gql_ir_selection_set_to_legacy_fields_sv(pTHX_ gql_ir_document_t *document, gql_ir_selection_set_t *selection_set);
static SV *gql_ir_fragment_definitions_to_legacy_map_sv(pTHX_ gql_ir_prepared_exec_t *prepared);
static SV *gql_ir_operation_to_legacy_sv(pTHX_ gql_ir_prepared_exec_t *prepared, gql_ir_operation_definition_t *operation, SV *operation_name);
static void gql_ir_attach_compiled_field_defs_to_selections(pTHX_ SV *schema, SV *parent_type, AV *selections_av, SV *fragments_sv);
static void gql_ir_attach_compiled_field_defs_to_nodes(pTHX_ SV *schema, SV *parent_type, SV *nodes_sv, SV *fragments_sv);
static void gql_ir_attach_compiled_field_defs_to_fragments(pTHX_ SV *schema, SV *fragments_sv);
static void gql_ir_attach_compiled_concrete_subfields_to_node(pTHX_ SV *schema, SV *abstract_type, SV *fragments_sv, SV *selection_sv);
static void gql_ir_attach_compiled_field_defs_to_selection_sv(pTHX_ SV *schema, SV *parent_type, SV *selection_sv, SV *fragments_sv);
static void gql_ir_accumulate_completed_result(pTHX_ HV *data_hv, AV **all_errors_avp, SV *key_sv, SV *completed_sv);
static SV *gql_ir_build_native_result(pTHX_ HV *data_hv, AV *all_errors_av);

static void
gql_ir_compiled_exec_destroy(gql_ir_compiled_exec_t *compiled) {
  if (!compiled) {
    return;
  }

  if (compiled->prepared_handle_sv) {
    SvREFCNT_dec(compiled->prepared_handle_sv);
    compiled->prepared_handle_sv = NULL;
  }
  if (compiled->schema_sv) {
    SvREFCNT_dec(compiled->schema_sv);
    compiled->schema_sv = NULL;
  }
  if (compiled->operation_name_sv) {
    SvREFCNT_dec(compiled->operation_name_sv);
    compiled->operation_name_sv = NULL;
  }
  if (compiled->root_selection_plan_sv) {
    SvREFCNT_dec(compiled->root_selection_plan_sv);
    compiled->root_selection_plan_sv = NULL;
  }
  if (compiled->root_field_plan) {
    gql_ir_compiled_root_field_plan_destroy(compiled->root_field_plan);
    compiled->root_field_plan = NULL;
  }
  if (compiled->root_field_plan_sv) {
    SvREFCNT_dec(compiled->root_field_plan_sv);
    compiled->root_field_plan_sv = NULL;
  }
  if (compiled->root_type_sv) {
    SvREFCNT_dec(compiled->root_type_sv);
    compiled->root_type_sv = NULL;
  }

  Safefree(compiled);
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

static void
gql_ir_accumulate_completed_result(pTHX_ HV *data_hv, AV **all_errors_avp, SV *key_sv, SV *completed_sv) {
  HV *value_hv;
  SV **data_svp;
  SV **child_errors_svp;
  STRLEN key_len;
  const char *key;
  I32 child_error_len;
  I32 j;

  if (!data_hv || !all_errors_avp || !key_sv || !SvOK(key_sv)
      || !completed_sv || !SvROK(completed_sv) || SvTYPE(SvRV(completed_sv)) != SVt_PVHV) {
    return;
  }

  value_hv = (HV *)SvRV(completed_sv);
  data_svp = hv_fetch(value_hv, "data", 4, 0);
  if (data_svp) {
    key = SvPV(key_sv, key_len);
    (void)hv_store(data_hv, key, (I32)key_len, newSVsv(*data_svp), 0);
  }

  child_errors_svp = hv_fetch(value_hv, "errors", 6, 0);
  if (child_errors_svp && SvROK(*child_errors_svp) && SvTYPE(SvRV(*child_errors_svp)) == SVt_PVAV) {
    AV *child_errors_av = (AV *)SvRV(*child_errors_svp);
    AV *all_errors_av = *all_errors_avp;
    child_error_len = av_len(child_errors_av);
    if (!all_errors_av) {
      all_errors_av = newAV();
      *all_errors_avp = all_errors_av;
    }
    for (j = 0; j <= child_error_len; j++) {
      SV **child_error_svp = av_fetch(child_errors_av, j, 0);
      if (child_error_svp) {
        av_push(all_errors_av, newSVsv(*child_error_svp));
      }
    }
  }
}

static SV *
gql_ir_build_native_result(pTHX_ HV *data_hv, AV *all_errors_av) {
  HV *result_hv = newHV();

  if (HvUSEDKEYS(data_hv) > 0) {
    gql_store_sv(result_hv, "data", newRV_noinc((SV *)data_hv));
  } else {
    SvREFCNT_dec((SV *)data_hv);
  }

  if (all_errors_av && av_len(all_errors_av) >= 0) {
    gql_store_sv(result_hv, "errors", newRV_noinc((SV *)all_errors_av));
  } else if (all_errors_av) {
    SvREFCNT_dec((SV *)all_errors_av);
  }

  return newRV_noinc((SV *)result_hv);
}

static SV *
gql_ir_compile_executable_plan_handle_sv(pTHX_ SV *schema, SV *prepared_handle_sv, SV *operation_name) {
  gql_ir_compiled_exec_t *compiled;
  gql_ir_prepared_exec_t *prepared;
  gql_ir_operation_definition_t *selected;
  const char *operation_type;
  SV *compiled_inner_sv;
  SV *compiled_handle_sv;
  HV *stash;
  SV *prepared_inner_sv;

  if (!prepared_handle_sv || !SvROK(prepared_handle_sv) || !sv_derived_from(prepared_handle_sv, "GraphQL::Houtou::XS::PreparedIR")) {
    croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
  }

  prepared_inner_sv = SvRV(prepared_handle_sv);
  if (!SvIOK(prepared_inner_sv) || SvUV(prepared_inner_sv) == 0) {
    croak("prepared IR handle is no longer valid");
  }

  prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(prepared_inner_sv));
  selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);
  operation_type = gql_ir_operation_kind_name(selected->operation);

  Newxz(compiled, 1, gql_ir_compiled_exec_t);
  compiled->prepared_handle_sv = newSVsv(prepared_handle_sv);
  compiled->schema_sv = gql_execution_share_or_copy_sv(schema);
  compiled->operation_name_sv = (operation_name && SvOK(operation_name)) ? newSVsv(operation_name) : newSV(0);
  compiled->selected_operation = selected;
  compiled->root_type_sv = gql_execution_call_schema_root_type(aTHX_ schema, operation_type);
  {
    SV *root_field_plan_sv = newRV_noinc((SV *)gql_ir_prepare_executable_root_field_plan_hv(
      aTHX_ schema,
      prepared,
      operation_name
    ));
    SV *fragments_sv = gql_ir_fragment_definitions_to_legacy_map_sv(aTHX_ prepared);
    SV *root_fields_sv = gql_ir_prepare_executable_root_legacy_fields_sv(aTHX_ schema, prepared, operation_name);

    gql_ir_attach_compiled_field_defs_to_fragments(aTHX_ schema, fragments_sv);
    gql_ir_attach_compiled_field_defs_to_nodes(aTHX_ schema, compiled->root_type_sv, root_fields_sv, fragments_sv);
    gql_ir_compiled_attach_root_field_runtime_data(aTHX_ root_field_plan_sv, root_fields_sv);
    compiled->root_field_plan = gql_ir_compiled_root_field_plan_from_sv(aTHX_ root_field_plan_sv);
    if (!compiled->root_field_plan) {
      compiled->root_field_plan_sv = root_field_plan_sv;
      root_field_plan_sv = NULL;
    } else {
      UV field_i;
      for (field_i = 0; field_i < compiled->root_field_plan->field_count; field_i++) {
        gql_ir_compiled_root_field_plan_entry_t *entry = &compiled->root_field_plan->entries[field_i];
        gql_ir_compiled_strip_legacy_buckets_from_nodes(aTHX_ entry->nodes_sv);
      }
    }

    if (root_field_plan_sv) {
      SvREFCNT_dec(root_field_plan_sv);
    }
    SvREFCNT_dec(root_fields_sv);
    SvREFCNT_dec(fragments_sv);
  }

  stash = gv_stashpv("GraphQL::Houtou::XS::CompiledIR", GV_ADD);
  compiled_inner_sv = newSVuv(PTR2UV(compiled));
  compiled_handle_sv = newRV_noinc(compiled_inner_sv);
  return sv_bless(compiled_handle_sv, stash);
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
    gql_store_sv(variable_hv, "type", gql_ir_type_to_string_sv(aTHX_ prepared->document, definition->type));
    hv_stores(variable_hv, "has_default", newSViv(definition->default_value ? 1 : 0));
    hv_stores(variable_hv, "directive_count", newSVuv((UV)definition->directives.count));
    (void)hv_store_ent(variables_hv, name_sv, newRV_noinc((SV *)variable_hv), 0);
    SvREFCNT_dec(name_sv);
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
    SvREFCNT_dec(fragment_name_sv);
  }

  hv_stores(frontend_hv, "operation", newRV_noinc((SV *)operation_hv));
  hv_stores(frontend_hv, "fragments", newRV_noinc((SV *)fragments_hv));
  return frontend_hv;
}

static HV *
gql_ir_prepare_executable_context_seed_hv(
  pTHX_ SV *schema,
  gql_ir_prepared_exec_t *prepared,
  SV *operation_name,
  SV *variable_values
) {
  HV *seed_hv = newHV();
  HV *frontend_hv;
  gql_ir_operation_definition_t *selected;
  const char *operation_type;
  SV *root_type_sv;

  selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);
  operation_type = gql_ir_operation_kind_name(selected->operation);
  frontend_hv = gql_ir_prepare_executable_frontend_hv(aTHX_ prepared, operation_name);
  root_type_sv = gql_execution_call_schema_root_type(aTHX_ schema, operation_type);

  gql_store_sv(seed_hv, "schema", gql_execution_share_or_copy_sv(schema));
  gql_store_sv(seed_hv, "operation_type", newSVpv(operation_type, 0));
  gql_store_sv(seed_hv, "root_type", root_type_sv);
  gql_store_sv(seed_hv, "frontend", newRV_noinc((SV *)frontend_hv));
  if (variable_values && SvOK(variable_values)) {
    gql_store_sv(seed_hv, "variable_values", gql_execution_share_or_copy_sv(variable_values));
  } else {
    gql_store_sv(seed_hv, "variable_values", newRV_noinc((SV *)newHV()));
  }

  return seed_hv;
}

static AV *
gql_ir_prepare_selection_plan_av(pTHX_ gql_ir_prepared_exec_t *prepared, gql_ir_selection_set_t *selection_set) {
  AV *plan_av = newAV();
  UV i;

  if (!selection_set) {
    return plan_av;
  }

  if (selection_set->selections.count > 0) {
    av_extend(plan_av, selection_set->selections.count - 1);
  }

  for (i = 0; i < (UV)selection_set->selections.count; i++) {
    gql_ir_selection_t *selection = (gql_ir_selection_t *)selection_set->selections.items[i];
    HV *item_hv;

    if (!selection) {
      continue;
    }

    item_hv = newHV();
    switch (selection->kind) {
      case GQL_IR_SELECTION_FIELD: {
        gql_ir_field_t *field = selection->as.field;
        hv_stores(item_hv, "kind", newSVpv("field", 0));
        hv_stores(item_hv, "name", gql_ir_make_sv_from_span(aTHX_ prepared->document, field->name));
        if (field->alias.start != field->alias.end) {
          hv_stores(item_hv, "alias", gql_ir_make_sv_from_span(aTHX_ prepared->document, field->alias));
        } else {
          hv_stores(item_hv, "alias", newSV(0));
        }
        hv_stores(item_hv, "argument_count", newSVuv((UV)field->arguments.count));
        hv_stores(item_hv, "directive_count", newSVuv((UV)field->directives.count));
        hv_stores(
          item_hv,
          "selection_count",
          newSVuv((UV)(field->selection_set ? field->selection_set->selections.count : 0))
        );
        if (field->selection_set && field->selection_set->selections.count > 0) {
          hv_stores(
            item_hv,
            "selections",
            newRV_noinc((SV *)gql_ir_prepare_selection_plan_av(aTHX_ prepared, field->selection_set))
          );
        }
        break;
      }
      case GQL_IR_SELECTION_FRAGMENT_SPREAD: {
        gql_ir_fragment_spread_t *spread = selection->as.fragment_spread;
        SV *fragment_name_sv;
        STRLEN name_len;
        const char *name;
        gql_ir_fragment_definition_t *fragment;
        hv_stores(item_hv, "kind", newSVpv("fragment_spread", 0));
        fragment_name_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, spread->name);
        hv_stores(item_hv, "name", newSVsv(fragment_name_sv));
        hv_stores(item_hv, "directive_count", newSVuv((UV)spread->directives.count));
        name = SvPV(fragment_name_sv, name_len);
        fragment = gql_ir_prepare_find_fragment_by_name(aTHX_ prepared, name, name_len);
        if (fragment) {
          hv_stores(item_hv, "type_condition", gql_ir_make_sv_from_span(aTHX_ prepared->document, fragment->type_condition));
          hv_stores(
            item_hv,
            "selection_count",
            newSVuv((UV)(fragment->selection_set ? fragment->selection_set->selections.count : 0))
          );
          if (fragment->selection_set && fragment->selection_set->selections.count > 0) {
            hv_stores(
              item_hv,
              "selections",
              newRV_noinc((SV *)gql_ir_prepare_selection_plan_av(aTHX_ prepared, fragment->selection_set))
            );
          }
        }
        SvREFCNT_dec(fragment_name_sv);
        break;
      }
      case GQL_IR_SELECTION_INLINE_FRAGMENT: {
        gql_ir_inline_fragment_t *fragment = selection->as.inline_fragment;
        hv_stores(item_hv, "kind", newSVpv("inline_fragment", 0));
        if (fragment->type_condition.start != fragment->type_condition.end) {
          hv_stores(item_hv, "type_condition", gql_ir_make_sv_from_span(aTHX_ prepared->document, fragment->type_condition));
        } else {
          hv_stores(item_hv, "type_condition", newSV(0));
        }
        hv_stores(item_hv, "directive_count", newSVuv((UV)fragment->directives.count));
        hv_stores(
          item_hv,
          "selection_count",
          newSVuv((UV)(fragment->selection_set ? fragment->selection_set->selections.count : 0))
        );
        if (fragment->selection_set && fragment->selection_set->selections.count > 0) {
          hv_stores(
            item_hv,
            "selections",
            newRV_noinc((SV *)gql_ir_prepare_selection_plan_av(aTHX_ prepared, fragment->selection_set))
          );
        }
        break;
      }
      default:
        hv_stores(item_hv, "kind", newSVpv("unknown", 0));
        break;
    }

    av_push(plan_av, newRV_noinc((SV *)item_hv));
  }

  return plan_av;
}

static AV *
gql_ir_prepare_executable_root_selection_plan_av(
  pTHX_ gql_ir_prepared_exec_t *prepared,
  SV *operation_name
) {
  gql_ir_operation_definition_t *selected;
  selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);
  return gql_ir_prepare_selection_plan_av(aTHX_ prepared, selected->selection_set);
}

static gql_ir_fragment_definition_t *
gql_ir_prepare_find_fragment_by_name(
  pTHX_
  gql_ir_prepared_exec_t *prepared,
  const char *name,
  STRLEN name_len
) {
  UV i;

  if (!prepared || !prepared->document) {
    return NULL;
  }

  for (i = 0; i < (UV)prepared->document->definitions.count; i++) {
    gql_ir_definition_t *definition = (gql_ir_definition_t *)prepared->document->definitions.items[i];
    gql_ir_fragment_definition_t *fragment;
    SV *candidate_sv;
    int matches;

    if (!definition || definition->kind != GQL_IR_DEFINITION_FRAGMENT) {
      continue;
    }

    fragment = definition->as.fragment;
    candidate_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, fragment->name);
    matches = (SvCUR(candidate_sv) == name_len && memEQ(SvPV_nolen(candidate_sv), name, name_len));
    SvREFCNT_dec(candidate_sv);
    if (matches) {
      return fragment;
    }
  }

  return NULL;
}

static int
gql_ir_prepare_type_condition_matches_root(
  pTHX_ gql_ir_prepared_exec_t *prepared,
  SV *root_type,
  gql_ir_span_t type_condition
) {
  SV **name_svp;
  STRLEN root_len = 0;
  STRLEN cond_len = 0;
  const char *root_name;
  SV *cond_sv;
  const char *cond_name;
  int matches;

  if (type_condition.start == type_condition.end) {
    return 1;
  }
  if (!root_type || !SvROK(root_type) || SvTYPE(SvRV(root_type)) != SVt_PVHV) {
    return 0;
  }

  name_svp = hv_fetch((HV *)SvRV(root_type), "name", 4, 0);
  if (!name_svp || !SvOK(*name_svp)) {
    return 0;
  }

  root_name = SvPV(*name_svp, root_len);
  cond_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, type_condition);
  cond_name = SvPV(cond_sv, cond_len);
  matches = (root_len == cond_len && memEQ(root_name, cond_name, root_len));
  SvREFCNT_dec(cond_sv);
  return matches;
}

static int
gql_ir_prepare_collect_root_field_buckets_into(
  pTHX_ gql_ir_prepared_exec_t *prepared,
  SV *root_type,
  gql_ir_selection_set_t *selection_set,
  AV *field_names_av,
  HV *counts_hv
) {
  UV i;

  if (!selection_set) {
    return 1;
  }

  for (i = 0; i < (UV)selection_set->selections.count; i++) {
    gql_ir_selection_t *selection = (gql_ir_selection_t *)selection_set->selections.items[i];

    if (!selection) {
      continue;
    }

    switch (selection->kind) {
      case GQL_IR_SELECTION_FIELD: {
        gql_ir_field_t *field = selection->as.field;
        SV *result_name_sv;
        HE *count_he;
        SV *count_sv;
        if (field->directives.count > 0) {
          return 0;
        }
        result_name_sv = (field->alias.start != field->alias.end)
          ? gql_ir_make_sv_from_span(aTHX_ prepared->document, field->alias)
          : gql_ir_make_sv_from_span(aTHX_ prepared->document, field->name);
        count_he = hv_fetch_ent(counts_hv, result_name_sv, 0, 0);
        if (!count_he) {
          SV *result_name_key_sv = newSVsv(result_name_sv);
          av_push(field_names_av, newSVsv(result_name_sv));
          (void)hv_store_ent(counts_hv, result_name_key_sv, newSVuv(1), 0);
          SvREFCNT_dec(result_name_key_sv);
        } else {
          count_sv = HeVAL(count_he);
          sv_setuv(count_sv, SvUV(count_sv) + 1);
        }
        SvREFCNT_dec(result_name_sv);
        break;
      }
      case GQL_IR_SELECTION_FRAGMENT_SPREAD: {
        gql_ir_fragment_spread_t *spread = selection->as.fragment_spread;
        SV *fragment_name_sv;
        STRLEN name_len;
        const char *name;
        gql_ir_fragment_definition_t *fragment;
        if (spread->directives.count > 0) {
          return 0;
        }
        fragment_name_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, spread->name);
        name = SvPV(fragment_name_sv, name_len);
        fragment = gql_ir_prepare_find_fragment_by_name(aTHX_ prepared, name, name_len);
        SvREFCNT_dec(fragment_name_sv);
        if (!fragment) {
          return 0;
        }
        if (!gql_ir_prepare_type_condition_matches_root(aTHX_ prepared, root_type, fragment->type_condition)) {
          continue;
        }
        if (!gql_ir_prepare_collect_root_field_buckets_into(
              aTHX_ prepared,
              root_type,
              fragment->selection_set,
              field_names_av,
              counts_hv
            )) {
          return 0;
        }
        break;
      }
      case GQL_IR_SELECTION_INLINE_FRAGMENT: {
        gql_ir_inline_fragment_t *fragment = selection->as.inline_fragment;
        if (fragment->directives.count > 0) {
          return 0;
        }
        if (!gql_ir_prepare_type_condition_matches_root(aTHX_ prepared, root_type, fragment->type_condition)) {
          continue;
        }
        if (!gql_ir_prepare_collect_root_field_buckets_into(
              aTHX_ prepared,
              root_type,
              fragment->selection_set,
              field_names_av,
              counts_hv
            )) {
          return 0;
        }
        break;
      }
      default:
        return 0;
    }
  }

  return 1;
}

static HV *
gql_ir_prepare_executable_root_field_buckets_hv(
  pTHX_ SV *schema,
  gql_ir_prepared_exec_t *prepared,
  SV *operation_name
) {
  HV *result_hv = newHV();
  AV *field_names_av = newAV();
  HV *counts_hv = newHV();
  gql_ir_operation_definition_t *selected;
  const char *operation_type;
  SV *root_type_sv;

  selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);
  operation_type = gql_ir_operation_kind_name(selected->operation);
  root_type_sv = gql_execution_call_schema_root_type(aTHX_ schema, operation_type);

  if (!gql_ir_prepare_collect_root_field_buckets_into(
        aTHX_ prepared,
        root_type_sv,
        selected->selection_set,
        field_names_av,
        counts_hv
      )) {
    SvREFCNT_dec(root_type_sv);
    SvREFCNT_dec((SV *)field_names_av);
    SvREFCNT_dec((SV *)counts_hv);
    SvREFCNT_dec((SV *)result_hv);
    croak("IR root field bucket collection requires simple root selections");
  }

  gql_store_sv(result_hv, "operation_type", newSVpv(operation_type, 0));
  gql_store_sv(result_hv, "root_type", root_type_sv);
  gql_store_sv(result_hv, "field_names", newRV_noinc((SV *)field_names_av));
  gql_store_sv(result_hv, "field_counts", newRV_noinc((SV *)counts_hv));
  return result_hv;
}

static int
gql_ir_prepare_collect_root_field_plan_into(
  pTHX_ SV *schema,
  SV *root_type,
  gql_ir_prepared_exec_t *prepared,
  gql_ir_selection_set_t *selection_set,
  AV *field_order_av,
  HV *fields_hv
) {
  UV i;

  if (!selection_set) {
    return 1;
  }

  for (i = 0; i < (UV)selection_set->selections.count; i++) {
    gql_ir_selection_t *selection = (gql_ir_selection_t *)selection_set->selections.items[i];

    if (!selection) {
      continue;
    }

    switch (selection->kind) {
      case GQL_IR_SELECTION_FIELD: {
        gql_ir_field_t *field = selection->as.field;
        SV *result_name_sv;
        HE *existing_he;

        if (field->directives.count > 0) {
          return 0;
        }

        result_name_sv = (field->alias.start != field->alias.end)
          ? gql_ir_make_sv_from_span(aTHX_ prepared->document, field->alias)
          : gql_ir_make_sv_from_span(aTHX_ prepared->document, field->name);
        existing_he = hv_fetch_ent(fields_hv, result_name_sv, 0, 0);

        if (!existing_he) {
          HV *field_plan_hv = newHV();
          SV *field_name_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, field->name);
          SV *field_def_sv = gql_execution_get_field_def(aTHX_ schema, root_type, field_name_sv);

          gql_store_sv(field_plan_hv, "result_name", newSVsv(result_name_sv));
          gql_store_sv(field_plan_hv, "field_name", field_name_sv);
          gql_store_sv(field_plan_hv, "field_def", field_def_sv);
          hv_stores(field_plan_hv, "node_count", newSVuv(1));
          hv_stores(field_plan_hv, "argument_count", newSVuv((UV)field->arguments.count));
          hv_stores(field_plan_hv, "directive_count", newSVuv((UV)field->directives.count));
          hv_stores(
            field_plan_hv,
            "selection_count",
            newSVuv((UV)(field->selection_set ? field->selection_set->selections.count : 0))
          );

          av_push(field_order_av, newSVsv(result_name_sv));
          {
            SV *result_name_key_sv = newSVsv(result_name_sv);
            (void)hv_store_ent(fields_hv, result_name_key_sv, newRV_noinc((SV *)field_plan_hv), 0);
            SvREFCNT_dec(result_name_key_sv);
          }
        } else {
          SV *existing_sv = HeVAL(existing_he);
          HV *field_plan_hv;
          SV **node_count_svp;

          if (!existing_sv || !SvROK(existing_sv) || SvTYPE(SvRV(existing_sv)) != SVt_PVHV) {
            SvREFCNT_dec(result_name_sv);
            return 0;
          }

          field_plan_hv = (HV *)SvRV(existing_sv);
          node_count_svp = hv_fetch(field_plan_hv, "node_count", 10, 0);
          if (!node_count_svp || !SvOK(*node_count_svp)) {
            SvREFCNT_dec(result_name_sv);
            return 0;
          }
          sv_setuv(*node_count_svp, SvUV(*node_count_svp) + 1);
        }

        SvREFCNT_dec(result_name_sv);
        break;
      }
      case GQL_IR_SELECTION_FRAGMENT_SPREAD: {
        gql_ir_fragment_spread_t *spread = selection->as.fragment_spread;
        SV *fragment_name_sv;
        STRLEN name_len;
        const char *name;
        gql_ir_fragment_definition_t *fragment;

        if (spread->directives.count > 0) {
          return 0;
        }

        fragment_name_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, spread->name);
        name = SvPV(fragment_name_sv, name_len);
        fragment = gql_ir_prepare_find_fragment_by_name(aTHX_ prepared, name, name_len);
        SvREFCNT_dec(fragment_name_sv);
        if (!fragment) {
          return 0;
        }
        if (!gql_ir_prepare_type_condition_matches_root(aTHX_ prepared, root_type, fragment->type_condition)) {
          continue;
        }
        if (!gql_ir_prepare_collect_root_field_plan_into(
              aTHX_ schema,
              root_type,
              prepared,
              fragment->selection_set,
              field_order_av,
              fields_hv
            )) {
          return 0;
        }
        break;
      }
      case GQL_IR_SELECTION_INLINE_FRAGMENT: {
        gql_ir_inline_fragment_t *fragment = selection->as.inline_fragment;

        if (fragment->directives.count > 0) {
          return 0;
        }
        if (!gql_ir_prepare_type_condition_matches_root(aTHX_ prepared, root_type, fragment->type_condition)) {
          continue;
        }
        if (!gql_ir_prepare_collect_root_field_plan_into(
              aTHX_ schema,
              root_type,
              prepared,
              fragment->selection_set,
              field_order_av,
              fields_hv
            )) {
          return 0;
        }
        break;
      }
      default:
        return 0;
    }
  }

  return 1;
}

static HV *
gql_ir_prepare_executable_root_field_plan_hv(
  pTHX_ SV *schema,
  gql_ir_prepared_exec_t *prepared,
  SV *operation_name
) {
  HV *result_hv = newHV();
  AV *field_order_av = newAV();
  HV *fields_hv = newHV();
  gql_ir_operation_definition_t *selected;
  const char *operation_type;
  SV *root_type_sv;

  selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);
  operation_type = gql_ir_operation_kind_name(selected->operation);
  root_type_sv = gql_execution_call_schema_root_type(aTHX_ schema, operation_type);

  if (!gql_ir_prepare_collect_root_field_plan_into(
        aTHX_ schema,
        root_type_sv,
        prepared,
        selected->selection_set,
        field_order_av,
        fields_hv
      )) {
    SvREFCNT_dec(root_type_sv);
    SvREFCNT_dec((SV *)field_order_av);
    SvREFCNT_dec((SV *)fields_hv);
    SvREFCNT_dec((SV *)result_hv);
    croak("IR root field plan requires simple root selections");
  }

  gql_store_sv(result_hv, "operation_type", newSVpv(operation_type, 0));
  gql_store_sv(result_hv, "root_type", root_type_sv);
  gql_store_sv(result_hv, "field_order", newRV_noinc((SV *)field_order_av));
  gql_store_sv(result_hv, "fields", newRV_noinc((SV *)fields_hv));
  return result_hv;
}

static int
gql_ir_prepare_collect_root_field_nodes_into(
  pTHX_ gql_ir_prepared_exec_t *prepared,
  SV *root_type,
  gql_ir_selection_set_t *selection_set,
  SV *target_result_name_sv,
  AV *nodes_av
) {
  UV i;

  if (!selection_set) {
    return 1;
  }

  for (i = 0; i < (UV)selection_set->selections.count; i++) {
    gql_ir_selection_t *selection = (gql_ir_selection_t *)selection_set->selections.items[i];

    if (!selection) {
      continue;
    }

    switch (selection->kind) {
      case GQL_IR_SELECTION_FIELD: {
        gql_ir_field_t *field = selection->as.field;
        SV *result_name_sv;
        int matches;

        if (field->directives.count > 0) {
          return 0;
        }

        result_name_sv = (field->alias.start != field->alias.end)
          ? gql_ir_make_sv_from_span(aTHX_ prepared->document, field->alias)
          : gql_ir_make_sv_from_span(aTHX_ prepared->document, field->name);
        matches = sv_eq(result_name_sv, target_result_name_sv);
        SvREFCNT_dec(result_name_sv);

        if (matches) {
          SV *selection_sv = gql_ir_selection_to_legacy_sv(aTHX_ prepared->document, selection);
          if (!selection_sv || selection_sv == &PL_sv_undef) {
            return 0;
          }
          av_push(nodes_av, selection_sv);
        }
        break;
      }
      case GQL_IR_SELECTION_FRAGMENT_SPREAD: {
        gql_ir_fragment_spread_t *spread = selection->as.fragment_spread;
        SV *fragment_name_sv;
        STRLEN name_len;
        const char *name;
        gql_ir_fragment_definition_t *fragment;

        if (spread->directives.count > 0) {
          return 0;
        }

        fragment_name_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, spread->name);
        name = SvPV(fragment_name_sv, name_len);
        fragment = gql_ir_prepare_find_fragment_by_name(aTHX_ prepared, name, name_len);
        SvREFCNT_dec(fragment_name_sv);
        if (!fragment) {
          return 0;
        }
        if (!gql_ir_prepare_type_condition_matches_root(aTHX_ prepared, root_type, fragment->type_condition)) {
          continue;
        }
        if (!gql_ir_prepare_collect_root_field_nodes_into(
              aTHX_
              prepared,
              root_type,
              fragment->selection_set,
              target_result_name_sv,
              nodes_av
            )) {
          return 0;
        }
        break;
      }
      case GQL_IR_SELECTION_INLINE_FRAGMENT: {
        gql_ir_inline_fragment_t *fragment = selection->as.inline_fragment;

        if (fragment->directives.count > 0) {
          return 0;
        }
        if (!gql_ir_prepare_type_condition_matches_root(aTHX_ prepared, root_type, fragment->type_condition)) {
          continue;
        }
        if (!gql_ir_prepare_collect_root_field_nodes_into(
              aTHX_
              prepared,
              root_type,
              fragment->selection_set,
              target_result_name_sv,
              nodes_av
            )) {
          return 0;
        }
        break;
      }
      default:
        return 0;
    }
  }

  return 1;
}

static SV *
gql_ir_prepare_executable_root_field_nodes_sv(
  pTHX_ gql_ir_prepared_exec_t *prepared,
  SV *root_type,
  SV *operation_name,
  SV *target_result_name_sv
) {
  gql_ir_operation_definition_t *selected;
  AV *nodes_av;

  if (!prepared || !root_type || !target_result_name_sv || !SvOK(target_result_name_sv)) {
    return &PL_sv_undef;
  }

  selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);
  nodes_av = newAV();

  if (!gql_ir_prepare_collect_root_field_nodes_into(
        aTHX_
        prepared,
        root_type,
        selected->selection_set,
        target_result_name_sv,
        nodes_av
      )) {
    SvREFCNT_dec((SV *)nodes_av);
    return &PL_sv_undef;
  }

  return newRV_noinc((SV *)nodes_av);
}

static void
gql_ir_compiled_attach_root_field_runtime_data(pTHX_ SV *root_field_plan_sv, SV *root_fields_sv) {
  HV *root_field_plan_hv;
  AV *field_order_av;
  HV *fields_hv;
  AV *root_fields_av;
  HV *root_nodes_defs_hv;
  SV **field_order_svp;
  SV **fields_svp;
  SV **nodes_defs_svp;
  I32 field_len;
  I32 i;

  if (!root_field_plan_sv
      || !SvROK(root_field_plan_sv)
      || SvTYPE(SvRV(root_field_plan_sv)) != SVt_PVHV
      || !root_fields_sv
      || !SvROK(root_fields_sv)
      || SvTYPE(SvRV(root_fields_sv)) != SVt_PVAV) {
    return;
  }

  root_field_plan_hv = (HV *)SvRV(root_field_plan_sv);
  field_order_svp = hv_fetch(root_field_plan_hv, "field_order", 11, 0);
  fields_svp = hv_fetch(root_field_plan_hv, "fields", 6, 0);
  root_fields_av = (AV *)SvRV(root_fields_sv);
  nodes_defs_svp = av_fetch(root_fields_av, 1, 0);

  if (!field_order_svp
      || !SvROK(*field_order_svp)
      || SvTYPE(SvRV(*field_order_svp)) != SVt_PVAV
      || !fields_svp
      || !SvROK(*fields_svp)
      || SvTYPE(SvRV(*fields_svp)) != SVt_PVHV
      || !nodes_defs_svp
      || !SvROK(*nodes_defs_svp)
      || SvTYPE(SvRV(*nodes_defs_svp)) != SVt_PVHV) {
    return;
  }

  field_order_av = (AV *)SvRV(*field_order_svp);
  fields_hv = (HV *)SvRV(*fields_svp);
  root_nodes_defs_hv = (HV *)SvRV(*nodes_defs_svp);
  field_len = av_len(field_order_av);

  for (i = 0; i <= field_len; i++) {
    SV **result_name_svp = av_fetch(field_order_av, i, 0);
    HE *field_plan_he;
    HV *field_plan_hv;
    HE *nodes_he;

    if (!result_name_svp || !SvOK(*result_name_svp)) {
      continue;
    }

    field_plan_he = hv_fetch_ent(fields_hv, *result_name_svp, 0, 0);
    nodes_he = hv_fetch_ent(root_nodes_defs_hv, *result_name_svp, 0, 0);
    if (!field_plan_he
        || !SvROK(HeVAL(field_plan_he))
        || SvTYPE(SvRV(HeVAL(field_plan_he))) != SVt_PVHV
        || !nodes_he
        || !SvOK(HeVAL(nodes_he))) {
      continue;
    }

    field_plan_hv = (HV *)SvRV(HeVAL(field_plan_he));
    if (!hv_exists(field_plan_hv, "nodes", 5)) {
      gql_store_sv(field_plan_hv, "nodes", gql_execution_share_or_copy_sv(HeVAL(nodes_he)));
    }
  }
}

static void
gql_ir_compiled_root_field_plan_destroy(gql_ir_compiled_root_field_plan_t *plan) {
  UV i;

  if (!plan) {
    return;
  }

  if (plan->entries) {
    for (i = 0; i < plan->field_count; i++) {
      gql_ir_compiled_root_field_plan_entry_t *entry = &plan->entries[i];

      if (entry->result_name_sv) {
        SvREFCNT_dec(entry->result_name_sv);
        entry->result_name_sv = NULL;
      }
      if (entry->field_name_sv) {
        SvREFCNT_dec(entry->field_name_sv);
        entry->field_name_sv = NULL;
      }
      if (entry->field_def_sv) {
        SvREFCNT_dec(entry->field_def_sv);
        entry->field_def_sv = NULL;
      }
      if (entry->return_type_sv) {
        SvREFCNT_dec(entry->return_type_sv);
        entry->return_type_sv = NULL;
      }
      if (entry->type_sv) {
        SvREFCNT_dec(entry->type_sv);
        entry->type_sv = NULL;
      }
      if (entry->completion_type_sv) {
        SvREFCNT_dec(entry->completion_type_sv);
        entry->completion_type_sv = NULL;
      }
      if (entry->resolve_sv) {
        SvREFCNT_dec(entry->resolve_sv);
        entry->resolve_sv = NULL;
      }
      if (entry->nodes_sv) {
        SvREFCNT_dec(entry->nodes_sv);
        entry->nodes_sv = NULL;
      }
      if (entry->first_node_sv) {
        SvREFCNT_dec(entry->first_node_sv);
        entry->first_node_sv = NULL;
      }
      if (entry->path_sv) {
        SvREFCNT_dec(entry->path_sv);
        entry->path_sv = NULL;
      }
    }
    Safefree(plan->entries);
    plan->entries = NULL;
  }

  Safefree(plan);
}

static int
gql_ir_compiled_concrete_plan_table_magic_free(pTHX_ SV *sv, MAGIC *mg) {
  gql_ir_compiled_concrete_plan_table_t *table = (mg && mg->mg_ptr)
    ? INT2PTR(gql_ir_compiled_concrete_plan_table_t *, mg->mg_ptr)
    : NULL;

  if (table) {
    gql_ir_compiled_concrete_plan_table_destroy(table);
    mg->mg_ptr = NULL;
  }
  return 0;
}

static int
gql_ir_compiled_field_bucket_table_magic_free(pTHX_ SV *sv, MAGIC *mg) {
  gql_ir_compiled_field_bucket_table_t *table = (mg && mg->mg_ptr)
    ? INT2PTR(gql_ir_compiled_field_bucket_table_t *, mg->mg_ptr)
    : NULL;

  if (table) {
    gql_ir_compiled_field_bucket_table_destroy(table);
    mg->mg_ptr = NULL;
  }
  return 0;
}

static MGVTBL gql_ir_compiled_concrete_plan_table_vtbl = {
  NULL,
  NULL,
  NULL,
  NULL,
  gql_ir_compiled_concrete_plan_table_magic_free
#if PERL_VERSION_GE(5, 15, 0)
  ,NULL
  ,NULL
  ,NULL
#endif
};

static MGVTBL gql_ir_compiled_field_bucket_table_vtbl = {
  NULL,
  NULL,
  NULL,
  NULL,
  gql_ir_compiled_field_bucket_table_magic_free
#if PERL_VERSION_GE(5, 15, 0)
  ,NULL
  ,NULL
  ,NULL
#endif
};

static void
gql_ir_compiled_concrete_plan_table_destroy(gql_ir_compiled_concrete_plan_table_t *table) {
  UV i;

  if (!table) {
    return;
  }

  if (table->entries) {
    for (i = 0; i < table->count; i++) {
      gql_ir_compiled_concrete_plan_entry_t *entry = &table->entries[i];

      if (entry->possible_type_sv) {
        SvREFCNT_dec(entry->possible_type_sv);
        entry->possible_type_sv = NULL;
      }
      if (entry->compiled_fields_sv) {
        SvREFCNT_dec(entry->compiled_fields_sv);
        entry->compiled_fields_sv = NULL;
      }
      if (entry->field_plan_sv) {
        SvREFCNT_dec(entry->field_plan_sv);
        entry->field_plan_sv = NULL;
      }
      if (entry->native_field_plan) {
        gql_ir_compiled_root_field_plan_destroy(entry->native_field_plan);
        entry->native_field_plan = NULL;
      }
    }
    Safefree(table->entries);
    table->entries = NULL;
  }

  Safefree(table);
}

static void
gql_ir_compiled_field_bucket_table_destroy(gql_ir_compiled_field_bucket_table_t *table) {
  UV i;

  if (!table) {
    return;
  }

  if (table->entries) {
    for (i = 0; i < table->count; i++) {
      gql_ir_compiled_field_bucket_entry_t *entry = &table->entries[i];

      if (entry->result_name_sv) {
        SvREFCNT_dec(entry->result_name_sv);
        entry->result_name_sv = NULL;
      }
      if (entry->nodes_sv) {
        SvREFCNT_dec(entry->nodes_sv);
        entry->nodes_sv = NULL;
      }
    }
    Safefree(table->entries);
    table->entries = NULL;
  }

  Safefree(table);
}

static void
gql_ir_attach_concrete_field_plan_table(pTHX_ SV *sv, gql_ir_compiled_concrete_plan_table_t *table) {
  MAGIC *mg;
  SV *target = sv;

  if (!sv || !table) {
    return;
  }

  if (SvROK(target)) {
    target = SvRV(target);
  }

  sv_magicext(target, NULL, PERL_MAGIC_ext, &gql_ir_compiled_concrete_plan_table_vtbl, NULL, 0);
  mg = mg_findext(target, PERL_MAGIC_ext, &gql_ir_compiled_concrete_plan_table_vtbl);
  if (!mg) {
    gql_ir_compiled_concrete_plan_table_destroy(table);
    croak("failed to attach compiled concrete field plan table");
  }
  mg->mg_ptr = (char *)PTR2IV(table);
}

static void
gql_ir_attach_compiled_field_bucket_table(pTHX_ SV *sv, gql_ir_compiled_field_bucket_table_t *table) {
  MAGIC *mg;
  SV *target = sv;

  if (!sv || !table) {
    return;
  }

  if (SvROK(target)) {
    target = SvRV(target);
  }

  sv_magicext(target, NULL, PERL_MAGIC_ext, &gql_ir_compiled_field_bucket_table_vtbl, NULL, 0);
  mg = mg_findext(target, PERL_MAGIC_ext, &gql_ir_compiled_field_bucket_table_vtbl);
  if (!mg) {
    gql_ir_compiled_field_bucket_table_destroy(table);
    croak("failed to attach compiled field bucket table");
  }
  mg->mg_ptr = (char *)PTR2IV(table);
}

static gql_ir_compiled_concrete_plan_table_t *
gql_ir_get_concrete_field_plan_table(pTHX_ SV *sv) {
  MAGIC *mg;
  SV *target = sv;

  if (!sv) {
    return NULL;
  }

  if (SvROK(target)) {
    target = SvRV(target);
  }

  mg = mg_findext(target, PERL_MAGIC_ext, &gql_ir_compiled_concrete_plan_table_vtbl);
  if (!mg || !mg->mg_ptr) {
    return NULL;
  }

  return INT2PTR(gql_ir_compiled_concrete_plan_table_t *, mg->mg_ptr);
}

static gql_ir_compiled_field_bucket_table_t *
gql_ir_get_compiled_field_bucket_table(pTHX_ SV *sv) {
  MAGIC *mg;
  SV *target = sv;

  if (!sv) {
    return NULL;
  }

  if (SvROK(target)) {
    target = SvRV(target);
  }

  mg = mg_findext(target, PERL_MAGIC_ext, &gql_ir_compiled_field_bucket_table_vtbl);
  if (!mg || !mg->mg_ptr) {
    return NULL;
  }

  return INT2PTR(gql_ir_compiled_field_bucket_table_t *, mg->mg_ptr);
}

static gql_ir_compiled_field_bucket_table_t *
gql_ir_compiled_field_bucket_table_from_sv(pTHX_ SV *compiled_fields_sv) {
  AV *compiled_av;
  SV **compiled_names_svp;
  SV **compiled_defs_svp;
  AV *compiled_names_av;
  HV *compiled_defs_hv;
  I32 name_len;
  UV field_count;
  UV field_i;
  gql_ir_compiled_field_bucket_table_t *table = NULL;

  if (!compiled_fields_sv || !SvROK(compiled_fields_sv) || SvTYPE(SvRV(compiled_fields_sv)) != SVt_PVAV) {
    return NULL;
  }

  compiled_av = (AV *)SvRV(compiled_fields_sv);
  if (av_len(compiled_av) != 1) {
    return NULL;
  }

  compiled_names_svp = av_fetch(compiled_av, 0, 0);
  compiled_defs_svp = av_fetch(compiled_av, 1, 0);
  if (!compiled_names_svp || !compiled_defs_svp
      || !SvROK(*compiled_names_svp) || SvTYPE(SvRV(*compiled_names_svp)) != SVt_PVAV
      || !SvROK(*compiled_defs_svp) || SvTYPE(SvRV(*compiled_defs_svp)) != SVt_PVHV) {
    return NULL;
  }

  compiled_names_av = (AV *)SvRV(*compiled_names_svp);
  compiled_defs_hv = (HV *)SvRV(*compiled_defs_svp);
  name_len = av_len(compiled_names_av);
  field_count = name_len >= 0 ? (UV)(name_len + 1) : 0;

  Newxz(table, 1, gql_ir_compiled_field_bucket_table_t);
  table->count = field_count;
  if (field_count > 0) {
    Newxz(table->entries, field_count, gql_ir_compiled_field_bucket_entry_t);
  }

  for (field_i = 0; field_i < field_count; field_i++) {
    SV **result_name_svp = av_fetch(compiled_names_av, (I32)field_i, 0);
    HE *compiled_he;
    gql_ir_compiled_field_bucket_entry_t *entry = &table->entries[field_i];

    if (!result_name_svp || !SvOK(*result_name_svp)) {
      goto fail;
    }

    compiled_he = hv_fetch_ent(compiled_defs_hv, *result_name_svp, 0, 0);
    if (!compiled_he || !SvOK(HeVAL(compiled_he))) {
      goto fail;
    }

    entry->result_name_sv = gql_execution_share_or_copy_sv(*result_name_svp);
    entry->nodes_sv = gql_execution_share_or_copy_sv(HeVAL(compiled_he));
  }

  return table;

fail:
  gql_ir_compiled_field_bucket_table_destroy(table);
  return NULL;
}

static gql_ir_compiled_root_field_plan_t *
gql_ir_compiled_root_field_plan_from_sv(pTHX_ SV *root_field_plan_sv) {
  HV *root_field_plan_hv;
  SV **field_order_svp;
  SV **fields_svp;
  AV *field_order_av;
  HV *fields_hv;
  I32 field_len;
  UV field_count;
  UV field_i;
  gql_ir_compiled_root_field_plan_t *plan = NULL;

  if (!root_field_plan_sv
      || !SvROK(root_field_plan_sv)
      || SvTYPE(SvRV(root_field_plan_sv)) != SVt_PVHV) {
    return NULL;
  }

  root_field_plan_hv = (HV *)SvRV(root_field_plan_sv);
  field_order_svp = hv_fetch(root_field_plan_hv, "field_order", 11, 0);
  fields_svp = hv_fetch(root_field_plan_hv, "fields", 6, 0);
  if (!field_order_svp
      || !SvROK(*field_order_svp)
      || SvTYPE(SvRV(*field_order_svp)) != SVt_PVAV
      || !fields_svp
      || !SvROK(*fields_svp)
      || SvTYPE(SvRV(*fields_svp)) != SVt_PVHV) {
    return NULL;
  }

  field_order_av = (AV *)SvRV(*field_order_svp);
  fields_hv = (HV *)SvRV(*fields_svp);
  field_len = av_len(field_order_av);
  field_count = field_len >= 0 ? (UV)(field_len + 1) : 0;

  Newxz(plan, 1, gql_ir_compiled_root_field_plan_t);
  plan->field_count = field_count;
  if (field_count > 0) {
    Newxz(plan->entries, field_count, gql_ir_compiled_root_field_plan_entry_t);
  }

  for (field_i = 0; field_i < field_count; field_i++) {
    SV **result_name_svp = av_fetch(field_order_av, (I32)field_i, 0);
    HE *field_plan_he;
    HV *field_plan_hv;
    HV *field_def_hv;
    gql_ir_compiled_root_field_plan_entry_t *entry = &plan->entries[field_i];
    SV **field_name_svp;
    SV **field_def_svp;
    SV **type_svp;
    SV **resolve_svp;
    SV **field_args_svp;
    SV *completion_type_sv = NULL;
    UV trivial_completion_flags = 0;
    SV **nodes_svp;
    AV *nodes_av;
    SV **first_node_svp;
    SV **node_count_svp;
    SV **argument_count_svp;
    SV **directive_count_svp;
    SV **selection_count_svp;

    if (!result_name_svp || !SvOK(*result_name_svp)) {
      goto fail;
    }

    field_plan_he = hv_fetch_ent(fields_hv, *result_name_svp, 0, 0);
    if (!field_plan_he
        || !SvROK(HeVAL(field_plan_he))
        || SvTYPE(SvRV(HeVAL(field_plan_he))) != SVt_PVHV) {
      goto fail;
    }

    field_plan_hv = (HV *)SvRV(HeVAL(field_plan_he));
    field_name_svp = hv_fetch(field_plan_hv, "field_name", 10, 0);
    field_def_svp = hv_fetch(field_plan_hv, "field_def", 9, 0);
    nodes_svp = hv_fetch(field_plan_hv, "nodes", 5, 0);
    node_count_svp = hv_fetch(field_plan_hv, "node_count", 10, 0);
    argument_count_svp = hv_fetch(field_plan_hv, "argument_count", 14, 0);
    directive_count_svp = hv_fetch(field_plan_hv, "directive_count", 15, 0);
    selection_count_svp = hv_fetch(field_plan_hv, "selection_count", 15, 0);
    if (!field_name_svp
        || !SvOK(*field_name_svp)
        || !field_def_svp
        || !SvOK(*field_def_svp)
        || !nodes_svp
        || !SvOK(*nodes_svp)) {
      goto fail;
    }
    if (!SvROK(*nodes_svp) || SvTYPE(SvRV(*nodes_svp)) != SVt_PVAV) {
      goto fail;
    }
    nodes_av = (AV *)SvRV(*nodes_svp);
    first_node_svp = av_fetch(nodes_av, 0, 0);
    if (!first_node_svp || !SvROK(*first_node_svp) || SvTYPE(SvRV(*first_node_svp)) != SVt_PVHV) {
      goto fail;
    }

    field_def_hv = (HV *)SvRV(*field_def_svp);
    type_svp = hv_fetch(field_def_hv, "type", 4, 0);
    resolve_svp = hv_fetch(field_def_hv, "resolve", 7, 0);
    field_args_svp = hv_fetch(field_def_hv, "args", 4, 0);

    entry->result_name_sv = gql_execution_share_or_copy_sv(*result_name_svp);
    entry->field_name_sv = gql_execution_share_or_copy_sv(*field_name_svp);
    entry->field_def_sv = gql_execution_share_or_copy_sv(*field_def_svp);
    if (type_svp && SvOK(*type_svp)) {
      entry->return_type_sv = gql_execution_share_or_copy_sv(*type_svp);
    }
    if (type_svp && SvOK(*type_svp)) {
      entry->type_sv = gql_execution_share_or_copy_sv(*type_svp);
      if (gql_execution_get_trivial_completion_metadata(aTHX_ *type_svp, &completion_type_sv, &trivial_completion_flags)) {
        entry->completion_type_sv = completion_type_sv;
        entry->trivial_completion_flags = trivial_completion_flags;
        completion_type_sv = NULL;
      }
    }
    if (resolve_svp && SvOK(*resolve_svp)) {
      entry->resolve_sv = gql_execution_share_or_copy_sv(*resolve_svp);
    }
    entry->nodes_sv = gql_execution_share_or_copy_sv(*nodes_svp);
    entry->first_node_sv = gql_execution_share_or_copy_sv(*first_node_svp);
    entry->node_count = (node_count_svp && SvOK(*node_count_svp)) ? SvUV(*node_count_svp) : 0;
    entry->argument_count = (argument_count_svp && SvOK(*argument_count_svp)) ? SvUV(*argument_count_svp) : 0;
    entry->field_arg_count =
      (field_args_svp
       && SvROK(*field_args_svp)
       && SvTYPE(SvRV(*field_args_svp)) == SVt_PVHV)
        ? (UV)HvUSEDKEYS((HV *)SvRV(*field_args_svp))
        : 0;
    entry->directive_count = (directive_count_svp && SvOK(*directive_count_svp)) ? SvUV(*directive_count_svp) : 0;
    entry->selection_count = (selection_count_svp && SvOK(*selection_count_svp)) ? SvUV(*selection_count_svp) : 0;
    if (completion_type_sv) {
      SvREFCNT_dec(completion_type_sv);
      completion_type_sv = NULL;
    }
  }

  return plan;

fail:
  gql_ir_compiled_root_field_plan_destroy(plan);
  return NULL;
}

static void
gql_ir_compiled_strip_legacy_buckets_from_nodes(pTHX_ SV *nodes_sv) {
  AV *nodes_av;
  I32 node_len;
  I32 node_i;

  if (!nodes_sv || !SvROK(nodes_sv) || SvTYPE(SvRV(nodes_sv)) != SVt_PVAV) {
    return;
  }

  nodes_av = (AV *)SvRV(nodes_sv);
  node_len = av_len(nodes_av);
  for (node_i = 0; node_i <= node_len; node_i++) {
    SV **node_svp = av_fetch(nodes_av, node_i, 0);
    if (node_svp && SvOK(*node_svp)) {
      gql_ir_compiled_strip_legacy_buckets_from_node(aTHX_ *node_svp);
    }
  }
}

static void
gql_ir_compiled_strip_legacy_buckets_from_node(pTHX_ SV *node_sv) {
  HV *node_hv;
  SV **selections_svp;
  AV *selections_av;
  I32 selection_len;
  I32 selection_i;

  if (!node_sv || !SvROK(node_sv) || SvTYPE(SvRV(node_sv)) != SVt_PVHV) {
    return;
  }

  node_hv = (HV *)SvRV(node_sv);
  if (gql_ir_get_compiled_field_bucket_table(aTHX_ node_sv)) {
    (void)hv_delete(node_hv, "compiled_fields", 15, G_DISCARD);
  }
  if (gql_ir_get_concrete_field_plan_table(aTHX_ node_sv)) {
    (void)hv_delete(node_hv, "compiled_concrete_subfields", 27, G_DISCARD);
    (void)hv_delete(node_hv, "compiled_concrete_field_plans", 28, G_DISCARD);
  }

  selections_svp = hv_fetch(node_hv, "selections", 10, 0);
  if (!selections_svp
      || !SvROK(*selections_svp)
      || SvTYPE(SvRV(*selections_svp)) != SVt_PVAV) {
    return;
  }

  selections_av = (AV *)SvRV(*selections_svp);
  selection_len = av_len(selections_av);
  for (selection_i = 0; selection_i <= selection_len; selection_i++) {
    SV **selection_svp = av_fetch(selections_av, selection_i, 0);
    if (selection_svp && SvOK(*selection_svp)) {
      gql_ir_compiled_strip_legacy_buckets_from_node(aTHX_ *selection_svp);
    }
  }
}

static void
gql_ir_compiled_strip_legacy_buckets_from_fragments(pTHX_ SV *fragments_sv) {
  HV *fragments_hv;
  HE *he;

  if (!fragments_sv || !SvROK(fragments_sv) || SvTYPE(SvRV(fragments_sv)) != SVt_PVHV) {
    return;
  }

  fragments_hv = (HV *)SvRV(fragments_sv);
  hv_iterinit(fragments_hv);
  while ((he = hv_iternext(fragments_hv))) {
    SV *fragment_sv = HeVAL(he);
    if (fragment_sv && SvOK(fragment_sv)) {
      gql_ir_compiled_strip_legacy_buckets_from_node(aTHX_ fragment_sv);
    }
  }
}

static SV *
gql_ir_compiled_root_selection_plan_sv(pTHX_ gql_ir_compiled_exec_t *compiled) {
  gql_ir_prepared_exec_t *prepared;

  if (!compiled) {
    return &PL_sv_undef;
  }

  if (compiled->root_selection_plan_sv) {
    return compiled->root_selection_plan_sv;
  }

  prepared = gql_ir_compiled_prepared_exec(compiled);
  if (!prepared || !compiled->selected_operation) {
    return &PL_sv_undef;
  }

  compiled->root_selection_plan_sv = newRV_noinc((SV *)gql_ir_prepare_selection_plan_av(
    aTHX_ prepared,
    compiled->selected_operation->selection_set
  ));
  return compiled->root_selection_plan_sv;
}

static SV *
gql_ir_compiled_root_field_plan_legacy_sv(pTHX_ gql_ir_compiled_exec_t *compiled) {
  HV *root_field_plan_hv;
  AV *field_order_av;
  HV *fields_hv;
  UV field_i;

  if (!compiled) {
    return &PL_sv_undef;
  }

  if (compiled->root_field_plan_sv) {
    return compiled->root_field_plan_sv;
  }

  if (!compiled->root_field_plan) {
    return &PL_sv_undef;
  }

  root_field_plan_hv = newHV();
  field_order_av = newAV();
  fields_hv = newHV();
  gql_store_sv(
    root_field_plan_hv,
    "operation_type",
    newSVpv(gql_ir_operation_kind_name(compiled->selected_operation->operation), 0)
  );
  gql_store_sv(root_field_plan_hv, "root_type", gql_execution_share_or_copy_sv(compiled->root_type_sv));

  for (field_i = 0; field_i < compiled->root_field_plan->field_count; field_i++) {
    gql_ir_compiled_root_field_plan_entry_t *entry = &compiled->root_field_plan->entries[field_i];
    HV *field_plan_hv = newHV();

    gql_store_sv(field_plan_hv, "result_name", gql_execution_share_or_copy_sv(entry->result_name_sv));
    gql_store_sv(field_plan_hv, "field_name", gql_execution_share_or_copy_sv(entry->field_name_sv));
    gql_store_sv(field_plan_hv, "field_def", gql_execution_share_or_copy_sv(entry->field_def_sv));
    if (entry->return_type_sv) {
      gql_store_sv(field_plan_hv, "return_type", gql_execution_share_or_copy_sv(entry->return_type_sv));
    }
    gql_store_sv(field_plan_hv, "nodes", gql_execution_share_or_copy_sv(entry->nodes_sv));
    if (entry->path_sv && SvOK(entry->path_sv)) {
      gql_store_sv(field_plan_hv, "path", gql_execution_share_or_copy_sv(entry->path_sv));
    } else {
      AV *path_av = newAV();
      av_push(path_av, gql_execution_share_or_copy_sv(entry->result_name_sv));
      gql_store_sv(field_plan_hv, "path", newRV_noinc((SV *)path_av));
    }
    hv_stores(field_plan_hv, "node_count", newSVuv(entry->node_count));
    hv_stores(field_plan_hv, "argument_count", newSVuv(entry->argument_count));
    hv_stores(field_plan_hv, "directive_count", newSVuv(entry->directive_count));
    hv_stores(field_plan_hv, "selection_count", newSVuv(entry->selection_count));

    av_push(field_order_av, gql_execution_share_or_copy_sv(entry->result_name_sv));
    (void)hv_store_ent(
      fields_hv,
      gql_execution_share_or_copy_sv(entry->result_name_sv),
      newRV_noinc((SV *)field_plan_hv),
      0
    );
  }

  gql_store_sv(root_field_plan_hv, "field_order", newRV_noinc((SV *)field_order_av));
  gql_store_sv(root_field_plan_hv, "fields", newRV_noinc((SV *)fields_hv));
  compiled->root_field_plan_sv = newRV_noinc((SV *)root_field_plan_hv);
  return compiled->root_field_plan_sv;
}

static gql_ir_prepared_exec_t *
gql_ir_compiled_prepared_exec(gql_ir_compiled_exec_t *compiled) {
  SV *prepared_inner_sv;

  if (!compiled
      || !compiled->prepared_handle_sv
      || !SvROK(compiled->prepared_handle_sv)
      || !sv_derived_from(compiled->prepared_handle_sv, "GraphQL::Houtou::XS::PreparedIR")) {
    return NULL;
  }

  prepared_inner_sv = SvRV(compiled->prepared_handle_sv);
  if (!SvIOK(prepared_inner_sv) || SvUV(prepared_inner_sv) == 0) {
    return NULL;
  }

  return INT2PTR(gql_ir_prepared_exec_t *, SvUV(prepared_inner_sv));
}

static SV *
gql_ir_compiled_operation_legacy_sv(pTHX_ gql_ir_compiled_exec_t *compiled) {
  gql_ir_prepared_exec_t *prepared = gql_ir_compiled_prepared_exec(compiled);

  if (!prepared || !compiled || !compiled->selected_operation) {
    return &PL_sv_undef;
  }

  return gql_ir_operation_to_legacy_sv(aTHX_ prepared, compiled->selected_operation, compiled->operation_name_sv);
}

static SV *
gql_ir_compiled_fragments_legacy_sv(pTHX_ gql_ir_compiled_exec_t *compiled) {
  gql_ir_prepared_exec_t *prepared = gql_ir_compiled_prepared_exec(compiled);
  SV *fragments_sv;

  if (!prepared) {
    return &PL_sv_undef;
  }

  fragments_sv = gql_ir_fragment_definitions_to_legacy_map_sv(aTHX_ prepared);
  if (fragments_sv != &PL_sv_undef) {
    gql_ir_compiled_strip_legacy_buckets_from_fragments(aTHX_ fragments_sv);
  }
  return fragments_sv;
}

static SV *
gql_ir_compiled_root_legacy_fields_sv(pTHX_ gql_ir_compiled_exec_t *compiled) {
  gql_ir_prepared_exec_t *prepared = gql_ir_compiled_prepared_exec(compiled);

  if (!prepared || !compiled || !compiled->schema_sv) {
    return &PL_sv_undef;
  }

  return gql_ir_prepare_executable_root_legacy_fields_sv(aTHX_ compiled->schema_sv, prepared, compiled->operation_name_sv);
}

static SV *gql_ir_selection_to_legacy_sv(pTHX_ gql_ir_document_t *document, gql_ir_selection_t *selection);
static AV *gql_ir_selections_to_legacy_av(pTHX_ gql_ir_document_t *document, gql_ir_selection_set_t *selection_set);
static SV *gql_ir_value_to_legacy_sv(pTHX_ gql_ir_document_t *document, gql_ir_value_t *value);
static SV *gql_ir_directives_to_legacy_sv(pTHX_ gql_ir_document_t *document, gql_ir_ptr_array_t *directives);
static int gql_ir_selection_set_is_plain_fields(gql_ir_selection_set_t *selection_set);
static SV *gql_ir_selection_set_to_legacy_fields_sv(pTHX_ gql_ir_document_t *document, gql_ir_selection_set_t *selection_set);

static SV *
gql_ir_compiled_unwrap_output_type(pTHX_ SV *field_def_sv) {
  SV **type_svp;
  SV *current;

  if (!field_def_sv || !SvROK(field_def_sv) || SvTYPE(SvRV(field_def_sv)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  type_svp = hv_fetch((HV *)SvRV(field_def_sv), "type", 4, 0);
  if (!type_svp || !SvOK(*type_svp)) {
    return &PL_sv_undef;
  }

  current = newSVsv(*type_svp);
  while (sv_derived_from(current, "GraphQL::Houtou::Type::NonNull")
      || sv_derived_from(current, "GraphQL::Type::NonNull")
      || sv_derived_from(current, "GraphQL::Houtou::Type::List")
      || sv_derived_from(current, "GraphQL::Type::List")) {
    SV *inner = gql_execution_call_type_of(aTHX_ current);
    SvREFCNT_dec(current);
    current = inner;
  }

  return current;
}

static SV *
gql_ir_compiled_attach_concrete_output_type(pTHX_ SV *field_def_sv) {
  SV *current = gql_ir_compiled_unwrap_output_type(aTHX_ field_def_sv);

  if (current == &PL_sv_undef) {
    return &PL_sv_undef;
  }

  if (sv_derived_from(current, "GraphQL::Houtou::Type::Object")
      || sv_derived_from(current, "GraphQL::Type::Object")) {
    return current;
  }

  SvREFCNT_dec(current);
  return &PL_sv_undef;
}

static void
gql_ir_attach_compiled_concrete_subfields_to_node(
  pTHX_ SV *schema,
  SV *abstract_type,
  SV *fragments_sv,
  SV *selection_sv
) {
  SV **child_selections_svp;
  HV *selection_hv;
  SV *possible_types_sv;
  HV *context_hv;
  SV *context_sv;
  gql_ir_compiled_concrete_plan_table_t *compiled_plan_table = NULL;
  UV compiled_plan_table_count = 0;
  I32 possible_i;
  I32 possible_len;

  if (!selection_sv || !SvROK(selection_sv) || SvTYPE(SvRV(selection_sv)) != SVt_PVHV) {
    return;
  }

  selection_hv = (HV *)SvRV(selection_sv);
  child_selections_svp = hv_fetch(selection_hv, "selections", 10, 0);
  if (!child_selections_svp
      || !SvROK(*child_selections_svp)
      || SvTYPE(SvRV(*child_selections_svp)) != SVt_PVAV) {
    return;
  }

  possible_types_sv = gql_execution_schema_possible_types_sv(aTHX_ schema, abstract_type);
  if (possible_types_sv == &PL_sv_undef
      || !SvROK(possible_types_sv)
      || SvTYPE(SvRV(possible_types_sv)) != SVt_PVAV) {
    if (possible_types_sv != &PL_sv_undef) {
      SvREFCNT_dec(possible_types_sv);
    }
    return;
  }

  context_hv = newHV();
  {
    UV possible_count = possible_types_sv && SvROK(possible_types_sv) && SvTYPE(SvRV(possible_types_sv)) == SVt_PVAV
      ? (UV)(av_len((AV *)SvRV(possible_types_sv)) + 1)
      : 0;
    if (possible_count > 0) {
      Newxz(compiled_plan_table, 1, gql_ir_compiled_concrete_plan_table_t);
      Newxz(compiled_plan_table->entries, possible_count, gql_ir_compiled_concrete_plan_entry_t);
    }
  }
  gql_store_sv(context_hv, "schema", gql_execution_share_or_copy_sv(schema));
  {
    HV *runtime_cache_hv = gql_execution_schema_runtime_cache_hv(aTHX_ schema);
    if (runtime_cache_hv) {
      gql_store_sv(context_hv, "runtime_cache", newRV_inc((SV *)runtime_cache_hv));
    }
  }
  gql_store_sv(
    context_hv,
    "fragments",
    (fragments_sv && SvOK(fragments_sv))
      ? gql_execution_share_or_copy_sv(fragments_sv)
      : newRV_noinc((SV *)newHV())
  );
  gql_store_sv(context_hv, "variable_values", newRV_noinc((SV *)newHV()));
  context_sv = newRV_noinc((SV *)context_hv);

  possible_len = av_len((AV *)SvRV(possible_types_sv));
  for (possible_i = 0; possible_i <= possible_len; possible_i++) {
    SV **possible_svp = av_fetch((AV *)SvRV(possible_types_sv), possible_i, 0);
    SV *possible_type;

    if (!possible_svp || !SvROK(*possible_svp)) {
      continue;
    }

    possible_type = *possible_svp;
    if (!(sv_derived_from(possible_type, "GraphQL::Houtou::Type::Object")
          || sv_derived_from(possible_type, "GraphQL::Type::Object"))) {
      continue;
    }

    {
      AV *node_bucket_av = newAV();
      SV *node_bucket_sv;
      SV *compiled_fields_sv;
      SV *compiled_plan_sv;
      SV *type_name_sv;
      int ok = 0;

      av_push(node_bucket_av, newSVsv(selection_sv));
      node_bucket_sv = newRV_noinc((SV *)node_bucket_av);
      compiled_fields_sv = gql_execution_collect_simple_object_fields(
        aTHX_
        context_sv,
        possible_type,
        node_bucket_sv,
        &ok
      );
      SvREFCNT_dec(node_bucket_sv);

      if (!ok || compiled_fields_sv == &PL_sv_undef || !SvOK(compiled_fields_sv)) {
        continue;
      }

      type_name_sv = gql_execution_type_name_sv(aTHX_ possible_type);
      if (!type_name_sv || !SvOK(type_name_sv)) {
        SvREFCNT_dec(compiled_fields_sv);
        continue;
      }

      compiled_plan_sv = gql_execution_build_field_plan_from_compiled_fields(
        aTHX_
        schema,
        possible_type,
        compiled_fields_sv
      );
      if (compiled_plan_sv != &PL_sv_undef && SvOK(compiled_plan_sv)) {
        gql_ir_compiled_root_field_plan_t *native_field_plan
          = gql_ir_compiled_root_field_plan_from_sv(aTHX_ compiled_plan_sv);
        if (compiled_plan_table && compiled_plan_table->entries) {
          gql_ir_compiled_concrete_plan_entry_t *entry = &compiled_plan_table->entries[compiled_plan_table_count++];
          entry->possible_type_sv = gql_execution_share_or_copy_sv(possible_type);
          entry->compiled_fields_sv = gql_execution_share_or_copy_sv(compiled_fields_sv);
          if (native_field_plan) {
            entry->native_field_plan = native_field_plan;
            native_field_plan = NULL;
          } else {
            entry->field_plan_sv = gql_execution_share_or_copy_sv(compiled_plan_sv);
          }
        }
        if (native_field_plan) {
          gql_ir_compiled_root_field_plan_destroy(native_field_plan);
        }
        SvREFCNT_dec(compiled_plan_sv);
      } else if (compiled_plan_sv != &PL_sv_undef) {
        SvREFCNT_dec(compiled_plan_sv);
      }
      SvREFCNT_dec(compiled_fields_sv);
      SvREFCNT_dec(type_name_sv);
    }
  }

  if (compiled_plan_table) {
    compiled_plan_table->count = compiled_plan_table_count;
    if (compiled_plan_table_count > 0) {
      gql_ir_attach_concrete_field_plan_table(aTHX_ selection_sv, compiled_plan_table);
      compiled_plan_table = NULL;
    }
  }

  SvREFCNT_dec(context_sv);
  SvREFCNT_dec(possible_types_sv);
  if (compiled_plan_table) {
    gql_ir_compiled_concrete_plan_table_destroy(compiled_plan_table);
  }
}

static void
gql_ir_attach_compiled_field_defs_to_selection_sv(
  pTHX_ SV *schema,
  SV *parent_type,
  SV *selection_sv,
  SV *fragments_sv
) {
  HV *selection_hv;
  SV **kind_svp;
  STRLEN kind_len;
  const char *kind_pv;

  if (!parent_type || !SvOK(parent_type) || !selection_sv || !SvROK(selection_sv) || SvTYPE(SvRV(selection_sv)) != SVt_PVHV) {
    return;
  }

  selection_hv = (HV *)SvRV(selection_sv);
  kind_svp = hv_fetch(selection_hv, "kind", 4, 0);
  if (!kind_svp || !SvOK(*kind_svp)) {
    return;
  }
  kind_pv = SvPV(*kind_svp, kind_len);

  if (kind_len == 5 && strEQ(kind_pv, "field")) {
    SV **name_svp = hv_fetch(selection_hv, "name", 4, 0);
    SV **child_selections_svp = hv_fetch(selection_hv, "selections", 10, 0);

    if (name_svp && SvOK(*name_svp)) {
      SV *field_def_sv = gql_execution_get_field_def(aTHX_ schema, parent_type, *name_svp);
      if (field_def_sv && SvOK(field_def_sv) && field_def_sv != &PL_sv_undef) {
        SV *output_type_sv;
        SV *child_parent_type_sv;
        gql_store_sv(selection_hv, "compiled_field_def", field_def_sv);
        output_type_sv = gql_ir_compiled_unwrap_output_type(aTHX_ field_def_sv);
        child_parent_type_sv = gql_ir_compiled_attach_concrete_output_type(aTHX_ field_def_sv);
        if (child_parent_type_sv != &PL_sv_undef
            && child_selections_svp
            && SvROK(*child_selections_svp)
            && SvTYPE(SvRV(*child_selections_svp)) == SVt_PVAV) {
          gql_ir_attach_compiled_field_defs_to_selections(
            aTHX_
            schema,
            child_parent_type_sv,
            (AV *)SvRV(*child_selections_svp),
            fragments_sv
          );
          SvREFCNT_dec(child_parent_type_sv);
        } else if (output_type_sv != &PL_sv_undef
                   && (sv_does(output_type_sv, "GraphQL::Houtou::Role::Abstract")
                       || sv_does(output_type_sv, "GraphQL::Role::Abstract"))) {
          gql_ir_attach_compiled_concrete_subfields_to_node(
            aTHX_
            schema,
            output_type_sv,
            fragments_sv,
            selection_sv
          );
        }
        if (output_type_sv != &PL_sv_undef) {
          SvREFCNT_dec(output_type_sv);
        }
      }
    }
    return;
  }

  if (kind_len == 15 && strEQ(kind_pv, "inline_fragment")) {
    SV **child_selections_svp = hv_fetch(selection_hv, "selections", 10, 0);
    if (child_selections_svp
        && SvROK(*child_selections_svp)
        && SvTYPE(SvRV(*child_selections_svp)) == SVt_PVAV) {
      gql_ir_attach_compiled_field_defs_to_selections(
        aTHX_
        schema,
        parent_type,
        (AV *)SvRV(*child_selections_svp),
        fragments_sv
      );
    }
  }
}

static void
gql_ir_attach_compiled_field_defs_to_selections(
  pTHX_ SV *schema,
  SV *parent_type,
  AV *selections_av,
  SV *fragments_sv
) {
  I32 selection_i;
  I32 selection_len;

  if (!parent_type || !SvOK(parent_type) || !selections_av) {
    return;
  }

  selection_len = av_len(selections_av);
  for (selection_i = 0; selection_i <= selection_len; selection_i++) {
    SV **selection_svp = av_fetch(selections_av, selection_i, 0);

    if (!selection_svp) {
      continue;
    }

    gql_ir_attach_compiled_field_defs_to_selection_sv(
      aTHX_
      schema,
      parent_type,
      *selection_svp,
      fragments_sv
    );
  }
}

static void
gql_ir_attach_compiled_field_defs_to_nodes(pTHX_ SV *schema, SV *parent_type, SV *nodes_sv, SV *fragments_sv) {
  AV *nodes_av;
  I32 node_i;
  I32 node_len;

  if (!nodes_sv || !SvROK(nodes_sv) || SvTYPE(SvRV(nodes_sv)) != SVt_PVAV) {
    return;
  }

  nodes_av = (AV *)SvRV(nodes_sv);
  node_len = av_len(nodes_av);

  for (node_i = 0; node_i <= node_len; node_i++) {
    SV **node_svp = av_fetch(nodes_av, node_i, 0);

    if (!node_svp) {
      continue;
    }

    gql_ir_attach_compiled_field_defs_to_selection_sv(
      aTHX_
      schema,
      parent_type,
      *node_svp,
      fragments_sv
    );
  }
}

static SV *
gql_ir_lookup_concrete_type_by_name(pTHX_ SV *schema, SV *type_name_sv) {
  HV *runtime_cache_hv;
  SV **name2type_svp;
  HE *type_he;
  SV *type_sv;

  if (!schema || !SvROK(schema) || SvTYPE(SvRV(schema)) != SVt_PVHV || !type_name_sv || !SvOK(type_name_sv)) {
    return &PL_sv_undef;
  }

  runtime_cache_hv = gql_execution_schema_runtime_cache_hv(aTHX_ schema);
  name2type_svp = runtime_cache_hv
    ? hv_fetch(runtime_cache_hv, "name2type", 9, 0)
    : hv_fetch((HV *)SvRV(schema), "name2type", 9, 0);
  if (!name2type_svp || !SvROK(*name2type_svp) || SvTYPE(SvRV(*name2type_svp)) != SVt_PVHV) {
    return &PL_sv_undef;
  }

  type_he = hv_fetch_ent((HV *)SvRV(*name2type_svp), type_name_sv, 0, 0);
  type_sv = type_he ? HeVAL(type_he) : NULL;
  if (!type_sv || !SvOK(type_sv)) {
    return &PL_sv_undef;
  }

  if (sv_derived_from(type_sv, "GraphQL::Houtou::Type::Object")
      || sv_derived_from(type_sv, "GraphQL::Type::Object")) {
    return gql_execution_share_or_copy_sv(type_sv);
  }

  return &PL_sv_undef;
}

static void
gql_ir_attach_compiled_field_defs_to_fragments(pTHX_ SV *schema, SV *fragments_sv) {
  HV *fragments_hv;
  HE *he;

  if (!fragments_sv || !SvROK(fragments_sv) || SvTYPE(SvRV(fragments_sv)) != SVt_PVHV) {
    return;
  }

  fragments_hv = (HV *)SvRV(fragments_sv);
  hv_iterinit(fragments_hv);
  while ((he = hv_iternext(fragments_hv))) {
    SV *fragment_sv = HeVAL(he);
    HV *fragment_hv;
    SV **on_svp;
    SV **selections_svp;
    SV *parent_type_sv;

    if (!fragment_sv || !SvROK(fragment_sv) || SvTYPE(SvRV(fragment_sv)) != SVt_PVHV) {
      continue;
    }

    fragment_hv = (HV *)SvRV(fragment_sv);
    on_svp = hv_fetch(fragment_hv, "on", 2, 0);
    selections_svp = hv_fetch(fragment_hv, "selections", 10, 0);
    if (!on_svp || !SvOK(*on_svp) || !selections_svp || !SvROK(*selections_svp) || SvTYPE(SvRV(*selections_svp)) != SVt_PVAV) {
      continue;
    }

    parent_type_sv = gql_ir_lookup_concrete_type_by_name(aTHX_ schema, *on_svp);
    if (parent_type_sv == &PL_sv_undef) {
      continue;
    }

    gql_ir_attach_compiled_field_defs_to_selections(
      aTHX_
      schema,
      parent_type_sv,
      (AV *)SvRV(*selections_svp),
      fragments_sv
    );
    SvREFCNT_dec(parent_type_sv);
  }
}

static int
gql_ir_selection_set_is_plain_fields(gql_ir_selection_set_t *selection_set) {
  UV i;

  if (!selection_set) {
    return 1;
  }

  for (i = 0; i < (UV)selection_set->selections.count; i++) {
    gql_ir_selection_t *selection = (gql_ir_selection_t *)selection_set->selections.items[i];

    if (!selection) {
      return 0;
    }

    switch (selection->kind) {
      case GQL_IR_SELECTION_FIELD: {
        gql_ir_field_t *field = selection->as.field;
        if (field->directives.count > 0) {
          return 0;
        }
        break;
      }
      case GQL_IR_SELECTION_INLINE_FRAGMENT: {
        gql_ir_inline_fragment_t *fragment = selection->as.inline_fragment;
        if (fragment->directives.count > 0) {
          return 0;
        }
        if (fragment->type_condition.start != fragment->type_condition.end) {
          return 0;
        }
        if (!gql_ir_selection_set_is_plain_fields(fragment->selection_set)) {
          return 0;
        }
        break;
      }
      default:
        return 0;
    }
  }

  return 1;
}

static SV *
gql_ir_selection_set_to_legacy_fields_sv(pTHX_ gql_ir_document_t *document, gql_ir_selection_set_t *selection_set) {
  AV *field_names_av = newAV();
  HV *nodes_defs_hv = newHV();
  AV *ret_av = newAV();
  UV i;

  if (selection_set) {
    for (i = 0; i < (UV)selection_set->selections.count; i++) {
      gql_ir_selection_t *selection = (gql_ir_selection_t *)selection_set->selections.items[i];

      if (!selection) {
        continue;
      }

      switch (selection->kind) {
        case GQL_IR_SELECTION_FIELD: {
          gql_ir_field_t *field = selection->as.field;
          SV *result_name_sv;
          HE *bucket_he;
          AV *bucket_av;

          result_name_sv = (field->alias.start != field->alias.end)
            ? gql_ir_make_sv_from_span(aTHX_ document, field->alias)
            : gql_ir_make_sv_from_span(aTHX_ document, field->name);
          bucket_he = hv_fetch_ent(nodes_defs_hv, result_name_sv, 0, 0);
          if (!bucket_he) {
            bucket_av = newAV();
            {
              SV *result_name_key_sv = newSVsv(result_name_sv);
              (void)hv_store_ent(nodes_defs_hv, result_name_key_sv, newRV_noinc((SV *)bucket_av), 0);
              SvREFCNT_dec(result_name_key_sv);
            }
            av_push(field_names_av, newSVsv(result_name_sv));
          } else if (SvROK(HeVAL(bucket_he)) && SvTYPE(SvRV(HeVAL(bucket_he))) == SVt_PVAV) {
            bucket_av = (AV *)SvRV(HeVAL(bucket_he));
          } else {
            SvREFCNT_dec(result_name_sv);
            SvREFCNT_dec((SV *)field_names_av);
            SvREFCNT_dec((SV *)nodes_defs_hv);
            SvREFCNT_dec((SV *)ret_av);
            croak("compiled legacy field bucket is invalid");
          }

          av_push(bucket_av, gql_ir_selection_to_legacy_sv(aTHX_ document, selection));
          SvREFCNT_dec(result_name_sv);
          break;
        }
        case GQL_IR_SELECTION_INLINE_FRAGMENT: {
          gql_ir_inline_fragment_t *fragment = selection->as.inline_fragment;
          SV *fragment_fields_sv;
          AV *fragment_av;
          SV **fragment_names_svp;
          SV **fragment_defs_svp;
          AV *fragment_names_av;
          HV *fragment_defs_hv;
          I32 name_i;
          I32 name_len;

          if (fragment->type_condition.start != fragment->type_condition.end || fragment->directives.count > 0) {
            SvREFCNT_dec((SV *)field_names_av);
            SvREFCNT_dec((SV *)nodes_defs_hv);
            SvREFCNT_dec((SV *)ret_av);
            croak("compiled legacy inline fragment bucket must be unconditional");
          }

          fragment_fields_sv = gql_ir_selection_set_to_legacy_fields_sv(aTHX_ document, fragment->selection_set);
          fragment_av = (AV *)SvRV(fragment_fields_sv);
          fragment_names_svp = av_fetch(fragment_av, 0, 0);
          fragment_defs_svp = av_fetch(fragment_av, 1, 0);
          fragment_names_av = (AV *)SvRV(*fragment_names_svp);
          fragment_defs_hv = (HV *)SvRV(*fragment_defs_svp);
          name_len = av_len(fragment_names_av);

          for (name_i = 0; name_i <= name_len; name_i++) {
            SV **name_svp = av_fetch(fragment_names_av, name_i, 0);
            HE *source_he;
            HE *target_he;
            AV *source_bucket;
            AV *target_bucket;
            I32 bucket_i;
            I32 bucket_len;

            if (!name_svp || !SvOK(*name_svp)) {
              continue;
            }

            source_he = hv_fetch_ent(fragment_defs_hv, *name_svp, 0, 0);
            if (!source_he || !SvROK(HeVAL(source_he)) || SvTYPE(SvRV(HeVAL(source_he))) != SVt_PVAV) {
              SvREFCNT_dec(fragment_fields_sv);
              SvREFCNT_dec((SV *)field_names_av);
              SvREFCNT_dec((SV *)nodes_defs_hv);
              SvREFCNT_dec((SV *)ret_av);
              croak("compiled legacy inline fragment bucket is invalid");
            }

            source_bucket = (AV *)SvRV(HeVAL(source_he));
            target_he = hv_fetch_ent(nodes_defs_hv, *name_svp, 0, 0);
            if (!target_he) {
              target_bucket = newAV();
              {
                SV *target_name_key_sv = newSVsv(*name_svp);
                (void)hv_store_ent(nodes_defs_hv, target_name_key_sv, newRV_noinc((SV *)target_bucket), 0);
                SvREFCNT_dec(target_name_key_sv);
              }
              av_push(field_names_av, newSVsv(*name_svp));
            } else if (SvROK(HeVAL(target_he)) && SvTYPE(SvRV(HeVAL(target_he))) == SVt_PVAV) {
              target_bucket = (AV *)SvRV(HeVAL(target_he));
            } else {
              SvREFCNT_dec(fragment_fields_sv);
              SvREFCNT_dec((SV *)field_names_av);
              SvREFCNT_dec((SV *)nodes_defs_hv);
              SvREFCNT_dec((SV *)ret_av);
              croak("compiled legacy inline fragment target bucket is invalid");
            }

            bucket_len = av_len(source_bucket);
            for (bucket_i = 0; bucket_i <= bucket_len; bucket_i++) {
              SV **node_svp = av_fetch(source_bucket, bucket_i, 0);
              if (node_svp && SvOK(*node_svp)) {
                av_push(target_bucket, newSVsv(*node_svp));
              }
            }
          }

          SvREFCNT_dec(fragment_fields_sv);
          break;
        }
        default:
          break;
      }
    }
  }

  av_push(ret_av, newRV_noinc((SV *)field_names_av));
  av_push(ret_av, newRV_noinc((SV *)nodes_defs_hv));
  return newRV_noinc((SV *)ret_av);
}

static int
gql_ir_prepare_collect_root_legacy_fields_into(
  pTHX_ gql_ir_prepared_exec_t *prepared,
  SV *root_type,
  gql_ir_selection_set_t *selection_set,
  AV *field_names_av,
  HV *nodes_defs_hv
) {
  UV i;

  if (!selection_set) {
    return 1;
  }

  for (i = 0; i < (UV)selection_set->selections.count; i++) {
    gql_ir_selection_t *selection = (gql_ir_selection_t *)selection_set->selections.items[i];

    if (!selection) {
      continue;
    }

    switch (selection->kind) {
      case GQL_IR_SELECTION_FIELD: {
        gql_ir_field_t *field = selection->as.field;
        SV *result_name_sv;
        HE *bucket_he;
        AV *bucket_av;

        if (field->directives.count > 0) {
          return 0;
        }

        result_name_sv = (field->alias.start != field->alias.end)
          ? gql_ir_make_sv_from_span(aTHX_ prepared->document, field->alias)
          : gql_ir_make_sv_from_span(aTHX_ prepared->document, field->name);
        bucket_he = hv_fetch_ent(nodes_defs_hv, result_name_sv, 0, 0);
        if (!bucket_he) {
          bucket_av = newAV();
          {
            SV *result_name_key_sv = newSVsv(result_name_sv);
            (void)hv_store_ent(nodes_defs_hv, result_name_key_sv, newRV_noinc((SV *)bucket_av), 0);
            SvREFCNT_dec(result_name_key_sv);
          }
          av_push(field_names_av, newSVsv(result_name_sv));
        } else if (SvROK(HeVAL(bucket_he)) && SvTYPE(SvRV(HeVAL(bucket_he))) == SVt_PVAV) {
          bucket_av = (AV *)SvRV(HeVAL(bucket_he));
        } else {
          SvREFCNT_dec(result_name_sv);
          return 0;
        }
        av_push(bucket_av, gql_ir_selection_to_legacy_sv(aTHX_ prepared->document, selection));
        SvREFCNT_dec(result_name_sv);
        break;
      }
      case GQL_IR_SELECTION_FRAGMENT_SPREAD: {
        gql_ir_fragment_spread_t *spread = selection->as.fragment_spread;
        SV *fragment_name_sv;
        STRLEN name_len;
        const char *name;
        gql_ir_fragment_definition_t *fragment;

        if (spread->directives.count > 0) {
          return 0;
        }
        fragment_name_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, spread->name);
        name = SvPV(fragment_name_sv, name_len);
        fragment = gql_ir_prepare_find_fragment_by_name(aTHX_ prepared, name, name_len);
        SvREFCNT_dec(fragment_name_sv);
        if (!fragment) {
          return 0;
        }
        if (!gql_ir_prepare_type_condition_matches_root(aTHX_ prepared, root_type, fragment->type_condition)) {
          continue;
        }
        if (!gql_ir_prepare_collect_root_legacy_fields_into(
              aTHX_ prepared,
              root_type,
              fragment->selection_set,
              field_names_av,
              nodes_defs_hv
            )) {
          return 0;
        }
        break;
      }
      case GQL_IR_SELECTION_INLINE_FRAGMENT: {
        gql_ir_inline_fragment_t *fragment = selection->as.inline_fragment;
        if (fragment->directives.count > 0) {
          return 0;
        }
        if (!gql_ir_prepare_type_condition_matches_root(aTHX_ prepared, root_type, fragment->type_condition)) {
          continue;
        }
        if (!gql_ir_prepare_collect_root_legacy_fields_into(
              aTHX_ prepared,
              root_type,
              fragment->selection_set,
              field_names_av,
              nodes_defs_hv
            )) {
          return 0;
        }
        break;
      }
      default:
        return 0;
    }
  }

  return 1;
}

static SV *
gql_ir_prepare_executable_root_legacy_fields_sv(
  pTHX_ SV *schema,
  gql_ir_prepared_exec_t *prepared,
  SV *operation_name
) {
  AV *field_names_av = newAV();
  HV *nodes_defs_hv = newHV();
  AV *ret_av = newAV();
  gql_ir_operation_definition_t *selected;
  const char *operation_type;
  SV *root_type_sv;

  selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);
  operation_type = gql_ir_operation_kind_name(selected->operation);
  root_type_sv = gql_execution_call_schema_root_type(aTHX_ schema, operation_type);

  if (!gql_ir_prepare_collect_root_legacy_fields_into(
        aTHX_ prepared,
        root_type_sv,
        selected->selection_set,
        field_names_av,
        nodes_defs_hv
      )) {
    SvREFCNT_dec(root_type_sv);
    SvREFCNT_dec((SV *)field_names_av);
    SvREFCNT_dec((SV *)nodes_defs_hv);
    SvREFCNT_dec((SV *)ret_av);
    croak("IR root legacy field bridge requires simple root selections");
  }

  SvREFCNT_dec(root_type_sv);
  av_push(ret_av, newRV_noinc((SV *)field_names_av));
  av_push(ret_av, newRV_noinc((SV *)nodes_defs_hv));
  return newRV_noinc((SV *)ret_av);
}

static int
gql_ir_prepare_operation_name_matches(SV *left, SV *right) {
  if ((!left || !SvOK(left)) && (!right || !SvOK(right))) {
    return 1;
  }
  if (!left || !SvOK(left) || !right || !SvOK(right)) {
    return 0;
  }
  return sv_eq(left, right);
}

static SV *
gql_ir_type_to_legacy_typedef_sv(pTHX_ gql_ir_document_t *document, gql_ir_type_t *type) {
  if (!type) {
    return newSV(0);
  }

  switch (type->kind) {
    case GQL_IR_TYPE_NAMED:
      return gql_ir_make_sv_from_span(aTHX_ document, type->name);
    case GQL_IR_TYPE_LIST: {
      AV *av = newAV();
      HV *hv = newHV();
      av_push(av, newSVpv("list", 0));
      gql_store_sv(hv, "type", gql_ir_type_to_legacy_typedef_sv(aTHX_ document, type->inner));
      av_push(av, newRV_noinc((SV *)hv));
      return newRV_noinc((SV *)av);
    }
    case GQL_IR_TYPE_NON_NULL: {
      AV *av = newAV();
      HV *hv = newHV();
      av_push(av, newSVpv("non_null", 0));
      gql_store_sv(hv, "type", gql_ir_type_to_legacy_typedef_sv(aTHX_ document, type->inner));
      av_push(av, newRV_noinc((SV *)hv));
      return newRV_noinc((SV *)av);
    }
    default:
      return newSV(0);
  }
}

static SV *
gql_ir_variable_definitions_to_legacy_sv(
  pTHX_ gql_ir_document_t *document,
  gql_ir_ptr_array_t *variable_definitions
) {
  HV *hv = newHV();
  UV i;

  if (!variable_definitions || variable_definitions->count == 0) {
    return newRV_noinc((SV *)hv);
  }

  for (i = 0; i < (UV)variable_definitions->count; i++) {
    gql_ir_variable_definition_t *definition = (gql_ir_variable_definition_t *)variable_definitions->items[i];
    HV *var_hv;
    SV *name_sv;

    if (!definition) {
      continue;
    }

    var_hv = newHV();
    name_sv = gql_ir_make_sv_from_span(aTHX_ document, definition->name);
    gql_store_sv(var_hv, "type", gql_ir_type_to_legacy_typedef_sv(aTHX_ document, definition->type));
    if (definition->default_value) {
      gql_store_sv(var_hv, "default_value", gql_ir_value_to_legacy_sv(aTHX_ document, definition->default_value));
    }
    {
      SV *directives_sv = gql_ir_directives_to_legacy_sv(aTHX_ document, &definition->directives);
      if (directives_sv && directives_sv != &PL_sv_undef) {
        gql_store_sv(var_hv, "directives", directives_sv);
      }
    }
    (void)hv_store_ent(hv, name_sv, newRV_noinc((SV *)var_hv), 0);
    SvREFCNT_dec(name_sv);
  }

  return newRV_noinc((SV *)hv);
}

static SV *
gql_ir_fragment_definitions_to_legacy_map_sv(pTHX_ gql_ir_prepared_exec_t *prepared) {
  if (prepared->cached_fragments_legacy_sv) {
    return newSVsv(prepared->cached_fragments_legacy_sv);
  }

  HV *hv = newHV();
  UV i;

  for (i = 0; i < (UV)prepared->document->definitions.count; i++) {
    gql_ir_definition_t *definition = (gql_ir_definition_t *)prepared->document->definitions.items[i];
    gql_ir_fragment_definition_t *fragment;
    HV *fragment_hv;
    SV *name_sv;

    if (!definition || definition->kind != GQL_IR_DEFINITION_FRAGMENT) {
      continue;
    }

    fragment = definition->as.fragment;
    fragment_hv = newHV();
    name_sv = gql_ir_make_sv_from_span(aTHX_ prepared->document, fragment->name);
    gql_store_sv(fragment_hv, "kind", newSVpv("fragment", 0));
    gql_store_sv(fragment_hv, "name", newSVsv(name_sv));
    gql_store_sv(fragment_hv, "on", gql_ir_make_sv_from_span(aTHX_ prepared->document, fragment->type_condition));
    {
      SV *directives_sv = gql_ir_directives_to_legacy_sv(aTHX_ prepared->document, &fragment->directives);
      if (directives_sv && directives_sv != &PL_sv_undef) {
        gql_store_sv(fragment_hv, "directives", directives_sv);
      }
    }
    gql_store_sv(fragment_hv, "selections", newRV_noinc((SV *)gql_ir_selections_to_legacy_av(aTHX_ prepared->document, fragment->selection_set)));
    if (gql_ir_selection_set_is_plain_fields(fragment->selection_set)) {
      SV *compiled_fields_sv = gql_ir_selection_set_to_legacy_fields_sv(aTHX_ prepared->document, fragment->selection_set);
      gql_ir_compiled_field_bucket_table_t *bucket_table = gql_ir_compiled_field_bucket_table_from_sv(aTHX_ compiled_fields_sv);
      gql_store_sv(fragment_hv, "compiled_fields", compiled_fields_sv);
      if (bucket_table) {
        gql_ir_attach_compiled_field_bucket_table(aTHX_ (SV *)fragment_hv, bucket_table);
      }
    }
    (void)hv_store_ent(hv, name_sv, newRV_noinc((SV *)fragment_hv), 0);
    SvREFCNT_dec(name_sv);
  }

  {
    SV *ret = newRV_noinc((SV *)hv);
    prepared->cached_fragments_legacy_sv = newSVsv(ret);
    return ret;
  }
}

static SV *
gql_ir_operation_to_legacy_sv(
  pTHX_ gql_ir_prepared_exec_t *prepared,
  gql_ir_operation_definition_t *operation,
  SV *operation_name
) {
  if (prepared->cached_operation_legacy_sv
      && gql_ir_prepare_operation_name_matches(prepared->cached_operation_name_sv, operation_name)) {
    return newSVsv(prepared->cached_operation_legacy_sv);
  }

  HV *hv = newHV();

  gql_store_sv(hv, "kind", newSVpv("operation", 0));
  gql_store_sv(hv, "operationType", newSVpv(gql_ir_operation_kind_name(operation->operation), 0));
  if (operation->name.start != operation->name.end) {
    gql_store_sv(hv, "name", gql_ir_make_sv_from_span(aTHX_ prepared->document, operation->name));
  }
  {
    SV *directives_sv = gql_ir_directives_to_legacy_sv(aTHX_ prepared->document, &operation->directives);
    if (directives_sv && directives_sv != &PL_sv_undef) {
      gql_store_sv(hv, "directives", directives_sv);
    }
  }
  gql_store_sv(hv, "variables", gql_ir_variable_definitions_to_legacy_sv(aTHX_ prepared->document, &operation->variable_definitions));
  gql_store_sv(hv, "selections", newRV_noinc((SV *)gql_ir_selections_to_legacy_av(aTHX_ prepared->document, operation->selection_set)));
  {
    SV *ret = newRV_noinc((SV *)hv);
    if (prepared->cached_operation_name_sv) {
      SvREFCNT_dec(prepared->cached_operation_name_sv);
      prepared->cached_operation_name_sv = NULL;
    }
    if (prepared->cached_operation_legacy_sv) {
      SvREFCNT_dec(prepared->cached_operation_legacy_sv);
      prepared->cached_operation_legacy_sv = NULL;
    }
    prepared->cached_operation_name_sv = (operation_name && SvOK(operation_name))
      ? newSVsv(operation_name)
      : newSV(0);
    prepared->cached_operation_legacy_sv = newSVsv(ret);
    return ret;
  }
}

static SV *
gql_ir_compiled_plan_to_hv_sv(pTHX_ gql_ir_compiled_exec_t *compiled) {
  HV *hv;
  SV *operation_sv;
  SV *fragments_sv;
  SV *root_fields_sv;

  if (!compiled) {
    return newRV_noinc((SV *)newHV());
  }

  hv = newHV();
  operation_sv = gql_ir_compiled_operation_legacy_sv(aTHX_ compiled);
  fragments_sv = gql_ir_compiled_fragments_legacy_sv(aTHX_ compiled);
  root_fields_sv = gql_ir_compiled_root_legacy_fields_sv(aTHX_ compiled);
  gql_store_sv(hv, "operation", operation_sv != &PL_sv_undef ? operation_sv : newSV(0));
  gql_store_sv(hv, "fragments", fragments_sv != &PL_sv_undef ? fragments_sv : newSV(0));
  gql_store_sv(hv, "root_type", gql_execution_share_or_copy_sv(compiled->root_type_sv));
  {
    SV *root_selection_plan_sv = gql_ir_compiled_root_selection_plan_sv(aTHX_ compiled);
    gql_store_sv(
      hv,
      "root_selection_plan",
      root_selection_plan_sv != &PL_sv_undef ? gql_execution_share_or_copy_sv(root_selection_plan_sv) : newSV(0)
    );
  }
  {
    SV *root_field_plan_sv = gql_ir_compiled_root_field_plan_legacy_sv(aTHX_ compiled);
    gql_store_sv(hv, "root_field_plan", root_field_plan_sv != &PL_sv_undef ? gql_execution_share_or_copy_sv(root_field_plan_sv) : newSV(0));
  }
  gql_store_sv(hv, "root_fields", root_fields_sv != &PL_sv_undef ? root_fields_sv : newSV(0));
  return newRV_noinc((SV *)hv);
}

static SV *
gql_ir_build_execution_context_sv(
  pTHX_ SV *schema,
  gql_ir_prepared_exec_t *prepared,
  SV *root_value,
  SV *context_value,
  SV *variable_values,
  SV *operation_name,
  SV *field_resolver,
  SV *promise_code
) {
  HV *context_hv = newHV();
  HV *resolve_info_base_hv = newHV();
  gql_ir_operation_definition_t *selected;
  SV *operation_sv;
  SV *fragments_sv;
  SV *applied_variables_sv;
  SV *runtime_variables_sv = NULL;

  selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);
  operation_sv = gql_ir_operation_to_legacy_sv(aTHX_ prepared, selected, operation_name);
  fragments_sv = gql_ir_fragment_definitions_to_legacy_map_sv(aTHX_ prepared);

  if (!variable_values || !SvOK(variable_values)) {
    runtime_variables_sv = newRV_noinc((SV *)newHV());
  }

  if (selected->variable_definitions.count == 0) {
    applied_variables_sv = newRV_noinc((SV *)newHV());
  } else {
    SV *operation_variables_sv = gql_ir_variable_definitions_to_legacy_sv(aTHX_ prepared->document, &selected->variable_definitions);
    applied_variables_sv = gql_execution_call_pp_variables_apply_defaults(
      aTHX_
      schema,
      operation_variables_sv,
      (variable_values && SvOK(variable_values)) ? variable_values : runtime_variables_sv
    );
    SvREFCNT_dec(operation_variables_sv);
  }

  gql_store_sv(context_hv, "schema", gql_execution_share_or_copy_sv(schema));
  {
    HV *runtime_cache_hv = gql_execution_schema_runtime_cache_hv(aTHX_ schema);
    if (runtime_cache_hv) {
      gql_store_sv(context_hv, "runtime_cache", newRV_inc((SV *)runtime_cache_hv));
    }
  }
  gql_store_sv(context_hv, "fragments", fragments_sv);
  gql_store_sv(context_hv, "root_value", gql_execution_share_or_copy_sv(root_value));
  gql_store_sv(context_hv, "context_value", gql_execution_share_or_copy_sv(context_value));
  gql_store_sv(context_hv, "operation", operation_sv);
  gql_store_sv(context_hv, "variable_values", applied_variables_sv);
  gql_store_sv(
    context_hv,
    "field_resolver",
    (field_resolver && SvOK(field_resolver))
      ? gql_execution_share_or_copy_sv(field_resolver)
      : gql_execution_default_field_resolver_sv(aTHX)
  );
  gql_store_sv(context_hv, "promise_code", gql_execution_share_or_copy_sv(promise_code));
  gql_store_sv(context_hv, "empty_args", newRV_noinc((SV *)newHV()));

  gql_store_sv(resolve_info_base_hv, "schema", gql_execution_share_or_copy_sv(schema));
  gql_store_sv(resolve_info_base_hv, "fragments", gql_execution_share_or_copy_sv(fragments_sv));
  gql_store_sv(resolve_info_base_hv, "root_value", gql_execution_share_or_copy_sv(root_value));
  gql_store_sv(resolve_info_base_hv, "operation", gql_execution_share_or_copy_sv(operation_sv));
  gql_store_sv(resolve_info_base_hv, "variable_values", gql_execution_share_or_copy_sv(applied_variables_sv));
  gql_store_sv(resolve_info_base_hv, "promise_code", gql_execution_share_or_copy_sv(promise_code));
  gql_store_sv(context_hv, "resolve_info_base", newRV_noinc((SV *)resolve_info_base_hv));

  if (runtime_variables_sv) {
    SvREFCNT_dec(runtime_variables_sv);
  }

  return newRV_noinc((SV *)context_hv);
}

static SV *
gql_ir_build_execution_context_from_compiled_sv(
  pTHX_ gql_ir_compiled_exec_t *compiled,
  SV *root_value,
  SV *context_value,
  SV *variable_values,
  SV *field_resolver,
  SV *promise_code
) {
  HV *context_hv = newHV();
  HV *resolve_info_base_hv = newHV();
  gql_ir_prepared_exec_t *prepared;
  SV *runtime_variables_sv = NULL;
  SV *applied_variables_sv;
  SV *operation_sv;
  SV *fragments_sv;
  SV *operation_variables_sv;
  SV *root_fields_sv;

  prepared = gql_ir_compiled_prepared_exec(compiled);
  if (!compiled || !prepared || !compiled->selected_operation) {
    croak("compiled IR plan is missing selected operation metadata");
  }

  operation_sv = gql_ir_compiled_operation_legacy_sv(aTHX_ compiled);
  fragments_sv = gql_ir_compiled_fragments_legacy_sv(aTHX_ compiled);
  root_fields_sv = gql_ir_compiled_root_legacy_fields_sv(aTHX_ compiled);
  operation_variables_sv = compiled->selected_operation->variable_definitions.count == 0
    ? &PL_sv_undef
    : gql_ir_variable_definitions_to_legacy_sv(aTHX_ prepared->document, &compiled->selected_operation->variable_definitions);

  if (!variable_values || !SvOK(variable_values)) {
    runtime_variables_sv = newRV_noinc((SV *)newHV());
  }

  if (operation_variables_sv == &PL_sv_undef || !SvOK(operation_variables_sv)) {
    applied_variables_sv = newRV_noinc((SV *)newHV());
  } else {
    applied_variables_sv = gql_execution_call_pp_variables_apply_defaults(
      aTHX_
      compiled->schema_sv,
      operation_variables_sv,
      (variable_values && SvOK(variable_values)) ? variable_values : runtime_variables_sv
    );
  }

  gql_store_sv(context_hv, "schema", gql_execution_share_or_copy_sv(compiled->schema_sv));
  {
    HV *runtime_cache_hv = gql_execution_schema_runtime_cache_hv(aTHX_ compiled->schema_sv);
    if (runtime_cache_hv) {
      gql_store_sv(context_hv, "runtime_cache", newRV_inc((SV *)runtime_cache_hv));
    }
  }
  gql_store_sv(context_hv, "fragments", fragments_sv != &PL_sv_undef ? fragments_sv : newSV(0));
  gql_store_sv(context_hv, "root_value", gql_execution_share_or_copy_sv(root_value));
  gql_store_sv(context_hv, "context_value", gql_execution_share_or_copy_sv(context_value));
  gql_store_sv(context_hv, "operation", operation_sv != &PL_sv_undef ? operation_sv : newSV(0));
  gql_store_sv(context_hv, "variable_values", applied_variables_sv);
  gql_store_sv(
    context_hv,
    "field_resolver",
    (field_resolver && SvOK(field_resolver))
      ? gql_execution_share_or_copy_sv(field_resolver)
      : gql_execution_default_field_resolver_sv(aTHX)
  );
  gql_store_sv(context_hv, "promise_code", gql_execution_share_or_copy_sv(promise_code));
  gql_store_sv(context_hv, "empty_args", newRV_noinc((SV *)newHV()));
  if (root_fields_sv != &PL_sv_undef && SvOK(root_fields_sv)) {
    gql_store_sv(context_hv, "compiled_root_field_defs", gql_execution_share_or_copy_sv(root_fields_sv));
  }

  gql_store_sv(resolve_info_base_hv, "schema", gql_execution_share_or_copy_sv(compiled->schema_sv));
  gql_store_sv(resolve_info_base_hv, "fragments", fragments_sv != &PL_sv_undef ? gql_execution_share_or_copy_sv(fragments_sv) : newSV(0));
  gql_store_sv(resolve_info_base_hv, "root_value", gql_execution_share_or_copy_sv(root_value));
  gql_store_sv(resolve_info_base_hv, "operation", operation_sv != &PL_sv_undef ? gql_execution_share_or_copy_sv(operation_sv) : newSV(0));
  gql_store_sv(resolve_info_base_hv, "variable_values", gql_execution_share_or_copy_sv(applied_variables_sv));
  gql_store_sv(resolve_info_base_hv, "promise_code", gql_execution_share_or_copy_sv(promise_code));
  gql_store_sv(context_hv, "resolve_info_base", newRV_noinc((SV *)resolve_info_base_hv));

  if (operation_variables_sv != &PL_sv_undef) {
    SvREFCNT_dec(operation_variables_sv);
  }
  if (runtime_variables_sv) {
    SvREFCNT_dec(runtime_variables_sv);
  }

  return newRV_noinc((SV *)context_hv);
}

static SV *
gql_ir_execute_compiled_root_field_plan(pTHX_ gql_ir_compiled_exec_t *compiled, SV *context_sv, SV *root_value, SV *path_sv) {
  gql_ir_prepared_exec_t *prepared;
  SV *prepared_inner_sv;
  HV *context_hv;
  gql_execution_context_fast_cache_t *context_cache;
  gql_ir_compiled_root_field_plan_t *root_field_plan;
  SV **context_value_svp;
  SV **variable_values_svp;
  SV **empty_args_svp;
  SV **field_resolver_svp;
  SV **promise_code_svp;
  SV *promise_code_sv = &PL_sv_undef;
  HV *direct_data_hv = newHV();
  AV *result_keys_av = newAV();
  AV *result_values_av = newAV();
  AV *all_errors_av = NULL;
  UV field_i;
  int promise_present = 0;

  if (!compiled
      || !compiled->root_field_plan
      || !context_sv
      || !SvROK(context_sv)
      || SvTYPE(SvRV(context_sv)) != SVt_PVHV) {
    goto fallback;
  }

  root_field_plan = compiled->root_field_plan;
  context_hv = (HV *)SvRV(context_sv);
  context_cache = gql_execution_context_fast_cache(aTHX_ context_sv);
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

  if (promise_code_svp && SvOK(*promise_code_svp)) {
    promise_code_sv = *promise_code_svp;
  }

  for (field_i = 0; field_i < root_field_plan->field_count; field_i++) {
    gql_ir_compiled_root_field_plan_entry_t *entry = &root_field_plan->entries[field_i];
    SV *field_def_sv;
    SV *nodes_sv;
    SV *type_sv;
    SV *resolve_sv;
    SV *path_copy_sv = NULL;
    SV *info_sv = NULL;
    SV *args_sv = NULL;
    SV *direct_data_sv = NULL;
    gql_execution_lazy_resolve_info_t lazy_info;
    SV *result_sv = NULL;
    SV *completed_sv = NULL;
    int used_fast_default_resolve = 0;
    int is_completed_promise = 0;
    int owns_nodes_sv = 0;
    int owns_field_def_sv = 0;
    int owns_resolve_sv = 0;
    int owns_args_sv = 0;

    if (!entry->result_name_sv || !SvOK(entry->result_name_sv)) {
      continue;
    }

    if (!entry->field_name_sv || !SvOK(entry->field_name_sv)) {
      goto fallback;
    }

    if (entry->nodes_sv && SvOK(entry->nodes_sv)) {
      nodes_sv = entry->nodes_sv;
    } else {
      if (!compiled->prepared_handle_sv
          || !SvROK(compiled->prepared_handle_sv)
          || !sv_derived_from(compiled->prepared_handle_sv, "GraphQL::Houtou::XS::PreparedIR")) {
        goto fallback;
      }
      prepared_inner_sv = SvRV(compiled->prepared_handle_sv);
      if (!SvIOK(prepared_inner_sv) || SvUV(prepared_inner_sv) == 0) {
        goto fallback;
      }
      prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(prepared_inner_sv));
      nodes_sv = gql_ir_prepare_executable_root_field_nodes_sv(
        aTHX_
        prepared,
        compiled->root_type_sv,
        compiled->operation_name_sv,
        entry->result_name_sv
      );
      owns_nodes_sv = 1;
    }

    if (nodes_sv == &PL_sv_undef || !SvROK(nodes_sv) || SvTYPE(SvRV(nodes_sv)) != SVt_PVAV) {
      if (owns_nodes_sv && nodes_sv != &PL_sv_undef) {
        SvREFCNT_dec(nodes_sv);
      }
      goto fallback;
    }

    if (entry->field_def_sv && SvOK(entry->field_def_sv)) {
      field_def_sv = entry->field_def_sv;
    } else {
      field_def_sv = gql_execution_get_field_def(aTHX_ compiled->schema_sv, compiled->root_type_sv, entry->field_name_sv);
      owns_field_def_sv = 1;
    }

    if (!SvOK(field_def_sv) || field_def_sv == &PL_sv_undef || !SvROK(field_def_sv) || SvTYPE(SvRV(field_def_sv)) != SVt_PVHV) {
      if (owns_field_def_sv && field_def_sv != &PL_sv_undef) {
        SvREFCNT_dec(field_def_sv);
      }
      if (owns_nodes_sv) {
        SvREFCNT_dec(nodes_sv);
      }
      continue;
    }

    if (entry->type_sv && SvOK(entry->type_sv)) {
      type_sv = entry->type_sv;
    } else {
      SV **type_svp = hv_fetch((HV *)SvRV(field_def_sv), "type", 4, 0);
      type_sv = (type_svp && SvOK(*type_svp)) ? *type_svp : &PL_sv_undef;
    }
    if (!SvOK(type_sv)) {
      if (owns_nodes_sv) {
        SvREFCNT_dec(nodes_sv);
      }
      if (owns_field_def_sv) {
        SvREFCNT_dec(field_def_sv);
      }
      continue;
    }
    Zero(&lazy_info, 1, gql_execution_lazy_resolve_info_t);
    lazy_info.context_sv = context_sv;
    lazy_info.parent_type_sv = compiled->root_type_sv;
    lazy_info.field_def_sv = field_def_sv;
    lazy_info.return_type_sv = entry->return_type_sv ? entry->return_type_sv : type_sv;
    lazy_info.field_name_sv = entry->field_name_sv;
    lazy_info.nodes_sv = nodes_sv;
    if (entry->path_sv && SvOK(entry->path_sv)) {
      lazy_info.path_sv = entry->path_sv;
    } else {
      lazy_info.base_path_sv = path_sv;
      lazy_info.result_name_sv = entry->result_name_sv;
    }
    if (gql_execution_try_typename_meta_field_data_fast(aTHX_ compiled->root_type_sv, entry->field_name_sv, type_sv, &direct_data_sv)) {
      (void)hv_store_ent(direct_data_hv, entry->result_name_sv, direct_data_sv, 0);
      goto field_done;
    }
    if (gql_execution_try_typename_meta_field_fast(aTHX_ compiled->root_type_sv, entry->field_name_sv, type_sv, &completed_sv)) {
      goto have_completed;
    }
    if (entry->resolve_sv && SvOK(entry->resolve_sv)) {
      resolve_sv = entry->resolve_sv;
    } else {
      resolve_sv = (field_resolver_svp && SvOK(*field_resolver_svp))
        ? *field_resolver_svp
        : newSV(0);
      owns_resolve_sv = !(field_resolver_svp && SvOK(*field_resolver_svp));
    }

    if (entry->completion_type_sv
        && gql_execution_is_default_field_resolver(aTHX_ resolve_sv)
        && gql_execution_try_default_field_resolve_borrowed_fast(aTHX_ root_value, entry->field_name_sv, &result_sv)
        && gql_execution_try_complete_trivial_value_with_metadata_data_fast(
            aTHX_ entry->completion_type_sv,
            entry->trivial_completion_flags,
            result_sv,
            &direct_data_sv
          )) {
      (void)hv_store_ent(direct_data_hv, entry->result_name_sv, direct_data_sv, 0);
      result_sv = NULL;
      goto field_done;
    }

    if (gql_execution_is_default_field_resolver(aTHX_ resolve_sv)
        && gql_execution_try_default_field_resolve_fast(aTHX_ root_value, entry->field_name_sv, &result_sv)) {
      used_fast_default_resolve = 1;
      if (entry->completion_type_sv
          && gql_execution_try_complete_trivial_value_with_metadata_data_fast(
              aTHX_ entry->completion_type_sv,
              entry->trivial_completion_flags,
              result_sv,
              &direct_data_sv
            )) {
        (void)hv_store_ent(direct_data_hv, entry->result_name_sv, direct_data_sv, 0);
        goto field_done;
      }
      if (entry->completion_type_sv && entry->trivial_completion_flags) {
        if (gql_execution_try_complete_trivial_value_with_metadata_fast(
              aTHX_ entry->completion_type_sv,
              entry->trivial_completion_flags,
              result_sv,
              &completed_sv
            )) {
          goto have_completed;
        }
      } else if (gql_execution_try_complete_trivial_value_fast(aTHX_ type_sv, result_sv, &completed_sv)) {
        goto have_completed;
      }
    }

    if (!used_fast_default_resolve) {
      info_sv = gql_execution_lazy_resolve_info_materialize(aTHX_ &lazy_info);
      if (entry->argument_count == 0 && entry->field_arg_count == 0) {
        if (empty_args_svp && SvOK(*empty_args_svp)) {
          args_sv = *empty_args_svp;
        } else {
          args_sv = newRV_noinc((SV *)newHV());
          owns_args_sv = 1;
        }
      } else {
        SV *field_node_sv = (entry->first_node_sv && SvOK(entry->first_node_sv))
          ? entry->first_node_sv
          : &PL_sv_undef;
        SV *field_node_arg = field_node_sv;
        if (!SvROK(field_node_sv) || SvTYPE(SvRV(field_node_sv)) != SVt_PVHV) {
          if (owns_nodes_sv) {
            SvREFCNT_dec(nodes_sv);
          }
          if (lazy_info.info_sv) {
            SvREFCNT_dec(lazy_info.info_sv);
          }
          if (owns_field_def_sv) {
            SvREFCNT_dec(field_def_sv);
          }
          if (owns_resolve_sv) {
            SvREFCNT_dec(resolve_sv);
          }
          goto fallback;
        }
        args_sv = gql_execution_get_argument_values_xs_impl(
          aTHX_ field_def_sv,
          field_node_arg,
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
      context_sv,
      compiled->root_type_sv,
      field_def_sv,
      entry->return_type_sv,
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
      if (!is_completed_promise && SvTYPE(SvRV(completed_sv)) == SVt_PVHV) {
        gql_ir_accumulate_completed_result(aTHX_ direct_data_hv, &all_errors_av, entry->result_name_sv, completed_sv);
        SvREFCNT_dec(completed_sv);
        completed_sv = NULL;
      } else {
        av_push(result_keys_av, SvREFCNT_inc_simple_NN(entry->result_name_sv));
        av_push(result_values_av, completed_sv);
        completed_sv = NULL;
      }
    }

field_done:
    if (owns_nodes_sv) {
      SvREFCNT_dec(nodes_sv);
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
    if (lazy_info.path_sv && (!entry->path_sv || !SvOK(entry->path_sv))) {
      path_copy_sv = lazy_info.path_sv;
    }
    if (path_copy_sv && (!entry->path_sv || !SvOK(entry->path_sv))) {
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
    AV *merge_errors_av = all_errors_av ? all_errors_av : newAV();
    SV *ret = gql_execution_call_xs_then_merge_hash_with_head(
      aTHX_
      promise_code_sv,
      direct_data_hv,
      result_keys_av,
      aggregate,
      merge_errors_av
    );

    SvREFCNT_dec(aggregate);
    SvREFCNT_dec((SV *)direct_data_hv);
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)merge_errors_av);
    return ret;
  }

  if (!SvOK(promise_code_sv) || av_len(result_values_av) < 0) {
    SV *ret = gql_ir_build_native_result(aTHX_ direct_data_hv, all_errors_av);
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    return ret;
  }

  {
    AV *merge_errors_av = all_errors_av ? all_errors_av : newAV();
    SV *ret = gql_execution_merge_hash(aTHX_ result_keys_av, result_values_av, merge_errors_av);
    SvREFCNT_dec((SV *)direct_data_hv);
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)merge_errors_av);
    return ret;
  }

fallback:
  SvREFCNT_dec((SV *)direct_data_hv);
  SvREFCNT_dec((SV *)result_keys_av);
  SvREFCNT_dec((SV *)result_values_av);
  if (all_errors_av) {
    SvREFCNT_dec((SV *)all_errors_av);
  }
  return &PL_sv_undef;
}

static SV *
gql_ir_execute_native_field_plan(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan
) {
  /* Mirrors gql_execution_execute_field_plan(), but compiled IR is allowed to
   * diverge here so native plan metadata can replace legacy bucket lookups. */
  HV *context_hv;
  gql_execution_context_fast_cache_t *context_cache;
  SV **context_value_svp;
  SV **variable_values_svp;
  SV **empty_args_svp;
  SV **field_resolver_svp;
  SV **promise_code_svp;
  SV *promise_code_sv = &PL_sv_undef;
  HV *direct_data_hv = newHV();
  AV *result_keys_av = newAV();
  AV *result_values_av = newAV();
  AV *all_errors_av = NULL;
  UV field_i;
  int promise_present = 0;

  if (!field_plan
      || !context_sv
      || !SvROK(context_sv)
      || SvTYPE(SvRV(context_sv)) != SVt_PVHV) {
    goto fallback;
  }

  context_hv = (HV *)SvRV(context_sv);
  context_cache = gql_execution_context_fast_cache(aTHX_ context_sv);
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

  if (promise_code_svp && SvOK(*promise_code_svp)) {
    promise_code_sv = *promise_code_svp;
  }

  for (field_i = 0; field_i < field_plan->field_count; field_i++) {
    gql_ir_compiled_root_field_plan_entry_t *entry = &field_plan->entries[field_i];
    SV *field_def_sv;
    SV *nodes_sv;
    SV *type_sv;
    SV *resolve_sv;
    SV *info_sv = NULL;
    SV *args_sv = NULL;
    SV *direct_data_sv = NULL;
    gql_execution_lazy_resolve_info_t lazy_info;
    SV *result_sv = NULL;
    SV *completed_sv = NULL;
    int used_fast_default_resolve = 0;
    int is_completed_promise = 0;
    int owns_resolve_sv = 0;
    int owns_args_sv = 0;

    if (!entry->result_name_sv || !SvOK(entry->result_name_sv)
        || !entry->field_name_sv || !SvOK(entry->field_name_sv)
        || !entry->nodes_sv || !SvOK(entry->nodes_sv)
        || !entry->field_def_sv || !SvOK(entry->field_def_sv)) {
      goto fallback;
    }

    nodes_sv = entry->nodes_sv;
    field_def_sv = entry->field_def_sv;
    if (!SvROK(nodes_sv) || SvTYPE(SvRV(nodes_sv)) != SVt_PVAV
        || !SvROK(field_def_sv) || SvTYPE(SvRV(field_def_sv)) != SVt_PVHV) {
      goto fallback;
    }

    if (entry->type_sv && SvOK(entry->type_sv)) {
      type_sv = entry->type_sv;
    } else {
      SV **type_svp = hv_fetch((HV *)SvRV(field_def_sv), "type", 4, 0);
      type_sv = (type_svp && SvOK(*type_svp)) ? *type_svp : &PL_sv_undef;
    }
    if (!SvOK(type_sv)) {
      goto fallback;
    }

    Zero(&lazy_info, 1, gql_execution_lazy_resolve_info_t);
    lazy_info.context_sv = context_sv;
    lazy_info.parent_type_sv = parent_type_sv;
    lazy_info.field_def_sv = field_def_sv;
    lazy_info.return_type_sv = entry->return_type_sv ? entry->return_type_sv : type_sv;
    lazy_info.field_name_sv = entry->field_name_sv;
    lazy_info.nodes_sv = nodes_sv;
    if (entry->path_sv && SvOK(entry->path_sv)) {
      lazy_info.path_sv = entry->path_sv;
    } else {
      lazy_info.base_path_sv = path_sv;
      lazy_info.result_name_sv = entry->result_name_sv;
    }

    if (gql_execution_try_typename_meta_field_data_fast(aTHX_ parent_type_sv, entry->field_name_sv, type_sv, &direct_data_sv)) {
      (void)hv_store_ent(direct_data_hv, entry->result_name_sv, direct_data_sv, 0);
      goto field_done;
    }
    if (gql_execution_try_typename_meta_field_fast(aTHX_ parent_type_sv, entry->field_name_sv, type_sv, &completed_sv)) {
      goto have_completed;
    }

    if (entry->resolve_sv && SvOK(entry->resolve_sv)) {
      resolve_sv = entry->resolve_sv;
    } else {
      resolve_sv = (field_resolver_svp && SvOK(*field_resolver_svp))
        ? *field_resolver_svp
        : newSV(0);
      owns_resolve_sv = !(field_resolver_svp && SvOK(*field_resolver_svp));
    }

    if (entry->completion_type_sv
        && gql_execution_is_default_field_resolver(aTHX_ resolve_sv)
        && gql_execution_try_default_field_resolve_borrowed_fast(aTHX_ root_value, entry->field_name_sv, &result_sv)
        && gql_execution_try_complete_trivial_value_with_metadata_data_fast(
            aTHX_ entry->completion_type_sv,
            entry->trivial_completion_flags,
            result_sv,
            &direct_data_sv
          )) {
      (void)hv_store_ent(direct_data_hv, entry->result_name_sv, direct_data_sv, 0);
      result_sv = NULL;
      goto field_done;
    }

    if (gql_execution_is_default_field_resolver(aTHX_ resolve_sv)
        && gql_execution_try_default_field_resolve_fast(aTHX_ root_value, entry->field_name_sv, &result_sv)) {
      used_fast_default_resolve = 1;
      if (entry->completion_type_sv
          && gql_execution_try_complete_trivial_value_with_metadata_data_fast(
              aTHX_ entry->completion_type_sv,
              entry->trivial_completion_flags,
              result_sv,
              &direct_data_sv
            )) {
        (void)hv_store_ent(direct_data_hv, entry->result_name_sv, direct_data_sv, 0);
        goto field_done;
      }
      if (entry->completion_type_sv && entry->trivial_completion_flags) {
        if (gql_execution_try_complete_trivial_value_with_metadata_fast(
              aTHX_ entry->completion_type_sv,
              entry->trivial_completion_flags,
              result_sv,
              &completed_sv
            )) {
          goto have_completed;
        }
      } else if (gql_execution_try_complete_trivial_value_fast(aTHX_ type_sv, result_sv, &completed_sv)) {
        goto have_completed;
      }
    }

    if (!used_fast_default_resolve) {
      info_sv = gql_execution_lazy_resolve_info_materialize(aTHX_ &lazy_info);
      if (entry->argument_count == 0 && entry->field_arg_count == 0) {
        if (empty_args_svp && SvOK(*empty_args_svp)) {
          args_sv = *empty_args_svp;
        } else {
          args_sv = newRV_noinc((SV *)newHV());
          owns_args_sv = 1;
        }
      } else {
        SV *field_node_sv = (entry->first_node_sv && SvOK(entry->first_node_sv))
          ? entry->first_node_sv
          : &PL_sv_undef;
        if (!SvROK(field_node_sv) || SvTYPE(SvRV(field_node_sv)) != SVt_PVHV) {
          if (lazy_info.info_sv) {
            SvREFCNT_dec(lazy_info.info_sv);
          }
          if (owns_resolve_sv) {
            SvREFCNT_dec(resolve_sv);
          }
          goto fallback;
        }
        args_sv = gql_execution_get_argument_values_xs_impl(
          aTHX_ field_def_sv,
          field_node_sv,
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
      context_sv,
      parent_type_sv,
      field_def_sv,
      entry->return_type_sv,
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
      if (!is_completed_promise && SvTYPE(SvRV(completed_sv)) == SVt_PVHV) {
        gql_ir_accumulate_completed_result(aTHX_ direct_data_hv, &all_errors_av, entry->result_name_sv, completed_sv);
        SvREFCNT_dec(completed_sv);
        completed_sv = NULL;
      } else {
        av_push(result_keys_av, SvREFCNT_inc_simple_NN(entry->result_name_sv));
        av_push(result_values_av, completed_sv);
        completed_sv = NULL;
      }
    }

field_done:
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
    if (lazy_info.path_sv && (!entry->path_sv || !SvOK(entry->path_sv))) {
      SvREFCNT_dec(lazy_info.path_sv);
    }
    if (completed_sv) {
      SvREFCNT_dec(completed_sv);
    }
  }

  if (promise_present) {
    SV *aggregate = gql_promise_call_all(aTHX_ promise_code_sv, result_values_av);
    AV *merge_errors_av = all_errors_av ? all_errors_av : newAV();
    SV *ret = gql_execution_call_xs_then_merge_hash_with_head(
      aTHX_
      promise_code_sv,
      direct_data_hv,
      result_keys_av,
      aggregate,
      merge_errors_av
    );

    SvREFCNT_dec(aggregate);
    SvREFCNT_dec((SV *)direct_data_hv);
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)merge_errors_av);
    return ret;
  }

  if (!SvOK(promise_code_sv) || av_len(result_values_av) < 0) {
    SV *ret = gql_ir_build_native_result(aTHX_ direct_data_hv, all_errors_av);
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    return ret;
  }

  {
    AV *merge_errors_av = all_errors_av ? all_errors_av : newAV();
    SV *ret = gql_execution_merge_hash(aTHX_ result_keys_av, result_values_av, merge_errors_av);
    SvREFCNT_dec((SV *)direct_data_hv);
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)merge_errors_av);
    return ret;
  }

fallback:
  SvREFCNT_dec((SV *)direct_data_hv);
  SvREFCNT_dec((SV *)result_keys_av);
  SvREFCNT_dec((SV *)result_values_av);
  if (all_errors_av) {
    SvREFCNT_dec((SV *)all_errors_av);
  }
  return &PL_sv_undef;
}

static SV *
gql_execution_execute_prepared_ir_xs_impl(
  pTHX_ SV *schema,
  SV *handle,
  SV *root_value,
  SV *context_value,
  SV *variable_values,
  SV *operation_name,
  SV *field_resolver,
  SV *promise_code
) {
  gql_ir_prepared_exec_t *prepared;
  gql_ir_operation_definition_t *selected;
  const char *operation_type;
  SV *context_sv;
  SV *fields_sv;
  SV *root_type_sv;
  SV *path_sv;
  SV *result_sv;
  AV *path_av;
  SV *response_sv;
  SV *inner_sv;
  SV *promise_code_sv;

  if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::PreparedIR")) {
    croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
  }

  inner_sv = SvRV(handle);
  if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
    croak("prepared IR handle is no longer valid");
  }

  prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
  selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);
  operation_type = gql_ir_operation_kind_name(selected->operation);

  context_sv = gql_ir_build_execution_context_sv(
    aTHX_
    schema,
    prepared,
    root_value,
    context_value,
    variable_values,
    operation_name,
    field_resolver,
    promise_code
  );
  fields_sv = gql_ir_prepare_executable_root_legacy_fields_sv(aTHX_ schema, prepared, operation_name);
  root_type_sv = gql_execution_call_schema_root_type(aTHX_ schema, operation_type);
  path_av = newAV();
  path_sv = newRV_noinc((SV *)path_av);

  result_sv = gql_execution_execute_fields(aTHX_ context_sv, root_type_sv, root_value, path_sv, fields_sv);
  promise_code_sv = gql_execution_context_promise_code(context_sv);
  if (promise_code_sv != &PL_sv_undef && SvTRUE(gql_promise_call_is_promise(aTHX_ promise_code_sv, result_sv))) {
    response_sv = gql_execution_call_xs_then_build_response(aTHX_ promise_code_sv, result_sv, 0);
  } else {
    response_sv = gql_execution_build_response_xs(aTHX_ result_sv, 0);
  }

  SvREFCNT_dec(result_sv);
  SvREFCNT_dec(path_sv);
  SvREFCNT_dec(root_type_sv);
  SvREFCNT_dec(fields_sv);
  SvREFCNT_dec(context_sv);

  return response_sv;
}

static SV *
gql_execution_execute_compiled_ir_xs_impl(
  pTHX_ SV *handle,
  SV *root_value,
  SV *context_value,
  SV *variable_values,
  SV *field_resolver,
  SV *promise_code
) {
  gql_ir_compiled_exec_t *compiled;
  SV *inner_sv;
  SV *context_sv;
  SV *path_sv = &PL_sv_undef;
  SV *result_sv;
  SV *response_sv;
  SV *promise_code_sv;

  if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::CompiledIR")) {
    croak("expected a GraphQL::Houtou::XS::CompiledIR handle");
  }

  inner_sv = SvRV(handle);
  if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
    croak("compiled IR handle is no longer valid");
  }

  compiled = INT2PTR(gql_ir_compiled_exec_t *, SvUV(inner_sv));
  context_sv = gql_ir_build_execution_context_from_compiled_sv(
    aTHX_
    compiled,
    root_value,
    context_value,
    variable_values,
    field_resolver,
    promise_code
  );

  result_sv = gql_ir_execute_compiled_root_field_plan(aTHX_ compiled, context_sv, root_value, path_sv);
  if (result_sv == &PL_sv_undef) {
    SV *root_fields_sv = gql_ir_compiled_root_legacy_fields_sv(aTHX_ compiled);
    if (root_fields_sv == &PL_sv_undef) {
      SvREFCNT_dec(context_sv);
      croak("compiled IR plan could not materialize root legacy fields");
    }
    result_sv = gql_execution_execute_fields(
      aTHX_
      context_sv,
      compiled->root_type_sv,
      root_value,
      path_sv,
      root_fields_sv
    );
    SvREFCNT_dec(root_fields_sv);
  }
  promise_code_sv = gql_execution_context_promise_code(context_sv);
  if (promise_code_sv != &PL_sv_undef && SvTRUE(gql_promise_call_is_promise(aTHX_ promise_code_sv, result_sv))) {
    response_sv = gql_execution_call_xs_then_build_response(aTHX_ promise_code_sv, result_sv, 0);
  } else {
    response_sv = gql_execution_build_response_xs(aTHX_ result_sv, 0);
  }

  SvREFCNT_dec(result_sv);
  SvREFCNT_dec(context_sv);

  return response_sv;
}

static SV *
gql_ir_value_to_legacy_sv(pTHX_ gql_ir_document_t *document, gql_ir_value_t *value) {
  if (!value) {
    return newSV(0);
  }

  switch (value->kind) {
    case GQL_IR_VALUE_VARIABLE:
      return newRV_noinc(gql_ir_make_sv_from_span(aTHX_ document, value->as.span));
    case GQL_IR_VALUE_INT: {
      SV *sv = gql_ir_make_sv_from_span(aTHX_ document, value->as.span);
      SV *out = newSViv(SvIV(sv));
      SvREFCNT_dec(sv);
      return out;
    }
    case GQL_IR_VALUE_FLOAT: {
      SV *sv = gql_ir_make_sv_from_span(aTHX_ document, value->as.span);
      SV *out = newSVnv(SvNV(sv));
      SvREFCNT_dec(sv);
      return out;
    }
    case GQL_IR_VALUE_STRING:
    case GQL_IR_VALUE_ENUM: {
      SV *sv = gql_ir_make_sv_from_span(aTHX_ document, value->as.span);
      if (value->kind == GQL_IR_VALUE_ENUM) {
        SV *inner = newRV_noinc(sv);
        return newRV_noinc(inner);
      }
      return sv;
    }
    case GQL_IR_VALUE_BOOL:
      return gql_call_helper1(
        aTHX_
        "GraphQL::Houtou::XS::Parser::_make_bool",
        newSViv(value->as.boolean ? 1 : 0)
      );
    case GQL_IR_VALUE_NULL:
      return newSV(0);
    case GQL_IR_VALUE_LIST: {
      AV *av = newAV();
      UV i;
      if (value->as.list_items.count > 0) {
        av_extend(av, value->as.list_items.count - 1);
      }
      for (i = 0; i < (UV)value->as.list_items.count; i++) {
        av_push(av, gql_ir_value_to_legacy_sv(
          aTHX_
          document,
          (gql_ir_value_t *)value->as.list_items.items[i]
        ));
      }
      return newRV_noinc((SV *)av);
    }
    case GQL_IR_VALUE_OBJECT: {
      HV *hv = newHV();
      UV i;
      for (i = 0; i < (UV)value->as.object_fields.count; i++) {
        gql_ir_object_field_t *field = (gql_ir_object_field_t *)value->as.object_fields.items[i];
        SV *name_sv;
        if (!field) {
          continue;
        }
        name_sv = gql_ir_make_sv_from_span(aTHX_ document, field->name);
        (void)hv_store_ent(hv, name_sv, gql_ir_value_to_legacy_sv(aTHX_ document, field->value), 0);
        SvREFCNT_dec(name_sv);
      }
      return newRV_noinc((SV *)hv);
    }
    default:
      return newSV(0);
  }
}

static SV *
gql_ir_arguments_to_legacy_sv(pTHX_ gql_ir_document_t *document, gql_ir_ptr_array_t *arguments) {
  HV *hv;
  UV i;

  if (!arguments || arguments->count == 0) {
    return &PL_sv_undef;
  }

  hv = newHV();
  for (i = 0; i < (UV)arguments->count; i++) {
    gql_ir_argument_t *argument = (gql_ir_argument_t *)arguments->items[i];
    SV *name_sv;
    if (!argument) {
      continue;
    }
    name_sv = gql_ir_make_sv_from_span(aTHX_ document, argument->name);
    (void)hv_store_ent(hv, name_sv, gql_ir_value_to_legacy_sv(aTHX_ document, argument->value), 0);
    SvREFCNT_dec(name_sv);
  }

  return newRV_noinc((SV *)hv);
}

static SV *
gql_ir_directives_to_legacy_sv(pTHX_ gql_ir_document_t *document, gql_ir_ptr_array_t *directives) {
  AV *av;
  UV i;

  if (!directives || directives->count == 0) {
    return &PL_sv_undef;
  }

  av = newAV();
  if (directives->count > 0) {
    av_extend(av, directives->count - 1);
  }

  for (i = 0; i < (UV)directives->count; i++) {
    gql_ir_directive_t *directive = (gql_ir_directive_t *)directives->items[i];
    HV *hv;
    if (!directive) {
      continue;
    }
    hv = newHV();
    gql_store_sv(hv, "name", gql_ir_make_sv_from_span(aTHX_ document, directive->name));
    {
      SV *arguments_sv = gql_ir_arguments_to_legacy_sv(aTHX_ document, &directive->arguments);
      if (arguments_sv && arguments_sv != &PL_sv_undef) {
        gql_store_sv(hv, "arguments", arguments_sv);
      }
    }
    av_push(av, newRV_noinc((SV *)hv));
  }

  return newRV_noinc((SV *)av);
}

static SV *
gql_ir_selection_to_legacy_sv(pTHX_ gql_ir_document_t *document, gql_ir_selection_t *selection) {
  HV *hv = newHV();

  if (!selection) {
    SvREFCNT_dec((SV *)hv);
    return &PL_sv_undef;
  }

  switch (selection->kind) {
    case GQL_IR_SELECTION_FIELD: {
      gql_ir_field_t *field = selection->as.field;
      gql_store_sv(hv, "kind", newSVpv("field", 0));
      gql_store_sv(hv, "name", gql_ir_make_sv_from_span(aTHX_ document, field->name));
      if (field->alias.start != field->alias.end) {
        gql_store_sv(hv, "alias", gql_ir_make_sv_from_span(aTHX_ document, field->alias));
      }
      {
        SV *arguments_sv = gql_ir_arguments_to_legacy_sv(aTHX_ document, &field->arguments);
        if (arguments_sv && arguments_sv != &PL_sv_undef) {
          gql_store_sv(hv, "arguments", arguments_sv);
        }
      }
      {
        SV *directives_sv = gql_ir_directives_to_legacy_sv(aTHX_ document, &field->directives);
        if (directives_sv && directives_sv != &PL_sv_undef) {
          gql_store_sv(hv, "directives", directives_sv);
        }
      }
      if (field->selection_set && field->selection_set->selections.count > 0) {
        gql_store_sv(hv, "selections", newRV_noinc((SV *)gql_ir_selections_to_legacy_av(aTHX_ document, field->selection_set)));
        if (gql_ir_selection_set_is_plain_fields(field->selection_set)) {
          SV *compiled_fields_sv = gql_ir_selection_set_to_legacy_fields_sv(aTHX_ document, field->selection_set);
          gql_ir_compiled_field_bucket_table_t *bucket_table = gql_ir_compiled_field_bucket_table_from_sv(aTHX_ compiled_fields_sv);
          gql_store_sv(hv, "compiled_fields", compiled_fields_sv);
          if (bucket_table) {
            gql_ir_attach_compiled_field_bucket_table(aTHX_ (SV *)hv, bucket_table);
          }
        }
      }
      return newRV_noinc((SV *)hv);
    }
    case GQL_IR_SELECTION_FRAGMENT_SPREAD: {
      gql_ir_fragment_spread_t *spread = selection->as.fragment_spread;
      gql_store_sv(hv, "kind", newSVpv("fragment_spread", 0));
      gql_store_sv(hv, "name", gql_ir_make_sv_from_span(aTHX_ document, spread->name));
      {
        SV *directives_sv = gql_ir_directives_to_legacy_sv(aTHX_ document, &spread->directives);
        if (directives_sv && directives_sv != &PL_sv_undef) {
          gql_store_sv(hv, "directives", directives_sv);
        }
      }
      return newRV_noinc((SV *)hv);
    }
    case GQL_IR_SELECTION_INLINE_FRAGMENT: {
      gql_ir_inline_fragment_t *fragment = selection->as.inline_fragment;
      gql_store_sv(hv, "kind", newSVpv("inline_fragment", 0));
      if (fragment->type_condition.start != fragment->type_condition.end) {
        gql_store_sv(hv, "on", gql_ir_make_sv_from_span(aTHX_ document, fragment->type_condition));
      }
      {
        SV *directives_sv = gql_ir_directives_to_legacy_sv(aTHX_ document, &fragment->directives);
        if (directives_sv && directives_sv != &PL_sv_undef) {
          gql_store_sv(hv, "directives", directives_sv);
        }
      }
      gql_store_sv(hv, "selections", newRV_noinc((SV *)gql_ir_selections_to_legacy_av(aTHX_ document, fragment->selection_set)));
      if (gql_ir_selection_set_is_plain_fields(fragment->selection_set)) {
        SV *compiled_fields_sv = gql_ir_selection_set_to_legacy_fields_sv(aTHX_ document, fragment->selection_set);
        gql_ir_compiled_field_bucket_table_t *bucket_table = gql_ir_compiled_field_bucket_table_from_sv(aTHX_ compiled_fields_sv);
        gql_store_sv(hv, "compiled_fields", compiled_fields_sv);
        if (bucket_table) {
          gql_ir_attach_compiled_field_bucket_table(aTHX_ (SV *)hv, bucket_table);
        }
      }
      return newRV_noinc((SV *)hv);
    }
    default:
      SvREFCNT_dec((SV *)hv);
      return &PL_sv_undef;
  }
}

static AV *
gql_ir_selections_to_legacy_av(pTHX_ gql_ir_document_t *document, gql_ir_selection_set_t *selection_set) {
  AV *av = newAV();
  UV i;

  if (!selection_set) {
    return av;
  }

  if (selection_set->selections.count > 0) {
    av_extend(av, selection_set->selections.count - 1);
  }

  for (i = 0; i < (UV)selection_set->selections.count; i++) {
    gql_ir_selection_t *selection = (gql_ir_selection_t *)selection_set->selections.items[i];
    SV *selection_sv = gql_ir_selection_to_legacy_sv(aTHX_ document, selection);
    if (selection_sv && selection_sv != &PL_sv_undef) {
      av_push(av, selection_sv);
    }
  }

  return av;
}
