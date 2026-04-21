/*
 * Responsibility: prepared executable IR handle ownership and small
 * introspection helpers used as groundwork for future IR-direct execution.
 */
static gql_ir_vm_program_t *gql_ir_execution_lowered_program(gql_ir_compiled_exec_t *compiled);
static gql_ir_vm_block_t *gql_ir_vm_program_root_block(gql_ir_vm_program_t *program);
static gql_ir_compiled_root_field_plan_t *gql_ir_compiled_root_field_plan_clone(pTHX_ gql_ir_compiled_root_field_plan_t *plan);
static void gql_ir_compiled_root_field_plan_destroy(gql_ir_compiled_root_field_plan_t *plan);
static gql_ir_vm_field_meta_t *gql_ir_native_field_meta(gql_ir_compiled_root_field_plan_entry_t *entry);
static gql_ir_vm_field_hot_t *gql_ir_native_field_hot(gql_ir_compiled_root_field_plan_entry_t *entry);
static void gql_ir_vm_block_init_view(gql_ir_vm_block_t *block, gql_ir_compiled_root_field_plan_t *field_plan, int owns_field_plan);
static void gql_ir_vm_field_slot_refresh(gql_ir_vm_field_slot_t *slot, gql_ir_compiled_root_field_plan_entry_t *entry);
static void gql_ir_vm_exec_state_init(
  gql_ir_vm_exec_state_t *state,
  gql_ir_compiled_exec_t *compiled,
  gql_ir_vm_block_t *block,
  gql_ir_native_exec_env_t *env,
  gql_ir_native_result_writer_t *writer,
  int *promise_present,
  int require_runtime_operand_fill
);
static gql_ir_vm_block_t *gql_ir_vm_block_new(gql_ir_compiled_root_field_plan_t *field_plan, int owns_field_plan);
static gql_ir_vm_block_t *gql_ir_vm_block_clone(pTHX_ gql_ir_vm_block_t *block);
static void gql_ir_vm_block_destroy(gql_ir_vm_block_t *block);

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

static gql_ir_compiled_root_field_plan_t *
gql_ir_execution_lowered_root_field_plan(gql_ir_compiled_exec_t *compiled) {
  gql_ir_vm_block_t *root_block = gql_ir_vm_program_root_block(gql_ir_execution_lowered_program(compiled));

  if (!root_block) {
    return NULL;
  }

  return root_block->field_plan;
}

static gql_ir_vm_program_t *
gql_ir_execution_lowered_program(gql_ir_compiled_exec_t *compiled) {
  if (!compiled || !compiled->lowered_plan) {
    return NULL;
  }

  return compiled->lowered_plan->program;
}

static gql_ir_vm_block_t *
gql_ir_vm_program_root_block(gql_ir_vm_program_t *program) {
  if (!program) {
    return NULL;
  }

  return program->root_block;
}

static void
gql_ir_vm_field_slot_refresh(gql_ir_vm_field_slot_t *slot, gql_ir_compiled_root_field_plan_entry_t *entry) {
  gql_ir_vm_field_hot_t *hot;
  gql_ir_vm_field_cold_t *cold;

  if (!slot) {
    return;
  }

  Zero(slot, 1, gql_ir_vm_field_slot_t);
  if (!entry) {
    return;
  }

  hot = gql_ir_native_field_hot(entry);
  cold = entry ? entry->cold : NULL;
  if (!cold && entry) {
    cold = &entry->cold_inline;
  }
  slot->entry = entry;
  slot->meta = gql_ir_native_field_meta(entry);
  slot->hot = hot;
  slot->cold = cold;
  slot->field_def_sv = (hot && hot->field_def_sv) ? hot->field_def_sv : entry->field_def_sv;
  slot->resolve_sv = (hot && hot->resolve_sv) ? hot->resolve_sv : entry->resolve_sv;
  slot->nodes_sv = (hot && hot->nodes_sv) ? hot->nodes_sv : entry->nodes_sv;
  slot->first_node_sv = (hot && hot->first_node_sv) ? hot->first_node_sv : entry->first_node_sv;
  slot->type_sv = (hot && hot->type_sv) ? hot->type_sv : entry->type_sv;
  slot->path_sv = (cold && cold->path_sv && SvOK(cold->path_sv)) ? cold->path_sv : NULL;
  slot->native_field_plan = (hot && hot->native_field_plan) ? hot->native_field_plan : entry->native_field_plan;
  slot->native_block = (hot && hot->native_block) ? hot->native_block : entry->native_block;
  slot->abstract_child_plan_table =
    (hot && hot->abstract_child_plan_table) ? hot->abstract_child_plan_table : entry->abstract_child_plan_table;
  slot->list_item_abstract_child_plan_table =
    (hot && hot->list_item_abstract_child_plan_table)
      ? hot->list_item_abstract_child_plan_table
      : entry->list_item_abstract_child_plan_table;
}

static void
gql_ir_vm_block_init_view(gql_ir_vm_block_t *block, gql_ir_compiled_root_field_plan_t *field_plan, int owns_field_plan) {
  UV i;

  if (!block) {
    return;
  }

  Zero(block, 1, gql_ir_vm_block_t);
  block->field_plan = field_plan;
  block->entries = field_plan ? field_plan->entries : NULL;
  block->field_count = field_plan ? field_plan->field_count : 0;
  block->requires_runtime_operand_fill = field_plan ? field_plan->requires_runtime_operand_fill : 0;
  block->owns_field_plan = owns_field_plan ? 1 : 0;

  if (!block->entries || block->field_count == 0 || !owns_field_plan) {
    return;
  }

  Newxz(block->slots, block->field_count, gql_ir_vm_field_slot_t);
  for (i = 0; i < block->field_count; i++) {
    gql_ir_compiled_root_field_plan_entry_t *entry = &block->entries[i];
    gql_ir_vm_field_slot_refresh(&block->slots[i], entry);
  }
}

static void
gql_ir_vm_exec_state_init(
  gql_ir_vm_exec_state_t *state,
  gql_ir_compiled_exec_t *compiled,
  gql_ir_vm_block_t *block,
  gql_ir_native_exec_env_t *env,
  gql_ir_native_result_writer_t *writer,
  int *promise_present,
  int require_runtime_operand_fill
) {
  if (!state) {
    return;
  }

  Zero(state, 1, gql_ir_vm_exec_state_t);
  state->compiled = compiled;
  state->block = block;
  state->env = env;
  state->writer = writer;
  state->promise_present = promise_present;
  state->require_runtime_operand_fill = require_runtime_operand_fill ? 1 : 0;
}

static gql_ir_vm_block_t *
gql_ir_vm_block_new(gql_ir_compiled_root_field_plan_t *field_plan, int owns_field_plan) {
  gql_ir_vm_block_t *block;

  if (!field_plan) {
    return NULL;
  }

  Newxz(block, 1, gql_ir_vm_block_t);
  gql_ir_vm_block_init_view(block, field_plan, owns_field_plan);
  return block;
}

static gql_ir_vm_block_t *
gql_ir_vm_block_clone(pTHX_ gql_ir_vm_block_t *block) {
  if (!block || !block->field_plan) {
    return NULL;
  }

  return gql_ir_vm_block_new(
    gql_ir_compiled_root_field_plan_clone(aTHX_ block->field_plan),
    1
  );
}

static void
gql_ir_vm_block_destroy(gql_ir_vm_block_t *block) {
  if (!block) {
    return;
  }

  if (block->field_plan && block->owns_field_plan) {
    gql_ir_compiled_root_field_plan_destroy(block->field_plan);
    block->field_plan = NULL;
  }

  if (block->slots) {
    Safefree(block->slots);
    block->slots = NULL;
  }

  Safefree(block);
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
static void gql_ir_attach_exact_object_child_native_plans(
  pTHX_ SV *schema,
  gql_ir_compiled_root_field_plan_t *plan
);
static gql_ir_vm_field_meta_t *gql_ir_vm_field_meta_from_seed(
  pTHX_ gql_ir_compiled_root_field_plan_entry_t *entry,
  const gql_ir_vm_field_meta_t *seed
);
static void gql_ir_vm_field_meta_destroy(gql_ir_vm_field_meta_t *meta);
static gql_ir_execution_lowered_plan_t *gql_ir_execution_lowered_plan_from_root_field_plan_sv(pTHX_ SV *root_field_plan_sv);
static void gql_ir_execution_lowered_plan_destroy(gql_ir_execution_lowered_plan_t *plan);
static gql_ir_vm_program_t *gql_ir_vm_program_from_root_field_plan_sv(pTHX_ SV *root_field_plan_sv);
static void gql_ir_vm_program_destroy(gql_ir_vm_program_t *program);
static gql_ir_compiled_root_field_plan_t *gql_ir_execution_lowered_root_field_plan(gql_ir_compiled_exec_t *compiled);
static gql_ir_compiled_root_field_plan_t *gql_ir_compiled_root_field_plan_clone(pTHX_ gql_ir_compiled_root_field_plan_t *plan);
static gql_ir_lowered_abstract_child_plan_table_t *gql_ir_lowered_abstract_child_plan_table_from_concrete_table(
  pTHX_ gql_ir_compiled_concrete_plan_table_t *table
);
static gql_ir_lowered_abstract_child_plan_table_t *gql_ir_lowered_abstract_child_plan_table_clone(
  pTHX_ gql_ir_lowered_abstract_child_plan_table_t *table
);
static void gql_ir_lowered_abstract_child_plan_table_destroy(gql_ir_lowered_abstract_child_plan_table_t *table);
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
static int gql_ir_consume_completed_result(pTHX_ HV *data_hv, AV **all_errors_avp, SV *key_sv, SV *completed_sv);
static int gql_ir_native_field_normalize_sync_completed_outcome(
  pTHX_ gql_ir_native_field_frame_t *frame
);
static int gql_ir_native_field_try_meta_dispatch(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_vm_field_meta_t *meta,
  SV *type_sv,
  gql_ir_native_field_frame_t *frame
);
static SV *gql_ir_native_field_get_resolver(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_vm_field_meta_t *meta,
  SV *resolve_sv,
  int *owns_resolve_out
);
static int gql_ir_native_field_call_resolver_empty_args(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *resolve_sv,
  SV **result_out,
  SV **args_out,
  int *owns_args_out
);
static int gql_ir_native_field_call_resolver_build_args(
  pTHX_ gql_ir_native_exec_env_t *env,
  SV *field_def_sv,
  SV *first_node_sv,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *resolve_sv,
  SV **result_out,
  SV **args_out,
  int *owns_args_out
);
static int gql_ir_native_field_complete_generic_result(
  pTHX_ gql_ir_vm_exec_state_t *state
);
static int gql_ir_native_field_complete_object_result(
  pTHX_ gql_ir_vm_exec_state_t *state
);
static int gql_ir_native_field_complete_list_result(
  pTHX_ gql_ir_vm_exec_state_t *state
);
static int gql_ir_native_field_complete_abstract_result(
  pTHX_ gql_ir_vm_exec_state_t *state
);
static int gql_ir_native_field_complete_generic_fallback_result(
  pTHX_ gql_ir_vm_exec_state_t *state
);
static int gql_ir_native_field_complete_no_direct_data_fallback_result(
  pTHX_ gql_ir_vm_exec_state_t *state
);
static int gql_ir_native_field_complete_family_fallback_result(
  pTHX_ gql_ir_vm_exec_state_t *state,
  gql_ir_native_completion_dispatch_kind_t family_kind
);
static int gql_ir_native_field_consume_completed(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_native_result_writer_t *writer,
  int *promise_present,
  gql_ir_vm_field_meta_t *meta,
  gql_ir_native_field_frame_t *frame
);
static int gql_ir_try_complete_sync_list_into_outcome(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_compiled_root_field_plan_entry_t *entry,
  SV *return_type,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *result_sv,
  gql_ir_native_field_frame_t *frame
);
static int gql_ir_try_complete_sync_object_into_outcome(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_compiled_root_field_plan_entry_t *entry,
  SV *return_type,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *result_sv,
  gql_ir_native_field_frame_t *frame
);
static int gql_ir_try_complete_abstract_sync_into(
  pTHX_ gql_ir_native_exec_env_t *env,
  SV *return_type,
  SV *nodes,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *result,
  gql_ir_native_field_frame_t *frame,
  gql_ir_compiled_root_field_plan_entry_t *entry
);
static int gql_ir_execute_native_child_field_plan_sync_to_outcome(
  pTHX_ gql_ir_native_exec_env_t *parent_env,
  SV *child_parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan,
  SV **data_out,
  AV **errors_out
);
static int gql_ir_execute_native_child_block_sync_to_child_outcome(
  pTHX_ gql_ir_native_exec_env_t *parent_env,
  SV *child_parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_vm_block_t *block,
  gql_ir_native_child_outcome_t *outcome
);
static int gql_ir_execute_native_child_field_plan_sync_to_child_outcome(
  pTHX_ gql_ir_native_exec_env_t *parent_env,
  SV *child_parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan,
  gql_ir_native_child_outcome_t *outcome
);
static int gql_ir_execute_native_child_field_plan_sync_to_frame_outcome(
  pTHX_ gql_ir_native_exec_env_t *parent_env,
  SV *child_parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan,
  gql_ir_native_field_frame_t *frame
);
static int gql_ir_execute_native_child_block_sync_to_frame_outcome(
  pTHX_ gql_ir_native_exec_env_t *parent_env,
  SV *child_parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_vm_block_t *block,
  gql_ir_native_field_frame_t *frame
);
static int gql_ir_execute_native_field_plan_sync_to_outcome(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan,
  SV **data_out,
  AV **errors_out
);
static int gql_ir_execute_native_block_sync_to_outcome(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_vm_block_t *block,
  SV **data_out,
  AV **errors_out
);
static int gql_ir_execute_native_field_plan_sync_to_child_outcome(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan,
  gql_ir_native_child_outcome_t *outcome
);
static int gql_ir_execute_native_block_sync_to_child_outcome(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_vm_block_t *block,
  gql_ir_native_child_outcome_t *outcome
);
static SV *gql_ir_execute_vm_block(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_vm_block_t *block
);
static void gql_ir_sync_outcome_move_to_frame(
  gql_execution_sync_outcome_t *outcome,
  gql_ir_native_field_frame_t *frame
);
static void gql_ir_native_child_outcome_move_to_frame(
  gql_ir_native_child_outcome_t *outcome,
  gql_ir_native_field_frame_t *frame
);
static SV *gql_ir_native_child_outcome_take_value_sv(gql_ir_native_child_outcome_t *outcome);
static SV *gql_ir_build_native_result(pTHX_ HV *data_hv, AV *all_errors_av);
static SV *gql_ir_finish_native_exec_result(
  pTHX_ SV *promise_code_sv,
  gql_ir_native_exec_accum_t *accum
);
static int gql_ir_run_vm_block_loop(pTHX_ gql_ir_vm_exec_state_t *state);
static int gql_ir_run_vm_block(pTHX_ gql_ir_vm_exec_state_t *state);
static int gql_ir_run_vm_program_root(pTHX_ gql_ir_vm_exec_state_t *state);
static int gql_ir_vm_exec_state_run_current_field(
  pTHX_ gql_ir_vm_exec_state_t *state
);
static int gql_ir_vm_exec_state_try_meta_dispatch(
  pTHX_ gql_ir_vm_exec_state_t *state
);
static int gql_ir_vm_exec_state_call_current_resolver(
  pTHX_ gql_ir_vm_exec_state_t *state,
  gql_ir_native_field_op_t op
);
static int gql_ir_vm_exec_state_complete_current_field(
  pTHX_ gql_ir_vm_exec_state_t *state,
  gql_ir_native_field_op_t op
);
static int gql_ir_vm_exec_state_consume_current_field(
  pTHX_ gql_ir_vm_exec_state_t *state
);
static int gql_ir_ensure_native_field_entry_operands(
  pTHX_ gql_ir_compiled_exec_t *compiled,
  gql_ir_compiled_root_field_plan_entry_t *entry
);
static int gql_ir_vm_exec_state_dispatch_current_field(
  gql_ir_vm_exec_state_t *state
);
static int gql_ir_vm_exec_state_prepare_field(
  pTHX_ gql_ir_vm_exec_state_t *state,
  UV field_index
);
static void gql_ir_init_native_field_frame(
  gql_ir_native_field_frame_t *frame,
  gql_ir_native_exec_env_t *env,
  gql_ir_vm_exec_cursor_t *cursor
);
static void gql_ir_cleanup_native_field_frame(
  pTHX_ gql_ir_native_field_frame_t *frame,
  gql_ir_vm_exec_cursor_t *cursor
);
static int gql_ir_vm_exec_state_begin_field(
  pTHX_ gql_ir_vm_exec_state_t *state,
  UV field_index
);
static void gql_ir_vm_exec_state_finish_field(
  pTHX_ gql_ir_vm_exec_state_t *state
);
static int gql_ir_native_field_entry_has_operands(
  gql_ir_compiled_root_field_plan_entry_t *entry
);
static gql_ir_vm_field_meta_t *gql_ir_native_field_meta(gql_ir_compiled_root_field_plan_entry_t *entry);
static SV *gql_ir_native_field_result_name(gql_ir_compiled_root_field_plan_entry_t *entry);
static SV *gql_ir_native_field_name(gql_ir_compiled_root_field_plan_entry_t *entry);
static gql_ir_vm_field_hot_t *gql_ir_native_field_hot(gql_ir_compiled_root_field_plan_entry_t *entry);
static void gql_ir_native_field_hot_refresh(gql_ir_compiled_root_field_plan_entry_t *entry);
static gql_ir_vm_field_cold_t *gql_ir_native_field_cold(gql_ir_compiled_root_field_plan_entry_t *entry);
static void gql_ir_native_field_cold_refresh(gql_ir_compiled_root_field_plan_entry_t *entry);
static gql_ir_vm_exec_hot_t *gql_ir_native_exec_hot(gql_ir_native_exec_env_t *env);
static SV *gql_ir_native_env_context(gql_ir_native_exec_env_t *env);
static SV *gql_ir_native_env_parent_type(gql_ir_native_exec_env_t *env);
static SV *gql_ir_native_env_root_value(gql_ir_native_exec_env_t *env);
static SV *gql_ir_native_env_base_path(gql_ir_native_exec_env_t *env);
static SV *gql_ir_native_env_promise_code(gql_ir_native_exec_env_t *env);
static int gql_ir_native_result_writer_push_pending(
  pTHX_ gql_ir_native_result_writer_t *writer,
  SV *key_sv,
  SV *value_sv
);
static int gql_ir_native_result_writer_append_errors(
  pTHX_ gql_ir_native_result_writer_t *writer,
  AV *child_errors_av
);
static int gql_ir_native_result_writer_write_direct(
  pTHX_ gql_ir_native_result_writer_t *writer,
  SV *key_sv,
  SV *value_sv,
  AV *child_errors_av
);
static int gql_ir_native_result_writer_consume_completed(
  pTHX_ gql_ir_native_result_writer_t *writer,
  SV *key_sv,
  SV *completed_sv
);
static gql_ir_lowered_abstract_child_plan_table_t *gql_ir_lower_single_node_abstract_child_plan_table(pTHX_ SV *return_type_sv, SV *nodes_sv);
static gql_ir_compiled_root_field_plan_t *gql_ir_lookup_native_concrete_child_plan(
  gql_ir_lowered_abstract_child_plan_table_t *table,
  SV *object_type
);
static void gql_ir_native_result_writer_materialize_pending_avs(
  pTHX_ gql_ir_native_result_writer_t *writer,
  AV **keys_out,
  AV **values_out
);
static int gql_ir_init_native_exec_env(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value_sv,
  SV *base_path_sv,
  gql_ir_native_exec_env_t *env_out,
  SV **promise_code_out
);
static void gql_ir_init_native_exec_accum(gql_ir_native_exec_accum_t *accum);
static void gql_ir_cleanup_native_exec_accum(gql_ir_native_exec_accum_t *accum);
static void gql_ir_init_native_result_writer(gql_ir_native_result_writer_t *writer);
static void gql_ir_cleanup_native_result_writer(gql_ir_native_result_writer_t *writer);

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
  if (compiled->lowered_plan) {
    gql_ir_execution_lowered_plan_destroy(compiled->lowered_plan);
    compiled->lowered_plan = NULL;
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

static int
gql_ir_consume_completed_result(pTHX_ HV *data_hv, AV **all_errors_avp, SV *key_sv, SV *completed_sv) {
  HV *value_hv;
  SV **data_svp;
  SV **child_errors_svp;
  STRLEN key_len;
  const char *key;
  I32 child_error_len;
  I32 j;

  if (!data_hv || !all_errors_avp || !key_sv || !SvOK(key_sv)
      || !completed_sv || !SvROK(completed_sv) || SvTYPE(SvRV(completed_sv)) != SVt_PVHV) {
    return 0;
  }

  value_hv = (HV *)SvRV(completed_sv);
  data_svp = hv_fetch(value_hv, "data", 4, 0);
  if (!data_svp) {
    return 0;
  }

  key = SvPV(key_sv, key_len);
  (void)hv_store(data_hv, key, (I32)key_len, SvREFCNT_inc_simple_NN(*data_svp), 0);

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
        av_push(all_errors_av, SvREFCNT_inc_simple_NN(*child_error_svp));
      }
    }
  }

  return 1;
}

static int
gql_ir_native_field_normalize_sync_completed_outcome(
  pTHX_ gql_ir_native_field_frame_t *frame
) {
  SV *data_sv = NULL;
  AV *errors_av = NULL;

  if (!frame
      || frame->outcome_kind != GQL_IR_NATIVE_FIELD_OUTCOME_COMPLETED_SV
      || !frame->outcome_sv) {
    return 0;
  }

  if (!gql_execution_extract_completed_outcome(aTHX_ frame->outcome_sv, &data_sv, &errors_av)) {
    return 0;
  }

  SvREFCNT_dec(frame->outcome_sv);
  frame->outcome_sv = data_sv;
  frame->outcome_errors_av = errors_av;
  frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_VALUE;
  return 1;
}

static int
gql_ir_try_complete_abstract_sync_into(
  pTHX_ gql_ir_native_exec_env_t *env,
  SV *return_type,
  SV *nodes,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *result,
  gql_ir_native_field_frame_t *frame,
  gql_ir_compiled_root_field_plan_entry_t *entry
) {
  gql_ir_vm_field_hot_t *hot = gql_ir_native_field_hot(entry);
  gql_ir_lowered_abstract_child_plan_table_t *abstract_child_plan_table =
    (hot && hot->abstract_child_plan_table)
      ? hot->abstract_child_plan_table
      : (entry ? entry->abstract_child_plan_table : NULL);
  gql_execution_sync_outcome_t outcome;
  SV *context;

  if (!frame) {
    return 0;
  }

  context = env ? gql_ir_native_env_context(env) : NULL;
  gql_execution_sync_outcome_reset(&outcome);
  if (!gql_execution_complete_abstract_field_value_catching_error_xs_lazy_sync_native_outcome_with_table(
        aTHX_
        context,
        lazy_info ? lazy_info->parent_type_sv : NULL,
        lazy_info ? lazy_info->field_def_sv : NULL,
        return_type,
        nodes,
        lazy_info,
        result,
        abstract_child_plan_table,
        &outcome
      )) {
    return 0;
  }

  gql_ir_sync_outcome_move_to_frame(&outcome, frame);
  return 1;
}

static int
gql_ir_execute_native_child_field_plan_sync_to_outcome(
  pTHX_ gql_ir_native_exec_env_t *parent_env,
  SV *child_parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan,
  SV **data_out,
  AV **errors_out
) {
  gql_ir_native_child_outcome_t outcome;

  if (data_out) {
    *data_out = NULL;
  }
  if (errors_out) {
    *errors_out = NULL;
  }

  if (!parent_env
      || !field_plan
      || !data_out
      || !errors_out
      || (gql_ir_native_env_promise_code(parent_env) && SvOK(gql_ir_native_env_promise_code(parent_env)))) {
    return 0;
  }

  if (!gql_ir_execute_native_child_field_plan_sync_to_child_outcome(
        aTHX_
        parent_env,
        child_parent_type_sv,
        root_value,
        path_sv,
        field_plan,
        &outcome
      )) {
    return 0;
  }

  *data_out = gql_ir_native_child_outcome_take_value_sv(&outcome);
  *errors_out = outcome.errors_av;
  outcome.errors_av = NULL;
  return 1;
}

static int
gql_ir_execute_native_child_field_plan_sync_to_child_outcome(
  pTHX_ gql_ir_native_exec_env_t *parent_env,
  SV *child_parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan,
  gql_ir_native_child_outcome_t *outcome
) {
  gql_ir_vm_block_t block_view;
  gql_ir_native_exec_env_t child_env;
  gql_ir_native_result_writer_t writer;
  gql_ir_vm_exec_state_t state;
  int promise_present = 0;

  if (outcome) {
    Zero(outcome, 1, gql_ir_native_child_outcome_t);
  }

  if (!parent_env
      || !field_plan
      || !outcome
      || (gql_ir_native_env_promise_code(parent_env) && SvOK(gql_ir_native_env_promise_code(parent_env)))) {
    return 0;
  }

  child_env = *parent_env;
  gql_ir_native_exec_hot(&child_env)->parent_type_sv = child_parent_type_sv;
  gql_ir_native_exec_hot(&child_env)->root_value_sv = root_value;
  gql_ir_native_exec_hot(&child_env)->base_path_sv = path_sv;
  gql_ir_vm_block_init_view(&block_view, field_plan, 0);

  gql_ir_init_native_result_writer(&writer);
  gql_ir_vm_exec_state_init(&state, NULL, &block_view, &child_env, &writer, &promise_present, 0);
  if (!gql_ir_run_vm_block(aTHX_ &state)) {
    gql_ir_cleanup_native_result_writer(&writer);
    return 0;
  }

  if (promise_present || writer.pending_count > 0 || !writer.direct_data_hv) {
    gql_ir_cleanup_native_result_writer(&writer);
    return 0;
  }

  outcome->data_hv = writer.direct_data_hv;
  writer.direct_data_hv = NULL;
  outcome->errors_av = writer.all_errors_av;
  writer.all_errors_av = NULL;

  gql_ir_cleanup_native_result_writer(&writer);
  return 1;
}

static int
gql_ir_execute_native_child_block_sync_to_child_outcome(
  pTHX_ gql_ir_native_exec_env_t *parent_env,
  SV *child_parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_vm_block_t *block,
  gql_ir_native_child_outcome_t *outcome
) {
  gql_ir_native_exec_env_t child_env;
  gql_ir_native_result_writer_t writer;
  gql_ir_vm_exec_state_t state;
  int promise_present = 0;

  if (outcome) {
    Zero(outcome, 1, gql_ir_native_child_outcome_t);
  }

  if (!parent_env
      || !block
      || !block->field_plan
      || !outcome
      || (gql_ir_native_env_promise_code(parent_env) && SvOK(gql_ir_native_env_promise_code(parent_env)))) {
    return 0;
  }

  child_env = *parent_env;
  gql_ir_native_exec_hot(&child_env)->parent_type_sv = child_parent_type_sv;
  gql_ir_native_exec_hot(&child_env)->root_value_sv = root_value;
  gql_ir_native_exec_hot(&child_env)->base_path_sv = path_sv;

  gql_ir_init_native_result_writer(&writer);
  gql_ir_vm_exec_state_init(&state, NULL, block, &child_env, &writer, &promise_present, 0);
  if (!gql_ir_run_vm_block(aTHX_ &state)) {
    gql_ir_cleanup_native_result_writer(&writer);
    return 0;
  }

  if (promise_present || writer.pending_count > 0 || !writer.direct_data_hv) {
    gql_ir_cleanup_native_result_writer(&writer);
    return 0;
  }

  outcome->data_hv = writer.direct_data_hv;
  writer.direct_data_hv = NULL;
  outcome->errors_av = writer.all_errors_av;
  writer.all_errors_av = NULL;

  gql_ir_cleanup_native_result_writer(&writer);
  return 1;
}

static int
gql_ir_execute_native_child_field_plan_sync_to_frame_outcome(
  pTHX_ gql_ir_native_exec_env_t *parent_env,
  SV *child_parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan,
  gql_ir_native_field_frame_t *frame
) {
  gql_ir_native_child_outcome_t outcome;

  if (!frame) {
    return 0;
  }

  if (!gql_ir_execute_native_child_field_plan_sync_to_child_outcome(
        aTHX_
        parent_env,
        child_parent_type_sv,
        root_value,
        path_sv,
        field_plan,
        &outcome
      )) {
    return 0;
  }

  gql_ir_native_child_outcome_move_to_frame(&outcome, frame);
  return 1;
}

static int
gql_ir_execute_native_child_block_sync_to_frame_outcome(
  pTHX_ gql_ir_native_exec_env_t *parent_env,
  SV *child_parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_vm_block_t *block,
  gql_ir_native_field_frame_t *frame
) {
  gql_ir_native_child_outcome_t outcome;

  if (!frame) {
    return 0;
  }

  if (!gql_ir_execute_native_child_block_sync_to_child_outcome(
        aTHX_
        parent_env,
        child_parent_type_sv,
        root_value,
        path_sv,
        block,
        &outcome
      )) {
    return 0;
  }

  gql_ir_native_child_outcome_move_to_frame(&outcome, frame);
  return 1;
}

static void
gql_ir_sync_outcome_move_to_frame(
  gql_execution_sync_outcome_t *outcome,
  gql_ir_native_field_frame_t *frame
) {
  if (!outcome || !frame) {
    return;
  }

  switch (outcome->kind) {
    case GQL_EXECUTION_SYNC_OUTCOME_DIRECT_OBJECT_HV:
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_OBJECT_HV;
      frame->outcome_sv = (SV *)outcome->object_hv;
      frame->outcome_errors_av = outcome->errors_av;
      outcome->object_hv = NULL;
      outcome->errors_av = NULL;
      break;
    case GQL_EXECUTION_SYNC_OUTCOME_DIRECT_LIST_AV:
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_LIST_AV;
      frame->outcome_sv = (SV *)outcome->list_av;
      frame->outcome_errors_av = outcome->errors_av;
      outcome->list_av = NULL;
      outcome->errors_av = NULL;
      break;
    case GQL_EXECUTION_SYNC_OUTCOME_DIRECT_VALUE:
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_VALUE;
      frame->outcome_sv = outcome->value_sv;
      frame->outcome_errors_av = outcome->errors_av;
      outcome->value_sv = NULL;
      outcome->errors_av = NULL;
      break;
    case GQL_EXECUTION_SYNC_OUTCOME_COMPLETED_SV:
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_COMPLETED_SV;
      frame->outcome_sv = outcome->completed_sv;
      outcome->completed_sv = NULL;
      break;
    default:
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_NONE;
      break;
  }
}

static void
gql_ir_native_child_outcome_move_to_frame(
  gql_ir_native_child_outcome_t *outcome,
  gql_ir_native_field_frame_t *frame
) {
  if (!outcome || !frame) {
    return;
  }

  frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_OBJECT_HV;
  frame->outcome_sv = (SV *)outcome->data_hv;
  frame->outcome_errors_av = outcome->errors_av;
  outcome->data_hv = NULL;
  outcome->errors_av = NULL;
}

static SV *
gql_ir_native_child_outcome_take_value_sv(gql_ir_native_child_outcome_t *outcome) {
  HV *data_hv;

  if (!outcome) {
    return newSV(0);
  }

  data_hv = outcome->data_hv;
  outcome->data_hv = NULL;
  return data_hv ? newRV_noinc((SV *)data_hv) : newSV(0);
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
gql_ir_finish_native_exec_result(
  pTHX_ SV *promise_code_sv,
  gql_ir_native_exec_accum_t *accum
) {
  gql_ir_native_result_writer_t *writer;
  HV *direct_data_hv;
  AV *result_keys_av = NULL;
  AV *result_values_av = NULL;
  AV *all_errors_av;

  if (!accum) {
    return &PL_sv_undef;
  }
  writer = &accum->writer;
  if (!writer->direct_data_hv) {
    return &PL_sv_undef;
  }

  direct_data_hv = writer->direct_data_hv;
  all_errors_av = writer->all_errors_av;

  if (accum->promise_present) {
    gql_ir_native_result_writer_materialize_pending_avs(aTHX_ writer, &result_keys_av, &result_values_av);
    if (!result_keys_av || !result_values_av) {
      return &PL_sv_undef;
    }
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

  if (!SvOK(promise_code_sv) || writer->pending_count == 0) {
    SV *ret = gql_ir_build_native_result(aTHX_ direct_data_hv, all_errors_av);
    return ret;
  }

  {
    gql_ir_native_result_writer_materialize_pending_avs(aTHX_ writer, &result_keys_av, &result_values_av);
    if (!result_keys_av || !result_values_av) {
      return &PL_sv_undef;
    }
    AV *merge_errors_av = all_errors_av ? all_errors_av : newAV();
    SV *ret = gql_execution_merge_hash(aTHX_ result_keys_av, result_values_av, merge_errors_av);
    SvREFCNT_dec((SV *)direct_data_hv);
    SvREFCNT_dec((SV *)result_keys_av);
    SvREFCNT_dec((SV *)result_values_av);
    SvREFCNT_dec((SV *)merge_errors_av);
    return ret;
  }
}

static int
gql_ir_vm_exec_state_prepare_field(
  pTHX_ gql_ir_vm_exec_state_t *state,
  UV field_index
) {
  gql_ir_compiled_exec_t *compiled;
  gql_ir_vm_block_t *block;
  gql_ir_vm_field_slot_t *slot;
  gql_ir_compiled_root_field_plan_entry_t *entry;
  gql_ir_vm_field_meta_t *meta;
  int fill_runtime_operands;

  if (!state || !state->block || !state->block->entries) {
    return 0;
  }

  block = state->block;
  if (field_index >= block->field_count) {
    return 0;
  }

  compiled = state->compiled;
  slot = block->slots ? &block->slots[field_index] : NULL;
  entry = &block->entries[field_index];
  meta = slot ? slot->meta : gql_ir_native_field_meta(entry);
  if (!meta || !meta->field_name_sv || !SvOK(meta->field_name_sv)) {
    return 0;
  }
  if (!meta->result_name_sv || !SvOK(meta->result_name_sv)) {
    return 0;
  }

  fill_runtime_operands = state->require_runtime_operand_fill && block->requires_runtime_operand_fill;
  if (fill_runtime_operands) {
    if (!entry->operands_ready
        && (!compiled || !gql_ir_ensure_native_field_entry_operands(aTHX_ compiled, entry))) {
      return 0;
    }
  } else if (!entry->operands_ready && !gql_ir_native_field_entry_has_operands(entry)) {
    return 0;
  }

  if (slot) {
    gql_ir_vm_field_slot_refresh(slot, entry);
  }

  state->cursor.field_index = field_index;
  state->cursor.pc = 0;
  state->cursor.current_op = GQL_IR_NATIVE_FIELD_OP_META;
  state->cursor.slot = slot;
  state->cursor.entry = entry;
  state->cursor.meta = slot ? slot->meta : meta;
  state->cursor.hot = slot ? slot->hot : gql_ir_native_field_hot(entry);
  state->cursor.cold = slot ? slot->cold : gql_ir_native_field_cold(entry);
  state->cursor.field_def_sv = slot ? slot->field_def_sv : ((state->cursor.hot && state->cursor.hot->field_def_sv) ? state->cursor.hot->field_def_sv : entry->field_def_sv);
  state->cursor.resolve_sv = slot ? slot->resolve_sv : ((state->cursor.hot && state->cursor.hot->resolve_sv) ? state->cursor.hot->resolve_sv : entry->resolve_sv);
  state->cursor.nodes_sv = slot ? slot->nodes_sv : ((state->cursor.hot && state->cursor.hot->nodes_sv) ? state->cursor.hot->nodes_sv : entry->nodes_sv);
  state->cursor.first_node_sv = slot ? slot->first_node_sv : ((state->cursor.hot && state->cursor.hot->first_node_sv) ? state->cursor.hot->first_node_sv : entry->first_node_sv);
  state->cursor.type_sv = slot ? slot->type_sv : ((state->cursor.hot && state->cursor.hot->type_sv) ? state->cursor.hot->type_sv : entry->type_sv);
  state->cursor.path_sv = slot ? slot->path_sv : ((state->cursor.cold && state->cursor.cold->path_sv && SvOK(state->cursor.cold->path_sv)) ? state->cursor.cold->path_sv : NULL);
  state->cursor.native_field_plan = slot ? slot->native_field_plan : ((state->cursor.hot && state->cursor.hot->native_field_plan) ? state->cursor.hot->native_field_plan : entry->native_field_plan);
  state->cursor.native_block = slot ? slot->native_block : ((state->cursor.hot && state->cursor.hot->native_block) ? state->cursor.hot->native_block : entry->native_block);
  state->cursor.abstract_child_plan_table =
    slot
      ? slot->abstract_child_plan_table
      : ((state->cursor.hot && state->cursor.hot->abstract_child_plan_table)
          ? state->cursor.hot->abstract_child_plan_table
          : entry->abstract_child_plan_table);
  state->cursor.list_item_abstract_child_plan_table =
    slot
      ? slot->list_item_abstract_child_plan_table
      : ((state->cursor.hot && state->cursor.hot->list_item_abstract_child_plan_table)
          ? state->cursor.hot->list_item_abstract_child_plan_table
          : entry->list_item_abstract_child_plan_table);
  return 1;
}

static int
gql_ir_vm_exec_state_begin_field(
  pTHX_ gql_ir_vm_exec_state_t *state,
  UV field_index
) {
  if (!gql_ir_vm_exec_state_prepare_field(aTHX_ state, field_index)) {
    return 0;
  }
  gql_ir_init_native_field_frame(&state->frame, state->env, &state->cursor);
  return 1;
}

static void
gql_ir_vm_exec_state_finish_field(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  if (!state || !state->cursor.entry) {
    return;
  }
  gql_ir_cleanup_native_field_frame(aTHX_ &state->frame, &state->cursor);
}

static int
gql_ir_run_vm_block_loop(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  UV field_i;
  gql_ir_vm_block_t *block;
  gql_ir_native_exec_env_t *env;
  gql_ir_native_result_writer_t *writer;
  int *promise_present;

  if (!state) {
    return 0;
  }

  block = state->block;
  env = state->env;
  writer = state->writer;
  promise_present = state->promise_present;

  if (!block || !block->field_plan || !block->entries || !env || !writer || !promise_present) {
    return 0;
  }

  for (field_i = 0; field_i < block->field_count; field_i++) {
    if (!gql_ir_vm_exec_state_begin_field(aTHX_ state, field_i)) {
      continue;
    }

    if (!gql_ir_vm_exec_state_run_current_field(
          aTHX_ state
        )) {
      gql_ir_vm_exec_state_finish_field(aTHX_ state);
      return 0;
    }
    gql_ir_vm_exec_state_finish_field(aTHX_ state);
  }

  return 1;
}

static int
gql_ir_vm_exec_state_run_current_field(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  return gql_ir_vm_exec_state_dispatch_current_field(aTHX_ state);
}

static int
gql_ir_run_vm_block(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  return gql_ir_run_vm_block_loop(aTHX_ state);
}

static int
gql_ir_run_vm_program_root(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  if (!state) {
    return 0;
  }
  state->block = state->compiled ? gql_ir_vm_program_root_block(gql_ir_execution_lowered_program(state->compiled)) : state->block;
  return gql_ir_run_vm_block(aTHX_ state);
}

static int
gql_ir_vm_exec_state_try_meta_dispatch(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  if (!state) {
    return 0;
  }

  return gql_ir_native_field_try_meta_dispatch(
    aTHX_
    state->env,
    state->cursor.meta,
    state->cursor.type_sv,
    &state->frame
  );
}

static int
gql_ir_vm_exec_state_call_current_resolver(
  pTHX_ gql_ir_vm_exec_state_t *state,
  gql_ir_native_field_op_t op
) {
  gql_ir_native_field_frame_t *frame;

  if (!state || !state->env || !state->cursor.entry) {
    return 0;
  }

  frame = &state->frame;

  switch (op) {
    case GQL_IR_NATIVE_FIELD_OP_CALL_FIXED_EMPTY_ARGS:
      frame->resolve_sv = state->cursor.resolve_sv;
      frame->resolve_is_default = 0;
      return gql_ir_native_field_call_resolver_empty_args(
        aTHX_
        state->env,
        &frame->lazy_info,
        frame->resolve_sv,
        &frame->result_sv,
        &frame->args_sv,
        &frame->owns_args_sv
      );
    case GQL_IR_NATIVE_FIELD_OP_CALL_FIXED_BUILD_ARGS:
      frame->resolve_sv = state->cursor.resolve_sv;
      frame->resolve_is_default = 0;
      return gql_ir_native_field_call_resolver_build_args(
        aTHX_
        state->env,
        state->cursor.field_def_sv,
        state->cursor.first_node_sv,
        &frame->lazy_info,
        frame->resolve_sv,
        &frame->result_sv,
        &frame->args_sv,
        &frame->owns_args_sv
      );
    case GQL_IR_NATIVE_FIELD_OP_CALL_CONTEXT_EMPTY_ARGS:
      if (!frame->resolve_sv) {
        frame->resolve_sv = gql_ir_native_field_get_resolver(
          aTHX_
          state->env,
          state->cursor.meta,
          state->cursor.resolve_sv,
          &frame->owns_resolve_sv
        );
        frame->resolve_is_default = gql_execution_is_default_field_resolver(aTHX_ frame->resolve_sv);
      }
      if (frame->resolve_is_default && !frame->used_fast_default_resolve) {
        return 1;
      }
      return gql_ir_native_field_call_resolver_empty_args(
        aTHX_
        state->env,
        &frame->lazy_info,
        frame->resolve_sv,
        &frame->result_sv,
        &frame->args_sv,
        &frame->owns_args_sv
      );
    case GQL_IR_NATIVE_FIELD_OP_CALL_CONTEXT_BUILD_ARGS:
      if (!frame->resolve_sv) {
        frame->resolve_sv = gql_ir_native_field_get_resolver(
          aTHX_
          state->env,
          state->cursor.meta,
          state->cursor.resolve_sv,
          &frame->owns_resolve_sv
        );
        frame->resolve_is_default = gql_execution_is_default_field_resolver(aTHX_ frame->resolve_sv);
      }
      if (frame->resolve_is_default && !frame->used_fast_default_resolve) {
        return 1;
      }
      return gql_ir_native_field_call_resolver_build_args(
        aTHX_
        state->env,
        state->cursor.field_def_sv,
        state->cursor.first_node_sv,
        &frame->lazy_info,
        frame->resolve_sv,
        &frame->result_sv,
        &frame->args_sv,
        &frame->owns_args_sv
      );
    default:
      return 0;
  }
}

static int
gql_ir_vm_exec_state_complete_current_field(
  pTHX_ gql_ir_vm_exec_state_t *state,
  gql_ir_native_field_op_t op
) {
  gql_ir_native_field_frame_t *frame;

  if (!state || !state->env || !state->writer || !state->cursor.entry) {
    return 0;
  }

  frame = &state->frame;

  switch (op) {
    case GQL_IR_NATIVE_FIELD_OP_COMPLETE_GENERIC:
      return gql_ir_native_field_complete_generic_result(aTHX_ state);
    case GQL_IR_NATIVE_FIELD_OP_COMPLETE_OBJECT:
      return gql_ir_native_field_complete_object_result(aTHX_ state);
    case GQL_IR_NATIVE_FIELD_OP_COMPLETE_LIST:
      return gql_ir_native_field_complete_list_result(aTHX_ state);
    case GQL_IR_NATIVE_FIELD_OP_COMPLETE_ABSTRACT:
      return gql_ir_native_field_complete_abstract_result(aTHX_ state);
    default:
      return 0;
  }
}

static int
gql_ir_vm_exec_state_consume_current_field(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  if (!state) {
    return 0;
  }

  return gql_ir_native_field_consume_completed(
    aTHX_
    state->env,
    state->writer,
    state->promise_present,
    state->cursor.meta,
    &state->frame
  );
}

static int
gql_ir_native_field_entry_has_operands(gql_ir_compiled_root_field_plan_entry_t *entry) {
  return entry
    && entry->nodes_sv
    && SvOK(entry->nodes_sv)
    && SvROK(entry->nodes_sv)
    && SvTYPE(SvRV(entry->nodes_sv)) == SVt_PVAV
    && entry->field_def_sv
    && SvOK(entry->field_def_sv)
    && SvROK(entry->field_def_sv)
    && SvTYPE(SvRV(entry->field_def_sv)) == SVt_PVHV
    && entry->type_sv
    && SvOK(entry->type_sv);
}

static gql_ir_vm_field_meta_t *
gql_ir_native_field_meta(gql_ir_compiled_root_field_plan_entry_t *entry) {
  return entry ? entry->meta : NULL;
}

static SV *
gql_ir_native_field_result_name(gql_ir_compiled_root_field_plan_entry_t *entry) {
  gql_ir_vm_field_meta_t *meta = gql_ir_native_field_meta(entry);
  return (meta && meta->result_name_sv) ? meta->result_name_sv : NULL;
}

static SV *
gql_ir_native_field_name(gql_ir_compiled_root_field_plan_entry_t *entry) {
  gql_ir_vm_field_meta_t *meta = gql_ir_native_field_meta(entry);
  return (meta && meta->field_name_sv) ? meta->field_name_sv : NULL;
}

static void
gql_ir_native_field_hot_refresh(gql_ir_compiled_root_field_plan_entry_t *entry) {
  gql_ir_vm_field_hot_t *hot;

  if (!entry) {
    return;
  }

  hot = &entry->hot_inline;
  Zero(hot, 1, gql_ir_vm_field_hot_t);
  hot->field_def_sv = entry->field_def_sv;
  hot->return_type_sv = entry->meta ? entry->meta->return_type_sv : NULL;
  hot->type_sv = entry->type_sv;
  hot->resolve_sv = entry->resolve_sv;
  hot->nodes_sv = entry->nodes_sv;
  hot->first_node_sv = entry->first_node_sv;
  hot->native_field_plan = entry->native_field_plan;
  hot->native_block = entry->native_block;
  hot->abstract_child_plan_table = entry->abstract_child_plan_table;
  hot->list_item_abstract_child_plan_table = entry->list_item_abstract_child_plan_table;
  entry->hot = hot;
}

static gql_ir_vm_field_hot_t *
gql_ir_native_field_hot(gql_ir_compiled_root_field_plan_entry_t *entry) {
  return entry ? entry->hot : NULL;
}

static void
gql_ir_native_field_cold_refresh(gql_ir_compiled_root_field_plan_entry_t *entry) {
  if (!entry) {
    return;
  }
  entry->cold = &entry->cold_inline;
}

static gql_ir_vm_field_cold_t *
gql_ir_native_field_cold(gql_ir_compiled_root_field_plan_entry_t *entry) {
  return entry ? entry->cold : NULL;
}

static gql_ir_vm_exec_hot_t *
gql_ir_native_exec_hot(gql_ir_native_exec_env_t *env) {
  if (!env) {
    return NULL;
  }
  if (!env->hot) {
    env->hot = &env->hot_inline;
  }
  return env->hot;
}

static SV *
gql_ir_native_env_context(gql_ir_native_exec_env_t *env) {
  gql_ir_vm_exec_hot_t *hot = gql_ir_native_exec_hot(env);
  return hot ? hot->context_sv : NULL;
}

static SV *
gql_ir_native_env_parent_type(gql_ir_native_exec_env_t *env) {
  gql_ir_vm_exec_hot_t *hot = gql_ir_native_exec_hot(env);
  return hot ? hot->parent_type_sv : NULL;
}

static SV *
gql_ir_native_env_root_value(gql_ir_native_exec_env_t *env) {
  gql_ir_vm_exec_hot_t *hot = gql_ir_native_exec_hot(env);
  return hot ? hot->root_value_sv : NULL;
}

static SV *
gql_ir_native_env_base_path(gql_ir_native_exec_env_t *env) {
  gql_ir_vm_exec_hot_t *hot = gql_ir_native_exec_hot(env);
  return hot ? hot->base_path_sv : NULL;
}

static SV *
gql_ir_native_env_promise_code(gql_ir_native_exec_env_t *env) {
  gql_ir_vm_exec_hot_t *hot = gql_ir_native_exec_hot(env);
  return hot ? hot->promise_code_sv : NULL;
}

static int
gql_ir_native_result_writer_push_pending(
  pTHX_ gql_ir_native_result_writer_t *writer,
  SV *key_sv,
  SV *value_sv
) {
  gql_ir_native_pending_entry_t *new_entries;
  UV new_capacity;

  if (!writer || !key_sv || !SvOK(key_sv) || !value_sv) {
    return 0;
  }

  if (writer->pending_count == writer->pending_capacity) {
    new_capacity = writer->pending_capacity ? writer->pending_capacity * 2 : 4;
    Renew(writer->pending_entries, new_capacity, gql_ir_native_pending_entry_t);
    writer->pending_capacity = new_capacity;
  }

  new_entries = writer->pending_entries;
  new_entries[writer->pending_count].key_sv = SvREFCNT_inc_simple_NN(key_sv);
  new_entries[writer->pending_count].value_sv = value_sv;
  writer->pending_count++;
  return 1;
}

static int
gql_ir_native_result_writer_append_errors(
  pTHX_ gql_ir_native_result_writer_t *writer,
  AV *child_errors_av
) {
  AV *all_errors_av;
  I32 error_len;
  I32 i;

  if (!writer || !child_errors_av || av_len(child_errors_av) < 0) {
    return 1;
  }

  all_errors_av = writer->all_errors_av;
  error_len = av_len(child_errors_av);
  if (!all_errors_av) {
    all_errors_av = newAV();
    writer->all_errors_av = all_errors_av;
  }

  for (i = 0; i <= error_len; i++) {
    SV **error_svp = av_fetch(child_errors_av, i, 0);
    if (error_svp) {
      av_push(all_errors_av, SvREFCNT_inc_simple_NN(*error_svp));
    }
  }

  return 1;
}

static int
gql_ir_native_result_writer_write_direct(
  pTHX_ gql_ir_native_result_writer_t *writer,
  SV *key_sv,
  SV *value_sv,
  AV *child_errors_av
) {
  if (!writer || !writer->direct_data_hv || !key_sv || !SvOK(key_sv) || !value_sv) {
    return 0;
  }

  (void)hv_store_ent(writer->direct_data_hv, key_sv, value_sv, 0);
  return gql_ir_native_result_writer_append_errors(aTHX_ writer, child_errors_av);
}

static int
gql_ir_native_result_writer_consume_completed(
  pTHX_ gql_ir_native_result_writer_t *writer,
  SV *key_sv,
  SV *completed_sv
) {
  if (!writer || !writer->direct_data_hv || !key_sv || !SvOK(key_sv) || !completed_sv) {
    return 0;
  }

  gql_ir_accumulate_completed_result(
    aTHX_
    writer->direct_data_hv,
    &writer->all_errors_av,
    key_sv,
    completed_sv
  );
  return 1;
}

static void
gql_ir_native_result_writer_materialize_pending_avs(
  pTHX_ gql_ir_native_result_writer_t *writer,
  AV **keys_out,
  AV **values_out
) {
  AV *keys_av;
  AV *values_av;
  UV i;

  if (keys_out) {
    *keys_out = NULL;
  }
  if (values_out) {
    *values_out = NULL;
  }
  if (!writer) {
    return;
  }

  keys_av = newAV();
  values_av = newAV();
  for (i = 0; i < writer->pending_count; i++) {
    av_push(keys_av, writer->pending_entries[i].key_sv);
    av_push(values_av, writer->pending_entries[i].value_sv);
    writer->pending_entries[i].key_sv = NULL;
    writer->pending_entries[i].value_sv = NULL;
  }
  Safefree(writer->pending_entries);
  writer->pending_entries = NULL;
  writer->pending_count = 0;
  writer->pending_capacity = 0;
  if (keys_out) {
    *keys_out = keys_av;
  } else {
    SvREFCNT_dec((SV *)keys_av);
  }
  if (values_out) {
    *values_out = values_av;
  } else {
    SvREFCNT_dec((SV *)values_av);
  }
}

static int
gql_ir_init_native_exec_env(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value_sv,
  SV *base_path_sv,
  gql_ir_native_exec_env_t *env_out,
  SV **promise_code_out
) {
  HV *context_hv;
  gql_execution_context_fast_cache_t *context_cache;
  SV **context_value_svp;
  SV **variable_values_svp;
  SV **empty_args_svp;
  SV **field_resolver_svp;
  SV **promise_code_svp;
  SV *promise_code_sv = &PL_sv_undef;

  if (!context_sv
      || !SvROK(context_sv)
      || SvTYPE(SvRV(context_sv)) != SVt_PVHV
      || !env_out) {
    return 0;
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

  Zero(env_out, 1, gql_ir_native_exec_env_t);
  env_out->hot = &env_out->hot_inline;
  env_out->hot_inline.context_sv = context_sv;
  env_out->hot_inline.parent_type_sv = parent_type_sv;
  env_out->hot_inline.root_value_sv = root_value_sv;
  env_out->hot_inline.base_path_sv = base_path_sv;
  env_out->hot_inline.promise_code_sv = promise_code_sv;
  env_out->context_value_sv = (context_value_svp && SvOK(*context_value_svp)) ? *context_value_svp : &PL_sv_undef;
  env_out->variable_values_sv = (variable_values_svp && SvOK(*variable_values_svp)) ? *variable_values_svp : &PL_sv_undef;
  env_out->empty_args_sv = (empty_args_svp && SvOK(*empty_args_svp)) ? *empty_args_svp : &PL_sv_undef;
  env_out->field_resolver_sv = (field_resolver_svp && SvOK(*field_resolver_svp)) ? *field_resolver_svp : &PL_sv_undef;

  if (promise_code_out) {
    *promise_code_out = promise_code_sv;
  }
  return 1;
}

static void
gql_ir_init_native_result_writer(gql_ir_native_result_writer_t *writer) {
  if (!writer) {
    return;
  }
  Zero(writer, 1, gql_ir_native_result_writer_t);
  writer->direct_data_hv = newHV();
}

static void
gql_ir_cleanup_native_result_writer(gql_ir_native_result_writer_t *writer) {
  if (!writer) {
    return;
  }
  if (writer->direct_data_hv) {
    SvREFCNT_dec((SV *)writer->direct_data_hv);
    writer->direct_data_hv = NULL;
  }
  if (writer->all_errors_av) {
    SvREFCNT_dec((SV *)writer->all_errors_av);
    writer->all_errors_av = NULL;
  }
  if (writer->pending_entries) {
    UV i;
    for (i = 0; i < writer->pending_count; i++) {
      if (writer->pending_entries[i].key_sv) {
        SvREFCNT_dec(writer->pending_entries[i].key_sv);
      }
      if (writer->pending_entries[i].value_sv) {
        SvREFCNT_dec(writer->pending_entries[i].value_sv);
      }
    }
    Safefree(writer->pending_entries);
    writer->pending_entries = NULL;
  }
  writer->pending_count = 0;
  writer->pending_capacity = 0;
}

static void
gql_ir_init_native_exec_accum(gql_ir_native_exec_accum_t *accum) {
  if (!accum) {
    return;
  }
  Zero(accum, 1, gql_ir_native_exec_accum_t);
  gql_ir_init_native_result_writer(&accum->writer);
}

static void
gql_ir_cleanup_native_exec_accum(gql_ir_native_exec_accum_t *accum) {
  if (!accum) {
    return;
  }
  gql_ir_cleanup_native_result_writer(&accum->writer);
  accum->promise_present = 0;
}

static int
gql_ir_native_field_try_meta_dispatch(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_vm_field_meta_t *meta,
  SV *type_sv,
  gql_ir_native_field_frame_t *frame
) {
  SV *direct_data_sv = NULL;

  if (!env || !meta || !type_sv || !SvOK(type_sv) || !frame) {
    return 0;
  }
  if (meta->meta_dispatch_kind != GQL_IR_NATIVE_META_DISPATCH_TYPENAME) {
    return 0;
  }

  if (gql_execution_try_typename_meta_field_data_fast(aTHX_ gql_ir_native_env_parent_type(env), meta->field_name_sv, type_sv, &direct_data_sv)) {
    frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_VALUE;
    frame->outcome_sv = direct_data_sv;
    return 1;
  }
  if (gql_execution_try_typename_meta_field_fast(aTHX_ gql_ir_native_env_parent_type(env), meta->field_name_sv, type_sv, &frame->outcome_sv)) {
    frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_COMPLETED_SV;
    return 1;
  }

  return 0;
}

static SV *
gql_ir_native_field_get_resolver(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_vm_field_meta_t *meta,
  SV *resolve_sv,
  int *owns_resolve_out
) {
  if (owns_resolve_out) {
    *owns_resolve_out = 0;
  }
  if (!env) {
    return &PL_sv_undef;
  }

  switch (meta ? meta->resolve_dispatch_kind : GQL_IR_NATIVE_RESOLVE_DISPATCH_CONTEXT_OR_DEFAULT) {
    case GQL_IR_NATIVE_RESOLVE_DISPATCH_FIXED:
      return resolve_sv ? resolve_sv : &PL_sv_undef;
    case GQL_IR_NATIVE_RESOLVE_DISPATCH_CONTEXT_OR_DEFAULT:
    default:
      if (resolve_sv && SvOK(resolve_sv)) {
        return resolve_sv;
      }
      if (env->field_resolver_sv && SvOK(env->field_resolver_sv)) {
        return env->field_resolver_sv;
      }
      if (owns_resolve_out) {
        *owns_resolve_out = 1;
      }
      return newSV(0);
  }
}

static int
gql_ir_native_field_call_resolver_empty_args(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *resolve_sv,
  SV **result_out,
  SV **args_out,
  int *owns_args_out
) {
  SV *args_sv = NULL;

  if (result_out) {
    *result_out = NULL;
  }
  if (args_out) {
    *args_out = NULL;
  }
  if (owns_args_out) {
    *owns_args_out = 0;
  }
  if (!env || !lazy_info || !resolve_sv || !result_out) {
    return 0;
  }

  (void)gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
  if (env->empty_args_sv && SvOK(env->empty_args_sv)) {
    args_sv = env->empty_args_sv;
  } else {
    args_sv = newRV_noinc((SV *)newHV());
    if (owns_args_out) {
      *owns_args_out = 1;
    }
  }

  if (args_out) {
    *args_out = args_sv;
  }
  *result_out = gql_execution_call_resolver(
    aTHX_
    resolve_sv,
    gql_ir_native_env_root_value(env),
    args_sv,
    (env->context_value_sv && SvOK(env->context_value_sv)) ? env->context_value_sv : &PL_sv_undef,
    lazy_info->info_sv
  );
  return 1;
}

static int
gql_ir_native_field_call_resolver_build_args(
  pTHX_ gql_ir_native_exec_env_t *env,
  SV *field_def_sv,
  SV *first_node_sv,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *resolve_sv,
  SV **result_out,
  SV **args_out,
  int *owns_args_out
) {
  SV *field_node_sv;
  SV *args_sv;

  if (result_out) {
    *result_out = NULL;
  }
  if (args_out) {
    *args_out = NULL;
  }
  if (owns_args_out) {
    *owns_args_out = 0;
  }
  if (!env || !field_def_sv || !first_node_sv || !lazy_info || !resolve_sv || !result_out) {
    return 0;
  }

  field_node_sv = first_node_sv;
  if (!SvROK(field_node_sv) || SvTYPE(SvRV(field_node_sv)) != SVt_PVHV) {
    return 0;
  }

  (void)gql_execution_lazy_resolve_info_materialize(aTHX_ lazy_info);
  args_sv = gql_execution_get_argument_values_xs_impl(
    aTHX_ field_def_sv,
    field_node_sv,
    (env->variable_values_sv && SvOK(env->variable_values_sv)) ? env->variable_values_sv : &PL_sv_undef
  );
  if (owns_args_out) {
    *owns_args_out = 1;
  }
  if (args_out) {
    *args_out = args_sv;
  }
  *result_out = gql_execution_call_resolver(
    aTHX_
    resolve_sv,
    gql_ir_native_env_root_value(env),
    args_sv,
    (env->context_value_sv && SvOK(env->context_value_sv)) ? env->context_value_sv : &PL_sv_undef,
    lazy_info->info_sv
  );
  return 1;
}

static int
gql_ir_native_field_try_trivial_completion(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_vm_field_meta_t *meta,
  gql_ir_native_field_frame_t *frame,
  SV *type_sv,
  int resolve_is_default,
  SV **result_io
) {
  SV *direct_data_sv = NULL;
  SV *result_sv = result_io ? *result_io : NULL;

  if (!env || !frame || !result_io || !type_sv || !SvOK(type_sv) || !meta) {
    return 0;
  }
  if (meta->completion_dispatch_kind != GQL_IR_NATIVE_COMPLETION_TRIVIAL) {
    return 0;
  }

  if (!result_sv && resolve_is_default
      && gql_execution_try_default_field_resolve_borrowed_fast(aTHX_ gql_ir_native_env_root_value(env), meta->field_name_sv, &result_sv)) {
    *result_io = result_sv;
    if (gql_execution_try_complete_trivial_value_with_metadata_data_fast(
          aTHX_ meta->completion_type_sv,
          meta->trivial_completion_flags,
          result_sv,
          &direct_data_sv
        )) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_VALUE;
      frame->outcome_sv = direct_data_sv;
      SvREFCNT_dec(result_sv);
      *result_io = NULL;
      return 1;
    }
  }

  if (result_sv) {
    if (gql_execution_try_complete_trivial_value_with_metadata_data_fast(
          aTHX_ meta->completion_type_sv,
          meta->trivial_completion_flags,
          result_sv,
          &direct_data_sv
        )) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_VALUE;
      frame->outcome_sv = direct_data_sv;
      return 1;
    }
    if (gql_execution_try_complete_trivial_value_with_metadata_fast(
          aTHX_ meta->completion_type_sv,
          meta->trivial_completion_flags,
          result_sv,
          &frame->outcome_sv
        )) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_COMPLETED_SV;
      (void)gql_ir_native_field_normalize_sync_completed_outcome(aTHX_ frame);
      return 1;
    }
  }

  return 0;
}

static int
gql_ir_native_field_complete_trivial_result(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_vm_field_meta_t *meta,
  gql_ir_native_field_frame_t *frame,
  SV *result_sv
) {
  SV *direct_data_sv = NULL;

  if (!env || !frame || !meta || !meta->completion_type_sv || !result_sv) {
    return 0;
  }

  if (gql_execution_try_complete_trivial_value_with_metadata_data_fast(
        aTHX_ meta->completion_type_sv,
        meta->trivial_completion_flags,
        result_sv,
        &direct_data_sv
      )) {
    frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_VALUE;
    frame->outcome_sv = direct_data_sv;
    return 1;
  }

  if (gql_execution_try_complete_trivial_value_with_metadata_fast(
        aTHX_ meta->completion_type_sv,
        meta->trivial_completion_flags,
        result_sv,
        &frame->outcome_sv
      )) {
    frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_COMPLETED_SV;
    (void)gql_ir_native_field_normalize_sync_completed_outcome(aTHX_ frame);
    return 1;
  }

  return 0;
}

static int
gql_ir_try_complete_sync_object_into_outcome(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_compiled_root_field_plan_entry_t *entry,
  SV *return_type,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *result_sv,
  gql_ir_native_field_frame_t *frame
) {
  gql_ir_compiled_root_field_plan_t *native_field_plan;
  gql_ir_vm_block_t *native_block = NULL;
  SV *path_sv;
  gql_ir_vm_field_hot_t *hot = gql_ir_native_field_hot(entry);

  if (!env
      || !return_type
      || !SvOK(return_type)
      || !lazy_info
      || !lazy_info->nodes_sv
      || !result_sv
      || !SvOK(result_sv)
      || !frame
      || (gql_ir_native_env_promise_code(env) && SvOK(gql_ir_native_env_promise_code(env)))) {
    return 0;
  }

  if (!(SvROK(return_type)
        && (sv_derived_from(return_type, "GraphQL::Houtou::Type::Object")
            || sv_derived_from(return_type, "GraphQL::Type::Object")))) {
    return 0;
  }

  native_field_plan = (hot && hot->native_field_plan)
    ? hot->native_field_plan
    : gql_execution_collect_single_node_concrete_native_field_plan(
        aTHX_ return_type,
        lazy_info->nodes_sv
      );
  native_block = (hot && hot->native_block) ? hot->native_block : NULL;
  if (!native_field_plan) {
    return 0;
  }

  path_sv = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
  if (native_block && native_block->field_plan == native_field_plan) {
    return gql_ir_execute_native_child_block_sync_to_frame_outcome(
          aTHX_
          env,
          return_type,
          result_sv,
          path_sv,
          native_block,
          frame
        );
  }
  return gql_ir_execute_native_child_field_plan_sync_to_frame_outcome(
        aTHX_
        env,
        return_type,
        result_sv,
        path_sv,
        native_field_plan,
        frame
      );
}

static int
gql_ir_try_complete_sync_list_into_outcome(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_compiled_root_field_plan_entry_t *entry,
  SV *return_type,
  gql_execution_lazy_resolve_info_t *lazy_info,
  SV *result_sv,
  gql_ir_native_field_frame_t *frame
) {
  SV *item_type = NULL;
  AV *result_av;
  AV *data_av = NULL;
  AV *errors_av = NULL;
  I32 result_len;
  I32 i;
  gql_ir_vm_field_meta_t *meta = gql_ir_native_field_meta(entry);
  gql_ir_vm_field_hot_t *hot = gql_ir_native_field_hot(entry);
  gql_ir_compiled_root_field_plan_t *item_native_field_plan
    = (hot && hot->native_field_plan) ? hot->native_field_plan : NULL;
  gql_ir_vm_block_t *item_native_block
    = (hot && hot->native_block) ? hot->native_block : NULL;
  gql_ir_lowered_abstract_child_plan_table_t *item_abstract_child_plan_table =
    (hot && hot->list_item_abstract_child_plan_table)
      ? hot->list_item_abstract_child_plan_table
      : NULL;

  if (!env
      || !return_type
      || !lazy_info
      || !frame
      || (gql_ir_native_env_promise_code(env) && SvOK(gql_ir_native_env_promise_code(env)))
      || !(sv_derived_from(return_type, "GraphQL::Houtou::Type::List")
           || sv_derived_from(return_type, "GraphQL::Type::List"))
      || !result_sv
      || !SvROK(result_sv)
      || SvTYPE(SvRV(result_sv)) != SVt_PVAV) {
    return 0;
  }

  item_type = (meta && meta->list_item_type_sv)
    ? gql_execution_share_or_copy_sv(meta->list_item_type_sv)
    : gql_execution_call_type_of(aTHX_ return_type);
  result_av = (AV *)SvRV(result_sv);
  result_len = av_len(result_av);
  data_av = newAV();

  for (i = 0; i <= result_len; i++) {
    SV **item_svp = av_fetch(result_av, i, 0);
    SV *item_data_sv = NULL;
    SV *item_completed_sv = NULL;
    AV *item_errors_av = NULL;
    gql_ir_native_child_outcome_t item_outcome;
    gql_execution_sync_outcome_t item_sync_outcome;
    SV *base_path_sv = gql_execution_lazy_path_materialize(aTHX_ lazy_info);
    SV *item_path_sv = gql_execution_path_with_index(aTHX_ base_path_sv, (IV)i);
    gql_execution_lazy_resolve_info_t item_lazy_info = *lazy_info;

    item_lazy_info.base_path_sv = NULL;
    item_lazy_info.result_name_sv = NULL;
    item_lazy_info.path_sv = item_path_sv;
    item_lazy_info.info_sv = NULL;
    gql_execution_sync_outcome_reset(&item_sync_outcome);

    if (item_native_field_plan) {
      if (item_native_block && item_native_block->field_plan == item_native_field_plan) {
        if (gql_ir_execute_native_child_block_sync_to_child_outcome(
              aTHX_
              env,
              item_type,
              item_svp ? *item_svp : &PL_sv_undef,
              item_path_sv,
              item_native_block,
              &item_outcome
            )) {
          item_data_sv = gql_ir_native_child_outcome_take_value_sv(&item_outcome);
          item_errors_av = item_outcome.errors_av;
          item_outcome.errors_av = NULL;
        }
      } else if (gql_ir_execute_native_child_field_plan_sync_to_child_outcome(
            aTHX_
            env,
            item_type,
            item_svp ? *item_svp : &PL_sv_undef,
            item_path_sv,
            item_native_field_plan,
            &item_outcome
          )) {
        item_data_sv = gql_ir_native_child_outcome_take_value_sv(&item_outcome);
        item_errors_av = item_outcome.errors_av;
        item_outcome.errors_av = NULL;
      }
    } else if (item_abstract_child_plan_table) {
      if (gql_execution_complete_abstract_field_value_catching_error_xs_lazy_sync_native_outcome_with_table(
            aTHX_
            gql_ir_native_env_context(env),
            item_lazy_info.parent_type_sv,
            item_lazy_info.field_def_sv,
            item_type,
            item_lazy_info.nodes_sv,
            &item_lazy_info,
            item_svp ? *item_svp : &PL_sv_undef,
            item_abstract_child_plan_table,
            &item_sync_outcome
          )) {
        if (item_sync_outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_DIRECT_OBJECT_HV) {
          item_data_sv = item_sync_outcome.object_hv ? newRV_noinc((SV *)item_sync_outcome.object_hv) : newSV(0);
          item_sync_outcome.object_hv = NULL;
          item_errors_av = item_sync_outcome.errors_av;
          item_sync_outcome.errors_av = NULL;
        } else if (item_sync_outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_DIRECT_LIST_AV) {
          item_data_sv = item_sync_outcome.list_av ? newRV_noinc((SV *)item_sync_outcome.list_av) : newSV(0);
          item_sync_outcome.list_av = NULL;
          item_errors_av = item_sync_outcome.errors_av;
          item_sync_outcome.errors_av = NULL;
        } else if (item_sync_outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_DIRECT_VALUE) {
          item_data_sv = item_sync_outcome.value_sv;
          item_sync_outcome.value_sv = NULL;
          item_errors_av = item_sync_outcome.errors_av;
          item_sync_outcome.errors_av = NULL;
        } else if (item_sync_outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_COMPLETED_SV) {
          item_completed_sv = item_sync_outcome.completed_sv;
          item_sync_outcome.completed_sv = NULL;
        }
      }
    }

    if (!item_data_sv
        && !item_completed_sv
        && !gql_execution_complete_field_value_catching_error_xs_lazy_sync_outcome(
             aTHX_
             gql_ir_native_env_context(env),
             item_lazy_info.parent_type_sv,
             item_lazy_info.field_def_sv,
             item_type,
             item_lazy_info.nodes_sv,
             &item_lazy_info,
             item_svp ? *item_svp : &PL_sv_undef,
             &item_data_sv,
             &item_errors_av,
             &item_completed_sv
           )) {
      SvREFCNT_dec(item_path_sv);
      if (item_errors_av) {
        SvREFCNT_dec((SV *)item_errors_av);
      }
      goto fallback;
    }

    if (item_completed_sv) {
      if (SvROK(item_completed_sv) && SvTYPE(SvRV(item_completed_sv)) == SVt_PVHV) {
        gql_execution_accumulate_completed_list_item_into_head(
          aTHX_ data_av,
          errors_av ? errors_av : (errors_av = newAV()),
          i,
          item_completed_sv
        );
        SvREFCNT_dec(item_completed_sv);
        item_completed_sv = NULL;
      } else {
        SvREFCNT_dec(item_completed_sv);
        SvREFCNT_dec(item_path_sv);
        if (item_errors_av) {
          SvREFCNT_dec((SV *)item_errors_av);
        }
        goto fallback;
      }
    } else {
      av_fill(data_av, i);
      (void)av_store(data_av, i, item_data_sv ? item_data_sv : newSV(0));

      if (item_errors_av && av_len(item_errors_av) >= 0) {
        I32 err_len = av_len(item_errors_av);
        I32 err_i;
        if (!errors_av) {
          errors_av = newAV();
        }
        for (err_i = 0; err_i <= err_len; err_i++) {
          SV **err_svp = av_fetch(item_errors_av, err_i, 0);
          if (err_svp) {
            av_push(errors_av, SvREFCNT_inc_simple_NN(*err_svp));
          }
        }
      }
    }
    if (item_errors_av) {
      SvREFCNT_dec((SV *)item_errors_av);
    }
    SvREFCNT_dec(item_path_sv);
  }

  SvREFCNT_dec(item_type);
  frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_LIST_AV;
  frame->outcome_sv = (SV *)data_av;
  frame->outcome_errors_av = errors_av;
  return 1;

fallback:
  if (item_type) {
    SvREFCNT_dec(item_type);
  }
  if (data_av) {
    SvREFCNT_dec((SV *)data_av);
  }
  if (errors_av) {
    SvREFCNT_dec((SV *)errors_av);
  }
  return 0;
}

static int
gql_ir_native_field_complete_generic_fallback_result(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  gql_ir_native_exec_env_t *env = state ? state->env : NULL;
  gql_ir_native_result_writer_t *writer = state ? state->writer : NULL;
  gql_ir_vm_exec_cursor_t *cursor = state ? &state->cursor : NULL;
  gql_ir_native_field_frame_t *frame = state ? &state->frame : NULL;
  gql_execution_lazy_resolve_info_t *lazy_info = frame ? &frame->lazy_info : NULL;
  SV *result_sv = frame ? frame->result_sv : NULL;
  gql_ir_vm_field_meta_t *meta = cursor ? cursor->meta : NULL;
  SV *field_def_sv = cursor ? cursor->field_def_sv : NULL;
  SV *nodes_sv = cursor ? cursor->nodes_sv : NULL;
  SV *return_type_sv = meta ? meta->return_type_sv : NULL;
  SV *direct_data_sv = NULL;
  AV *direct_errors_av = NULL;
  SV *completed_sv = NULL;
  if (!return_type_sv || !SvOK(return_type_sv)) {
    return_type_sv = cursor ? cursor->type_sv : NULL;
  }

  if (!env
      || !writer
      || !cursor
      || !field_def_sv
      || !nodes_sv
      || !return_type_sv
      || !lazy_info
      || !frame) {
    return 0;
  }

  if (gql_execution_complete_field_value_catching_error_xs_lazy_sync_outcome(
        aTHX_
        gql_ir_native_env_context(env),
        gql_ir_native_env_parent_type(env),
        field_def_sv,
        return_type_sv,
        nodes_sv,
        lazy_info,
        result_sv,
        &direct_data_sv,
        &direct_errors_av,
        &completed_sv
      )) {
    if (direct_data_sv) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_VALUE;
      frame->outcome_sv = direct_data_sv;
      frame->outcome_errors_av = direct_errors_av;
      return 1;
    }
    if (completed_sv) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_COMPLETED_SV;
      frame->outcome_sv = completed_sv;
      return 1;
    }
  }
  return 0;
}

static int
gql_ir_native_field_complete_no_direct_data_fallback_result(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  gql_ir_native_exec_env_t *env = state ? state->env : NULL;
  gql_ir_native_result_writer_t *writer = state ? state->writer : NULL;
  gql_ir_vm_exec_cursor_t *cursor = state ? &state->cursor : NULL;
  gql_ir_native_field_frame_t *frame = state ? &state->frame : NULL;
  gql_execution_lazy_resolve_info_t *lazy_info = frame ? &frame->lazy_info : NULL;
  SV *result_sv = frame ? frame->result_sv : NULL;
  gql_ir_vm_field_meta_t *meta = cursor ? cursor->meta : NULL;
  SV *field_def_sv = cursor ? cursor->field_def_sv : NULL;
  SV *nodes_sv = cursor ? cursor->nodes_sv : NULL;
  SV *return_type_sv = meta ? meta->return_type_sv : NULL;
  gql_ir_lowered_abstract_child_plan_table_t *abstract_child_plan_table =
    cursor ? cursor->abstract_child_plan_table : NULL;
  SV *list_item_type_sv = (meta && meta->list_item_type_sv) ? meta->list_item_type_sv : NULL;
  gql_ir_lowered_abstract_child_plan_table_t *list_item_abstract_child_plan_table =
    cursor ? cursor->list_item_abstract_child_plan_table : NULL;
  gql_execution_sync_outcome_t outcome;
  gql_ir_native_completion_dispatch_kind_t family_kind =
    meta ? meta->completion_dispatch_kind : GQL_IR_NATIVE_COMPLETION_GENERIC;

  if (!return_type_sv || !SvOK(return_type_sv)) {
    return_type_sv = cursor ? cursor->type_sv : NULL;
  }

  if (!env
      || !writer
      || !cursor
      || !field_def_sv
      || !nodes_sv
      || !return_type_sv
      || !lazy_info
      || !frame) {
    return 0;
  }

  gql_execution_sync_outcome_reset(&outcome);
  switch (family_kind) {
    case GQL_IR_NATIVE_COMPLETION_OBJECT:
      (void)gql_execution_complete_object_field_value_catching_error_xs_lazy_sync_native_outcome_no_direct_data(
        aTHX_
        gql_ir_native_env_context(env),
        gql_ir_native_env_parent_type(env),
        field_def_sv,
        return_type_sv,
        nodes_sv,
        lazy_info,
        result_sv,
        &outcome
      );
      break;
    case GQL_IR_NATIVE_COMPLETION_LIST:
      (void)gql_execution_complete_list_field_value_catching_error_xs_lazy_sync_native_outcome_no_direct_data(
        aTHX_
        gql_ir_native_env_context(env),
        gql_ir_native_env_parent_type(env),
        field_def_sv,
        return_type_sv,
        nodes_sv,
        lazy_info,
        result_sv,
        &outcome
      );
      break;
    case GQL_IR_NATIVE_COMPLETION_ABSTRACT:
      (void)gql_execution_complete_abstract_field_value_catching_error_xs_lazy_sync_native_outcome_no_direct_data_with_table(
        aTHX_
        gql_ir_native_env_context(env),
        gql_ir_native_env_parent_type(env),
        field_def_sv,
        return_type_sv,
        nodes_sv,
        lazy_info,
        result_sv,
        abstract_child_plan_table,
        &outcome
      );
      break;
    default:
      (void)gql_execution_complete_field_value_catching_error_xs_lazy_sync_native_outcome_no_direct_data(
        aTHX_
        gql_ir_native_env_context(env),
        gql_ir_native_env_parent_type(env),
        field_def_sv,
        return_type_sv,
        nodes_sv,
        lazy_info,
        result_sv,
        &outcome
      );
      break;
  }
  if (outcome.kind != GQL_EXECUTION_SYNC_OUTCOME_NONE) {
    if (outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_DIRECT_VALUE) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_VALUE;
      frame->outcome_sv = outcome.value_sv;
      frame->outcome_errors_av = outcome.errors_av;
      gql_execution_sync_outcome_reset(&outcome);
      return 1;
    }
    if (outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_DIRECT_LIST_AV) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_LIST_AV;
      frame->outcome_sv = (SV *)outcome.list_av;
      frame->outcome_errors_av = outcome.errors_av;
      gql_execution_sync_outcome_reset(&outcome);
      return 1;
    }
    if (outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_DIRECT_OBJECT_HV) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_OBJECT_HV;
      frame->outcome_sv = (SV *)outcome.object_hv;
      frame->outcome_errors_av = outcome.errors_av;
      gql_execution_sync_outcome_reset(&outcome);
      return 1;
    }
    if (outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_COMPLETED_SV) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_COMPLETED_SV;
      frame->outcome_sv = outcome.completed_sv;
      gql_execution_sync_outcome_reset(&outcome);
      return 1;
    }
  }
  return 0;
}

static int
gql_ir_native_field_complete_family_fallback_result(
  pTHX_ gql_ir_vm_exec_state_t *state,
  gql_ir_native_completion_dispatch_kind_t family_kind
) {
  gql_ir_native_exec_env_t *env = state ? state->env : NULL;
  gql_ir_native_result_writer_t *writer = state ? state->writer : NULL;
  gql_ir_vm_exec_cursor_t *cursor = state ? &state->cursor : NULL;
  gql_ir_native_field_frame_t *frame = state ? &state->frame : NULL;
  gql_execution_lazy_resolve_info_t *lazy_info = frame ? &frame->lazy_info : NULL;
  SV *result_sv = frame ? frame->result_sv : NULL;
  gql_ir_vm_field_meta_t *meta = cursor ? cursor->meta : NULL;
  SV *field_def_sv = cursor ? cursor->field_def_sv : NULL;
  SV *nodes_sv = cursor ? cursor->nodes_sv : NULL;
  SV *return_type_sv = meta ? meta->return_type_sv : NULL;
  gql_ir_lowered_abstract_child_plan_table_t *abstract_child_plan_table =
    cursor ? cursor->abstract_child_plan_table : NULL;
  SV *list_item_type_sv = (meta && meta->list_item_type_sv) ? meta->list_item_type_sv : NULL;
  gql_ir_lowered_abstract_child_plan_table_t *list_item_abstract_child_plan_table =
    cursor ? cursor->list_item_abstract_child_plan_table : NULL;
  gql_ir_compiled_root_field_plan_t *native_field_plan = cursor ? cursor->native_field_plan : NULL;
  gql_execution_sync_outcome_t outcome;

  if (!return_type_sv || !SvOK(return_type_sv)) {
    return_type_sv = cursor ? cursor->type_sv : NULL;
  }

  if (!env
      || !writer
      || !cursor
      || !field_def_sv
      || !nodes_sv
      || !return_type_sv
      || !lazy_info
      || !frame) {
    return 0;
  }

  gql_execution_sync_outcome_reset(&outcome);
  switch (family_kind) {
    case GQL_IR_NATIVE_COMPLETION_OBJECT:
      if (gql_execution_complete_object_field_value_catching_error_xs_lazy_sync_native_outcome_with_plan(
            aTHX_
            gql_ir_native_env_context(env),
            gql_ir_native_env_parent_type(env),
            field_def_sv,
            return_type_sv,
            nodes_sv,
            lazy_info,
            result_sv,
            native_field_plan,
            &outcome
          )) {
        break;
      }
      return 0;
    case GQL_IR_NATIVE_COMPLETION_LIST:
      if (gql_execution_complete_list_field_value_catching_error_xs_lazy_sync_native_outcome_with_items(
            aTHX_
            gql_ir_native_env_context(env),
            gql_ir_native_env_parent_type(env),
            field_def_sv,
            return_type_sv,
            nodes_sv,
            lazy_info,
            result_sv,
            list_item_type_sv,
            native_field_plan,
            list_item_abstract_child_plan_table,
            &outcome
          )) {
        break;
      }
      return 0;
    case GQL_IR_NATIVE_COMPLETION_ABSTRACT:
      if (gql_execution_complete_abstract_field_value_catching_error_xs_lazy_sync_native_outcome_with_table(
            aTHX_
            gql_ir_native_env_context(env),
            gql_ir_native_env_parent_type(env),
            field_def_sv,
            return_type_sv,
            nodes_sv,
            lazy_info,
            result_sv,
            abstract_child_plan_table,
            &outcome
          )) {
        break;
      }
      return 0;
    default:
      if (gql_execution_complete_field_value_catching_error_xs_lazy_sync_native_outcome(
            aTHX_
            gql_ir_native_env_context(env),
            gql_ir_native_env_parent_type(env),
            field_def_sv,
            return_type_sv,
            nodes_sv,
            lazy_info,
            result_sv,
            &outcome
          )) {
        break;
      }
      return 0;
  }

    if (outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_DIRECT_VALUE) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_VALUE;
      frame->outcome_sv = outcome.value_sv;
      frame->outcome_errors_av = outcome.errors_av;
      gql_execution_sync_outcome_reset(&outcome);
      return 1;
    }
    if (outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_DIRECT_LIST_AV) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_LIST_AV;
      frame->outcome_sv = (SV *)outcome.list_av;
      frame->outcome_errors_av = outcome.errors_av;
      gql_execution_sync_outcome_reset(&outcome);
      return 1;
    }
    if (outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_DIRECT_OBJECT_HV) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_OBJECT_HV;
      frame->outcome_sv = (SV *)outcome.object_hv;
      frame->outcome_errors_av = outcome.errors_av;
      gql_execution_sync_outcome_reset(&outcome);
      return 1;
    }
    if (outcome.kind == GQL_EXECUTION_SYNC_OUTCOME_COMPLETED_SV) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_COMPLETED_SV;
      frame->outcome_sv = outcome.completed_sv;
      gql_execution_sync_outcome_reset(&outcome);
      return 1;
    }
  return 0;
}

static int
gql_ir_native_field_complete_generic_result(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  gql_ir_native_exec_env_t *env = state ? state->env : NULL;
  gql_ir_native_result_writer_t *writer = state ? state->writer : NULL;
  gql_ir_vm_exec_cursor_t *cursor = state ? &state->cursor : NULL;
  gql_ir_native_field_frame_t *frame = state ? &state->frame : NULL;
  gql_execution_lazy_resolve_info_t *lazy_info = frame ? &frame->lazy_info : NULL;
  SV *result_sv = frame ? frame->result_sv : NULL;
  gql_ir_vm_field_meta_t *meta = cursor ? cursor->meta : NULL;
  SV *nodes_sv = cursor ? cursor->nodes_sv : NULL;
  SV *return_type_sv = meta ? meta->return_type_sv : NULL;

  if (!return_type_sv || !SvOK(return_type_sv)) {
    return_type_sv = cursor ? cursor->type_sv : NULL;
  }
  if (!env || !cursor || !return_type_sv || !lazy_info || !frame) {
    return 0;
  }

  if (!gql_ir_native_env_promise_code(env) || !SvOK(gql_ir_native_env_promise_code(env))) {
    switch (meta ? meta->completion_dispatch_kind : GQL_IR_NATIVE_COMPLETION_GENERIC) {
      case GQL_IR_NATIVE_COMPLETION_ABSTRACT:
        if (gql_ir_try_complete_abstract_sync_into(
              aTHX_
              env,
              return_type_sv,
              nodes_sv,
              lazy_info,
              result_sv,
              frame,
              cursor ? cursor->entry : NULL
            )) {
          return 1;
        }
        break;
      case GQL_IR_NATIVE_COMPLETION_OBJECT:
        if (gql_ir_try_complete_sync_object_into_outcome(
              aTHX_
              env,
              cursor->entry,
              return_type_sv,
              lazy_info,
              result_sv,
              frame
            )) {
          return 1;
        }
        break;
      case GQL_IR_NATIVE_COMPLETION_LIST:
        if (gql_ir_try_complete_sync_list_into_outcome(
              aTHX_
              env,
              cursor->entry,
              return_type_sv,
              lazy_info,
              result_sv,
              frame
            )) {
          return 1;
        }
        break;
      default:
        break;
    }
  }

  return gql_ir_native_field_complete_generic_fallback_result(
    aTHX_ state
  );
}

static int
gql_ir_native_field_complete_object_result(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  gql_ir_native_exec_env_t *env = state ? state->env : NULL;
  gql_ir_native_result_writer_t *writer = state ? state->writer : NULL;
  gql_ir_vm_exec_cursor_t *cursor = state ? &state->cursor : NULL;
  gql_ir_native_field_frame_t *frame = state ? &state->frame : NULL;
  gql_execution_lazy_resolve_info_t *lazy_info = frame ? &frame->lazy_info : NULL;
  SV *result_sv = frame ? frame->result_sv : NULL;
  gql_ir_vm_field_meta_t *meta = cursor ? cursor->meta : NULL;
  SV *field_def_sv = cursor ? cursor->field_def_sv : NULL;
  SV *nodes_sv = cursor ? cursor->nodes_sv : NULL;
  SV *return_type_sv = meta ? meta->return_type_sv : NULL;

  if (!return_type_sv || !SvOK(return_type_sv)) {
    return_type_sv = cursor ? cursor->type_sv : NULL;
  }
  if (!env || !writer || !cursor || !field_def_sv || !nodes_sv || !return_type_sv || !lazy_info || !frame) {
    return 0;
  }

  return gql_ir_native_field_complete_family_fallback_result(
    aTHX_ state,
    GQL_IR_NATIVE_COMPLETION_OBJECT
  );
}

static int
gql_ir_native_field_complete_list_result(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  gql_ir_native_exec_env_t *env = state ? state->env : NULL;
  gql_ir_native_result_writer_t *writer = state ? state->writer : NULL;
  gql_ir_vm_exec_cursor_t *cursor = state ? &state->cursor : NULL;
  gql_ir_native_field_frame_t *frame = state ? &state->frame : NULL;
  gql_execution_lazy_resolve_info_t *lazy_info = frame ? &frame->lazy_info : NULL;
  SV *result_sv = frame ? frame->result_sv : NULL;
  gql_ir_vm_field_meta_t *meta = cursor ? cursor->meta : NULL;
  SV *field_def_sv = cursor ? cursor->field_def_sv : NULL;
  SV *nodes_sv = cursor ? cursor->nodes_sv : NULL;
  SV *return_type_sv = meta ? meta->return_type_sv : NULL;

  if (!return_type_sv || !SvOK(return_type_sv)) {
    return_type_sv = cursor ? cursor->type_sv : NULL;
  }
  if (!env || !writer || !cursor || !field_def_sv || !nodes_sv || !return_type_sv || !lazy_info || !frame) {
    return 0;
  }

  return gql_ir_native_field_complete_family_fallback_result(
    aTHX_ state,
    GQL_IR_NATIVE_COMPLETION_LIST
  );
}

static int
gql_ir_native_field_complete_abstract_result(
  pTHX_ gql_ir_vm_exec_state_t *state
) {
  gql_ir_native_exec_env_t *env = state ? state->env : NULL;
  gql_ir_native_result_writer_t *writer = state ? state->writer : NULL;
  gql_ir_vm_exec_cursor_t *cursor = state ? &state->cursor : NULL;
  gql_ir_native_field_frame_t *frame = state ? &state->frame : NULL;
  gql_execution_lazy_resolve_info_t *lazy_info = frame ? &frame->lazy_info : NULL;
  SV *result_sv = frame ? frame->result_sv : NULL;
  gql_ir_vm_field_meta_t *meta = cursor ? cursor->meta : NULL;
  SV *field_def_sv = cursor ? cursor->field_def_sv : NULL;
  SV *nodes_sv = cursor ? cursor->nodes_sv : NULL;
  SV *return_type_sv = meta ? meta->return_type_sv : NULL;

  if (!return_type_sv || !SvOK(return_type_sv)) {
    return_type_sv = cursor ? cursor->type_sv : NULL;
  }
  if (!env || !writer || !cursor || !field_def_sv || !nodes_sv || !return_type_sv || !lazy_info || !frame) {
    return 0;
  }

  return gql_ir_native_field_complete_family_fallback_result(
    aTHX_ state,
    GQL_IR_NATIVE_COMPLETION_ABSTRACT
  );
}

static int
gql_ir_native_field_consume_completed(
  pTHX_ gql_ir_native_exec_env_t *env,
  gql_ir_native_result_writer_t *writer,
  int *promise_present,
  gql_ir_vm_field_meta_t *meta,
  gql_ir_native_field_frame_t *frame
) {
  SV *completed_sv = NULL;
  int is_completed_promise = 0;

  if (!env || !writer || !promise_present || !frame || !meta) {
    return 0;
  }

  if (frame->outcome_kind == GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_VALUE) {
    AV *child_errors_av = frame->outcome_errors_av;
    if (!frame->outcome_sv) {
      return 0;
    }
    if (!gql_ir_native_result_writer_write_direct(
          aTHX_
          writer,
          meta->result_name_sv,
          frame->outcome_sv,
          child_errors_av
        )) {
      return 0;
    }
    frame->outcome_sv = NULL;
    if (child_errors_av) {
      SvREFCNT_dec((SV *)child_errors_av);
      frame->outcome_errors_av = NULL;
    }
    frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_NONE;
    return 1;
  }

  if (frame->outcome_kind == GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_OBJECT_HV) {
    SV *child_value_sv;
    AV *child_errors_av = frame->outcome_errors_av;

    if (!frame->outcome_sv) {
      return 0;
    }

    child_value_sv = newRV_noinc(frame->outcome_sv);
    frame->outcome_sv = NULL;
    if (!gql_ir_native_result_writer_write_direct(
          aTHX_
          writer,
          meta->result_name_sv,
          child_value_sv,
          child_errors_av
        )) {
      SvREFCNT_dec(child_value_sv);
      return 0;
    }
    if (child_errors_av) {
      SvREFCNT_dec((SV *)child_errors_av);
      frame->outcome_errors_av = NULL;
    }
    frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_NONE;
    return 1;
  }

  if (frame->outcome_kind == GQL_IR_NATIVE_FIELD_OUTCOME_DIRECT_LIST_AV) {
    SV *child_value_sv;
    AV *child_errors_av = frame->outcome_errors_av;

    if (!frame->outcome_sv) {
      return 0;
    }

    child_value_sv = newRV_noinc(frame->outcome_sv);
    frame->outcome_sv = NULL;
    if (!gql_ir_native_result_writer_write_direct(
          aTHX_
          writer,
          meta->result_name_sv,
          child_value_sv,
          child_errors_av
        )) {
      SvREFCNT_dec(child_value_sv);
      return 0;
    }
    if (child_errors_av) {
      SvREFCNT_dec((SV *)child_errors_av);
      frame->outcome_errors_av = NULL;
    }
    frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_NONE;
    return 1;
  }

  if (frame->outcome_kind != GQL_IR_NATIVE_FIELD_OUTCOME_COMPLETED_SV || !frame->outcome_sv) {
    return 0;
  }
  completed_sv = frame->outcome_sv;

  if (gql_ir_native_env_promise_code(env) && SvOK(gql_ir_native_env_promise_code(env)) && SvROK(completed_sv)) {
    SV *is_completed_promise_sv = gql_promise_call_is_promise(aTHX_ gql_ir_native_env_promise_code(env), completed_sv);
    is_completed_promise = SvTRUE(is_completed_promise_sv);
    SvREFCNT_dec(is_completed_promise_sv);
    if (is_completed_promise) {
      *promise_present = 1;
    }
  }

  if (SvROK(completed_sv) && (SvTYPE(SvRV(completed_sv)) == SVt_PVHV || is_completed_promise)) {
    if (!is_completed_promise && SvTYPE(SvRV(completed_sv)) == SVt_PVHV) {
      if (!gql_ir_native_result_writer_consume_completed(
            aTHX_
            writer,
            meta->result_name_sv,
            completed_sv
          )) {
        return 0;
      }
      SvREFCNT_dec(completed_sv);
      frame->outcome_sv = NULL;
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_NONE;
      return 1;
    }
    if (!gql_ir_native_result_writer_push_pending(
          aTHX_
          writer,
          meta->result_name_sv,
          completed_sv
        )) {
      return 0;
    }
    frame->outcome_sv = NULL;
    frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_NONE;
    return 1;
  }

  return 0;
}

static int
gql_ir_ensure_native_field_entry_operands(
  pTHX_ gql_ir_compiled_exec_t *compiled,
  gql_ir_compiled_root_field_plan_entry_t *entry
) {
  gql_ir_prepared_exec_t *prepared;
  SV *prepared_inner_sv;
  SV *result_name_sv;
  SV *field_name_sv;

  if (!compiled || !entry) {
    return 0;
  }

  result_name_sv = gql_ir_native_field_result_name(entry);
  field_name_sv = gql_ir_native_field_name(entry);

  if ((!entry->nodes_sv || !SvOK(entry->nodes_sv)) && result_name_sv && SvOK(result_name_sv)) {
    SV *nodes_sv;
    SV **first_node_svp;
    AV *nodes_av;

    if (!compiled->prepared_handle_sv
        || !SvROK(compiled->prepared_handle_sv)
        || !sv_derived_from(compiled->prepared_handle_sv, "GraphQL::Houtou::XS::PreparedIR")) {
      return 0;
    }
    prepared_inner_sv = SvRV(compiled->prepared_handle_sv);
    if (!SvIOK(prepared_inner_sv) || SvUV(prepared_inner_sv) == 0) {
      return 0;
    }
    prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(prepared_inner_sv));
    nodes_sv = gql_ir_prepare_executable_root_field_nodes_sv(
      aTHX_
      prepared,
      compiled->root_type_sv,
      compiled->operation_name_sv,
      result_name_sv
    );
    if (nodes_sv == &PL_sv_undef || !SvROK(nodes_sv) || SvTYPE(SvRV(nodes_sv)) != SVt_PVAV) {
      if (nodes_sv != &PL_sv_undef) {
        SvREFCNT_dec(nodes_sv);
      }
      return 0;
    }
    nodes_av = (AV *)SvRV(nodes_sv);
    first_node_svp = av_fetch(nodes_av, 0, 0);
    if (!first_node_svp || !SvROK(*first_node_svp) || SvTYPE(SvRV(*first_node_svp)) != SVt_PVHV) {
      SvREFCNT_dec(nodes_sv);
      return 0;
    }
    entry->nodes_sv = nodes_sv;
    entry->first_node_sv = gql_execution_share_or_copy_sv(*first_node_svp);
    entry->cold_inline.node_count = (UV)(av_len(nodes_av) + 1);
  }

  if ((!entry->field_def_sv || !SvOK(entry->field_def_sv))
      && field_name_sv && SvOK(field_name_sv)) {
    entry->field_def_sv = gql_execution_get_field_def(aTHX_ compiled->schema_sv, compiled->root_type_sv, field_name_sv);
  }

  if (!entry->field_def_sv || !SvOK(entry->field_def_sv)
      || !SvROK(entry->field_def_sv) || SvTYPE(SvRV(entry->field_def_sv)) != SVt_PVHV) {
    return 0;
  }

  if ((!entry->type_sv || !SvOK(entry->type_sv))) {
    SV **type_svp = hv_fetch((HV *)SvRV(entry->field_def_sv), "type", 4, 0);
    if (!type_svp || !SvOK(*type_svp)) {
      return 0;
    }
    entry->type_sv = gql_execution_share_or_copy_sv(*type_svp);
  }

  if (!entry->abstract_child_plan_table && entry->nodes_sv && entry->type_sv) {
    entry->abstract_child_plan_table = gql_ir_lower_single_node_abstract_child_plan_table(
      aTHX_ entry->type_sv,
      entry->nodes_sv
    );
  }

  entry->operands_ready = gql_ir_native_field_entry_has_operands(entry) ? 1 : 0;
  gql_ir_native_field_cold_refresh(entry);
  gql_ir_native_field_hot_refresh(entry);
  return entry->operands_ready;
}

static gql_ir_lowered_abstract_child_plan_table_t *
gql_ir_lower_single_node_abstract_child_plan_table(pTHX_ SV *return_type_sv, SV *nodes_sv) {
  AV *nodes_av;
  SV **node_svp;

  if (!return_type_sv
      || !SvOK(return_type_sv)
      || !(sv_does(return_type_sv, "GraphQL::Houtou::Role::Abstract")
           || sv_does(return_type_sv, "GraphQL::Role::Abstract"))
      || !nodes_sv
      || !SvROK(nodes_sv)
      || SvTYPE(SvRV(nodes_sv)) != SVt_PVAV) {
    return NULL;
  }

  nodes_av = (AV *)SvRV(nodes_sv);
  if (av_len(nodes_av) != 0) {
    return NULL;
  }

  node_svp = av_fetch(nodes_av, 0, 0);
  if (!node_svp || !SvROK(*node_svp) || SvTYPE(SvRV(*node_svp)) != SVt_PVHV) {
    return NULL;
  }

  return gql_ir_lowered_abstract_child_plan_table_from_concrete_table(
    aTHX_ gql_ir_get_concrete_field_plan_table(aTHX_ *node_svp)
  );
}

static gql_ir_compiled_root_field_plan_t *
gql_ir_lookup_native_concrete_child_plan(
  gql_ir_lowered_abstract_child_plan_table_t *table,
  SV *object_type
) {
  UV i;

  if (!table || !object_type) {
    return NULL;
  }

  for (i = 0; i < table->count; i++) {
    gql_ir_lowered_abstract_child_entry_t *entry = &table->entries[i];

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

static void
gql_ir_init_native_field_ops(gql_ir_compiled_root_field_plan_entry_t *entry) {
  gql_ir_vm_field_meta_t *meta;
  U8 op_count = 0;

  if (!entry) {
    return;
  }
  meta = gql_ir_native_field_meta(entry);
  if (!meta) {
    return;
  }

  if (meta->meta_dispatch_kind != GQL_IR_NATIVE_META_DISPATCH_NONE) {
    meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_META;
  }
  if (meta->resolve_dispatch_kind == GQL_IR_NATIVE_RESOLVE_DISPATCH_CONTEXT_OR_DEFAULT) {
    meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_TRIVIAL_CONTEXT;
  }
  if (meta->resolve_dispatch_kind == GQL_IR_NATIVE_RESOLVE_DISPATCH_FIXED) {
    if (meta->args_dispatch_kind == GQL_IR_NATIVE_ARGS_DISPATCH_BUILD) {
      meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_CALL_FIXED_BUILD_ARGS;
    } else {
      meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_CALL_FIXED_EMPTY_ARGS;
    }
  } else {
    if (meta->args_dispatch_kind == GQL_IR_NATIVE_ARGS_DISPATCH_BUILD) {
      meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_CALL_CONTEXT_BUILD_ARGS;
    } else {
      meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_CALL_CONTEXT_EMPTY_ARGS;
    }
  }
  if (meta->completion_dispatch_kind == GQL_IR_NATIVE_COMPLETION_TRIVIAL) {
    meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_COMPLETE_TRIVIAL;
  } else if (meta->completion_dispatch_kind == GQL_IR_NATIVE_COMPLETION_OBJECT) {
    meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_COMPLETE_OBJECT;
  } else if (meta->completion_dispatch_kind == GQL_IR_NATIVE_COMPLETION_LIST) {
    meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_COMPLETE_LIST;
  } else if (meta->completion_dispatch_kind == GQL_IR_NATIVE_COMPLETION_ABSTRACT) {
    meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_COMPLETE_ABSTRACT;
  } else {
    meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_COMPLETE_GENERIC;
  }
  meta->consume_op_index = op_count;
  meta->ops[op_count++] = GQL_IR_NATIVE_FIELD_OP_CONSUME;
  meta->op_count = op_count;
}

static void
gql_ir_init_native_field_frame(
  gql_ir_native_field_frame_t *frame,
  gql_ir_native_exec_env_t *env,
  gql_ir_vm_exec_cursor_t *cursor
) {
  gql_ir_vm_field_meta_t *meta = cursor ? cursor->meta : NULL;
  SV *field_def_sv = cursor ? cursor->field_def_sv : NULL;
  SV *return_type_sv = (meta && meta->return_type_sv)
    ? meta->return_type_sv
    : (cursor ? cursor->type_sv : NULL);
  SV *nodes_sv = cursor ? cursor->nodes_sv : NULL;

  if (!frame || !env || !cursor) {
    return;
  }

  Zero(frame, 1, gql_ir_native_field_frame_t);
  frame->meta = meta;
  frame->lazy_info.context_sv = gql_ir_native_env_context(env);
  frame->lazy_info.parent_type_sv = gql_ir_native_env_parent_type(env);
  frame->lazy_info.field_def_sv = field_def_sv;
  frame->lazy_info.return_type_sv = return_type_sv;
  frame->lazy_info.field_name_sv = meta ? meta->field_name_sv : NULL;
  frame->lazy_info.nodes_sv = nodes_sv;
  if (cursor->path_sv && SvOK(cursor->path_sv)) {
    frame->lazy_info.path_sv = cursor->path_sv;
  } else {
    frame->lazy_info.base_path_sv = gql_ir_native_env_base_path(env);
    frame->lazy_info.result_name_sv = meta ? meta->result_name_sv : NULL;
  }
}

static void
gql_ir_cleanup_native_field_frame(
  pTHX_ gql_ir_native_field_frame_t *frame,
  gql_ir_vm_exec_cursor_t *cursor
) {
  if (!frame || !cursor) {
    return;
  }

  if (frame->lazy_info.info_sv) {
    SvREFCNT_dec(frame->lazy_info.info_sv);
    frame->lazy_info.info_sv = NULL;
  }
  if (frame->owns_args_sv && frame->args_sv) {
    SvREFCNT_dec(frame->args_sv);
    frame->args_sv = NULL;
  }
  if (frame->result_sv) {
    SvREFCNT_dec(frame->result_sv);
    frame->result_sv = NULL;
  }
  if (frame->owns_resolve_sv && frame->resolve_sv) {
    SvREFCNT_dec(frame->resolve_sv);
    frame->resolve_sv = NULL;
  }
  if (frame->lazy_info.path_sv && (!cursor->path_sv || !SvOK(cursor->path_sv))) {
    SvREFCNT_dec(frame->lazy_info.path_sv);
    frame->lazy_info.path_sv = NULL;
  }
  if (frame->outcome_sv) {
    SvREFCNT_dec(frame->outcome_sv);
    frame->outcome_sv = NULL;
  }
  if (frame->outcome_errors_av) {
    SvREFCNT_dec((SV *)frame->outcome_errors_av);
    frame->outcome_errors_av = NULL;
  }
  frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_NONE;
}

static int
gql_ir_vm_exec_state_dispatch_current_field(
  gql_ir_vm_exec_state_t *state
) {
  gql_ir_native_field_frame_t *frame;
  gql_ir_compiled_root_field_plan_entry_t *entry;
  gql_ir_vm_field_meta_t *meta;
  gql_ir_vm_field_hot_t *hot;
  gql_ir_native_exec_env_t *env;
  gql_ir_native_result_writer_t *writer;
  int *promise_present;
  gql_ir_native_field_op_t op;

  /* Mirrors one field iteration of gql_execution_execute_field_plan(), but the
   * compiled-IR executor treats this as the VM-ready "execute one field op"
   * unit and consumes native plan metadata directly. */
  if (!state) {
    return 0;
  }

  env = state->env;
  writer = state->writer;
  promise_present = state->promise_present;
  entry = state->cursor.entry;
  meta = state->cursor.meta;
  hot = state->cursor.hot;
  frame = &state->frame;
  if (!env
      || !writer
      || !promise_present
      || !entry
      || !meta
      || meta->op_count == 0) {
    return 0;
  }

  if (!state->cursor.field_def_sv
      || !SvOK(state->cursor.field_def_sv)
      || !SvROK(state->cursor.field_def_sv)
      || SvTYPE(SvRV(state->cursor.field_def_sv)) != SVt_PVHV
      || !state->cursor.nodes_sv
      || !SvOK(state->cursor.nodes_sv)
      || !SvROK(state->cursor.nodes_sv)
      || SvTYPE(SvRV(state->cursor.nodes_sv)) != SVt_PVAV
      || !state->cursor.type_sv
      || !SvOK(state->cursor.type_sv)) {
    return 0;
  }

dispatch:
#if defined(__GNUC__) || defined(__clang__)
  {
    static void *dispatch_table[] = {
      &&op_meta,
      &&op_trivial_context,
      &&op_call_fixed_empty_args,
      &&op_call_fixed_build_args,
      &&op_call_context_empty_args,
      &&op_call_context_build_args,
      &&op_complete_trivial,
      &&op_complete_generic,
      &&op_complete_object,
      &&op_complete_list,
      &&op_complete_abstract,
      &&op_consume
    };
    if (state->cursor.pc >= meta->op_count) {
      goto op_done;
    }
    state->cursor.current_op = meta->ops[state->cursor.pc];
    op = state->cursor.current_op;
    goto *dispatch_table[op];
  }
#else
  if (state->cursor.pc >= meta->op_count) {
    goto op_done;
  }
  state->cursor.current_op = meta->ops[state->cursor.pc];
  op = state->cursor.current_op;
  switch (op) {
    case GQL_IR_NATIVE_FIELD_OP_META: goto op_meta;
    case GQL_IR_NATIVE_FIELD_OP_TRIVIAL_CONTEXT: goto op_trivial_context;
    case GQL_IR_NATIVE_FIELD_OP_CALL_FIXED_EMPTY_ARGS: goto op_call_fixed_empty_args;
    case GQL_IR_NATIVE_FIELD_OP_CALL_FIXED_BUILD_ARGS: goto op_call_fixed_build_args;
    case GQL_IR_NATIVE_FIELD_OP_CALL_CONTEXT_EMPTY_ARGS: goto op_call_context_empty_args;
    case GQL_IR_NATIVE_FIELD_OP_CALL_CONTEXT_BUILD_ARGS: goto op_call_context_build_args;
    case GQL_IR_NATIVE_FIELD_OP_COMPLETE_TRIVIAL: goto op_complete_trivial;
    case GQL_IR_NATIVE_FIELD_OP_COMPLETE_GENERIC: goto op_complete_generic;
    case GQL_IR_NATIVE_FIELD_OP_COMPLETE_OBJECT: goto op_complete_object;
    case GQL_IR_NATIVE_FIELD_OP_COMPLETE_LIST: goto op_complete_list;
    case GQL_IR_NATIVE_FIELD_OP_COMPLETE_ABSTRACT: goto op_complete_abstract;
    case GQL_IR_NATIVE_FIELD_OP_CONSUME: goto op_consume;
    default:
      goto op_fail;
  }
#endif

op_meta:
  if (gql_ir_vm_exec_state_try_meta_dispatch(
        aTHX_ state
      )) {
    if (frame->outcome_kind != GQL_IR_NATIVE_FIELD_OUTCOME_NONE) {
      state->cursor.pc = meta->consume_op_index;
      goto dispatch;
    }
    goto op_done;
  }
  state->cursor.pc++;
  goto dispatch;

op_trivial_context:
  if (!frame->resolve_sv) {
    frame->resolve_sv = gql_ir_native_field_get_resolver(aTHX_ env, meta, state->cursor.resolve_sv, &frame->owns_resolve_sv);
    frame->resolve_is_default = gql_execution_is_default_field_resolver(aTHX_ frame->resolve_sv);
  }
  if (gql_ir_native_field_try_trivial_completion(
        aTHX_
        env,
        meta,
        frame,
        state->cursor.type_sv,
        frame->resolve_is_default,
        &frame->result_sv
      )) {
    if (frame->outcome_kind != GQL_IR_NATIVE_FIELD_OUTCOME_NONE) {
      state->cursor.pc = meta->consume_op_index;
      goto dispatch;
    }
    goto op_done;
  }

  if (frame->resolve_is_default
      && gql_execution_try_default_field_resolve_fast(aTHX_ gql_ir_native_env_root_value(env), meta->field_name_sv, &frame->result_sv)) {
    frame->used_fast_default_resolve = 1;
    if (gql_ir_native_field_try_trivial_completion(
          aTHX_
          env,
          meta,
          frame,
          state->cursor.type_sv,
          0,
          &frame->result_sv
        )) {
      if (frame->outcome_kind != GQL_IR_NATIVE_FIELD_OUTCOME_NONE) {
        state->cursor.pc = meta->consume_op_index;
        goto dispatch;
      }
      goto op_done;
    }
    if (meta->completion_dispatch_kind == GQL_IR_NATIVE_COMPLETION_GENERIC
        && gql_execution_try_complete_trivial_value_fast(aTHX_ state->cursor.type_sv, frame->result_sv, &frame->outcome_sv)) {
      frame->outcome_kind = GQL_IR_NATIVE_FIELD_OUTCOME_COMPLETED_SV;
      (void)gql_ir_native_field_normalize_sync_completed_outcome(aTHX_ frame);
      state->cursor.pc = meta->consume_op_index;
      goto dispatch;
    }
  }

  state->cursor.pc++;
  goto dispatch;

op_call_fixed_empty_args:
  if (!gql_ir_vm_exec_state_call_current_resolver(
        aTHX_
        state,
        GQL_IR_NATIVE_FIELD_OP_CALL_FIXED_EMPTY_ARGS
      )) {
    goto op_fail;
  }
  state->cursor.pc++;
  goto dispatch;

op_call_fixed_build_args:
  if (!gql_ir_vm_exec_state_call_current_resolver(
        aTHX_
        state,
        GQL_IR_NATIVE_FIELD_OP_CALL_FIXED_BUILD_ARGS
      )) {
    goto op_fail;
  }
  state->cursor.pc++;
  goto dispatch;

op_call_context_empty_args:
  if (!frame->used_fast_default_resolve
      && !gql_ir_vm_exec_state_call_current_resolver(
           aTHX_
           state,
           GQL_IR_NATIVE_FIELD_OP_CALL_CONTEXT_EMPTY_ARGS
         )) {
    goto op_fail;
  }
  state->cursor.pc++;
  goto dispatch;

op_call_context_build_args:
  if (!frame->used_fast_default_resolve
      && !gql_ir_vm_exec_state_call_current_resolver(
           aTHX_
           state,
           GQL_IR_NATIVE_FIELD_OP_CALL_CONTEXT_BUILD_ARGS
         )) {
    goto op_fail;
  }
  state->cursor.pc++;
  goto dispatch;

op_complete_trivial:
  if (!gql_ir_native_field_complete_trivial_result(
        aTHX_
        env,
        meta,
        frame,
        frame->result_sv
      )) {
    goto op_fail;
  }
  if (frame->outcome_kind == GQL_IR_NATIVE_FIELD_OUTCOME_NONE) {
    goto op_done;
  }
  state->cursor.pc++;
  goto dispatch;

op_complete_generic:
  if (!gql_ir_vm_exec_state_complete_current_field(
        aTHX_
        state,
        GQL_IR_NATIVE_FIELD_OP_COMPLETE_GENERIC
      )) {
    goto op_fail;
  }
  if (frame->outcome_kind == GQL_IR_NATIVE_FIELD_OUTCOME_NONE) {
    goto op_done;
  }
  state->cursor.pc++;
  goto dispatch;

op_complete_object:
  if (!gql_ir_vm_exec_state_complete_current_field(
        aTHX_
        state,
        GQL_IR_NATIVE_FIELD_OP_COMPLETE_OBJECT
      )) {
    goto op_fail;
  }
  if (frame->outcome_kind == GQL_IR_NATIVE_FIELD_OUTCOME_NONE) {
    goto op_done;
  }
  state->cursor.pc++;
  goto dispatch;

op_complete_list:
  if (!gql_ir_vm_exec_state_complete_current_field(
        aTHX_
        state,
        GQL_IR_NATIVE_FIELD_OP_COMPLETE_LIST
      )) {
    goto op_fail;
  }
  if (frame->outcome_kind == GQL_IR_NATIVE_FIELD_OUTCOME_NONE) {
    goto op_done;
  }
  state->cursor.pc++;
  goto dispatch;

op_complete_abstract:
  if (!gql_ir_vm_exec_state_complete_current_field(
        aTHX_
        state,
        GQL_IR_NATIVE_FIELD_OP_COMPLETE_ABSTRACT
      )) {
    goto op_fail;
  }
  if (frame->outcome_kind == GQL_IR_NATIVE_FIELD_OUTCOME_NONE) {
    goto op_done;
  }
  state->cursor.pc++;
  goto dispatch;

op_consume:
  if (!gql_ir_vm_exec_state_consume_current_field(
        aTHX_ state
      )) {
    goto op_fail;
  }
  state->cursor.pc++;
  goto dispatch;

op_done:
  return 1;

op_fail:
  return 0;
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
    compiled->lowered_plan = gql_ir_execution_lowered_plan_from_root_field_plan_sv(aTHX_ root_field_plan_sv);
    if (!compiled->lowered_plan) {
      compiled->root_field_plan_sv = root_field_plan_sv;
      root_field_plan_sv = NULL;
    } else {
      gql_ir_compiled_root_field_plan_t *root_field_plan = gql_ir_execution_lowered_root_field_plan(compiled);
      UV field_i;
      gql_ir_attach_exact_object_child_native_plans(aTHX_ schema, root_field_plan);
      for (field_i = 0; field_i < root_field_plan->field_count; field_i++) {
        gql_ir_compiled_root_field_plan_entry_t *entry = &root_field_plan->entries[field_i];
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

      if (entry->meta) {
        gql_ir_vm_field_meta_destroy(entry->meta);
        entry->meta = NULL;
      }
      if (entry->field_def_sv) {
        SvREFCNT_dec(entry->field_def_sv);
        entry->field_def_sv = NULL;
      }
      if (entry->type_sv) {
        SvREFCNT_dec(entry->type_sv);
        entry->type_sv = NULL;
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
      if (entry->cold && entry->cold->path_sv) {
        SvREFCNT_dec(entry->cold->path_sv);
        entry->cold->path_sv = NULL;
      }
      if (entry->abstract_child_plan_table) {
        gql_ir_lowered_abstract_child_plan_table_destroy(entry->abstract_child_plan_table);
        entry->abstract_child_plan_table = NULL;
      }
      if (entry->list_item_abstract_child_plan_table) {
        gql_ir_lowered_abstract_child_plan_table_destroy(entry->list_item_abstract_child_plan_table);
        entry->list_item_abstract_child_plan_table = NULL;
      }
      if (entry->native_field_plan) {
        gql_ir_compiled_root_field_plan_destroy(entry->native_field_plan);
        entry->native_field_plan = NULL;
      }
      if (entry->native_block) {
        gql_ir_vm_block_destroy(entry->native_block);
        entry->native_block = NULL;
      }
    }
    Safefree(plan->entries);
    plan->entries = NULL;
  }

  if (plan->fallback_subfields_sv) {
    SvREFCNT_dec(plan->fallback_subfields_sv);
    plan->fallback_subfields_sv = NULL;
  }

  Safefree(plan);
}

static gql_ir_vm_field_meta_t *
gql_ir_vm_field_meta_from_seed(
  pTHX_ gql_ir_compiled_root_field_plan_entry_t *entry,
  const gql_ir_vm_field_meta_t *seed
) {
  gql_ir_vm_field_meta_t *meta;

  if (!entry || !seed) {
    return NULL;
  }

  meta = &entry->meta_inline;
  Zero(meta, 1, gql_ir_vm_field_meta_t);

  if (seed->result_name_sv) meta->result_name_sv = gql_execution_share_or_copy_sv(seed->result_name_sv);
  if (seed->field_name_sv) meta->field_name_sv = gql_execution_share_or_copy_sv(seed->field_name_sv);
  if (seed->return_type_sv) meta->return_type_sv = gql_execution_share_or_copy_sv(seed->return_type_sv);
  if (seed->completion_type_sv) meta->completion_type_sv = gql_execution_share_or_copy_sv(seed->completion_type_sv);
  if (seed->list_item_type_sv) meta->list_item_type_sv = gql_execution_share_or_copy_sv(seed->list_item_type_sv);
  meta->argument_count = seed->argument_count;
  meta->field_arg_count = seed->field_arg_count;
  meta->directive_count = seed->directive_count;
  meta->selection_count = seed->selection_count;
  meta->trivial_completion_flags = seed->trivial_completion_flags;
  meta->op_count = seed->op_count;
  meta->consume_op_index = seed->consume_op_index;
  Copy(seed->ops, meta->ops, 5, gql_ir_native_field_op_t);
  meta->meta_dispatch_kind = seed->meta_dispatch_kind;
  meta->resolve_dispatch_kind = seed->resolve_dispatch_kind;
  meta->args_dispatch_kind = seed->args_dispatch_kind;
  meta->completion_dispatch_kind = seed->completion_dispatch_kind;
  entry->meta = meta;

  return meta;
}

static void
gql_ir_vm_field_meta_destroy(gql_ir_vm_field_meta_t *meta) {
  if (!meta) {
    return;
  }
  if (meta->result_name_sv) SvREFCNT_dec(meta->result_name_sv);
  if (meta->field_name_sv) SvREFCNT_dec(meta->field_name_sv);
  if (meta->return_type_sv) SvREFCNT_dec(meta->return_type_sv);
  if (meta->completion_type_sv) SvREFCNT_dec(meta->completion_type_sv);
  if (meta->list_item_type_sv) SvREFCNT_dec(meta->list_item_type_sv);
  Zero(meta, 1, gql_ir_vm_field_meta_t);
}

static gql_ir_execution_lowered_plan_t *
gql_ir_execution_lowered_plan_from_root_field_plan_sv(pTHX_ SV *root_field_plan_sv) {
  gql_ir_execution_lowered_plan_t *plan;

  Newxz(plan, 1, gql_ir_execution_lowered_plan_t);
  plan->program = gql_ir_vm_program_from_root_field_plan_sv(aTHX_ root_field_plan_sv);
  if (!plan->program) {
    Safefree(plan);
    return NULL;
  }

  return plan;
}

static void
gql_ir_execution_lowered_plan_destroy(gql_ir_execution_lowered_plan_t *plan) {
  if (!plan) {
    return;
  }

  if (plan->program) {
    gql_ir_vm_program_destroy(plan->program);
    plan->program = NULL;
  }

  Safefree(plan);
}

static gql_ir_vm_program_t *
gql_ir_vm_program_from_root_field_plan_sv(pTHX_ SV *root_field_plan_sv) {
  gql_ir_compiled_root_field_plan_t *root_field_plan;
  gql_ir_vm_program_t *program;
  gql_ir_vm_block_t *root_block;

  root_field_plan = gql_ir_compiled_root_field_plan_from_sv(aTHX_ root_field_plan_sv);
  if (!root_field_plan) {
    return NULL;
  }

  Newxz(program, 1, gql_ir_vm_program_t);
  root_block = gql_ir_vm_block_new(root_field_plan, 1);
  if (!root_block) {
    Safefree(program);
    gql_ir_compiled_root_field_plan_destroy(root_field_plan);
    return NULL;
  }
  program->stage = GQL_IR_COMPILATION_STAGE_LOWERED_NATIVE_FIELDS;
  program->root_block = root_block;
  return program;
}

static void
gql_ir_vm_program_destroy(gql_ir_vm_program_t *program) {
  if (!program) {
    return;
  }

  if (program->root_block) {
    gql_ir_vm_block_destroy(program->root_block);
    program->root_block = NULL;
  }

  Safefree(program);
}

static gql_ir_compiled_root_field_plan_t *
gql_ir_compiled_root_field_plan_clone(pTHX_ gql_ir_compiled_root_field_plan_t *plan) {
  gql_ir_compiled_root_field_plan_t *clone;
  UV i;

  if (!plan) {
    return NULL;
  }

  Newxz(clone, 1, gql_ir_compiled_root_field_plan_t);
  clone->field_count = plan->field_count;
  clone->requires_runtime_operand_fill = plan->requires_runtime_operand_fill;
  clone->fallback_subfields_sv = NULL;
  if (clone->field_count > 0) {
    Newxz(clone->entries, clone->field_count, gql_ir_compiled_root_field_plan_entry_t);
  }

  for (i = 0; i < clone->field_count; i++) {
    gql_ir_compiled_root_field_plan_entry_t *dst = &clone->entries[i];
    gql_ir_compiled_root_field_plan_entry_t *src = &plan->entries[i];

    if (src->field_def_sv) dst->field_def_sv = gql_execution_share_or_copy_sv(src->field_def_sv);
    if (src->type_sv) dst->type_sv = gql_execution_share_or_copy_sv(src->type_sv);
    if (src->resolve_sv) dst->resolve_sv = gql_execution_share_or_copy_sv(src->resolve_sv);
    if (src->nodes_sv) dst->nodes_sv = gql_execution_share_or_copy_sv(src->nodes_sv);
    if (src->first_node_sv) dst->first_node_sv = gql_execution_share_or_copy_sv(src->first_node_sv);
    if (src->cold && src->cold->path_sv) {
      dst->cold_inline.path_sv = gql_execution_share_or_copy_sv(src->cold->path_sv);
    }
    if (src->cold) {
      dst->cold_inline.node_count = src->cold->node_count;
    }
    dst->operands_ready = src->operands_ready;
    gql_ir_native_field_cold_refresh(dst);
    dst->meta = gql_ir_vm_field_meta_from_seed(aTHX_ dst, src->meta);
    if (src->native_field_plan) {
      dst->native_field_plan = gql_ir_compiled_root_field_plan_clone(aTHX_ src->native_field_plan);
    }
    if (src->native_block) {
      dst->native_block = gql_ir_vm_block_clone(aTHX_ src->native_block);
    } else if (dst->native_field_plan) {
      dst->native_block = gql_ir_vm_block_new(dst->native_field_plan, 0);
    }
    dst->abstract_child_plan_table = gql_ir_lowered_abstract_child_plan_table_clone(
      aTHX_ src->abstract_child_plan_table
    );
    dst->list_item_abstract_child_plan_table = gql_ir_lowered_abstract_child_plan_table_clone(
      aTHX_ src->list_item_abstract_child_plan_table
    );
    gql_ir_native_field_hot_refresh(dst);
  }

  return clone;
}

static gql_ir_lowered_abstract_child_plan_table_t *
gql_ir_lowered_abstract_child_plan_table_clone(
  pTHX_ gql_ir_lowered_abstract_child_plan_table_t *table
) {
  gql_ir_lowered_abstract_child_plan_table_t *clone = NULL;
  UV i;

  if (!table || table->count == 0) {
    return NULL;
  }

  Newxz(clone, 1, gql_ir_lowered_abstract_child_plan_table_t);
  clone->count = table->count;
  Newxz(clone->entries, clone->count, gql_ir_lowered_abstract_child_entry_t);

  for (i = 0; i < clone->count; i++) {
    gql_ir_lowered_abstract_child_entry_t *dst = &clone->entries[i];
    gql_ir_lowered_abstract_child_entry_t *src = &table->entries[i];

    if (src->possible_type_sv) {
      dst->possible_type_sv = gql_execution_share_or_copy_sv(src->possible_type_sv);
    }
    if (src->possible_type_name_sv) {
      dst->possible_type_name_sv = gql_execution_share_or_copy_sv(src->possible_type_name_sv);
    }
    if (src->native_field_plan) {
      dst->native_field_plan = gql_ir_compiled_root_field_plan_clone(aTHX_ src->native_field_plan);
    }
    if (src->native_block) {
      dst->native_block = gql_ir_vm_block_clone(aTHX_ src->native_block);
    } else if (dst->native_field_plan) {
      dst->native_block = gql_ir_vm_block_new(dst->native_field_plan, 0);
    }
  }

  return clone;
}

static gql_ir_lowered_abstract_child_plan_table_t *
gql_ir_lowered_abstract_child_plan_table_from_concrete_table(
  pTHX_ gql_ir_compiled_concrete_plan_table_t *table
) {
  gql_ir_lowered_abstract_child_plan_table_t *lowered = NULL;
  UV i;
  UV count = 0;

  if (!table) {
    return NULL;
  }

  for (i = 0; i < table->count; i++) {
    gql_ir_compiled_concrete_plan_entry_t *entry = &table->entries[i];
    if (entry->possible_type_sv && entry->native_field_plan) {
      count++;
    }
  }

  if (count == 0) {
    return NULL;
  }

  Newxz(lowered, 1, gql_ir_lowered_abstract_child_plan_table_t);
  lowered->count = count;
  Newxz(lowered->entries, count, gql_ir_lowered_abstract_child_entry_t);

  count = 0;
  for (i = 0; i < table->count; i++) {
    gql_ir_compiled_concrete_plan_entry_t *entry = &table->entries[i];
    gql_ir_lowered_abstract_child_entry_t *dst;

    if (!entry->possible_type_sv || !entry->native_field_plan) {
      continue;
    }

    dst = &lowered->entries[count++];
    dst->possible_type_sv = gql_execution_share_or_copy_sv(entry->possible_type_sv);
    dst->possible_type_name_sv = gql_execution_type_name_sv(aTHX_ entry->possible_type_sv);
    dst->native_field_plan = gql_ir_compiled_root_field_plan_clone(aTHX_ entry->native_field_plan);
    if (dst->native_field_plan) {
      dst->native_block = gql_ir_vm_block_new(dst->native_field_plan, 0);
    }
  }

  return lowered;
}

static void
gql_ir_lowered_abstract_child_plan_table_destroy(gql_ir_lowered_abstract_child_plan_table_t *table) {
  UV i;

  if (!table) {
    return;
  }

  if (table->entries) {
    for (i = 0; i < table->count; i++) {
      gql_ir_lowered_abstract_child_entry_t *entry = &table->entries[i];
      if (entry->possible_type_sv) {
        SvREFCNT_dec(entry->possible_type_sv);
        entry->possible_type_sv = NULL;
      }
      if (entry->possible_type_name_sv) {
        SvREFCNT_dec(entry->possible_type_name_sv);
        entry->possible_type_name_sv = NULL;
      }
      if (entry->native_field_plan) {
        gql_ir_compiled_root_field_plan_destroy(entry->native_field_plan);
        entry->native_field_plan = NULL;
      }
      if (entry->native_block) {
        gql_ir_vm_block_destroy(entry->native_block);
        entry->native_block = NULL;
      }
    }
    Safefree(table->entries);
    table->entries = NULL;
  }

  Safefree(table);
}

static void
gql_ir_attach_exact_object_child_native_plans(
  pTHX_ SV *schema,
  gql_ir_compiled_root_field_plan_t *plan
) {
  UV i;

  if (!schema || !SvOK(schema) || !plan || !plan->entries) {
    return;
  }

  for (i = 0; i < plan->field_count; i++) {
    gql_ir_compiled_root_field_plan_entry_t *entry = &plan->entries[i];
    gql_ir_vm_field_meta_t *meta = gql_ir_native_field_meta(entry);
    SV *compiled_fields_sv = NULL;
    SV *compiled_plan_sv = NULL;
    SV *plan_type_sv = NULL;
    SV *list_item_type_sv = NULL;
    int ok = 0;

    if (entry->native_field_plan) {
      gql_ir_attach_exact_object_child_native_plans(aTHX_ schema, entry->native_field_plan);
      continue;
    }

    if (!meta
        || !entry->type_sv
        || !SvOK(entry->type_sv)
        || !entry->nodes_sv
        || !SvOK(entry->nodes_sv)) {
      goto recurse_abstract_children;
    }

    plan_type_sv = entry->type_sv;
    if (meta->completion_dispatch_kind == GQL_IR_NATIVE_COMPLETION_LIST) {
      list_item_type_sv = (meta->list_item_type_sv && SvOK(meta->list_item_type_sv))
        ? gql_execution_share_or_copy_sv(meta->list_item_type_sv)
        : gql_execution_call_type_of(aTHX_ entry->type_sv);
      if (list_item_type_sv
          && SvOK(list_item_type_sv)
          && SvROK(list_item_type_sv)
          && (sv_derived_from(list_item_type_sv, "GraphQL::Houtou::Type::Object")
              || sv_derived_from(list_item_type_sv, "GraphQL::Type::Object"))) {
        plan_type_sv = list_item_type_sv;
      } else if (list_item_type_sv
                 && SvOK(list_item_type_sv)
                 && (sv_does(list_item_type_sv, "GraphQL::Houtou::Role::Abstract")
                     || sv_does(list_item_type_sv, "GraphQL::Role::Abstract"))) {
        if (!entry->list_item_abstract_child_plan_table) {
          entry->list_item_abstract_child_plan_table = gql_ir_lower_single_node_abstract_child_plan_table(
            aTHX_ list_item_type_sv,
            entry->nodes_sv
          );
          gql_ir_native_field_hot_refresh(entry);
        }
        goto recurse_abstract_children;
      } else {
        goto recurse_abstract_children;
      }
    } else if (meta->completion_dispatch_kind != GQL_IR_NATIVE_COMPLETION_OBJECT) {
      goto recurse_abstract_children;
    }

    compiled_fields_sv = gql_execution_collect_concrete_compiled_object_fields(
      aTHX_ plan_type_sv,
      entry->nodes_sv,
      &ok
    );
    if (!ok || compiled_fields_sv == &PL_sv_undef || !SvOK(compiled_fields_sv)) {
      goto recurse_abstract_children;
    }

    compiled_plan_sv = gql_execution_build_field_plan_from_compiled_fields(
      aTHX_
      schema,
      plan_type_sv,
      compiled_fields_sv
    );
    if (compiled_plan_sv != &PL_sv_undef && SvOK(compiled_plan_sv)) {
      gql_ir_compiled_root_field_plan_t *native_field_plan
        = gql_ir_compiled_root_field_plan_from_sv(aTHX_ compiled_plan_sv);
      if (native_field_plan) {
        entry->native_field_plan = native_field_plan;
        entry->native_block = gql_ir_vm_block_new(entry->native_field_plan, 0);
        gql_ir_native_field_hot_refresh(entry);
        gql_ir_attach_exact_object_child_native_plans(aTHX_ schema, entry->native_field_plan);
      }
    }

recurse_abstract_children:
    if (list_item_type_sv && list_item_type_sv != &PL_sv_undef) {
      SvREFCNT_dec(list_item_type_sv);
    }
    if (compiled_plan_sv && compiled_plan_sv != &PL_sv_undef) {
      SvREFCNT_dec(compiled_plan_sv);
    }
    if (compiled_fields_sv && compiled_fields_sv != &PL_sv_undef) {
      SvREFCNT_dec(compiled_fields_sv);
    }
    if (entry->abstract_child_plan_table && entry->abstract_child_plan_table->entries) {
      UV table_i;
      for (table_i = 0; table_i < entry->abstract_child_plan_table->count; table_i++) {
        gql_ir_lowered_abstract_child_entry_t *child_entry = &entry->abstract_child_plan_table->entries[table_i];
        if (child_entry->native_field_plan) {
          gql_ir_attach_exact_object_child_native_plans(aTHX_ schema, child_entry->native_field_plan);
        }
      }
    }
    if (entry->list_item_abstract_child_plan_table && entry->list_item_abstract_child_plan_table->entries) {
      UV table_i;
      for (table_i = 0; table_i < entry->list_item_abstract_child_plan_table->count; table_i++) {
        gql_ir_lowered_abstract_child_entry_t *child_entry = &entry->list_item_abstract_child_plan_table->entries[table_i];
        if (child_entry->native_field_plan) {
          gql_ir_attach_exact_object_child_native_plans(aTHX_ schema, child_entry->native_field_plan);
        }
      }
    }
  }
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
      if (entry->native_block) {
        gql_ir_vm_block_destroy(entry->native_block);
        entry->native_block = NULL;
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
  plan->requires_runtime_operand_fill = 0;
  if (field_count > 0) {
    Newxz(plan->entries, field_count, gql_ir_compiled_root_field_plan_entry_t);
  }

  for (field_i = 0; field_i < field_count; field_i++) {
    SV **result_name_svp = av_fetch(field_order_av, (I32)field_i, 0);
    HE *field_plan_he;
    HV *field_plan_hv;
    HV *field_def_hv;
    gql_ir_compiled_root_field_plan_entry_t *entry = &plan->entries[field_i];
    gql_ir_vm_field_meta_t meta_seed;
    SV **field_name_svp;
    SV **field_def_svp;
    SV **type_svp;
    SV **resolve_svp;
    SV **field_args_svp;
    SV *completion_type_sv = NULL;
    SV *meta_completion_type_sv = NULL;
    UV trivial_completion_flags = 0;
    gql_ir_native_meta_dispatch_kind_t meta_dispatch_kind = GQL_IR_NATIVE_META_DISPATCH_NONE;
    gql_ir_native_resolve_dispatch_kind_t resolve_dispatch_kind = GQL_IR_NATIVE_RESOLVE_DISPATCH_CONTEXT_OR_DEFAULT;
    gql_ir_native_args_dispatch_kind_t args_dispatch_kind;
    gql_ir_native_completion_dispatch_kind_t completion_dispatch_kind = GQL_IR_NATIVE_COMPLETION_GENERIC;
    SV **nodes_svp;
    AV *nodes_av;
    SV **first_node_svp;
    SV **node_count_svp;
    SV **argument_count_svp;
    SV **directive_count_svp;
    SV **selection_count_svp;
    const char *field_name_pv;
    STRLEN field_name_len;
    UV argument_count;
    UV field_arg_count;
    UV directive_count;
    UV selection_count;

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

    args_dispatch_kind =
      ((argument_count_svp && SvOK(*argument_count_svp)) ? SvUV(*argument_count_svp) : 0) == 0
      && ((field_args_svp
           && SvROK(*field_args_svp)
           && SvTYPE(SvRV(*field_args_svp)) == SVt_PVHV)
            ? (UV)HvUSEDKEYS((HV *)SvRV(*field_args_svp))
            : 0) == 0
        ? GQL_IR_NATIVE_ARGS_DISPATCH_EMPTY
        : GQL_IR_NATIVE_ARGS_DISPATCH_BUILD;
    field_name_pv = SvPV(*field_name_svp, field_name_len);
    if (field_name_len == 10 && memEQ(field_name_pv, "__typename", 10)) {
      meta_dispatch_kind = GQL_IR_NATIVE_META_DISPATCH_TYPENAME;
    }
    argument_count = (argument_count_svp && SvOK(*argument_count_svp)) ? SvUV(*argument_count_svp) : 0;
    field_arg_count =
      (field_args_svp
       && SvROK(*field_args_svp)
       && SvTYPE(SvRV(*field_args_svp)) == SVt_PVHV)
        ? (UV)HvUSEDKEYS((HV *)SvRV(*field_args_svp))
        : 0;
    directive_count = (directive_count_svp && SvOK(*directive_count_svp)) ? SvUV(*directive_count_svp) : 0;
    selection_count = (selection_count_svp && SvOK(*selection_count_svp)) ? SvUV(*selection_count_svp) : 0;
    entry->field_def_sv = gql_execution_share_or_copy_sv(*field_def_svp);
    if (type_svp && SvOK(*type_svp)) {
      entry->type_sv = gql_execution_share_or_copy_sv(*type_svp);
      if (gql_execution_get_trivial_completion_metadata(aTHX_ *type_svp, &completion_type_sv, &trivial_completion_flags)) {
        meta_completion_type_sv = completion_type_sv;
        completion_dispatch_kind = GQL_IR_NATIVE_COMPLETION_TRIVIAL;
        completion_type_sv = NULL;
      }
    }
    if (resolve_svp && SvOK(*resolve_svp)) {
      entry->resolve_sv = gql_execution_share_or_copy_sv(*resolve_svp);
      resolve_dispatch_kind = GQL_IR_NATIVE_RESOLVE_DISPATCH_FIXED;
    }
    entry->nodes_sv = gql_execution_share_or_copy_sv(*nodes_svp);
    entry->first_node_sv = gql_execution_share_or_copy_sv(*first_node_svp);
    entry->cold_inline.node_count = (node_count_svp && SvOK(*node_count_svp)) ? SvUV(*node_count_svp) : 0;
    entry->abstract_child_plan_table = gql_ir_lower_single_node_abstract_child_plan_table(
      aTHX_ entry->type_sv,
      entry->nodes_sv
    );
    if (completion_dispatch_kind == GQL_IR_NATIVE_COMPLETION_LIST
        && entry->type_sv
        && SvOK(entry->type_sv)) {
      SV *list_item_type_sv = gql_execution_call_type_of(aTHX_ entry->type_sv);
      if (list_item_type_sv && SvOK(list_item_type_sv)) {
        meta_seed.list_item_type_sv = list_item_type_sv;
        if (sv_does(list_item_type_sv, "GraphQL::Houtou::Role::Abstract")
            || sv_does(list_item_type_sv, "GraphQL::Role::Abstract")) {
          entry->list_item_abstract_child_plan_table = gql_ir_lower_single_node_abstract_child_plan_table(
            aTHX_ list_item_type_sv,
            entry->nodes_sv
          );
        }
      }
    }
    if (type_svp
        && SvOK(*type_svp)
        && SvROK(*type_svp)
        && (sv_derived_from(*type_svp, "GraphQL::Houtou::Type::Object")
            || sv_derived_from(*type_svp, "GraphQL::Type::Object"))) {
      entry->native_field_plan = gql_execution_collect_single_node_concrete_native_field_plan(
        aTHX_ *type_svp,
        entry->nodes_sv
      );
      if (entry->native_field_plan) {
        entry->native_block = gql_ir_vm_block_new(entry->native_field_plan, 0);
      }
    }
    if (completion_dispatch_kind == GQL_IR_NATIVE_COMPLETION_GENERIC
        && type_svp && SvOK(*type_svp)) {
      if (SvROK(*type_svp)
          && (sv_derived_from(*type_svp, "GraphQL::Houtou::Type::Object")
              || sv_derived_from(*type_svp, "GraphQL::Type::Object"))) {
        completion_dispatch_kind = GQL_IR_NATIVE_COMPLETION_OBJECT;
      } else if (sv_derived_from(*type_svp, "GraphQL::Houtou::Type::List")
                 || sv_derived_from(*type_svp, "GraphQL::Type::List")) {
        completion_dispatch_kind = GQL_IR_NATIVE_COMPLETION_LIST;
      } else if (sv_does(*type_svp, "GraphQL::Houtou::Role::Abstract")
                 || sv_does(*type_svp, "GraphQL::Role::Abstract")) {
        completion_dispatch_kind = GQL_IR_NATIVE_COMPLETION_ABSTRACT;
      }
    }
    entry->operands_ready = gql_ir_native_field_entry_has_operands(entry) ? 1 : 0;
    if (!entry->operands_ready) {
      plan->requires_runtime_operand_fill = 1;
    }
    gql_ir_native_field_cold_refresh(entry);
    Zero(&meta_seed, 1, gql_ir_vm_field_meta_t);
    meta_seed.result_name_sv = *result_name_svp;
    meta_seed.field_name_sv = *field_name_svp;
    meta_seed.return_type_sv = (type_svp && SvOK(*type_svp)) ? *type_svp : NULL;
    meta_seed.completion_type_sv = meta_completion_type_sv;
    meta_seed.argument_count = argument_count;
    meta_seed.field_arg_count = field_arg_count;
    meta_seed.directive_count = directive_count;
    meta_seed.selection_count = selection_count;
    meta_seed.trivial_completion_flags = trivial_completion_flags;
    meta_seed.meta_dispatch_kind = meta_dispatch_kind;
    meta_seed.resolve_dispatch_kind = resolve_dispatch_kind;
    meta_seed.args_dispatch_kind = args_dispatch_kind;
    meta_seed.completion_dispatch_kind = completion_dispatch_kind;
    entry->meta = gql_ir_vm_field_meta_from_seed(aTHX_ entry, &meta_seed);
    if (!entry->meta) {
      if (meta_seed.list_item_type_sv) {
        SvREFCNT_dec(meta_seed.list_item_type_sv);
        meta_seed.list_item_type_sv = NULL;
      }
      goto fail;
    }
    gql_ir_init_native_field_ops(entry);
    gql_ir_native_field_hot_refresh(entry);
    if (meta_seed.list_item_type_sv) {
      SvREFCNT_dec(meta_seed.list_item_type_sv);
      meta_seed.list_item_type_sv = NULL;
    }
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

  if (!gql_ir_execution_lowered_root_field_plan(compiled)) {
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

  {
    gql_ir_compiled_root_field_plan_t *root_field_plan = gql_ir_execution_lowered_root_field_plan(compiled);
    for (field_i = 0; field_i < root_field_plan->field_count; field_i++) {
      gql_ir_compiled_root_field_plan_entry_t *entry = &root_field_plan->entries[field_i];
      gql_ir_vm_field_meta_t *meta = gql_ir_native_field_meta(entry);
      gql_ir_vm_field_cold_t *cold = gql_ir_native_field_cold(entry);
      SV *result_name_sv = gql_ir_native_field_result_name(entry);
      SV *field_name_sv = gql_ir_native_field_name(entry);
      HV *field_plan_hv = newHV();

      gql_store_sv(field_plan_hv, "result_name", gql_execution_share_or_copy_sv(result_name_sv));
      gql_store_sv(field_plan_hv, "field_name", gql_execution_share_or_copy_sv(field_name_sv));
      gql_store_sv(field_plan_hv, "field_def", gql_execution_share_or_copy_sv(entry->field_def_sv));
      if (entry->meta && entry->meta->return_type_sv) {
        gql_store_sv(field_plan_hv, "return_type", gql_execution_share_or_copy_sv(entry->meta->return_type_sv));
      }
      gql_store_sv(field_plan_hv, "nodes", gql_execution_share_or_copy_sv(entry->nodes_sv));
      if (cold && cold->path_sv && SvOK(cold->path_sv)) {
        gql_store_sv(field_plan_hv, "path", gql_execution_share_or_copy_sv(cold->path_sv));
      } else {
        AV *path_av = newAV();
        av_push(path_av, gql_execution_share_or_copy_sv(result_name_sv));
        gql_store_sv(field_plan_hv, "path", newRV_noinc((SV *)path_av));
      }
      hv_stores(field_plan_hv, "node_count", newSVuv(cold ? cold->node_count : 0));
      hv_stores(field_plan_hv, "argument_count", newSVuv(meta ? meta->argument_count : 0));
      hv_stores(field_plan_hv, "directive_count", newSVuv(meta ? meta->directive_count : 0));
      hv_stores(field_plan_hv, "selection_count", newSVuv(meta ? meta->selection_count : 0));

      av_push(field_order_av, gql_execution_share_or_copy_sv(result_name_sv));
      (void)hv_store_ent(
        fields_hv,
        gql_execution_share_or_copy_sv(result_name_sv),
        newRV_noinc((SV *)field_plan_hv),
        0
      );
    }
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
            entry->native_block = gql_ir_vm_block_new(entry->native_field_plan, 0);
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
  gql_ir_vm_program_t *program;
  SV *promise_code_sv = &PL_sv_undef;
  gql_ir_native_exec_env_t exec_env;
  gql_ir_native_exec_accum_t exec_accum;
  gql_ir_vm_exec_state_t state;

  Zero(&exec_accum, 1, gql_ir_native_exec_accum_t);

  if (!compiled
      || !(program = gql_ir_execution_lowered_program(compiled))
      || !gql_ir_vm_program_root_block(program)
      || !context_sv
      || !SvROK(context_sv)
      || SvTYPE(SvRV(context_sv)) != SVt_PVHV) {
    goto fallback;
  }

  if (!gql_ir_init_native_exec_env(
        aTHX_
        context_sv,
        compiled->root_type_sv,
        root_value,
        path_sv,
        &exec_env,
        &promise_code_sv
      )) {
    goto fallback;
  }
  gql_ir_init_native_exec_accum(&exec_accum);
  gql_ir_vm_exec_state_init(
    &state,
    compiled,
    gql_ir_vm_program_root_block(program),
    &exec_env,
    &exec_accum.writer,
    &exec_accum.promise_present,
    1
  );
  if (!gql_ir_run_vm_program_root(aTHX_ &state)) {
    goto fallback;
  }

  return gql_ir_finish_native_exec_result(aTHX_ promise_code_sv, &exec_accum);

fallback:
  gql_ir_cleanup_native_exec_accum(&exec_accum);
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
  gql_ir_vm_block_t block_view;

  if (!field_plan) {
    return &PL_sv_undef;
  }

  gql_ir_vm_block_init_view(&block_view, field_plan, 0);
  return gql_ir_execute_vm_block(aTHX_ context_sv, parent_type_sv, root_value, path_sv, &block_view);
}

static SV *
gql_ir_execute_vm_block(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_vm_block_t *block
) {
  /* Mirrors gql_execution_execute_field_plan(), but compiled IR is allowed to
   * diverge here so native plan metadata can replace legacy bucket lookups. */
  SV *promise_code_sv = &PL_sv_undef;
  gql_ir_native_exec_env_t exec_env;
  gql_ir_native_exec_accum_t exec_accum;
  gql_ir_vm_exec_state_t state;

  Zero(&exec_accum, 1, gql_ir_native_exec_accum_t);

  if (!block
      || !block->field_plan
      || !context_sv
      || !SvROK(context_sv)
      || SvTYPE(SvRV(context_sv)) != SVt_PVHV) {
    goto fallback;
  }

  if (!gql_ir_init_native_exec_env(
        aTHX_
        context_sv,
        parent_type_sv,
        root_value,
        path_sv,
        &exec_env,
        &promise_code_sv
      )) {
    goto fallback;
  }
  gql_ir_init_native_exec_accum(&exec_accum);
  gql_ir_vm_exec_state_init(&state, NULL, block, &exec_env, &exec_accum.writer, &exec_accum.promise_present, 0);
  if (!gql_ir_run_vm_block(aTHX_ &state)) {
    goto fallback;
  }

  return gql_ir_finish_native_exec_result(aTHX_ promise_code_sv, &exec_accum);

fallback:
  gql_ir_cleanup_native_exec_accum(&exec_accum);
  return &PL_sv_undef;
}

static int
gql_ir_execute_native_field_plan_sync_to_outcome(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan,
  SV **data_out,
  AV **errors_out
) {
  gql_ir_vm_block_t block_view;

  if (!field_plan) {
    return 0;
  }

  gql_ir_vm_block_init_view(&block_view, field_plan, 0);
  return gql_ir_execute_native_block_sync_to_outcome(
    aTHX_ context_sv,
    parent_type_sv,
    root_value,
    path_sv,
    &block_view,
    data_out,
    errors_out
  );
}

static int
gql_ir_execute_native_block_sync_to_outcome(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_vm_block_t *block,
  SV **data_out,
  AV **errors_out
) {
  SV *promise_code_sv = &PL_sv_undef;
  gql_ir_native_exec_env_t exec_env;
  gql_ir_native_result_writer_t writer;
  gql_ir_vm_exec_state_t state;
  int promise_present = 0;

  Zero(&writer, 1, gql_ir_native_result_writer_t);

  if (!block
      || !block->field_plan
      || !data_out
      || !errors_out
      || !context_sv
      || !SvROK(context_sv)
      || SvTYPE(SvRV(context_sv)) != SVt_PVHV) {
    goto fallback;
  }

  if (!gql_ir_init_native_exec_env(
        aTHX_
        context_sv,
        parent_type_sv,
        root_value,
        path_sv,
        &exec_env,
        &promise_code_sv
      )) {
    goto fallback;
  }
  if (promise_code_sv && SvOK(promise_code_sv)) {
    goto fallback;
  }

  gql_ir_init_native_result_writer(&writer);
  gql_ir_vm_exec_state_init(&state, NULL, block, &exec_env, &writer, &promise_present, 0);
  if (!gql_ir_run_vm_block(aTHX_ &state)) {
    goto fallback;
  }
  if (promise_present
      || writer.pending_count > 0
      || !writer.direct_data_hv) {
    goto fallback;
  }

  *data_out = newRV_noinc((SV *)writer.direct_data_hv);
  writer.direct_data_hv = NULL;
  *errors_out = writer.all_errors_av;
  writer.all_errors_av = NULL;

  gql_ir_cleanup_native_result_writer(&writer);
  return 1;

fallback:
  gql_ir_cleanup_native_result_writer(&writer);
  return 0;
}

static int
gql_ir_execute_native_field_plan_sync_to_child_outcome(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_compiled_root_field_plan_t *field_plan,
  gql_ir_native_child_outcome_t *outcome
) {
  gql_ir_vm_block_t block_view;

  if (!field_plan) {
    return 0;
  }

  gql_ir_vm_block_init_view(&block_view, field_plan, 0);
  return gql_ir_execute_native_block_sync_to_child_outcome(
    aTHX_ context_sv,
    parent_type_sv,
    root_value,
    path_sv,
    &block_view,
    outcome
  );
}

static int
gql_ir_execute_native_block_sync_to_child_outcome(
  pTHX_ SV *context_sv,
  SV *parent_type_sv,
  SV *root_value,
  SV *path_sv,
  gql_ir_vm_block_t *block,
  gql_ir_native_child_outcome_t *outcome
) {
  SV *promise_code_sv = &PL_sv_undef;
  gql_ir_native_exec_env_t exec_env;
  gql_ir_native_result_writer_t writer;
  gql_ir_vm_exec_state_t state;
  int promise_present = 0;

  if (outcome) {
    Zero(outcome, 1, gql_ir_native_child_outcome_t);
  }

  Zero(&writer, 1, gql_ir_native_result_writer_t);

  if (!block
      || !block->field_plan
      || !outcome
      || !context_sv
      || !SvROK(context_sv)
      || SvTYPE(SvRV(context_sv)) != SVt_PVHV) {
    goto fallback;
  }

  if (!gql_ir_init_native_exec_env(
        aTHX_
        context_sv,
        parent_type_sv,
        root_value,
        path_sv,
        &exec_env,
        &promise_code_sv
      )) {
    goto fallback;
  }
  if (promise_code_sv && SvOK(promise_code_sv)) {
    goto fallback;
  }

  gql_ir_init_native_result_writer(&writer);
  gql_ir_vm_exec_state_init(&state, NULL, block, &exec_env, &writer, &promise_present, 0);
  if (!gql_ir_run_vm_block(aTHX_ &state)) {
    goto fallback;
  }
  if (promise_present
      || writer.pending_count > 0
      || !writer.direct_data_hv) {
    goto fallback;
  }

  outcome->data_hv = writer.direct_data_hv;
  writer.direct_data_hv = NULL;
  outcome->errors_av = writer.all_errors_av;
  writer.all_errors_av = NULL;

  gql_ir_cleanup_native_result_writer(&writer);
  return 1;

fallback:
  gql_ir_cleanup_native_result_writer(&writer);
  return 0;
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
