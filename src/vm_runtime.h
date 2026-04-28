#ifndef GQL_RUNTIME_VM_H
#define GQL_RUNTIME_VM_H

#include <stdlib.h>

enum {
  GQL_VM_RESOLVE_DEFAULT = 1,
  GQL_VM_RESOLVE_EXPLICIT = 2
};

enum {
  GQL_VM_COMPLETE_GENERIC = 1,
  GQL_VM_COMPLETE_OBJECT = 2,
  GQL_VM_COMPLETE_LIST = 3,
  GQL_VM_COMPLETE_ABSTRACT = 4
};

enum {
  GQL_VM_FAMILY_GENERIC = 1,
  GQL_VM_FAMILY_OBJECT = 2,
  GQL_VM_FAMILY_LIST = 3,
  GQL_VM_FAMILY_ABSTRACT = 4
};

enum {
  GQL_VM_DISPATCH_GENERIC = 1,
  GQL_VM_DISPATCH_RESOLVE_TYPE = 2,
  GQL_VM_DISPATCH_TAG = 3,
  GQL_VM_DISPATCH_POSSIBLE_TYPES = 4
};

enum {
  GQL_VM_ARGS_NONE = 0,
  GQL_VM_ARGS_STATIC = 1,
  GQL_VM_ARGS_DYNAMIC = 2
};

enum {
  GQL_VM_KIND_UNKNOWN = 0,
  GQL_VM_KIND_SCALAR = 1,
  GQL_VM_KIND_OBJECT = 2,
  GQL_VM_KIND_LIST = 3,
  GQL_VM_KIND_INTERFACE = 4,
  GQL_VM_KIND_UNION = 5,
  GQL_VM_KIND_ENUM = 6,
  GQL_VM_KIND_INPUT_OBJECT = 7,
  GQL_VM_KIND_NON_NULL = 8
};

enum {
  GQL_VM_OPTYPE_QUERY = 1,
  GQL_VM_OPTYPE_MUTATION = 2,
  GQL_VM_OPTYPE_SUBSCRIPTION = 3
};

enum {
  GQL_VM_GUARD_INCLUDE = 1,
  GQL_VM_GUARD_SKIP = 2
};

enum {
  GQL_VM_DYNAMIC_UNDEF = 0,
  GQL_VM_DYNAMIC_SCALAR = 1,
  GQL_VM_DYNAMIC_VARIABLE = 2,
  GQL_VM_DYNAMIC_LIST = 3,
  GQL_VM_DYNAMIC_OBJECT = 4
};

#define GQL_VM_OPCODE(resolve_code, complete_code) (((resolve_code) * 16) + (complete_code))

typedef struct gql_runtime_vm_native_value gql_runtime_vm_native_value_t;
typedef struct gql_runtime_vm_native_dynamic_value gql_runtime_vm_native_dynamic_value_t;

typedef struct {
  char *name;
  SV *type_def_sv;
  SV *input_type_sv;
  U8 has_default;
  SV *default_value_sv;
  gql_runtime_vm_native_value_t *default_native_value;
} gql_runtime_vm_native_arg_def_t;

typedef struct {
  IV count;
  char **names;
  gql_runtime_vm_native_dynamic_value_t **values;
} gql_runtime_vm_native_args_payload_t;

typedef struct {
  IV kind_code;
  gql_runtime_vm_native_dynamic_value_t *if_expr;
} gql_runtime_vm_native_guard_t;

typedef struct {
  IV count;
  gql_runtime_vm_native_guard_t *guards;
} gql_runtime_vm_native_directives_payload_t;

typedef struct {
  char *field_name;
  char *result_name;
  char *return_type_name;
  IV schema_slot_index;
  IV resolver_shape_code;
  IV resolver_mode_code;
  IV completion_family_code;
  IV dispatch_family_code;
  IV return_type_kind_code;
  IV arg_def_count;
  gql_runtime_vm_native_arg_def_t *arg_defs;
  U8 has_args;
  U8 has_directives;
} gql_runtime_vm_native_slot_t;

typedef struct {
  char *tag_name;
  char *type_name;
} gql_runtime_vm_native_tag_entry_t;

typedef struct {
  char *type_name;
  SV *type_sv;
  SV *is_type_of_cb;
} gql_runtime_vm_native_possible_type_entry_t;

typedef struct {
  SV *runtime_schema;
  SV **slot_resolvers;
  SV **slot_type_objects;
  SV **slot_tag_resolvers;
  SV **slot_resolve_types;
  gql_runtime_vm_native_tag_entry_t **slot_tag_entries;
  IV *slot_tag_entry_counts;
  gql_runtime_vm_native_possible_type_entry_t **slot_possible_type_entries;
  IV *slot_possible_type_entry_counts;
} gql_runtime_vm_native_callback_catalog_t;

typedef struct {
  char **abstract_child_names;
  IV *abstract_child_indexes;
  IV opcode_code;
  IV resolve_code;
  IV complete_code;
  IV dispatch_family_code;
  IV slot_index;
  IV child_block_index;
  IV abstract_child_count;
  IV args_mode_code;
  IV directives_mode_code;
  gql_runtime_vm_native_args_payload_t *args_payload_native;
  gql_runtime_vm_native_directives_payload_t *directives_payload_native;
  U8 has_args;
  U8 has_directives;
} gql_runtime_vm_native_op_t;

typedef struct {
  IV family_code;
  char *type_name;
  IV slot_count;
  IV op_count;
  gql_runtime_vm_native_slot_t *slots;
  gql_runtime_vm_native_op_t *ops;
} gql_runtime_vm_native_block_t;

typedef struct {
  IV runtime_slot_count;
  gql_runtime_vm_native_slot_t *runtime_slots;
  gql_runtime_vm_native_callback_catalog_t *callback_catalog;
} gql_runtime_vm_native_runtime_t;

typedef struct {
  IV operation_type_code;
  IV root_block_index;
  IV runtime_slot_count;
  IV block_count;
  U8 owns_runtime_slots;
  U8 owns_blocks;
  gql_runtime_vm_native_slot_t *runtime_slots;
  gql_runtime_vm_native_block_t *blocks;
} gql_runtime_vm_native_bundle_t;

typedef struct {
  IV operation_type_code;
  IV root_block_index;
  IV block_count;
  gql_runtime_vm_native_block_t *blocks;
} gql_runtime_vm_native_program_t;

typedef struct gql_runtime_vm_path_frame gql_runtime_vm_path_frame_t;
typedef struct gql_runtime_vm_outcome gql_runtime_vm_outcome_t;
typedef struct gql_runtime_vm_cursor_t gql_runtime_vm_cursor_t;
typedef struct gql_runtime_vm_field_frame_t gql_runtime_vm_field_frame_t;
typedef struct gql_runtime_vm_block_frame_t gql_runtime_vm_block_frame_t;
typedef struct gql_runtime_vm_writer_t gql_runtime_vm_writer_t;
typedef struct gql_runtime_vm_pending_entry_t gql_runtime_vm_pending_entry_t;
typedef struct gql_runtime_vm_callback_context gql_runtime_vm_callback_context_t;

struct gql_runtime_vm_callback_context {
  SV *runtime_schema;
  SV *program;
  SV *context;
  SV *variables;
  SV *root_value;
};

typedef struct {
  gql_runtime_vm_native_runtime_t *runtime;
  gql_runtime_vm_native_bundle_t *bundle;
  gql_runtime_vm_callback_context_t *callback_ctx;
  gql_runtime_vm_path_frame_t *path_frame;
  gql_runtime_vm_writer_t *writer;
  const gql_runtime_vm_native_block_t *block;
  const gql_runtime_vm_native_op_t *op;
  const gql_runtime_vm_native_slot_t *slot;
  IV block_index;
  IV op_index;
} gql_runtime_vm_exec_state_t;

enum {
  GQL_VM_NATIVE_VALUE_UNDEF = 0,
  GQL_VM_NATIVE_VALUE_SCALAR = 1,
  GQL_VM_NATIVE_VALUE_OBJECT = 2,
  GQL_VM_NATIVE_VALUE_LIST = 3
};

enum {
  GQL_VM_NATIVE_SCALAR_UNDEF = 0,
  GQL_VM_NATIVE_SCALAR_IV = 1,
  GQL_VM_NATIVE_SCALAR_NV = 2,
  GQL_VM_NATIVE_SCALAR_PV = 3,
  GQL_VM_NATIVE_SCALAR_FALLBACK_SV = 4
};

typedef struct {
  char **names;
  gql_runtime_vm_native_value_t **values;
  IV count;
  IV capacity;
} gql_runtime_vm_native_object_t;

typedef struct {
  gql_runtime_vm_native_value_t **items;
  IV count;
  IV capacity;
} gql_runtime_vm_native_list_t;

struct gql_runtime_vm_native_value {
  U8 kind_code;
  U8 scalar_kind_code;
  IV scalar_iv;
  NV scalar_nv;
  char *scalar_pv;
  STRLEN scalar_pv_len;
  SV *scalar_fallback_sv;
  gql_runtime_vm_native_object_t object;
  gql_runtime_vm_native_list_t list;
};

struct gql_runtime_vm_native_dynamic_value {
  U8 kind_code;
  U8 scalar_kind_code;
  IV scalar_iv;
  NV scalar_nv;
  char *scalar_pv;
  STRLEN scalar_pv_len;
  char *variable_name;
  IV object_count;
  char **object_names;
  gql_runtime_vm_native_dynamic_value_t **object_values;
  IV list_count;
  gql_runtime_vm_native_dynamic_value_t **list_values;
};

typedef struct {
  SV *runtime_schema;
  SV *program;
  gql_runtime_vm_cursor_t *cursor;
  gql_runtime_vm_block_frame_t *frame;
  IV frame_stack_count;
  IV frame_stack_capacity;
  gql_runtime_vm_block_frame_t **frame_stack;
  gql_runtime_vm_field_frame_t *field_frame;
  gql_runtime_vm_writer_t *writer;
  SV *context;
  SV *variables;
  SV *root_value;
  SV *promise_code;
  SV *empty_args;
} gql_runtime_vm_exec_state_handle_t;

struct gql_runtime_vm_cursor_t {
  UV refcount;
  SV *block;
  IV slot_index;
  IV op_index;
};

struct gql_runtime_vm_field_frame_t {
  UV refcount;
  SV *source;
  gql_runtime_vm_path_frame_t *path_frame;
  SV *resolved_value;
  gql_runtime_vm_outcome_t *outcome;
};

struct gql_runtime_vm_path_frame {
  UV refcount;
  struct gql_runtime_vm_path_frame *parent;
  IV key_kind;
  IV key_iv;
  char *key_pv;
};

typedef struct {
  UV refcount;
  char *message_pv;
  gql_runtime_vm_path_frame_t *path_frame;
} gql_runtime_vm_error_record_t;

struct gql_runtime_vm_block_frame_t {
  UV refcount;
  gql_runtime_vm_native_value_t *values_value;
  IV pending_count;
  IV pending_capacity;
  gql_runtime_vm_pending_entry_t *pending_entries;
};

enum {
  GQL_VM_PENDING_PROMISE_SV = 1,
  GQL_VM_PENDING_OUTCOME_PTR = 2,
};

struct gql_runtime_vm_pending_entry_t {
  char *result_name_pv;
  STRLEN result_name_len;
  U8 payload_kind;
  union {
    SV *promise_sv;
    gql_runtime_vm_outcome_t *outcome_ptr;
  } payload;
};

struct gql_runtime_vm_outcome {
  UV refcount;
  U8 kind_code;
  gql_runtime_vm_native_value_t *value;
  IV error_record_count;
  gql_runtime_vm_error_record_t **error_records;
};

struct gql_runtime_vm_writer_t {
  UV refcount;
  IV error_record_count;
  IV error_record_capacity;
  gql_runtime_vm_error_record_t **error_records;
};

static AV *gql_runtime_vm_expect_op_array(pTHX_ SV *op_sv);
static SV *gql_runtime_vm_op_slot_sv(pTHX_ SV *op_sv, IV index);
static SV *gql_runtime_vm_op_result_name_sv(pTHX_ SV *op_sv);
static AV *gql_runtime_vm_cursor_ops_av(pTHX_ const gql_runtime_vm_cursor_t *cursor);
static SV *gql_runtime_vm_cursor_current_op_borrowed_sv(pTHX_ const gql_runtime_vm_cursor_t *cursor);
static SV *gql_runtime_vm_cursor_current_slot_borrowed_sv(pTHX_ const gql_runtime_vm_cursor_t *cursor);
static SV *gql_runtime_vm_new_handle_sv(pTHX_ const char *pkg, void *ptr);
static SV *gql_runtime_vm_fetch_hash_entry_sv(pTHX_ HV *hv, const char *key, I32 keylen);
static gql_runtime_vm_cursor_t *gql_runtime_vm_expect_cursor(pTHX_ SV *self);
static gql_runtime_vm_error_record_t *gql_runtime_vm_expect_error_record(pTHX_ SV *self);
static gql_runtime_vm_outcome_t *gql_runtime_vm_expect_outcome(pTHX_ SV *self);
static void gql_runtime_vm_error_record_incref(gql_runtime_vm_error_record_t *record);
static void gql_runtime_vm_error_record_decref(pTHX_ gql_runtime_vm_error_record_t *record);
static void gql_runtime_vm_outcome_incref(gql_runtime_vm_outcome_t *outcome);
static void gql_runtime_vm_outcome_decref(pTHX_ gql_runtime_vm_outcome_t *outcome);
static void gql_runtime_vm_writer_push_error_record(gql_runtime_vm_writer_t *writer, gql_runtime_vm_error_record_t *record);
static void gql_runtime_vm_block_frame_push_pending(pTHX_ gql_runtime_vm_block_frame_t *frame, SV *result_name, SV *outcome);
static void gql_runtime_vm_block_frame_clear_pending(pTHX_ gql_runtime_vm_block_frame_t *frame);
static void gql_runtime_vm_path_frame_decref(gql_runtime_vm_path_frame_t *frame);
static SV *gql_runtime_vm_call_cb4(pTHX_ SV *cb, SV *arg0, SV *arg1, SV *arg2, SV *arg3);
static SV *gql_runtime_vm_call_cb4_nonfatal(pTHX_ SV *cb, SV *arg0, SV *arg1, SV *arg2, SV *arg3, SV **error_out);
static SV *gql_runtime_vm_call_cb5_nonfatal(pTHX_ SV *cb, SV *arg0, SV *arg1, SV *arg2, SV *arg3, SV *arg4, SV **error_out);
static SV *gql_runtime_vm_new_callback_info_sv(pTHX_ const gql_runtime_vm_exec_state_t *state);
static gql_runtime_vm_native_value_t *gql_runtime_vm_new_native_value_scalar(pTHX_ SV *value);
static gql_runtime_vm_native_value_t *gql_runtime_vm_new_native_value_object(void);
static gql_runtime_vm_native_value_t *gql_runtime_vm_new_native_value_list(void);
static void gql_runtime_vm_native_object_store(pTHX_ gql_runtime_vm_native_value_t *value, const char *name, gql_runtime_vm_native_value_t *child);
static void gql_runtime_vm_native_list_push(gql_runtime_vm_native_value_t *value, gql_runtime_vm_native_value_t *child);
static void gql_runtime_vm_native_value_destroy(pTHX_ gql_runtime_vm_native_value_t *value);
static SV *gql_runtime_vm_native_value_materialize_sv(pTHX_ gql_runtime_vm_native_value_t *value);
static gql_runtime_vm_native_value_t *gql_runtime_vm_native_value_from_sv(pTHX_ SV *value);
static gql_runtime_vm_native_value_t *gql_runtime_vm_native_value_clone(pTHX_ const gql_runtime_vm_native_value_t *value);
static gql_runtime_vm_native_dynamic_value_t *gql_runtime_vm_native_dynamic_value_from_sv(pTHX_ SV *value);
static gql_runtime_vm_native_dynamic_value_t *gql_runtime_vm_native_dynamic_value_clone(
  pTHX_ const gql_runtime_vm_native_dynamic_value_t *value
);
static void gql_runtime_vm_native_dynamic_value_destroy(
  pTHX_ gql_runtime_vm_native_dynamic_value_t *value
);
static SV *gql_runtime_vm_native_dynamic_value_materialize_sv(
  pTHX_ const gql_runtime_vm_native_dynamic_value_t *value,
  HV *variables
);
static gql_runtime_vm_native_args_payload_t *gql_runtime_vm_native_args_payload_from_hv(pTHX_ HV *hv);
static gql_runtime_vm_native_args_payload_t *gql_runtime_vm_native_args_payload_clone(
  pTHX_ const gql_runtime_vm_native_args_payload_t *payload
);
static void gql_runtime_vm_native_args_payload_destroy(pTHX_ gql_runtime_vm_native_args_payload_t *payload);
static SV *gql_runtime_vm_native_args_payload_materialize_sv(
  pTHX_ const gql_runtime_vm_native_args_payload_t *payload
);
static gql_runtime_vm_native_directives_payload_t *gql_runtime_vm_native_directives_payload_from_sv(
  pTHX_ SV *guards_sv
);
static gql_runtime_vm_native_directives_payload_t *gql_runtime_vm_native_directives_payload_clone(
  pTHX_ const gql_runtime_vm_native_directives_payload_t *payload
);
static void gql_runtime_vm_native_directives_payload_destroy(
  pTHX_ gql_runtime_vm_native_directives_payload_t *payload
);
static int gql_runtime_vm_evaluate_runtime_guards_native(
  pTHX_ const gql_runtime_vm_native_directives_payload_t *payload,
  HV *variables
);
static const gql_runtime_vm_native_slot_t *gql_runtime_vm_effective_slot(
  const gql_runtime_vm_native_runtime_t *runtime,
  const gql_runtime_vm_native_slot_t *slot
);
static int gql_runtime_vm_sv_to_hv(pTHX_ SV *sv, HV **out);
static int gql_runtime_vm_sv_to_av(pTHX_ SV *sv, AV **out);
static void gql_runtime_vm_free_native_arg_defs(pTHX_ gql_runtime_vm_native_arg_def_t *arg_defs, IV count);

static AV *
gql_runtime_vm_expect_op_array(pTHX_ SV *op_sv)
{
  if (!op_sv || !SvOK(op_sv) || !SvROK(op_sv) || SvTYPE(SvRV(op_sv)) != SVt_PVAV) {
    return NULL;
  }
  return (AV *)SvRV(op_sv);
}

static SV *
gql_runtime_vm_op_slot_sv(pTHX_ SV *op_sv, IV index)
{
  AV *op_av = gql_runtime_vm_expect_op_array(aTHX_ op_sv);
  SV **svp;

  if (!op_av) {
    return NULL;
  }

  svp = av_fetch(op_av, index, 0);
  return (svp && SvOK(*svp)) ? *svp : NULL;
}

static SV *
gql_runtime_vm_op_result_name_sv(pTHX_ SV *op_sv)
{
  return gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 7);
}

static AV *
gql_runtime_vm_cursor_ops_av(pTHX_ const gql_runtime_vm_cursor_t *cursor)
{
  AV *block_av;
  SV **svp;

  if (!cursor || !cursor->block || !SvOK(cursor->block) || !SvROK(cursor->block) || SvTYPE(SvRV(cursor->block)) != SVt_PVAV) {
    return NULL;
  }

  block_av = (AV *)SvRV(cursor->block);
  svp = av_fetch(block_av, 3, 0);
  if (!svp || !SvOK(*svp) || !SvROK(*svp) || SvTYPE(SvRV(*svp)) != SVt_PVAV) {
    return NULL;
  }

  return (AV *)SvRV(*svp);
}

static SV *
gql_runtime_vm_cursor_current_op_borrowed_sv(pTHX_ const gql_runtime_vm_cursor_t *cursor)
{
  AV *ops_av;
  SV **svp;

  ops_av = gql_runtime_vm_cursor_ops_av(aTHX_ cursor);
  if (!ops_av || !cursor || cursor->op_index < 0 || cursor->op_index > av_len(ops_av)) {
    return NULL;
  }

  svp = av_fetch(ops_av, cursor->op_index, 0);
  return (svp && SvOK(*svp)) ? *svp : NULL;
}

static SV *
gql_runtime_vm_cursor_current_slot_borrowed_sv(pTHX_ const gql_runtime_vm_cursor_t *cursor)
{
  SV *op_sv = gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ cursor);
  return op_sv ? gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 19) : NULL;
}

static gql_runtime_vm_native_value_t *
gql_runtime_vm_new_native_value_scalar(pTHX_ SV *value)
{
  gql_runtime_vm_native_value_t *ret;
  Newxz(ret, 1, gql_runtime_vm_native_value_t);
  ret->kind_code = GQL_VM_NATIVE_VALUE_SCALAR;
  ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_UNDEF;
  ret->scalar_iv = 0;
  ret->scalar_nv = 0.0;
  ret->scalar_pv = NULL;
  ret->scalar_pv_len = 0;
  ret->scalar_fallback_sv = NULL;
  if (!value || !SvOK(value)) {
    return ret;
  }
  if (SvROK(value) || SvMAGICAL(value)) {
    ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_FALLBACK_SV;
    ret->scalar_fallback_sv = newSVsv(value);
    return ret;
  }
  if (SvPOKp(value)) {
    STRLEN len = 0;
    const char *pv = SvPV(value, len);
    ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_PV;
    ret->scalar_pv = savepvn(pv, len);
    ret->scalar_pv_len = len;
    return ret;
  }
  if (SvIOKp(value)) {
    ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_IV;
    ret->scalar_iv = SvIV(value);
    return ret;
  }
  if (SvNOKp(value)) {
    ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_NV;
    ret->scalar_nv = SvNV(value);
    return ret;
  }
  ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_FALLBACK_SV;
  ret->scalar_fallback_sv = newSVsv(value);
  return ret;
}

static gql_runtime_vm_native_value_t *
gql_runtime_vm_new_native_value_object(void)
{
  gql_runtime_vm_native_value_t *ret;
  Newxz(ret, 1, gql_runtime_vm_native_value_t);
  ret->kind_code = GQL_VM_NATIVE_VALUE_OBJECT;
  return ret;
}

static gql_runtime_vm_native_value_t *
gql_runtime_vm_new_native_value_list(void)
{
  gql_runtime_vm_native_value_t *ret;
  Newxz(ret, 1, gql_runtime_vm_native_value_t);
  ret->kind_code = GQL_VM_NATIVE_VALUE_LIST;
  return ret;
}

static void
gql_runtime_vm_native_object_store(pTHX_ gql_runtime_vm_native_value_t *value, const char *name, gql_runtime_vm_native_value_t *child)
{
  gql_runtime_vm_native_object_t *object;
  if (!value || value->kind_code != GQL_VM_NATIVE_VALUE_OBJECT || !name || !child) {
    return;
  }
  object = &value->object;
  if (object->count == object->capacity) {
    IV new_capacity = object->capacity ? object->capacity * 2 : 8;
    Renew(object->names, new_capacity, char *);
    Renew(object->values, new_capacity, gql_runtime_vm_native_value_t *);
    object->capacity = new_capacity;
  }
  object->names[object->count] = savepv(name);
  object->values[object->count] = child;
  object->count++;
}

static void
gql_runtime_vm_native_list_push(gql_runtime_vm_native_value_t *value, gql_runtime_vm_native_value_t *child)
{
  gql_runtime_vm_native_list_t *list;
  if (!value || value->kind_code != GQL_VM_NATIVE_VALUE_LIST || !child) {
    return;
  }
  list = &value->list;
  if (list->count == list->capacity) {
    IV new_capacity = list->capacity ? list->capacity * 2 : 8;
    Renew(list->items, new_capacity, gql_runtime_vm_native_value_t *);
    list->capacity = new_capacity;
  }
  list->items[list->count] = child;
  list->count++;
}

static void
gql_runtime_vm_native_value_destroy(pTHX_ gql_runtime_vm_native_value_t *value)
{
  IV i;
  if (!value) {
    return;
  }
  switch (value->kind_code) {
    case GQL_VM_NATIVE_VALUE_SCALAR:
      switch (value->scalar_kind_code) {
        case GQL_VM_NATIVE_SCALAR_PV:
          Safefree(value->scalar_pv);
          break;
        case GQL_VM_NATIVE_SCALAR_FALLBACK_SV:
          SvREFCNT_dec(value->scalar_fallback_sv);
          break;
        default:
          break;
      }
      break;
    case GQL_VM_NATIVE_VALUE_OBJECT:
      for (i = 0; i < value->object.count; i++) {
        Safefree(value->object.names[i]);
        gql_runtime_vm_native_value_destroy(aTHX_ value->object.values[i]);
      }
      Safefree(value->object.names);
      Safefree(value->object.values);
      break;
    case GQL_VM_NATIVE_VALUE_LIST:
      for (i = 0; i < value->list.count; i++) {
        gql_runtime_vm_native_value_destroy(aTHX_ value->list.items[i]);
      }
      Safefree(value->list.items);
      break;
  }
  Safefree(value);
}

static SV *
gql_runtime_vm_native_value_materialize_sv(pTHX_ gql_runtime_vm_native_value_t *value)
{
  IV i;
  if (!value) {
    return newSVsv(&PL_sv_undef);
  }
  switch (value->kind_code) {
    case GQL_VM_NATIVE_VALUE_OBJECT: {
      HV *hv = newHV();
      for (i = 0; i < value->object.count; i++) {
        hv_store(
          hv,
          value->object.names[i],
          (I32)strlen(value->object.names[i]),
          gql_runtime_vm_native_value_materialize_sv(aTHX_ value->object.values[i]),
          0
        );
      }
      return newRV_noinc((SV *)hv);
    }
    case GQL_VM_NATIVE_VALUE_LIST: {
      AV *av = newAV();
      av_extend(av, value->list.count > 0 ? value->list.count - 1 : 0);
      for (i = 0; i < value->list.count; i++) {
        av_store(av, i, gql_runtime_vm_native_value_materialize_sv(aTHX_ value->list.items[i]));
      }
      return newRV_noinc((SV *)av);
    }
    case GQL_VM_NATIVE_VALUE_SCALAR:
    default:
      switch (value->scalar_kind_code) {
        case GQL_VM_NATIVE_SCALAR_UNDEF:
          return newSVsv(&PL_sv_undef);
        case GQL_VM_NATIVE_SCALAR_IV:
          return newSViv(value->scalar_iv);
        case GQL_VM_NATIVE_SCALAR_NV:
          return newSVnv(value->scalar_nv);
        case GQL_VM_NATIVE_SCALAR_PV:
          return newSVpvn(value->scalar_pv ? value->scalar_pv : "", value->scalar_pv_len);
        case GQL_VM_NATIVE_SCALAR_FALLBACK_SV:
        default:
          return value->scalar_fallback_sv ? newSVsv(value->scalar_fallback_sv) : newSVsv(&PL_sv_undef);
      }
  }
}

static gql_runtime_vm_native_value_t *
gql_runtime_vm_native_value_from_sv(pTHX_ SV *value)
{
  SSize_t i;
  if (!value || !SvOK(value)) {
    return gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
  }
  if (SvROK(value)) {
    SV *rv = SvRV(value);
    if (SvTYPE(rv) == SVt_PVHV) {
      HV *hv = (HV *)rv;
      HE *he;
      gql_runtime_vm_native_value_t *ret = gql_runtime_vm_new_native_value_object();
      hv_iterinit(hv);
      while ((he = hv_iternext(hv))) {
        SV *key_sv = hv_iterkeysv(he);
        SV *val_sv = hv_iterval(hv, he);
        STRLEN key_len = 0;
        const char *key_pv = key_sv ? SvPV(key_sv, key_len) : "";
        char *name;
        Newxz(name, key_len + 1, char);
        Copy(key_pv, name, key_len, char);
        name[key_len] = '\0';
        gql_runtime_vm_native_object_store(aTHX_ ret, name, gql_runtime_vm_native_value_from_sv(aTHX_ val_sv));
        Safefree(name);
      }
      return ret;
    }
    if (SvTYPE(rv) == SVt_PVAV) {
      AV *av = (AV *)rv;
      gql_runtime_vm_native_value_t *ret = gql_runtime_vm_new_native_value_list();
      for (i = 0; i <= av_len(av); i++) {
        SV **svp = av_fetch(av, i, 0);
        gql_runtime_vm_native_list_push(ret, gql_runtime_vm_native_value_from_sv(aTHX_ (svp && *svp) ? *svp : &PL_sv_undef));
      }
      return ret;
    }
  }
  return gql_runtime_vm_new_native_value_scalar(aTHX_ value);
}

static gql_runtime_vm_native_value_t *
gql_runtime_vm_native_value_clone(pTHX_ const gql_runtime_vm_native_value_t *value)
{
  IV i;
  gql_runtime_vm_native_value_t *ret;
  if (!value) {
    return gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
  }
  switch (value->kind_code) {
    case GQL_VM_NATIVE_VALUE_OBJECT:
      ret = gql_runtime_vm_new_native_value_object();
      for (i = 0; i < value->object.count; i++) {
        gql_runtime_vm_native_object_store(
          aTHX_ ret,
          value->object.names[i],
          gql_runtime_vm_native_value_clone(aTHX_ value->object.values[i])
        );
      }
      return ret;
    case GQL_VM_NATIVE_VALUE_LIST:
      ret = gql_runtime_vm_new_native_value_list();
      for (i = 0; i < value->list.count; i++) {
        gql_runtime_vm_native_list_push(
          ret,
          gql_runtime_vm_native_value_clone(aTHX_ value->list.items[i])
        );
      }
      return ret;
    case GQL_VM_NATIVE_VALUE_SCALAR:
    default:
      switch (value->scalar_kind_code) {
        case GQL_VM_NATIVE_SCALAR_UNDEF:
          return gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
        case GQL_VM_NATIVE_SCALAR_IV:
          ret = gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
          ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_IV;
          ret->scalar_iv = value->scalar_iv;
          return ret;
        case GQL_VM_NATIVE_SCALAR_NV:
          ret = gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
          ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_NV;
          ret->scalar_nv = value->scalar_nv;
          return ret;
        case GQL_VM_NATIVE_SCALAR_PV:
          ret = gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
          ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_PV;
          if (value->scalar_pv && value->scalar_pv_len) {
            ret->scalar_pv = savepvn(value->scalar_pv, value->scalar_pv_len);
            ret->scalar_pv_len = value->scalar_pv_len;
          }
          return ret;
        case GQL_VM_NATIVE_SCALAR_FALLBACK_SV:
        default:
          return gql_runtime_vm_new_native_value_scalar(aTHX_ value->scalar_fallback_sv ? value->scalar_fallback_sv : &PL_sv_undef);
      }
  }
}

static gql_runtime_vm_native_dynamic_value_t *
gql_runtime_vm_native_dynamic_value_from_sv(pTHX_ SV *value)
{
  gql_runtime_vm_native_dynamic_value_t *ret;
  STRLEN len = 0;

  Newxz(ret, 1, gql_runtime_vm_native_dynamic_value_t);
  ret->kind_code = GQL_VM_DYNAMIC_UNDEF;
  ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_UNDEF;

  if (!value || !SvOK(value)) {
    return ret;
  }

  if (SvROK(value)) {
    SV *inner = SvRV(value);
    if (SvTYPE(inner) == SVt_PVAV) {
      AV *av = (AV *)inner;
      IV i;
      ret->kind_code = GQL_VM_DYNAMIC_LIST;
      ret->list_count = av_len(av) + 1;
      if (ret->list_count > 0) {
        Newxz(ret->list_values, ret->list_count, gql_runtime_vm_native_dynamic_value_t *);
        for (i = 0; i < ret->list_count; i++) {
          SV **svp = av_fetch(av, i, 0);
          ret->list_values[i] = gql_runtime_vm_native_dynamic_value_from_sv(aTHX_ (svp && SvOK(*svp)) ? *svp : &PL_sv_undef);
        }
      }
      return ret;
    }
    if (SvTYPE(inner) == SVt_PVHV) {
      HV *hv = (HV *)inner;
      HE *he;
      IV count = HvUSEDKEYS(hv);
      ret->kind_code = GQL_VM_DYNAMIC_OBJECT;
      ret->object_count = count;
      if (count > 0) {
        IV i = 0;
        Newxz(ret->object_names, count, char *);
        Newxz(ret->object_values, count, gql_runtime_vm_native_dynamic_value_t *);
        hv_iterinit(hv);
        while ((he = hv_iternext(hv))) {
          SV *key_sv = hv_iterkeysv(he);
          SV *val_sv = hv_iterval(hv, he);
          const char *key_pv = SvPV(key_sv, len);
          ret->object_names[i] = savepvn(key_pv, len);
          ret->object_values[i] = gql_runtime_vm_native_dynamic_value_from_sv(aTHX_ val_sv);
          i++;
        }
        ret->object_count = i;
      }
      return ret;
    }
    if (SvTYPE(inner) == SVt_PV) {
      const char *name = SvPV(inner, len);
      ret->kind_code = GQL_VM_DYNAMIC_VARIABLE;
      ret->variable_name = savepvn(name, len);
      return ret;
    }
  }

  ret->kind_code = GQL_VM_DYNAMIC_SCALAR;
  if (SvPOKp(value)) {
    const char *pv = SvPV(value, len);
    ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_PV;
    ret->scalar_pv = savepvn(pv, len);
    ret->scalar_pv_len = len;
    return ret;
  }
  if (SvIOKp(value)) {
    ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_IV;
    ret->scalar_iv = SvIV(value);
    return ret;
  }
  if (SvNOKp(value)) {
    ret->scalar_kind_code = GQL_VM_NATIVE_SCALAR_NV;
    ret->scalar_nv = SvNV(value);
    return ret;
  }
  return ret;
}

static gql_runtime_vm_native_dynamic_value_t *
gql_runtime_vm_native_dynamic_value_clone(
  pTHX_ const gql_runtime_vm_native_dynamic_value_t *value
)
{
  gql_runtime_vm_native_dynamic_value_t *ret;
  IV i;

  if (!value) {
    return NULL;
  }
  Newxz(ret, 1, gql_runtime_vm_native_dynamic_value_t);
  *ret = *value;
  ret->scalar_pv = NULL;
  ret->variable_name = NULL;
  ret->object_names = NULL;
  ret->object_values = NULL;
  ret->list_values = NULL;

  if (value->scalar_kind_code == GQL_VM_NATIVE_SCALAR_PV && value->scalar_pv) {
    ret->scalar_pv = savepvn(value->scalar_pv, value->scalar_pv_len);
  }
  if (value->kind_code == GQL_VM_DYNAMIC_VARIABLE && value->variable_name) {
    ret->variable_name = savepv(value->variable_name);
  }
  if (value->kind_code == GQL_VM_DYNAMIC_OBJECT && value->object_count > 0) {
    Newxz(ret->object_names, value->object_count, char *);
    Newxz(ret->object_values, value->object_count, gql_runtime_vm_native_dynamic_value_t *);
    for (i = 0; i < value->object_count; i++) {
      ret->object_names[i] = value->object_names[i] ? savepv(value->object_names[i]) : NULL;
      ret->object_values[i] = gql_runtime_vm_native_dynamic_value_clone(aTHX_ value->object_values[i]);
    }
  }
  if (value->kind_code == GQL_VM_DYNAMIC_LIST && value->list_count > 0) {
    Newxz(ret->list_values, value->list_count, gql_runtime_vm_native_dynamic_value_t *);
    for (i = 0; i < value->list_count; i++) {
      ret->list_values[i] = gql_runtime_vm_native_dynamic_value_clone(aTHX_ value->list_values[i]);
    }
  }
  return ret;
}

static void
gql_runtime_vm_native_dynamic_value_destroy(
  pTHX_ gql_runtime_vm_native_dynamic_value_t *value
)
{
  IV i;

  if (!value) {
    return;
  }
  if (value->scalar_kind_code == GQL_VM_NATIVE_SCALAR_PV) {
    Safefree(value->scalar_pv);
  }
  Safefree(value->variable_name);
  if (value->kind_code == GQL_VM_DYNAMIC_OBJECT) {
    for (i = 0; i < value->object_count; i++) {
      Safefree(value->object_names ? value->object_names[i] : NULL);
      gql_runtime_vm_native_dynamic_value_destroy(aTHX_ value->object_values ? value->object_values[i] : NULL);
    }
    Safefree(value->object_names);
    Safefree(value->object_values);
  } else if (value->kind_code == GQL_VM_DYNAMIC_LIST) {
    for (i = 0; i < value->list_count; i++) {
      gql_runtime_vm_native_dynamic_value_destroy(aTHX_ value->list_values ? value->list_values[i] : NULL);
    }
    Safefree(value->list_values);
  }
  Safefree(value);
}

static SV *
gql_runtime_vm_native_dynamic_value_materialize_sv(
  pTHX_ const gql_runtime_vm_native_dynamic_value_t *value,
  HV *variables
)
{
  IV i;

  if (!value || value->kind_code == GQL_VM_DYNAMIC_UNDEF) {
    return newSV(0);
  }

  switch (value->kind_code) {
    case GQL_VM_DYNAMIC_VARIABLE: {
      SV **svp = (variables && value->variable_name)
        ? hv_fetch(variables, value->variable_name, (I32)strlen(value->variable_name), 0)
        : NULL;
      return (svp && SvOK(*svp)) ? newSVsv(*svp) : newSV(0);
    }
    case GQL_VM_DYNAMIC_LIST: {
      AV *av = newAV();
      for (i = 0; i < value->list_count; i++) {
        av_push(av, gql_runtime_vm_native_dynamic_value_materialize_sv(aTHX_ value->list_values[i], variables));
      }
      return newRV_noinc((SV *)av);
    }
    case GQL_VM_DYNAMIC_OBJECT: {
      HV *hv = newHV();
      for (i = 0; i < value->object_count; i++) {
        if (!value->object_names || !value->object_names[i]) {
          continue;
        }
        hv_store(
          hv,
          value->object_names[i],
          (I32)strlen(value->object_names[i]),
          gql_runtime_vm_native_dynamic_value_materialize_sv(aTHX_ value->object_values[i], variables),
          0
        );
      }
      return newRV_noinc((SV *)hv);
    }
    case GQL_VM_DYNAMIC_SCALAR:
    default:
      switch (value->scalar_kind_code) {
        case GQL_VM_NATIVE_SCALAR_IV:
          return newSViv(value->scalar_iv);
        case GQL_VM_NATIVE_SCALAR_NV:
          return newSVnv(value->scalar_nv);
        case GQL_VM_NATIVE_SCALAR_PV:
          return newSVpvn(value->scalar_pv ? value->scalar_pv : "", value->scalar_pv_len);
        default:
          return newSV(0);
      }
  }
}

static gql_runtime_vm_native_args_payload_t *
gql_runtime_vm_native_args_payload_from_hv(pTHX_ HV *hv)
{
  HE *he;
  gql_runtime_vm_native_args_payload_t *payload;
  IV count = 0;

  if (!hv) {
    return NULL;
  }

  Newxz(payload, 1, gql_runtime_vm_native_args_payload_t);
  count = HvUSEDKEYS(hv);
  payload->count = count;
  if (count <= 0) {
    return payload;
  }

  Newxz(payload->names, count, char *);
  Newxz(payload->values, count, gql_runtime_vm_native_dynamic_value_t *);

  hv_iterinit(hv);
  count = 0;
  while ((he = hv_iternext(hv))) {
    SV *key_sv = hv_iterkeysv(he);
    SV *val_sv = hv_iterval(hv, he);
    STRLEN key_len = 0;
    const char *key_pv = key_sv ? SvPV(key_sv, key_len) : "";
    payload->names[count] = savepvn(key_pv, key_len);
    payload->values[count] = gql_runtime_vm_native_dynamic_value_from_sv(aTHX_ val_sv);
    count++;
  }
  payload->count = count;
  return payload;
}

static gql_runtime_vm_native_args_payload_t *
gql_runtime_vm_native_args_payload_clone(
  pTHX_ const gql_runtime_vm_native_args_payload_t *payload
)
{
  gql_runtime_vm_native_args_payload_t *copy;
  IV i;

  if (!payload) {
    return NULL;
  }

  Newxz(copy, 1, gql_runtime_vm_native_args_payload_t);
  copy->count = payload->count;
  if (copy->count <= 0) {
    return copy;
  }

  Newxz(copy->names, copy->count, char *);
  Newxz(copy->values, copy->count, gql_runtime_vm_native_dynamic_value_t *);
  for (i = 0; i < copy->count; i++) {
    copy->names[i] = payload->names[i] ? savepv(payload->names[i]) : NULL;
    copy->values[i] = gql_runtime_vm_native_dynamic_value_clone(aTHX_ payload->values[i]);
  }
  return copy;
}

static void
gql_runtime_vm_native_args_payload_destroy(pTHX_ gql_runtime_vm_native_args_payload_t *payload)
{
  IV i;
  if (!payload) {
    return;
  }
  for (i = 0; i < payload->count; i++) {
    Safefree(payload->names ? payload->names[i] : NULL);
    gql_runtime_vm_native_dynamic_value_destroy(payload->values ? payload->values[i] : NULL);
  }
  Safefree(payload->names);
  Safefree(payload->values);
  Safefree(payload);
}

static SV *
gql_runtime_vm_native_args_payload_materialize_sv(
  pTHX_ const gql_runtime_vm_native_args_payload_t *payload
)
{
  HV *hv;
  IV i;

  hv = newHV();
  if (!payload) {
    return newRV_noinc((SV *)hv);
  }

  for (i = 0; i < payload->count; i++) {
    if (!payload->names || !payload->names[i]) {
      continue;
    }
    hv_store(
      hv,
      payload->names[i],
      (I32)strlen(payload->names[i]),
      gql_runtime_vm_native_dynamic_value_materialize_sv(aTHX_ payload->values ? payload->values[i] : NULL, NULL),
      0
    );
  }

  return newRV_noinc((SV *)hv);
}

static gql_runtime_vm_native_directives_payload_t *
gql_runtime_vm_native_directives_payload_from_sv(pTHX_ SV *guards_sv)
{
  AV *guards_av;
  gql_runtime_vm_native_directives_payload_t *payload;
  IV i;

  if (!guards_sv || !SvOK(guards_sv) || !SvROK(guards_sv) || SvTYPE(SvRV(guards_sv)) != SVt_PVAV) {
    return NULL;
  }

  guards_av = (AV *)SvRV(guards_sv);
  Newxz(payload, 1, gql_runtime_vm_native_directives_payload_t);
  payload->count = av_len(guards_av) + 1;
  if (payload->count <= 0) {
    return payload;
  }
  Newxz(payload->guards, payload->count, gql_runtime_vm_native_guard_t);

  for (i = 0; i < payload->count; i++) {
    SV **directive_svp = av_fetch(guards_av, i, 0);
    HV *directive_hv;
    SV **name_svp;
    SV **arguments_svp;
    HV *arguments_hv;
    SV **if_svp;
    STRLEN name_len = 0;
    const char *name;

    if (!directive_svp || !SvOK(*directive_svp) || !SvROK(*directive_svp) || SvTYPE(SvRV(*directive_svp)) != SVt_PVHV) {
      continue;
    }
    directive_hv = (HV *)SvRV(*directive_svp);
    name_svp = hv_fetch(directive_hv, "name", 4, 0);
    arguments_svp = hv_fetch(directive_hv, "arguments", 9, 0);
    if (!name_svp || !SvOK(*name_svp) || !arguments_svp || !SvOK(*arguments_svp) || !SvROK(*arguments_svp) || SvTYPE(SvRV(*arguments_svp)) != SVt_PVHV) {
      continue;
    }
    arguments_hv = (HV *)SvRV(*arguments_svp);
    if_svp = hv_fetch(arguments_hv, "if", 2, 0);
    if (!if_svp || !SvOK(*if_svp)) {
      continue;
    }
    name = SvPV(*name_svp, name_len);
    if (name_len == 4 && memEQ(name, "skip", 4)) {
      payload->guards[i].kind_code = GQL_VM_GUARD_SKIP;
    } else {
      payload->guards[i].kind_code = GQL_VM_GUARD_INCLUDE;
    }
    payload->guards[i].if_expr = gql_runtime_vm_native_dynamic_value_from_sv(aTHX_ *if_svp);
  }

  return payload;
}

static gql_runtime_vm_native_directives_payload_t *
gql_runtime_vm_native_directives_payload_clone(
  pTHX_ const gql_runtime_vm_native_directives_payload_t *payload
)
{
  gql_runtime_vm_native_directives_payload_t *copy;
  IV i;

  if (!payload) {
    return NULL;
  }
  Newxz(copy, 1, gql_runtime_vm_native_directives_payload_t);
  copy->count = payload->count;
  if (copy->count <= 0) {
    return copy;
  }
  Newxz(copy->guards, copy->count, gql_runtime_vm_native_guard_t);
  for (i = 0; i < copy->count; i++) {
    copy->guards[i].kind_code = payload->guards[i].kind_code;
    copy->guards[i].if_expr = gql_runtime_vm_native_dynamic_value_clone(aTHX_ payload->guards[i].if_expr);
  }
  return copy;
}

static void
gql_runtime_vm_native_directives_payload_destroy(
  pTHX_ gql_runtime_vm_native_directives_payload_t *payload
)
{
  IV i;

  if (!payload) {
    return;
  }
  for (i = 0; i < payload->count; i++) {
    gql_runtime_vm_native_dynamic_value_destroy(aTHX_ payload->guards ? payload->guards[i].if_expr : NULL);
  }
  Safefree(payload->guards);
  Safefree(payload);
}

static int
gql_runtime_vm_evaluate_runtime_guards_native(
  pTHX_ const gql_runtime_vm_native_directives_payload_t *payload,
  HV *variables
)
{
  IV i;

  if (!payload) {
    return 1;
  }
  for (i = 0; i < payload->count; i++) {
    const gql_runtime_vm_native_guard_t *guard = &payload->guards[i];
    SV *if_value_sv = gql_runtime_vm_native_dynamic_value_materialize_sv(aTHX_ guard->if_expr, variables);
    int bool_value = SvTRUE(if_value_sv) ? 1 : 0;
    SvREFCNT_dec(if_value_sv);
    if (guard->kind_code == GQL_VM_GUARD_SKIP && bool_value) {
      return 0;
    }
    if (guard->kind_code == GQL_VM_GUARD_INCLUDE && !bool_value) {
      return 0;
    }
  }
  return 1;
}

static const gql_runtime_vm_native_slot_t *
gql_runtime_vm_effective_slot(
  const gql_runtime_vm_native_runtime_t *runtime,
  const gql_runtime_vm_native_slot_t *slot
)
{
  if (!runtime || !slot) {
    return slot;
  }
  if (slot->schema_slot_index >= 0 && slot->schema_slot_index < runtime->runtime_slot_count) {
    return &runtime->runtime_slots[slot->schema_slot_index];
  }
  return slot;
}

static SV *
gql_runtime_vm_new_cursor_handle(pTHX_ const char *pkg, gql_runtime_vm_cursor_t *cursor)
{
  return gql_runtime_vm_new_handle_sv(aTHX_ pkg, cursor);
}

static void
gql_runtime_vm_error_record_incref(gql_runtime_vm_error_record_t *record)
{
  if (record) {
    record->refcount++;
  }
}

static const char *
gql_runtime_vm_find_tagged_type_name(
  const gql_runtime_vm_native_runtime_t *runtime,
  IV slot_index,
  SV *tag_sv
)
{
  IV i;
  STRLEN tag_len = 0;
  const char *tag_name = NULL;
  gql_runtime_vm_native_tag_entry_t *entries;
  IV count;
  gql_runtime_vm_native_callback_catalog_t *catalog;

  if (!runtime || slot_index < 0 || slot_index >= runtime->runtime_slot_count || !tag_sv || !SvOK(tag_sv)) {
    return NULL;
  }
  catalog = runtime->callback_catalog;
  if (!catalog || !catalog->slot_tag_entries || !catalog->slot_tag_entry_counts) {
    return NULL;
  }
  entries = catalog->slot_tag_entries[slot_index];
  count = catalog->slot_tag_entry_counts[slot_index];
  if (!entries || count <= 0) {
    return NULL;
  }
  tag_name = SvPV(tag_sv, tag_len);
  if (!tag_name) {
    return NULL;
  }
  for (i = 0; i < count; i++) {
    const char *candidate = entries[i].tag_name;
    if (candidate && strlen(candidate) == (size_t)tag_len && memcmp(candidate, tag_name, (size_t)tag_len) == 0) {
      return entries[i].type_name;
    }
  }
  return NULL;
}

static gql_runtime_vm_native_possible_type_entry_t *
gql_runtime_vm_find_matching_possible_type(
  pTHX_
  const gql_runtime_vm_native_runtime_t *runtime,
  IV slot_index,
  SV *value,
  SV *context,
  SV *info,
  SV **error_out
)
{
  IV i;
  gql_runtime_vm_native_possible_type_entry_t *entries;
  IV count;
  gql_runtime_vm_native_callback_catalog_t *catalog;

  if (!runtime || slot_index < 0 || slot_index >= runtime->runtime_slot_count) {
    return NULL;
  }
  catalog = runtime->callback_catalog;
  if (!catalog || !catalog->slot_possible_type_entries || !catalog->slot_possible_type_entry_counts) {
    return NULL;
  }
  entries = catalog->slot_possible_type_entries[slot_index];
  count = catalog->slot_possible_type_entry_counts[slot_index];
  if (!entries || count <= 0) {
    return NULL;
  }

  for (i = 0; i < count; i++) {
    SV *ok_sv;
    if (!entries[i].type_sv || !entries[i].is_type_of_cb) {
      continue;
    }
    ok_sv = gql_runtime_vm_call_cb4_nonfatal(
      aTHX_
      entries[i].is_type_of_cb,
      value,
      context,
      info ? info : &PL_sv_undef,
      entries[i].type_sv,
      error_out
    );
    if (error_out && *error_out) {
      return NULL;
    }
    if (SvTRUE(ok_sv)) {
      SvREFCNT_dec(ok_sv);
      return &entries[i];
    }
    SvREFCNT_dec(ok_sv);
  }

  return NULL;
}

static void
gql_runtime_vm_error_record_decref(pTHX_ gql_runtime_vm_error_record_t *record)
{
  if (!record) {
    return;
  }
  if (record->refcount > 1) {
    record->refcount--;
    return;
  }
  if (record->message_pv) {
    Safefree(record->message_pv);
  }
  gql_runtime_vm_path_frame_decref(record->path_frame);
  Safefree(record);
}

static void
gql_runtime_vm_outcome_incref(gql_runtime_vm_outcome_t *outcome)
{
  if (outcome) {
    outcome->refcount++;
  }
}

static void
gql_runtime_vm_outcome_decref(pTHX_ gql_runtime_vm_outcome_t *outcome)
{
  IV i;
  if (!outcome) {
    return;
  }
  if (outcome->refcount > 1) {
    outcome->refcount--;
    return;
  }
  gql_runtime_vm_native_value_destroy(aTHX_ outcome->value);
  for (i = 0; i < outcome->error_record_count; i++) {
    gql_runtime_vm_error_record_decref(aTHX_ outcome->error_records[i]);
  }
  Safefree(outcome->error_records);
  Safefree(outcome);
}

static void
gql_runtime_vm_writer_push_error_record(gql_runtime_vm_writer_t *writer, gql_runtime_vm_error_record_t *record)
{
  if (!writer || !record) {
    return;
  }
  if (writer->error_record_count == writer->error_record_capacity) {
    writer->error_record_capacity = writer->error_record_capacity ? writer->error_record_capacity * 2 : 4;
    Renew(writer->error_records, writer->error_record_capacity, gql_runtime_vm_error_record_t *);
  }
  gql_runtime_vm_error_record_incref(record);
  writer->error_records[writer->error_record_count++] = record;
}

static void
gql_runtime_vm_block_frame_push_pending(pTHX_ gql_runtime_vm_block_frame_t *frame, SV *result_name, SV *outcome)
{
  STRLEN result_name_len = 0;
  const char *result_name_pv = NULL;
  gql_runtime_vm_pending_entry_t *entry = NULL;
  if (!frame || !result_name || !outcome) {
    return;
  }
  result_name_pv = SvPV(result_name, result_name_len);
  if (frame->pending_count == frame->pending_capacity) {
    frame->pending_capacity = frame->pending_capacity ? frame->pending_capacity * 2 : 4;
    Renew(frame->pending_entries, frame->pending_capacity, gql_runtime_vm_pending_entry_t);
  }
  entry = &frame->pending_entries[frame->pending_count];
  entry->result_name_pv = savepvn(result_name_pv, result_name_len);
  entry->result_name_len = result_name_len;
  if (sv_derived_from(outcome, "GraphQL::Houtou::Runtime::Outcome")) {
    entry->payload_kind = GQL_VM_PENDING_OUTCOME_PTR;
    entry->payload.outcome_ptr = gql_runtime_vm_expect_outcome(aTHX_ outcome);
    gql_runtime_vm_outcome_incref(entry->payload.outcome_ptr);
  } else {
    entry->payload_kind = GQL_VM_PENDING_PROMISE_SV;
    entry->payload.promise_sv = newSVsv(outcome);
  }
  frame->pending_count++;
}

static void
gql_runtime_vm_block_frame_clear_pending(pTHX_ gql_runtime_vm_block_frame_t *frame)
{
  IV i;
  if (!frame) {
    return;
  }
  for (i = 0; i < frame->pending_count; i++) {
    Safefree(frame->pending_entries[i].result_name_pv);
    if (frame->pending_entries[i].payload_kind == GQL_VM_PENDING_OUTCOME_PTR) {
      gql_runtime_vm_outcome_decref(aTHX_ frame->pending_entries[i].payload.outcome_ptr);
    } else if (frame->pending_entries[i].payload_kind == GQL_VM_PENDING_PROMISE_SV) {
      SvREFCNT_dec(frame->pending_entries[i].payload.promise_sv);
    }
  }
  Safefree(frame->pending_entries);
  frame->pending_entries = NULL;
  frame->pending_count = 0;
  frame->pending_capacity = 0;
}

static SV *
gql_runtime_vm_cursor_snapshot_sv(pTHX_ SV *cursor_sv)
{
  gql_runtime_vm_cursor_t *cursor;
  gql_runtime_vm_cursor_t *snapshot;

  if (!cursor_sv || !SvOK(cursor_sv) || !SvROK(cursor_sv)) {
    return newSVsv(&PL_sv_undef);
  }

  cursor = gql_runtime_vm_expect_cursor(aTHX_ cursor_sv);
  Newxz(snapshot, 1, gql_runtime_vm_cursor_t);
  snapshot->block = newSVsv(cursor->block ? cursor->block : &PL_sv_undef);
  snapshot->slot_index = cursor->slot_index;
  snapshot->op_index = cursor->op_index;

  return gql_runtime_vm_new_cursor_handle(aTHX_ "GraphQL::Houtou::Runtime::Cursor", snapshot);
}

static void
gql_runtime_vm_cursor_snapshot_copy(pTHX_ gql_runtime_vm_cursor_t *dst, const gql_runtime_vm_cursor_t *src)
{
  if (!dst) {
    return;
  }
  Zero(dst, 1, gql_runtime_vm_cursor_t);
  if (!src) {
    dst->block = newSVsv(&PL_sv_undef);
    return;
  }
  dst->block = newSVsv(src->block ? src->block : &PL_sv_undef);
  dst->slot_index = src->slot_index;
  dst->op_index = src->op_index;
}

static void
gql_runtime_vm_cursor_destroy_copy(pTHX_ gql_runtime_vm_cursor_t *cursor)
{
  if (!cursor) {
    return;
  }
  SvREFCNT_dec(cursor->block);
  Zero(cursor, 1, gql_runtime_vm_cursor_t);
}

static void
gql_runtime_vm_cursor_restore_copy(pTHX_ gql_runtime_vm_cursor_t *dst, const gql_runtime_vm_cursor_t *src)
{
  if (!dst) {
    return;
  }
  SvREFCNT_dec(dst->block);
  gql_runtime_vm_cursor_snapshot_copy(aTHX_ dst, src);
}

static void
gql_runtime_vm_cursor_restore_sv(pTHX_ gql_runtime_vm_cursor_t *dst, SV *snapshot_sv)
{
  gql_runtime_vm_cursor_t *src;

  if (!dst || !snapshot_sv || !SvOK(snapshot_sv) || !SvROK(snapshot_sv)) {
    return;
  }

  src = gql_runtime_vm_expect_cursor(aTHX_ snapshot_sv);
  SvREFCNT_dec(dst->block);
  gql_runtime_vm_cursor_snapshot_copy(aTHX_ dst, src);
}

static AV *
gql_runtime_vm_expect_error_records_av(pTHX_ SV *error_records)
{
  if (error_records && SvOK(error_records) && SvROK(error_records) && SvTYPE(SvRV(error_records)) == SVt_PVAV) {
    return (AV *)SvRV(error_records);
  }
  return newAV();
}

static gql_runtime_vm_error_record_t *
gql_runtime_vm_new_error_record_struct(pTHX_ SV *message, SV *path_frame)
{
  gql_runtime_vm_error_record_t *record;
  STRLEN len = 0;
  const char *pv = NULL;

  Newxz(record, 1, gql_runtime_vm_error_record_t);
  record->refcount = 1;
  if (message && SvOK(message)) {
    pv = SvPV(message, len);
    Newxz(record->message_pv, len + 1, char);
    Copy(pv, record->message_pv, len, char);
    record->message_pv[len] = '\0';
  }
  if (path_frame && SvOK(path_frame) && SvROK(path_frame) && SvIOK(SvRV(path_frame)) && SvUV(SvRV(path_frame)) != 0) {
    record->path_frame = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(path_frame)));
    record->path_frame->refcount++;
  } else {
    record->path_frame = NULL;
  }
  return record;
}

static SV *
gql_runtime_vm_path_frame_key_sv(pTHX_ const gql_runtime_vm_path_frame_t *frame)
{
  if (!frame) {
    return newSV(0);
  }
  if (frame->key_kind == 1) {
    return newSViv(frame->key_iv);
  }
  if (frame->key_pv) {
    return newSVpv(frame->key_pv, 0);
  }
  return newSV(0);
}

static void
gql_runtime_vm_path_frame_decref(gql_runtime_vm_path_frame_t *frame)
{
  if (!frame) {
    return;
  }
  if (frame->refcount > 0) {
    frame->refcount--;
  }
  if (frame->refcount == 0) {
    gql_runtime_vm_path_frame_t *parent = frame->parent;
    Safefree(frame->key_pv);
    Safefree(frame);
    gql_runtime_vm_path_frame_decref(parent);
  }
}

static SV *
gql_runtime_vm_path_frame_to_path_sv(pTHX_ gql_runtime_vm_path_frame_t *path_frame)
{
  AV *segments = newAV();
  AV *path_av = newAV();
  gql_runtime_vm_path_frame_t *cursor = path_frame;
  SSize_t i;

  while (cursor) {
    av_push(segments, gql_runtime_vm_path_frame_key_sv(aTHX_ cursor));
    cursor = cursor->parent;
  }

  for (i = av_len(segments); i >= 0; i--) {
    SV **svp = av_fetch(segments, i, 0);
    if (svp && *svp) {
      av_push(path_av, newSVsv(*svp));
    }
  }

  SvREFCNT_dec((SV *)segments);
  return newRV_noinc((SV *)path_av);
}

static SV *
gql_runtime_vm_error_record_to_error_sv(pTHX_ const gql_runtime_vm_error_record_t *record)
{
  HV *error_hv = newHV();
  SV *path_sv = NULL;

  if (!record) {
    return newRV_noinc((SV *)error_hv);
  }

  hv_store(error_hv, "message", 7, record->message_pv ? newSVpv(record->message_pv, 0) : newSVsv(&PL_sv_undef), 0);

  if (record->path_frame) {
    path_sv = gql_runtime_vm_path_frame_to_path_sv(aTHX_ record->path_frame);
    if (path_sv && SvOK(path_sv) && SvROK(path_sv) && SvTYPE(SvRV(path_sv)) == SVt_PVAV && av_count((AV *)SvRV(path_sv)) > 0) {
      hv_store(error_hv, "path", 4, path_sv, 0);
      path_sv = NULL;
    }
  }

  if (path_sv) {
    SvREFCNT_dec(path_sv);
  }

  return newRV_noinc((SV *)error_hv);
}

static gql_runtime_vm_outcome_t *
gql_runtime_vm_new_outcome_struct(pTHX_ U8 kind_code, SV *value, SV *error_records)
{
  gql_runtime_vm_outcome_t *outcome;
  AV *errors_av = gql_runtime_vm_expect_error_records_av(aTHX_ error_records);
  SSize_t i;

  Newxz(outcome, 1, gql_runtime_vm_outcome_t);
  outcome->refcount = 1;
  outcome->kind_code = kind_code;
  switch (kind_code) {
    case GQL_VM_KIND_OBJECT:
      if (value && SvOK(value)) {
        if (SvROK(value) && SvTYPE(SvRV(value)) == SVt_PVHV) {
          HV *src_hv = (HV *)SvRV(value);
          HE *he;
          outcome->value = gql_runtime_vm_new_native_value_object();
          hv_iterinit(src_hv);
          while ((he = hv_iternext(src_hv)) != NULL) {
            SV *key_sv = hv_iterkeysv(he);
            SV *val_sv = hv_iterval(src_hv, he);
            STRLEN key_len = 0;
            const char *key_pv = SvPV(key_sv, key_len);
            gql_runtime_vm_native_object_store(
              aTHX_
              outcome->value,
              key_pv,
              gql_runtime_vm_new_native_value_scalar(aTHX_ val_sv ? val_sv : &PL_sv_undef)
            );
          }
        } else {
          outcome->value = gql_runtime_vm_new_native_value_scalar(aTHX_ value);
        }
      } else {
        outcome->value = gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
      }
      break;
    case GQL_VM_KIND_LIST:
      if (value && SvOK(value) && SvROK(value) && SvTYPE(SvRV(value)) == SVt_PVAV) {
        AV *src_av = (AV *)SvRV(value);
        SSize_t max = av_len(src_av);
        outcome->value = gql_runtime_vm_new_native_value_list();
        for (i = 0; i <= max; i++) {
          SV **svp = av_fetch(src_av, i, 0);
          gql_runtime_vm_native_list_push(
            outcome->value,
            gql_runtime_vm_new_native_value_scalar(aTHX_ (svp && *svp) ? *svp : &PL_sv_undef)
          );
        }
      } else {
        outcome->value = gql_runtime_vm_new_native_value_scalar(aTHX_ value ? value : &PL_sv_undef);
      }
      break;
    case GQL_VM_KIND_SCALAR:
    default:
      outcome->value = gql_runtime_vm_new_native_value_scalar(aTHX_ value ? value : &PL_sv_undef);
      break;
  }
  outcome->error_record_count = av_count(errors_av);
  if (outcome->error_record_count > 0) {
    Newxz(outcome->error_records, outcome->error_record_count, gql_runtime_vm_error_record_t *);
    for (i = 0; i < outcome->error_record_count; i++) {
      SV **svp = av_fetch(errors_av, i, 0);
      if (svp && *svp && SvOK(*svp)) {
        gql_runtime_vm_error_record_t *record = gql_runtime_vm_expect_error_record(aTHX_ *svp);
        gql_runtime_vm_error_record_incref(record);
        outcome->error_records[i] = record;
      }
    }
  }

  return outcome;
}

static SV *
gql_runtime_vm_outcome_kind_sv(pTHX_ const gql_runtime_vm_outcome_t *outcome)
{
  if (!outcome) {
    return newSVpvs("");
  }
  switch (outcome->kind_code) {
    case GQL_VM_KIND_SCALAR:
      return newSVpvs("SCALAR");
    case GQL_VM_KIND_OBJECT:
      return newSVpvs("OBJECT");
    case GQL_VM_KIND_LIST:
      return newSVpvs("LIST");
    default:
      return newSVpvs("");
  }
}

static gql_runtime_vm_writer_t *
gql_runtime_vm_new_writer_struct(pTHX_)
{
  gql_runtime_vm_writer_t *writer;

  Newxz(writer, 1, gql_runtime_vm_writer_t);
  writer->refcount = 1;
  return writer;
}

static void
gql_runtime_vm_consume_outcome_struct(pTHX_ HV *data_hv, SV *result_name_sv, const gql_runtime_vm_outcome_t *outcome, gql_runtime_vm_writer_t *writer)
{
  IV i;

  if (!data_hv || !result_name_sv || !outcome) {
    return;
  }

  hv_store_ent(
    data_hv,
    result_name_sv,
    outcome->value ? gql_runtime_vm_native_value_materialize_sv(aTHX_ outcome->value) : newSV(0),
    0
  );

  if (!writer) {
    return;
  }

  for (i = 0; i < outcome->error_record_count; i++) {
    gql_runtime_vm_writer_push_error_record(writer, outcome->error_records[i]);
  }
}

static void
gql_runtime_vm_consume_outcome_native_object(
  pTHX_
  gql_runtime_vm_native_value_t *data_value,
  const char *result_name_pv,
  const gql_runtime_vm_outcome_t *outcome,
  gql_runtime_vm_writer_t *writer
)
{
  IV i;

  if (!data_value || data_value->kind_code != GQL_VM_NATIVE_VALUE_OBJECT || !result_name_pv || !outcome) {
    return;
  }

  gql_runtime_vm_native_object_store(
    aTHX_ data_value,
    result_name_pv,
    outcome->value ? gql_runtime_vm_native_value_clone(aTHX_ outcome->value)
                   : gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef)
  );

  if (!writer) {
    return;
  }

  for (i = 0; i < outcome->error_record_count; i++) {
    gql_runtime_vm_writer_push_error_record(writer, outcome->error_records[i]);
  }
}

static SV *
gql_runtime_vm_writer_materialize_errors_sv(pTHX_ const gql_runtime_vm_writer_t *writer)
{
  AV *errors_av = newAV();
  IV i;

  if (!writer) {
    return newRV_noinc((SV *)errors_av);
  }

  for (i = 0; i < writer->error_record_count; i++) {
    av_push(errors_av, gql_runtime_vm_error_record_to_error_sv(aTHX_ writer->error_records[i]));
  }

  return newRV_noinc((SV *)errors_av);
}

static SV *
gql_runtime_vm_dispatch_hash_fetch(pTHX_ SV *dispatch_sv, const char *key, STRLEN key_len)
{
  HV *hv;
  SV **svp;
  if (!dispatch_sv || !SvOK(dispatch_sv) || !SvROK(dispatch_sv) || SvTYPE(SvRV(dispatch_sv)) != SVt_PVHV) {
    return NULL;
  }
  hv = (HV *)SvRV(dispatch_sv);
  svp = hv_fetch(hv, key, (I32)key_len, 0);
  return svp ? *svp : NULL;
}

static SV *
gql_runtime_vm_hash_lookup_ent_sv(pTHX_ SV *hv_sv, SV *key_sv)
{
  HE *he;
  HV *hv;
  if (!hv_sv || !SvOK(hv_sv) || !SvROK(hv_sv) || SvTYPE(SvRV(hv_sv)) != SVt_PVHV || !key_sv) {
    return NULL;
  }
  hv = (HV *)SvRV(hv_sv);
  he = hv_fetch_ent(hv, key_sv, 0, 0);
  return he ? HeVAL(he) : NULL;
}

static SV *
gql_runtime_vm_call_cb_scalar(pTHX_ SV *cb, SV *value, SV *context, SV *info, SV *type_like, SV **error_out)
{
  dSP;
  SV *result = NULL;
  if (error_out) {
    *error_out = NULL;
  }
  if (!cb || !SvOK(cb)) {
    return NULL;
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(value ? value : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(context ? context : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(info ? info : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(type_like ? type_like : &PL_sv_undef)));
  PUTBACK;

  if (call_sv(cb, G_SCALAR | G_EVAL) > 0) {
    SPAGAIN;
    result = POPs;
    result = result ? newSVsv(result) : NULL;
    PUTBACK;
  }

  if (SvTRUE(ERRSV)) {
    if (error_out) {
      *error_out = newSVsv(ERRSV);
    }
    sv_setsv(ERRSV, &PL_sv_undef);
    result = NULL;
  }

  FREETMPS;
  LEAVE;
  return result;
}

static SV *
gql_runtime_vm_resolve_runtime_type_sv(
  pTHX_
  SV *dispatch_sv,
  SV *cache_sv,
  SV *value,
  SV *context,
  SV *info,
  SV *abstract_type,
  SV **error_out
)
{
  SV *tag_resolver;
  SV *tag_map_sv;
  SV *resolve_type;
  SV *name2type_sv;
  SV *possible_types_sv;
  SV *is_type_of_map_sv;
  SV *tmp_error = NULL;
  SV *resolved = NULL;

  if (error_out) {
    *error_out = NULL;
  }

  tag_resolver = gql_runtime_vm_dispatch_hash_fetch(aTHX_ dispatch_sv, "tag_resolver", 12);
  tag_map_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ dispatch_sv, "tag_map", 7);
  resolve_type = gql_runtime_vm_dispatch_hash_fetch(aTHX_ dispatch_sv, "resolve_type", 12);
  name2type_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ dispatch_sv, "name2type", 9);
  possible_types_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ dispatch_sv, "possible_types", 14);
  is_type_of_map_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ dispatch_sv, "is_type_of_map", 14);

  if (!name2type_sv) {
    name2type_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ cache_sv, "name2type", 9);
  }
  if (!possible_types_sv) {
    SV *possible_types_map = gql_runtime_vm_dispatch_hash_fetch(aTHX_ cache_sv, "possible_types", 14);
    SV *abstract_name = gql_runtime_vm_dispatch_hash_fetch(aTHX_ dispatch_sv, "abstract_name", 13);
    possible_types_sv = gql_runtime_vm_hash_lookup_ent_sv(aTHX_ possible_types_map, abstract_name);
  }
  if (!is_type_of_map_sv) {
    is_type_of_map_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ cache_sv, "is_type_of_map", 14);
  }

  if (tag_resolver) {
    SV *tag = gql_runtime_vm_call_cb_scalar(aTHX_ tag_resolver, value, context, info, abstract_type, &tmp_error);
    if (tmp_error) {
      if (error_out) *error_out = tmp_error;
      return NULL;
    }
    if (tag && SvOK(tag)) {
      SV *mapped = gql_runtime_vm_hash_lookup_ent_sv(aTHX_ tag_map_sv, tag);
      SvREFCNT_dec(tag);
      if (mapped && SvOK(mapped)) {
        return newSVsv(mapped);
      }
    } else if (tag) {
      SvREFCNT_dec(tag);
    }
  }

  if (resolve_type) {
    resolved = gql_runtime_vm_call_cb_scalar(aTHX_ resolve_type, value, context, info, abstract_type, &tmp_error);
    if (tmp_error) {
      if (error_out) *error_out = tmp_error;
      return NULL;
    }
    if (resolved && SvOK(resolved)) {
      if (SvROK(resolved)) {
        return resolved;
      }
      else {
        SV *mapped = gql_runtime_vm_hash_lookup_ent_sv(aTHX_ name2type_sv, resolved);
        SvREFCNT_dec(resolved);
        return mapped && SvOK(mapped) ? newSVsv(mapped) : NULL;
      }
    } else if (resolved) {
      SvREFCNT_dec(resolved);
    }
  }

  if (possible_types_sv && SvOK(possible_types_sv) && SvROK(possible_types_sv) && SvTYPE(SvRV(possible_types_sv)) == SVt_PVAV) {
    AV *possible_types_av = (AV *)SvRV(possible_types_sv);
    SSize_t i;
    for (i = 0; i <= av_len(possible_types_av); i++) {
      SV **type_svp = av_fetch(possible_types_av, i, 0);
      SV *type_sv;
      SV *type_name_sv;
      SV *cb;
      SV *matched;
      if (!type_svp || !(type_sv = *type_svp) || !SvOK(type_sv)) {
        continue;
      }
      type_name_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ type_sv, "name", 4);
      if (!type_name_sv) {
        dSP;
        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        XPUSHs(sv_2mortal(newSVsv(type_sv)));
        PUTBACK;
        if (call_method("name", G_SCALAR) > 0) {
          SPAGAIN;
          type_name_sv = POPs;
          type_name_sv = type_name_sv ? newSVsv(type_name_sv) : NULL;
          PUTBACK;
        }
        FREETMPS;
        LEAVE;
      } else {
        type_name_sv = newSVsv(type_name_sv);
      }
      cb = gql_runtime_vm_hash_lookup_ent_sv(aTHX_ is_type_of_map_sv, type_name_sv);
      SvREFCNT_dec(type_name_sv);
      if (!cb || !SvOK(cb)) {
        continue;
      }
      matched = gql_runtime_vm_call_cb_scalar(aTHX_ cb, value, context, info, type_sv, &tmp_error);
      if (tmp_error) {
        if (error_out) *error_out = tmp_error;
        return NULL;
      }
      if (matched && SvTRUE(matched)) {
        SvREFCNT_dec(matched);
        return newSVsv(type_sv);
      }
      if (matched) {
        SvREFCNT_dec(matched);
      }
    }
  }

  return NULL;
}

static SV *
gql_runtime_vm_resolve_runtime_type_for_abstract_sv(
  pTHX_
  SV *cache_sv,
  const char *abstract_name,
  SV *value,
  SV *context,
  SV *info,
  SV *abstract_type,
  SV **error_out
)
{
  SV *tag_resolver = NULL;
  SV *tag_map_sv = NULL;
  SV *resolve_type = NULL;
  SV *name2type_sv = NULL;
  SV *possible_types_sv = NULL;
  SV *is_type_of_map_sv = NULL;
  SV *tmp_error = NULL;
  SV *resolved = NULL;

  if (error_out) {
    *error_out = NULL;
  }

  if (!cache_sv || !SvOK(cache_sv) || !SvROK(cache_sv) || SvTYPE(SvRV(cache_sv)) != SVt_PVHV || !abstract_name) {
    return NULL;
  }

  {
    SV *abstract_name_sv = newSVpv(abstract_name, 0);
    SV *tag_resolver_map_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ cache_sv, "tag_resolver_map", 16);
    SV *runtime_tag_map_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ cache_sv, "runtime_tag_map", 15);
    SV *resolve_type_map_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ cache_sv, "resolve_type_map", 16);
    SV *possible_types_map_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ cache_sv, "possible_types", 14);

    name2type_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ cache_sv, "name2type", 9);
    is_type_of_map_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ cache_sv, "is_type_of_map", 14);

    if (tag_resolver_map_sv) {
      tag_resolver = gql_runtime_vm_hash_lookup_ent_sv(aTHX_ tag_resolver_map_sv, abstract_name_sv);
    }
    if (runtime_tag_map_sv) {
      tag_map_sv = gql_runtime_vm_hash_lookup_ent_sv(aTHX_ runtime_tag_map_sv, abstract_name_sv);
    }
    if (resolve_type_map_sv) {
      resolve_type = gql_runtime_vm_hash_lookup_ent_sv(aTHX_ resolve_type_map_sv, abstract_name_sv);
    }
    if (possible_types_map_sv) {
      possible_types_sv = gql_runtime_vm_hash_lookup_ent_sv(aTHX_ possible_types_map_sv, abstract_name_sv);
    }

    SvREFCNT_dec(abstract_name_sv);
  }

  if (tag_resolver) {
    SV *tag = gql_runtime_vm_call_cb_scalar(aTHX_ tag_resolver, value, context, info, abstract_type, &tmp_error);
    if (tmp_error) {
      if (error_out) *error_out = tmp_error;
      return NULL;
    }
    if (tag && SvOK(tag)) {
      SV *mapped = gql_runtime_vm_hash_lookup_ent_sv(aTHX_ tag_map_sv, tag);
      SvREFCNT_dec(tag);
      if (mapped && SvOK(mapped)) {
        return newSVsv(mapped);
      }
    } else if (tag) {
      SvREFCNT_dec(tag);
    }
  }

  if (resolve_type) {
    resolved = gql_runtime_vm_call_cb_scalar(aTHX_ resolve_type, value, context, info, abstract_type, &tmp_error);
    if (tmp_error) {
      if (error_out) *error_out = tmp_error;
      return NULL;
    }
    if (resolved && SvOK(resolved)) {
      if (SvROK(resolved)) {
        return resolved;
      }
      else {
        SV *mapped = gql_runtime_vm_hash_lookup_ent_sv(aTHX_ name2type_sv, resolved);
        SvREFCNT_dec(resolved);
        return mapped && SvOK(mapped) ? newSVsv(mapped) : NULL;
      }
    } else if (resolved) {
      SvREFCNT_dec(resolved);
    }
  }

  if (possible_types_sv && SvOK(possible_types_sv) && SvROK(possible_types_sv) && SvTYPE(SvRV(possible_types_sv)) == SVt_PVAV) {
    AV *possible_types_av = (AV *)SvRV(possible_types_sv);
    SSize_t i;
    for (i = 0; i <= av_len(possible_types_av); i++) {
      SV **type_svp = av_fetch(possible_types_av, i, 0);
      SV *type_sv;
      SV *type_name_sv;
      SV *cb;
      SV *matched;
      if (!type_svp || !(type_sv = *type_svp) || !SvOK(type_sv)) {
        continue;
      }
      type_name_sv = gql_runtime_vm_dispatch_hash_fetch(aTHX_ type_sv, "name", 4);
      if (!type_name_sv) {
        dSP;
        ENTER;
        SAVETMPS;
        PUSHMARK(SP);
        XPUSHs(sv_2mortal(newSVsv(type_sv)));
        PUTBACK;
        if (call_method("name", G_SCALAR) > 0) {
          SPAGAIN;
          type_name_sv = POPs;
          type_name_sv = type_name_sv ? newSVsv(type_name_sv) : NULL;
          PUTBACK;
        }
        FREETMPS;
        LEAVE;
      } else {
        type_name_sv = newSVsv(type_name_sv);
      }
      cb = gql_runtime_vm_hash_lookup_ent_sv(aTHX_ is_type_of_map_sv, type_name_sv);
      SvREFCNT_dec(type_name_sv);
      if (!cb || !SvOK(cb)) {
        continue;
      }
      matched = gql_runtime_vm_call_cb_scalar(aTHX_ cb, value, context, info, type_sv, &tmp_error);
      if (tmp_error) {
        if (error_out) *error_out = tmp_error;
        return NULL;
      }
      if (matched && SvTRUE(matched)) {
        SvREFCNT_dec(matched);
        return newSVsv(type_sv);
      }
      if (matched) {
        SvREFCNT_dec(matched);
      }
    }
  }

  return NULL;
}

static SV *
gql_runtime_vm_materialize_dynamic_value_sv(pTHX_ SV *value, HV *variables)
{
  SV *inner;

  if (!value || !SvOK(value)) {
    return newSV(0);
  }

  if (!SvROK(value)) {
    return newSVsv(value);
  }

  inner = SvRV(value);

  if (SvTYPE(inner) == SVt_PVAV) {
    AV *src = (AV *)inner;
    AV *dst = newAV();
    SSize_t max = av_len(src);
    SSize_t i;
    av_extend(dst, max);
    for (i = 0; i <= max; i++) {
      SV **svp = av_fetch(src, i, 0);
      av_store(dst, i, gql_runtime_vm_materialize_dynamic_value_sv(
        aTHX_
        (svp ? *svp : &PL_sv_undef),
        variables
      ));
    }
    return newRV_noinc((SV *)dst);
  }

  if (SvTYPE(inner) == SVt_PVHV) {
    HV *src = (HV *)inner;
    HV *dst = newHV();
    HE *he;
    (void)hv_iterinit(src);
    while ((he = hv_iternext(src))) {
      SV *key_sv = HeSVKEY_force(he);
      SV *val_sv = HeVAL(he);
      hv_store_ent(
        dst,
        newSVsv(key_sv),
        gql_runtime_vm_materialize_dynamic_value_sv(aTHX_ val_sv, variables),
        0
      );
    }
    return newRV_noinc((SV *)dst);
  }

  if (SvROK(inner)) {
    return newSVsv(SvRV(inner));
  }

  if (variables) {
    STRLEN len;
    const char *name = SvPV(inner, len);
    SV **svp = hv_fetch(variables, name, (I32)len, 0);
    return svp ? newSVsv(*svp) : newSV(0);
  }

  return newSV(0);
}

static int
gql_runtime_vm_evaluate_runtime_guards_hv(pTHX_ SV *guards_sv, HV *variables)
{
  AV *guards_av;
  SSize_t i;

  if (!guards_sv || !SvOK(guards_sv) || !SvROK(guards_sv) || SvTYPE(SvRV(guards_sv)) != SVt_PVAV) {
    return 1;
  }

  guards_av = (AV *)SvRV(guards_sv);
  for (i = 0; i <= av_len(guards_av); i++) {
    SV **directive_svp = av_fetch(guards_av, i, 0);
    SV *directive_sv;
    HV *directive_hv;
    SV **name_svp;
    SV **arguments_svp;
    HV *arguments_hv;
    SV **if_svp;
    SV *if_value_sv;
    int bool_value;
    STRLEN name_len;
    const char *name;

    if (!directive_svp || !(directive_sv = *directive_svp) || !SvOK(directive_sv)) {
      continue;
    }
    if (!SvROK(directive_sv) || SvTYPE(SvRV(directive_sv)) != SVt_PVHV) {
      continue;
    }
    directive_hv = (HV *)SvRV(directive_sv);
    name_svp = hv_fetch(directive_hv, "name", 4, 0);
    arguments_svp = hv_fetch(directive_hv, "arguments", 9, 0);
    if (!name_svp || !SvOK(*name_svp) || !arguments_svp || !SvOK(*arguments_svp)) {
      continue;
    }
    if (!SvROK(*arguments_svp) || SvTYPE(SvRV(*arguments_svp)) != SVt_PVHV) {
      continue;
    }
    arguments_hv = (HV *)SvRV(*arguments_svp);
    if_svp = hv_fetch(arguments_hv, "if", 2, 0);
    if (!if_svp) {
      continue;
    }

    if_value_sv = gql_runtime_vm_materialize_dynamic_value_sv(
      aTHX_
      *if_svp,
      variables
    );
    bool_value = SvTRUE(if_value_sv) ? 1 : 0;
    SvREFCNT_dec(if_value_sv);

    name = SvPV(*name_svp, name_len);
    if (name_len == 4 && memEQ(name, "skip", 4) && bool_value) {
      return 0;
    }
    if (name_len == 7 && memEQ(name, "include", 7) && !bool_value) {
      return 0;
    }
  }

  return 1;
}

static void
gql_runtime_vm_native_bundle_destroy(gql_runtime_vm_native_bundle_t *bundle)
{
  IV i;
  IV j;
  if (!bundle) {
    return;
  }
  if (bundle->runtime_slots) {
    if (bundle->owns_runtime_slots) {
      for (i = 0; i < bundle->runtime_slot_count; i++) {
        Safefree(bundle->runtime_slots[i].field_name);
        Safefree(bundle->runtime_slots[i].result_name);
        Safefree(bundle->runtime_slots[i].return_type_name);
        gql_runtime_vm_free_native_arg_defs(aTHX_ bundle->runtime_slots[i].arg_defs, bundle->runtime_slots[i].arg_def_count);
      }
    }
  }
  Safefree(bundle->runtime_slots);
  if (bundle->blocks && bundle->owns_blocks) {
    for (i = 0; i < bundle->block_count; i++) {
      Safefree(bundle->blocks[i].type_name);
      if (bundle->blocks[i].slots) {
        for (j = 0; j < bundle->blocks[i].slot_count; j++) {
          Safefree(bundle->blocks[i].slots[j].field_name);
          Safefree(bundle->blocks[i].slots[j].result_name);
          Safefree(bundle->blocks[i].slots[j].return_type_name);
          gql_runtime_vm_free_native_arg_defs(aTHX_ bundle->blocks[i].slots[j].arg_defs, bundle->blocks[i].slots[j].arg_def_count);
        }
      }
      if (bundle->blocks[i].ops) {
        for (j = 0; j < bundle->blocks[i].op_count; j++) {
          Safefree(bundle->blocks[i].ops[j].abstract_child_names);
          Safefree(bundle->blocks[i].ops[j].abstract_child_indexes);
          gql_runtime_vm_native_args_payload_destroy(aTHX_ bundle->blocks[i].ops[j].args_payload_native);
          gql_runtime_vm_native_directives_payload_destroy(aTHX_ bundle->blocks[i].ops[j].directives_payload_native);
        }
      }
      Safefree(bundle->blocks[i].slots);
      Safefree(bundle->blocks[i].ops);
    }
  }
  Safefree(bundle->blocks);
  Safefree(bundle);
}

static void
gql_runtime_vm_native_program_destroy(gql_runtime_vm_native_program_t *program)
{
  IV i;
  IV j;
  if (!program) {
    return;
  }
  if (program->blocks) {
    for (i = 0; i < program->block_count; i++) {
      Safefree(program->blocks[i].type_name);
      if (program->blocks[i].slots) {
        for (j = 0; j < program->blocks[i].slot_count; j++) {
          Safefree(program->blocks[i].slots[j].field_name);
          Safefree(program->blocks[i].slots[j].result_name);
          Safefree(program->blocks[i].slots[j].return_type_name);
          gql_runtime_vm_free_native_arg_defs(aTHX_ program->blocks[i].slots[j].arg_defs, program->blocks[i].slots[j].arg_def_count);
        }
      }
      if (program->blocks[i].ops) {
        for (j = 0; j < program->blocks[i].op_count; j++) {
          Safefree(program->blocks[i].ops[j].abstract_child_names);
          Safefree(program->blocks[i].ops[j].abstract_child_indexes);
          gql_runtime_vm_native_args_payload_destroy(aTHX_ program->blocks[i].ops[j].args_payload_native);
          gql_runtime_vm_native_directives_payload_destroy(aTHX_ program->blocks[i].ops[j].directives_payload_native);
        }
      }
      Safefree(program->blocks[i].slots);
      Safefree(program->blocks[i].ops);
    }
  }
  Safefree(program->blocks);
  Safefree(program);
}

static void
gql_runtime_vm_native_runtime_destroy(gql_runtime_vm_native_runtime_t *runtime)
{
  IV i;
  if (!runtime) {
    return;
  }
  if (runtime->runtime_slots) {
    for (i = 0; i < runtime->runtime_slot_count; i++) {
      Safefree(runtime->runtime_slots[i].field_name);
      Safefree(runtime->runtime_slots[i].result_name);
      Safefree(runtime->runtime_slots[i].return_type_name);
      gql_runtime_vm_free_native_arg_defs(aTHX_ runtime->runtime_slots[i].arg_defs, runtime->runtime_slots[i].arg_def_count);
    }
  }
  Safefree(runtime->runtime_slots);
  if (runtime->callback_catalog && runtime->callback_catalog->slot_resolvers) {
    gql_runtime_vm_native_callback_catalog_t *catalog = runtime->callback_catalog;
    for (i = 0; i < runtime->runtime_slot_count; i++) {
      if (catalog->slot_resolvers[i]) {
        SvREFCNT_dec(catalog->slot_resolvers[i]);
      }
      if (catalog->slot_type_objects && catalog->slot_type_objects[i]) {
        SvREFCNT_dec(catalog->slot_type_objects[i]);
      }
      if (catalog->slot_tag_resolvers && catalog->slot_tag_resolvers[i]) {
        SvREFCNT_dec(catalog->slot_tag_resolvers[i]);
      }
      if (catalog->slot_resolve_types && catalog->slot_resolve_types[i]) {
        SvREFCNT_dec(catalog->slot_resolve_types[i]);
      }
      if (catalog->slot_tag_entries && catalog->slot_tag_entries[i]) {
        IV j;
        for (j = 0; j < catalog->slot_tag_entry_counts[i]; j++) {
          Safefree(catalog->slot_tag_entries[i][j].tag_name);
          Safefree(catalog->slot_tag_entries[i][j].type_name);
        }
        Safefree(catalog->slot_tag_entries[i]);
      }
      if (catalog->slot_possible_type_entries && catalog->slot_possible_type_entries[i]) {
        IV j;
        for (j = 0; j < catalog->slot_possible_type_entry_counts[i]; j++) {
          Safefree(catalog->slot_possible_type_entries[i][j].type_name);
          SvREFCNT_dec(catalog->slot_possible_type_entries[i][j].type_sv);
          SvREFCNT_dec(catalog->slot_possible_type_entries[i][j].is_type_of_cb);
        }
        Safefree(catalog->slot_possible_type_entries[i]);
      }
    }
    Safefree(catalog->slot_resolvers);
    Safefree(catalog->slot_type_objects);
    Safefree(catalog->slot_tag_resolvers);
    Safefree(catalog->slot_tag_entries);
    Safefree(catalog->slot_tag_entry_counts);
    Safefree(catalog->slot_resolve_types);
    Safefree(catalog->slot_possible_type_entries);
    Safefree(catalog->slot_possible_type_entry_counts);
    if (catalog->runtime_schema) {
      SvREFCNT_dec(catalog->runtime_schema);
    }
    Safefree(catalog);
  }
  Safefree(runtime);
}

static int
gql_runtime_vm_fetch_hv_string(pTHX_ HV *hv, const char *key, I32 keylen, char **out)
{
  SV **svp = hv_fetch(hv, key, keylen, 0);
  STRLEN len;
  const char *pv;
  if (!svp || !SvOK(*svp)) {
    return 0;
  }
  pv = SvPV(*svp, len);
  Newxz(*out, len + 1, char);
  Copy(pv, *out, len, char);
  (*out)[len] = '\0';
  return 1;
}

static void
gql_runtime_vm_free_native_arg_defs(pTHX_ gql_runtime_vm_native_arg_def_t *arg_defs, IV count)
{
  IV i;
  if (!arg_defs) {
    return;
  }
  for (i = 0; i < count; i++) {
    Safefree(arg_defs[i].name);
    if (arg_defs[i].type_def_sv) {
      SvREFCNT_dec(arg_defs[i].type_def_sv);
    }
    if (arg_defs[i].input_type_sv) {
      SvREFCNT_dec(arg_defs[i].input_type_sv);
    }
    if (arg_defs[i].default_value_sv) {
      SvREFCNT_dec(arg_defs[i].default_value_sv);
    }
    if (arg_defs[i].default_native_value) {
      gql_runtime_vm_native_value_destroy(aTHX_ arg_defs[i].default_native_value);
    }
  }
  Safefree(arg_defs);
}

static int
gql_runtime_vm_parse_native_arg_defs(pTHX_ SV *sv, gql_runtime_vm_native_arg_def_t **out_defs, IV *out_count)
{
  AV *defs_av;
  HV *defs_hv;
  IV i;
  *out_defs = NULL;
  *out_count = 0;
  if (!sv || !SvOK(sv)) {
    return 1;
  }
  if (gql_runtime_vm_sv_to_hv(aTHX_ sv, &defs_hv)) {
    HE *he;
    IV count = hv_iterinit(defs_hv);
    if (count <= 0) {
      return 1;
    }
    Newxz(*out_defs, count, gql_runtime_vm_native_arg_def_t);
    *out_count = count;
    i = 0;
    while ((he = hv_iternext(defs_hv))) {
      SV *value_sv = hv_iterval(defs_hv, he);
      SV *key_sv = hv_iterkeysv(he);
      HV *def_hv = NULL;
      SV **svp;
      gql_runtime_vm_native_arg_def_t *def = &(*out_defs)[i++];

      if (key_sv && SvOK(key_sv)) {
        STRLEN len;
        const char *pv = SvPV(key_sv, len);
        Newxz(def->name, len + 1, char);
        Copy(pv, def->name, len, char);
        def->name[len] = '\0';
      }

      if (!value_sv || !gql_runtime_vm_sv_to_hv(aTHX_ value_sv, &def_hv)) {
        gql_runtime_vm_free_native_arg_defs(aTHX_ *out_defs, *out_count);
        *out_defs = NULL;
        *out_count = 0;
        croak("native VM slot arg_defs hash entry must be a hash reference");
      }

      svp = hv_fetch(def_hv, "type", 4, 0);
      def->type_def_sv = (svp && SvOK(*svp)) ? newSVsv(*svp) : NULL;

      svp = hv_fetch(def_hv, "has_default", 11, 0);
      def->has_default = (svp && SvOK(*svp) && SvTRUE(*svp)) ? 1 : 0;

      svp = hv_fetch(def_hv, "default_value", 13, 0);
      def->default_value_sv = (svp && SvOK(*svp)) ? newSVsv(*svp) : NULL;
    }
    return 1;
  }
  if (!gql_runtime_vm_sv_to_av(aTHX_ sv, &defs_av)) {
    croak("native VM slot arg_defs must be an array reference or hash reference");
  }
  *out_count = av_count(defs_av);
  if (*out_count <= 0) {
    *out_count = 0;
    return 1;
  }
  Newxz(*out_defs, *out_count, gql_runtime_vm_native_arg_def_t);
  for (i = 0; i < *out_count; i++) {
    SV **entry_svp = av_fetch(defs_av, i, 0);
    AV *entry_av;
    SV **svp;
    gql_runtime_vm_native_arg_def_t *def;
    if (!entry_svp || !gql_runtime_vm_sv_to_av(aTHX_ *entry_svp, &entry_av)) {
      gql_runtime_vm_free_native_arg_defs(aTHX_ *out_defs, *out_count);
      *out_defs = NULL;
      *out_count = 0;
      croak("native VM slot arg_defs entry must be an array reference");
    }
    def = &(*out_defs)[i];
    svp = av_fetch(entry_av, 0, 0);
    if (!svp || !SvOK(*svp)) {
      gql_runtime_vm_free_native_arg_defs(aTHX_ *out_defs, *out_count);
      *out_defs = NULL;
      *out_count = 0;
      croak("native VM slot arg_defs entry is missing name");
    }
    {
      STRLEN len;
      const char *pv = SvPV(*svp, len);
      Newxz(def->name, len + 1, char);
      Copy(pv, def->name, len, char);
      def->name[len] = '\0';
    }
    svp = av_fetch(entry_av, 1, 0);
    def->type_def_sv = (svp && SvOK(*svp)) ? newSVsv(*svp) : NULL;
    svp = av_fetch(entry_av, 2, 0);
    def->has_default = (svp && SvOK(*svp) && SvTRUE(*svp)) ? 1 : 0;
    svp = av_fetch(entry_av, 3, 0);
    def->default_value_sv = (svp && SvOK(*svp)) ? newSVsv(*svp) : NULL;
  }
  return 1;
}

static int
gql_runtime_vm_fetch_hv_iv(pTHX_ HV *hv, const char *key, I32 keylen, IV *out)
{
  SV **svp = hv_fetch(hv, key, keylen, 0);
  if (!svp || !SvOK(*svp)) {
    return 0;
  }
  *out = SvIV(*svp);
  return 1;
}

static int
gql_runtime_vm_fetch_hv_bool(pTHX_ HV *hv, const char *key, I32 keylen, U8 *out)
{
  IV value = 0;
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, key, keylen, &value)) {
    return 0;
  }
  *out = value ? 1 : 0;
  return 1;
}

static int
gql_runtime_vm_sv_to_hv(pTHX_ SV *sv, HV **out)
{
  if (!sv || !SvOK(sv) || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVHV) {
    return 0;
  }
  *out = (HV *)SvRV(sv);
  return 1;
}

static int
gql_runtime_vm_sv_to_av(pTHX_ SV *sv, AV **out)
{
  if (!sv || !SvOK(sv) || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVAV) {
    return 0;
  }
  *out = (AV *)SvRV(sv);
  return 1;
}

static int
gql_runtime_vm_parse_native_slot(pTHX_ SV *sv, gql_runtime_vm_native_slot_t *out)
{
  HV *hv;
  AV *av;
  SV **svp;
  if (gql_runtime_vm_sv_to_av(aTHX_ sv, &av)) {
    svp = av_fetch(av, 0, 0);
    if (!svp || !SvOK(*svp)) croak("native VM slot entry is missing field_name");
    {
      STRLEN len;
      const char *pv = SvPV(*svp, len);
      Newxz(out->field_name, len + 1, char);
      Copy(pv, out->field_name, len, char);
      out->field_name[len] = '\0';
    }
    svp = av_fetch(av, 1, 0);
    if (!svp || !SvOK(*svp)) croak("native VM slot entry is missing result_name");
    {
      STRLEN len;
      const char *pv = SvPV(*svp, len);
      Newxz(out->result_name, len + 1, char);
      Copy(pv, out->result_name, len, char);
      out->result_name[len] = '\0';
    }
    svp = av_fetch(av, 2, 0);
    if (!svp || !SvOK(*svp)) croak("native VM slot entry is missing return_type_name");
    {
      STRLEN len;
      const char *pv = SvPV(*svp, len);
      Newxz(out->return_type_name, len + 1, char);
      Copy(pv, out->return_type_name, len, char);
      out->return_type_name[len] = '\0';
    }
    svp = av_fetch(av, 3, 0);
    out->schema_slot_index = (svp && SvOK(*svp)) ? SvIV(*svp) : -1;
    svp = av_fetch(av, 4, 0);
    out->resolver_shape_code = (svp && SvOK(*svp)) ? SvIV(*svp) : 0;
    svp = av_fetch(av, 5, 0);
    out->completion_family_code = (svp && SvOK(*svp)) ? SvIV(*svp) : 0;
    svp = av_fetch(av, 6, 0);
    out->dispatch_family_code = (svp && SvOK(*svp)) ? SvIV(*svp) : 0;
    svp = av_fetch(av, 7, 0);
    out->return_type_kind_code = (svp && SvOK(*svp)) ? SvIV(*svp) : 0;
    svp = av_fetch(av, 8, 0);
    out->has_args = (svp && SvOK(*svp) && SvTRUE(*svp)) ? 1 : 0;
    svp = av_fetch(av, 9, 0);
    out->has_directives = (svp && SvOK(*svp) && SvTRUE(*svp)) ? 1 : 0;
    svp = av_fetch(av, 10, 0);
    out->resolver_mode_code = (svp && SvOK(*svp)) ? SvIV(*svp) : 0;
    svp = av_fetch(av, 11, 0);
    gql_runtime_vm_parse_native_arg_defs(aTHX_ (svp ? *svp : NULL), &out->arg_defs, &out->arg_def_count);
    return 1;
  }
  if (!gql_runtime_vm_sv_to_hv(aTHX_ sv, &hv)) {
    croak("native VM slot entry must be a hash reference");
  }
  if (!gql_runtime_vm_fetch_hv_string(aTHX_ hv, "field_name", 10, &out->field_name)) {
    croak("native VM slot entry is missing field_name");
  }
  if (!gql_runtime_vm_fetch_hv_string(aTHX_ hv, "result_name", 11, &out->result_name)) {
    croak("native VM slot entry is missing result_name");
  }
  if (!gql_runtime_vm_fetch_hv_string(aTHX_ hv, "return_type_name", 16, &out->return_type_name)) {
    croak("native VM slot entry is missing return_type_name");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, "schema_slot_index", 17, &out->schema_slot_index)) {
    croak("native VM slot entry is missing schema_slot_index");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, "resolver_shape_code", 19, &out->resolver_shape_code)) {
    croak("native VM slot entry is missing resolver_shape_code");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, "resolver_mode_code", 18, &out->resolver_mode_code)) {
    croak("native VM slot entry is missing resolver_mode_code");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, "completion_family_code", 22, &out->completion_family_code)) {
    croak("native VM slot entry is missing completion_family_code");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, "dispatch_family_code", 20, &out->dispatch_family_code)) {
    croak("native VM slot entry is missing dispatch_family_code");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, "return_type_kind_code", 21, &out->return_type_kind_code)) {
    croak("native VM slot entry is missing return_type_kind_code");
  }
  if (!gql_runtime_vm_fetch_hv_bool(aTHX_ hv, "has_args", 8, &out->has_args)) {
    croak("native VM slot entry is missing has_args");
  }
  if (!gql_runtime_vm_fetch_hv_bool(aTHX_ hv, "has_directives", 14, &out->has_directives)) {
    croak("native VM slot entry is missing has_directives");
  }
  svp = hv_fetch(hv, "arg_defs", 8, 0);
  gql_runtime_vm_parse_native_arg_defs(aTHX_ (svp ? *svp : NULL), &out->arg_defs, &out->arg_def_count);
  return 1;
}

static void
gql_runtime_vm_clone_native_slot(
  pTHX_
  const gql_runtime_vm_native_slot_t *src,
  gql_runtime_vm_native_slot_t *dst
)
{
  Zero(dst, 1, gql_runtime_vm_native_slot_t);
  dst->schema_slot_index = src->schema_slot_index;
  dst->resolver_shape_code = src->resolver_shape_code;
  dst->resolver_mode_code = src->resolver_mode_code;
  dst->completion_family_code = src->completion_family_code;
  dst->dispatch_family_code = src->dispatch_family_code;
  dst->return_type_kind_code = src->return_type_kind_code;
  dst->arg_def_count = src->arg_def_count;
  dst->has_args = src->has_args;
  dst->has_directives = src->has_directives;
  if (src->field_name) {
    STRLEN len = strlen(src->field_name);
    Newxz(dst->field_name, len + 1, char);
    Copy(src->field_name, dst->field_name, len, char);
    dst->field_name[len] = '\0';
  }
  if (src->result_name) {
    STRLEN len = strlen(src->result_name);
    Newxz(dst->result_name, len + 1, char);
    Copy(src->result_name, dst->result_name, len, char);
    dst->result_name[len] = '\0';
  }
  if (src->return_type_name) {
    STRLEN len = strlen(src->return_type_name);
    Newxz(dst->return_type_name, len + 1, char);
    Copy(src->return_type_name, dst->return_type_name, len, char);
    dst->return_type_name[len] = '\0';
  }
  if (src->arg_def_count > 0 && src->arg_defs) {
    IV i;
    Newxz(dst->arg_defs, src->arg_def_count, gql_runtime_vm_native_arg_def_t);
    for (i = 0; i < src->arg_def_count; i++) {
      gql_runtime_vm_native_arg_def_t *src_def = &src->arg_defs[i];
      gql_runtime_vm_native_arg_def_t *dst_def = &dst->arg_defs[i];
      dst_def->has_default = src_def->has_default;
      if (src_def->name) {
        STRLEN len = strlen(src_def->name);
        Newxz(dst_def->name, len + 1, char);
        Copy(src_def->name, dst_def->name, len, char);
        dst_def->name[len] = '\0';
      }
      if (src_def->type_def_sv) {
        dst_def->type_def_sv = newSVsv(src_def->type_def_sv);
      }
      if (src_def->input_type_sv) {
        dst_def->input_type_sv = newSVsv(src_def->input_type_sv);
      }
      if (src_def->default_value_sv) {
        dst_def->default_value_sv = newSVsv(src_def->default_value_sv);
      }
      if (src_def->default_native_value) {
        dst_def->default_native_value = gql_runtime_vm_native_value_clone(aTHX_ src_def->default_native_value);
      }
    }
  }
}

static void
gql_runtime_vm_clone_native_op(
  pTHX_
  const gql_runtime_vm_native_op_t *src,
  gql_runtime_vm_native_op_t *dst
)
{
  IV i;
  Zero(dst, 1, gql_runtime_vm_native_op_t);
  *dst = *src;
  dst->abstract_child_names = NULL;
  dst->abstract_child_indexes = NULL;
  dst->args_payload_native = NULL;
  dst->directives_payload_native = NULL;
  if (src->abstract_child_count > 0) {
    Newxz(dst->abstract_child_names, src->abstract_child_count, char *);
    Newxz(dst->abstract_child_indexes, src->abstract_child_count, IV);
    for (i = 0; i < src->abstract_child_count; i++) {
      dst->abstract_child_indexes[i] = src->abstract_child_indexes[i];
      if (src->abstract_child_names && src->abstract_child_names[i]) {
        STRLEN len = strlen(src->abstract_child_names[i]);
        Newxz(dst->abstract_child_names[i], len + 1, char);
        Copy(src->abstract_child_names[i], dst->abstract_child_names[i], len, char);
        dst->abstract_child_names[i][len] = '\0';
      }
    }
  }
  if (src->args_payload_native) {
    dst->args_payload_native = gql_runtime_vm_native_args_payload_clone(aTHX_ src->args_payload_native);
  }
  if (src->directives_payload_native) {
    dst->directives_payload_native = gql_runtime_vm_native_directives_payload_clone(aTHX_ src->directives_payload_native);
  }
}

static void
gql_runtime_vm_clone_native_block(
  pTHX_
  const gql_runtime_vm_native_block_t *src,
  gql_runtime_vm_native_block_t *dst
)
{
  IV i;
  Zero(dst, 1, gql_runtime_vm_native_block_t);
  dst->family_code = src->family_code;
  dst->slot_count = src->slot_count;
  dst->op_count = src->op_count;
  if (src->type_name) {
    STRLEN len = strlen(src->type_name);
    Newxz(dst->type_name, len + 1, char);
    Copy(src->type_name, dst->type_name, len, char);
    dst->type_name[len] = '\0';
  }
  if (src->slot_count > 0) {
    Newxz(dst->slots, src->slot_count, gql_runtime_vm_native_slot_t);
    for (i = 0; i < src->slot_count; i++) {
      gql_runtime_vm_clone_native_slot(aTHX_ &src->slots[i], &dst->slots[i]);
    }
  }
  if (src->op_count > 0) {
    Newxz(dst->ops, src->op_count, gql_runtime_vm_native_op_t);
    for (i = 0; i < src->op_count; i++) {
      gql_runtime_vm_clone_native_op(aTHX_ &src->ops[i], &dst->ops[i]);
    }
  }
}

static int
gql_runtime_vm_parse_native_op(pTHX_ SV *sv, gql_runtime_vm_native_op_t *out)
{
  HV *hv;
  AV *av;
  HV *children_hv;
  HE *he;
  SV **svp;
  IV idx;
  if (gql_runtime_vm_sv_to_av(aTHX_ sv, &av)) {
    svp = av_fetch(av, 0, 0);
    out->opcode_code = (svp && SvOK(*svp)) ? SvIV(*svp) : 0;
    svp = av_fetch(av, 1, 0);
    out->resolve_code = (svp && SvOK(*svp)) ? SvIV(*svp) : 0;
    svp = av_fetch(av, 2, 0);
    out->complete_code = (svp && SvOK(*svp)) ? SvIV(*svp) : 0;
    svp = av_fetch(av, 3, 0);
    out->dispatch_family_code = (svp && SvOK(*svp)) ? SvIV(*svp) : 0;
    svp = av_fetch(av, 4, 0);
    out->slot_index = (svp && SvOK(*svp)) ? SvIV(*svp) : -1;
    svp = av_fetch(av, 5, 0);
    out->child_block_index = (svp && SvOK(*svp)) ? SvIV(*svp) : -1;
    svp = av_fetch(av, 6, 0);
    if (svp && SvOK(*svp) && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVHV) {
      children_hv = (HV *)SvRV(*svp);
      out->abstract_child_count = hv_iterinit(children_hv);
      if (out->abstract_child_count > 0) {
        Newxz(out->abstract_child_names, out->abstract_child_count, char *);
        Newxz(out->abstract_child_indexes, out->abstract_child_count, IV);
        idx = 0;
        hv_iterinit(children_hv);
        while ((he = hv_iternext(children_hv))) {
          STRLEN keylen;
          const char *key = HePV(he, keylen);
          SV *val = HeVAL(he);
          Newxz(out->abstract_child_names[idx], keylen + 1, char);
          Copy(key, out->abstract_child_names[idx], keylen, char);
          out->abstract_child_names[idx][keylen] = '\0';
          out->abstract_child_indexes[idx] = (val && SvOK(val)) ? SvIV(val) : -1;
          idx++;
        }
      }
    } else {
      out->abstract_child_count = 0;
      out->abstract_child_names = NULL;
      out->abstract_child_indexes = NULL;
    }
    svp = av_fetch(av, 7, 0);
    out->args_mode_code = (svp && SvOK(*svp)) ? SvIV(*svp) : GQL_VM_ARGS_NONE;
    svp = av_fetch(av, 8, 0);
    out->args_payload_native =
      (svp && SvOK(*svp) && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVHV)
      ? gql_runtime_vm_native_args_payload_from_hv(aTHX_ (HV *)SvRV(*svp))
      : NULL;
    svp = av_fetch(av, 9, 0);
    out->has_args = (svp && SvOK(*svp) && SvTRUE(*svp)) ? 1 : 0;
    svp = av_fetch(av, 10, 0);
    out->directives_mode_code = (svp && SvOK(*svp)) ? SvIV(*svp) : GQL_VM_ARGS_NONE;
    svp = av_fetch(av, 11, 0);
    out->directives_payload_native = (svp && SvOK(*svp))
      ? gql_runtime_vm_native_directives_payload_from_sv(aTHX_ *svp)
      : NULL;
    svp = av_fetch(av, 12, 0);
    out->has_directives = (svp && SvOK(*svp) && SvTRUE(*svp)) ? 1 : 0;
    return 1;
  }
  if (!gql_runtime_vm_sv_to_hv(aTHX_ sv, &hv)) {
    croak("native VM op entry must be a hash reference");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, "opcode_code", 11, &out->opcode_code)) {
    croak("native VM op entry is missing opcode_code");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, "resolve_code", 12, &out->resolve_code)) {
    croak("native VM op entry is missing resolve_code");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, "complete_code", 13, &out->complete_code)) {
    croak("native VM op entry is missing complete_code");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, "dispatch_family_code", 20, &out->dispatch_family_code)) {
    croak("native VM op entry is missing dispatch_family_code");
  }
  svp = hv_fetch(hv, "slot_index", 10, 0);
  out->slot_index = (svp && SvOK(*svp)) ? SvIV(*svp) : -1;
  svp = hv_fetch(hv, "child_block_index", 17, 0);
  out->child_block_index = (svp && SvOK(*svp)) ? SvIV(*svp) : -1;
  if (!gql_runtime_vm_fetch_hv_bool(aTHX_ hv, "has_args", 8, &out->has_args)) {
    croak("native VM op entry is missing has_args");
  }
  if (!gql_runtime_vm_fetch_hv_bool(aTHX_ hv, "has_directives", 14, &out->has_directives)) {
    croak("native VM op entry is missing has_directives");
  }
  svp = hv_fetch(hv, "directives_mode_code", 20, 0);
  out->directives_mode_code = (svp && SvOK(*svp)) ? SvIV(*svp) : GQL_VM_ARGS_NONE;
  svp = hv_fetch(hv, "abstract_child_block_indexes", 28, 0);
  if (svp && SvOK(*svp) && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVHV) {
    children_hv = (HV *)SvRV(*svp);
    out->abstract_child_count = hv_iterinit(children_hv);
    if (out->abstract_child_count > 0) {
      Newxz(out->abstract_child_names, out->abstract_child_count, char *);
      Newxz(out->abstract_child_indexes, out->abstract_child_count, IV);
      idx = 0;
      hv_iterinit(children_hv);
      while ((he = hv_iternext(children_hv))) {
        STRLEN keylen;
        const char *key = HePV(he, keylen);
        SV *val = HeVAL(he);
        Newxz(out->abstract_child_names[idx], keylen + 1, char);
        Copy(key, out->abstract_child_names[idx], keylen, char);
        out->abstract_child_names[idx][keylen] = '\0';
        out->abstract_child_indexes[idx] = (val && SvOK(val)) ? SvIV(val) : -1;
        idx++;
      }
    }
  } else {
    out->abstract_child_count = 0;
    out->abstract_child_names = NULL;
    out->abstract_child_indexes = NULL;
  }
  svp = hv_fetch(hv, "args_mode_code", 14, 0);
  out->args_mode_code = (svp && SvOK(*svp)) ? SvIV(*svp) : GQL_VM_ARGS_NONE;
  svp = hv_fetch(hv, "args_payload", 12, 0);
  out->args_payload_native =
    (svp && SvOK(*svp) && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVHV)
    ? gql_runtime_vm_native_args_payload_from_hv(aTHX_ (HV *)SvRV(*svp))
    : NULL;
  svp = hv_fetch(hv, "directives_payload", 18, 0);
  out->directives_payload_native = (svp && SvOK(*svp))
    ? gql_runtime_vm_native_directives_payload_from_sv(aTHX_ *svp)
    : NULL;
  return 1;
}

static int
gql_runtime_vm_parse_native_block(pTHX_ SV *sv, gql_runtime_vm_native_block_t *out)
{
  HV *hv;
  AV *av;
  AV *slots_av;
  AV *ops_av;
  IV i;
  SV **svp;
  if (gql_runtime_vm_sv_to_av(aTHX_ sv, &av)) {
    SV **name_svp = av_fetch(av, 0, 0);
    SV **type_svp = av_fetch(av, 1, 0);
    SV **family_svp = av_fetch(av, 2, 0);
    SV **slots_svp = av_fetch(av, 3, 0);
    SV **ops_svp = av_fetch(av, 4, 0);
    if (!family_svp || !SvOK(*family_svp)) return 0;
    if (!type_svp || !SvOK(*type_svp)) croak("native VM block entry is missing type_name");
    out->family_code = SvIV(*family_svp);
    {
      STRLEN len;
      const char *pv = SvPV(*type_svp, len);
      Newxz(out->type_name, len + 1, char);
      Copy(pv, out->type_name, len, char);
      out->type_name[len] = '\0';
    }
    if (!slots_svp || !gql_runtime_vm_sv_to_av(aTHX_ *slots_svp, &slots_av)) return 0;
    if (!ops_svp || !gql_runtime_vm_sv_to_av(aTHX_ *ops_svp, &ops_av)) return 0;
    out->slot_count = av_count(slots_av);
    out->op_count = av_count(ops_av);
    out->slots = NULL;
    out->ops = NULL;
    if (out->slot_count > 0) {
      Newxz(out->slots, out->slot_count, gql_runtime_vm_native_slot_t);
      for (i = 0; i < out->slot_count; i++) {
        SV **slot_svp = av_fetch(slots_av, i, 0);
        if (!slot_svp || !gql_runtime_vm_parse_native_slot(aTHX_ *slot_svp, &out->slots[i])) return 0;
      }
    }
    if (out->op_count > 0) {
      Newxz(out->ops, out->op_count, gql_runtime_vm_native_op_t);
      for (i = 0; i < out->op_count; i++) {
        SV **op_svp = av_fetch(ops_av, i, 0);
        if (!op_svp || !gql_runtime_vm_parse_native_op(aTHX_ *op_svp, &out->ops[i])) return 0;
      }
    }
    return 1;
  }
  if (!gql_runtime_vm_sv_to_hv(aTHX_ sv, &hv)) {
    return 0;
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ hv, "family_code", 11, &out->family_code)) {
    return 0;
  }
  if (!gql_runtime_vm_fetch_hv_string(aTHX_ hv, "type_name", 9, &out->type_name)) {
    croak("native VM block entry is missing type_name");
  }
  svp = hv_fetch(hv, "slots", 5, 0);
  if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &slots_av)) {
    return 0;
  }
  svp = hv_fetch(hv, "ops", 3, 0);
  if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &ops_av)) {
    return 0;
  }
  out->slot_count = av_count(slots_av);
  out->op_count = av_count(ops_av);
  out->slots = NULL;
  out->ops = NULL;
  if (out->slot_count > 0) {
    Newxz(out->slots, out->slot_count, gql_runtime_vm_native_slot_t);
    for (i = 0; i < out->slot_count; i++) {
      SV **slot_svp = av_fetch(slots_av, i, 0);
      if (!slot_svp || !gql_runtime_vm_parse_native_slot(aTHX_ *slot_svp, &out->slots[i])) {
        return 0;
      }
    }
  }
  if (out->op_count > 0) {
    Newxz(out->ops, out->op_count, gql_runtime_vm_native_op_t);
    for (i = 0; i < out->op_count; i++) {
      SV **op_svp = av_fetch(ops_av, i, 0);
      if (!op_svp || !gql_runtime_vm_parse_native_op(aTHX_ *op_svp, &out->ops[i])) {
        return 0;
      }
    }
  }
  return 1;
}

static gql_runtime_vm_native_bundle_t *
gql_runtime_vm_native_bundle_from_runtime_and_program_sv(pTHX_ SV *runtime_sv, SV *program_sv)
{
  HV *runtime_hv;
  HV *program_hv;
  AV *runtime_slots_av;
  AV *blocks_av;
  IV i;
  SV **svp;
  gql_runtime_vm_native_bundle_t *bundle;

  if (!gql_runtime_vm_sv_to_hv(aTHX_ runtime_sv, &runtime_hv)) {
    croak("native VM runtime descriptor must be a hash reference");
  }
  if (!gql_runtime_vm_sv_to_hv(aTHX_ program_sv, &program_hv)) {
    croak("native VM program descriptor must be a hash reference");
  }

  Newxz(bundle, 1, gql_runtime_vm_native_bundle_t);

  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ program_hv, "operation_type_code", 19, &bundle->operation_type_code)) {
    gql_runtime_vm_native_bundle_destroy(bundle);
    croak("native VM program descriptor is missing operation_type_code");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ program_hv, "root_block_index", 16, &bundle->root_block_index)) {
    gql_runtime_vm_native_bundle_destroy(bundle);
    croak("native VM program descriptor is missing root_block_index");
  }

  svp = hv_fetch(runtime_hv, "slot_catalog_compact", 20, 0);
  if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &runtime_slots_av)) {
    svp = hv_fetch(runtime_hv, "slot_catalog", 12, 0);
  }
  if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &runtime_slots_av)) {
    gql_runtime_vm_native_bundle_destroy(bundle);
    croak("native VM runtime descriptor is missing slot_catalog");
  }
  bundle->runtime_slot_count = av_count(runtime_slots_av);
  if (bundle->runtime_slot_count > 0) {
    bundle->owns_runtime_slots = 1;
    Newxz(bundle->runtime_slots, bundle->runtime_slot_count, gql_runtime_vm_native_slot_t);
    for (i = 0; i < bundle->runtime_slot_count; i++) {
      SV **slot_svp = av_fetch(runtime_slots_av, i, 0);
      if (!slot_svp) {
        gql_runtime_vm_native_bundle_destroy(bundle);
        croak("native VM runtime slot entry %ld is missing", (long)i);
      }
      if (!gql_runtime_vm_parse_native_slot(aTHX_ *slot_svp, &bundle->runtime_slots[i])) {
        gql_runtime_vm_native_bundle_destroy(bundle);
        croak("native VM runtime slot entry %ld is invalid", (long)i);
      }
    }
  }

  svp = hv_fetch(program_hv, "blocks_compact", 14, 0);
  if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &blocks_av)) {
    svp = hv_fetch(program_hv, "blocks", 6, 0);
  }
  if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &blocks_av)) {
    gql_runtime_vm_native_bundle_destroy(bundle);
    croak("native VM program descriptor is missing blocks");
  }
  bundle->block_count = av_count(blocks_av);
  if (bundle->block_count > 0) {
    bundle->owns_blocks = 1;
    Newxz(bundle->blocks, bundle->block_count, gql_runtime_vm_native_block_t);
    for (i = 0; i < bundle->block_count; i++) {
      SV **block_svp = av_fetch(blocks_av, i, 0);
      if (!block_svp) {
        gql_runtime_vm_native_bundle_destroy(bundle);
        croak("native VM block entry %ld is missing", (long)i);
      }
      if (!gql_runtime_vm_parse_native_block(aTHX_ *block_svp, &bundle->blocks[i])) {
        gql_runtime_vm_native_bundle_destroy(bundle);
        croak("native VM block entry %ld is invalid", (long)i);
      }
    }
  }

  return bundle;
}

static gql_runtime_vm_native_program_t *
gql_runtime_vm_native_program_from_sv(pTHX_ SV *sv)
{
  HV *program_hv;
  AV *blocks_av;
  IV i;
  SV **svp;
  gql_runtime_vm_native_program_t *program;

  if (sv && SvROK(sv) && sv_derived_from(sv, "GraphQL::Houtou::Runtime::NativeProgram")) {
    gql_runtime_vm_native_program_t *existing =
      INT2PTR(gql_runtime_vm_native_program_t *, SvUV(SvRV(sv)));
    if (!existing) {
      croak("native VM program handle is no longer valid");
    }
    return existing;
  }

  if (!gql_runtime_vm_sv_to_hv(aTHX_ sv, &program_hv)) {
    croak("native VM program descriptor must be a hash reference");
  }

  Newxz(program, 1, gql_runtime_vm_native_program_t);
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ program_hv, "operation_type_code", 19, &program->operation_type_code)) {
    gql_runtime_vm_native_program_destroy(program);
    croak("native VM program descriptor is missing operation_type_code");
  }
  if (!gql_runtime_vm_fetch_hv_iv(aTHX_ program_hv, "root_block_index", 16, &program->root_block_index)) {
    gql_runtime_vm_native_program_destroy(program);
    croak("native VM program descriptor is missing root_block_index");
  }

  svp = hv_fetch(program_hv, "blocks_compact", 14, 0);
  if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &blocks_av)) {
    svp = hv_fetch(program_hv, "blocks", 6, 0);
  }
  if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &blocks_av)) {
    gql_runtime_vm_native_program_destroy(program);
    croak("native VM program descriptor is missing blocks");
  }

  program->block_count = av_count(blocks_av);
  if (program->block_count > 0) {
    Newxz(program->blocks, program->block_count, gql_runtime_vm_native_block_t);
    for (i = 0; i < program->block_count; i++) {
      SV **block_svp = av_fetch(blocks_av, i, 0);
      if (!block_svp) {
        gql_runtime_vm_native_program_destroy(program);
        croak("native VM block entry %ld is missing", (long)i);
      }
      if (!gql_runtime_vm_parse_native_block(aTHX_ *block_svp, &program->blocks[i])) {
        gql_runtime_vm_native_program_destroy(program);
        croak("native VM block entry %ld is invalid", (long)i);
      }
    }
  }

  return program;
}

static gql_runtime_vm_native_bundle_t *
gql_runtime_vm_native_bundle_from_runtime_and_program_handles(
  gql_runtime_vm_native_runtime_t *runtime,
  gql_runtime_vm_native_program_t *program
)
{
  gql_runtime_vm_native_bundle_t *bundle;
  IV i;
  if (!runtime || !program) {
    croak("native runtime and native program handles are required");
  }

  Newxz(bundle, 1, gql_runtime_vm_native_bundle_t);
  bundle->operation_type_code = program->operation_type_code;
  bundle->root_block_index = program->root_block_index;
  bundle->runtime_slot_count = runtime->runtime_slot_count;
  bundle->owns_runtime_slots = 1;
  bundle->runtime_slots = NULL;
  if (runtime->runtime_slot_count > 0) {
    Newxz(bundle->runtime_slots, runtime->runtime_slot_count, gql_runtime_vm_native_slot_t);
    for (i = 0; i < runtime->runtime_slot_count; i++) {
      gql_runtime_vm_clone_native_slot(aTHX_ &runtime->runtime_slots[i], &bundle->runtime_slots[i]);
    }
  }
  bundle->block_count = program->block_count;
  if (program->block_count > 0) {
    bundle->owns_blocks = 1;
    Newxz(bundle->blocks, program->block_count, gql_runtime_vm_native_block_t);
    for (i = 0; i < program->block_count; i++) {
      gql_runtime_vm_clone_native_block(aTHX_ &program->blocks[i], &bundle->blocks[i]);
    }
  }
  return bundle;
}

static gql_runtime_vm_native_bundle_t *
gql_runtime_vm_native_bundle_from_sv(pTHX_ SV *sv)
{
  HV *bundle_hv;
  SV **runtime_svp;
  SV **program_svp;

  if (!gql_runtime_vm_sv_to_hv(aTHX_ sv, &bundle_hv)) {
    croak("native VM bundle descriptor must be a hash reference");
  }

  runtime_svp = hv_fetch(bundle_hv, "runtime", 7, 0);
  if (!runtime_svp) {
    croak("native VM bundle descriptor is missing runtime");
  }
  program_svp = hv_fetch(bundle_hv, "program", 7, 0);
  if (!program_svp) {
    croak("native VM bundle descriptor is missing program");
  }

  return gql_runtime_vm_native_bundle_from_runtime_and_program_sv(
    aTHX_ *runtime_svp, *program_svp
  );
}

static int
gql_runtime_vm_program_is_native_eligible_sv(pTHX_ SV *program_sv, int has_promise)
{
  HV *program_hv;
  AV *blocks_av;
  IV i, j, k;
  SV **svp;

  if (has_promise) {
    return 0;
  }
  if (program_sv && SvROK(program_sv) && sv_derived_from(program_sv, "GraphQL::Houtou::Runtime::NativeProgram")) {
    gql_runtime_vm_native_program_t *program =
      INT2PTR(gql_runtime_vm_native_program_t *, SvUV(SvRV(program_sv)));
    return program ? 1 : 0;
  }
  if (!gql_runtime_vm_sv_to_hv(aTHX_ program_sv, &program_hv)) {
    return 0;
  }

  svp = hv_fetch(program_hv, "variable_defs", 13, 0);
  if (svp && SvOK(*svp) && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVHV) {
    HV *defs_hv = (HV *)SvRV(*svp);
    if (HvUSEDKEYS(defs_hv) > 0) {
      return 0;
    }
  }

  svp = hv_fetch(program_hv, "blocks_compact", 14, 0);
  if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &blocks_av)) {
    svp = hv_fetch(program_hv, "blocks", 6, 0);
  }
  if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &blocks_av)) {
    return 0;
  }

  for (i = 0; i <= av_len(blocks_av); i++) {
    SV **block_svp = av_fetch(blocks_av, i, 0);
    AV *block_av;
    AV *slots_av;
    AV *ops_av;
    if (!block_svp || !gql_runtime_vm_sv_to_av(aTHX_ *block_svp, &block_av)) {
      return 0;
    }

    svp = av_fetch(block_av, 3, 0);
    if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &slots_av)) {
      return 0;
    }
    for (j = 0; j <= av_len(slots_av); j++) {
      SV **slot_svp = av_fetch(slots_av, j, 0);
      AV *slot_av;
      IV resolver_shape_code;
      IV resolver_mode_code;
      if (!slot_svp || !gql_runtime_vm_sv_to_av(aTHX_ *slot_svp, &slot_av)) {
        return 0;
      }
      svp = av_fetch(slot_av, 4, 0);
      resolver_shape_code = (svp && SvOK(*svp)) ? SvIV(*svp) : 0;
      svp = av_fetch(slot_av, 10, 0);
      resolver_mode_code = (svp && SvOK(*svp)) ? SvIV(*svp) : 0;
      if (resolver_shape_code != GQL_VM_RESOLVE_DEFAULT) {
        if (resolver_shape_code != GQL_VM_RESOLVE_EXPLICIT || resolver_mode_code != 2) {
          return 0;
        }
      }
    }

    svp = av_fetch(block_av, 4, 0);
    if (!svp || !gql_runtime_vm_sv_to_av(aTHX_ *svp, &ops_av)) {
      return 0;
    }
    for (k = 0; k <= av_len(ops_av); k++) {
      SV **op_svp = av_fetch(ops_av, k, 0);
      AV *op_av;
      IV args_mode_code;
      int has_directives;
      if (!op_svp || !gql_runtime_vm_sv_to_av(aTHX_ *op_svp, &op_av)) {
        return 0;
      }
      svp = av_fetch(op_av, 7, 0);
      args_mode_code = (svp && SvOK(*svp)) ? SvIV(*svp) : GQL_VM_ARGS_NONE;
      svp = av_fetch(op_av, 12, 0);
      has_directives = (svp && SvOK(*svp) && SvTRUE(*svp)) ? 1 : 0;
      if (args_mode_code != GQL_VM_ARGS_NONE && args_mode_code != GQL_VM_ARGS_STATIC) {
        return 0;
      }
      if (has_directives) {
        return 0;
      }
    }
  }

  return 1;
}

static gql_runtime_vm_native_program_t *
gql_runtime_vm_clone_native_program(pTHX_ gql_runtime_vm_native_program_t *src)
{
  gql_runtime_vm_native_program_t *dst;
  IV i;
  if (!src) {
    return NULL;
  }
  Newxz(dst, 1, gql_runtime_vm_native_program_t);
  dst->operation_type_code = src->operation_type_code;
  dst->root_block_index = src->root_block_index;
  dst->block_count = src->block_count;
  if (src->block_count > 0) {
    Newxz(dst->blocks, src->block_count, gql_runtime_vm_native_block_t);
    for (i = 0; i < src->block_count; i++) {
      gql_runtime_vm_clone_native_block(aTHX_ &src->blocks[i], &dst->blocks[i]);
    }
  }
  return dst;
}

static SV *
gql_runtime_vm_lookup_type_object_by_name_from_schema_sv(pTHX_ SV *runtime_schema, const char *type_name)
{
  SV *runtime_cache_sv;
  SV *name2type_sv;
  HV *schema_hv;
  HV *runtime_cache_hv;
  HV *name2type_hv;
  SV **svp;

  if (!runtime_schema || !SvROK(runtime_schema) || SvTYPE(SvRV(runtime_schema)) != SVt_PVHV || !type_name) {
    return NULL;
  }
  schema_hv = (HV *)SvRV(runtime_schema);
  runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "runtime_cache", 13);
  if (!runtime_cache_sv || !SvROK(runtime_cache_sv) || SvTYPE(SvRV(runtime_cache_sv)) != SVt_PVHV) {
    return NULL;
  }
  runtime_cache_hv = (HV *)SvRV(runtime_cache_sv);
  name2type_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "name2type", 9);
  if (!name2type_sv || !SvROK(name2type_sv) || SvTYPE(SvRV(name2type_sv)) != SVt_PVHV) {
    return NULL;
  }
  name2type_hv = (HV *)SvRV(name2type_sv);
  svp = hv_fetch(name2type_hv, type_name, (I32)strlen(type_name), 0);
  return (svp && SvOK(*svp)) ? *svp : NULL;
}

static SV *
gql_runtime_vm_lookup_input_type_by_typedef_sv(pTHX_ SV *runtime_schema, SV *typedef_sv)
{
  dSP;
  SV *runtime_cache_sv;
  SV *name2type_sv;
  HV *schema_hv;
  HV *runtime_cache_hv;
  SV *result = NULL;
  int count;

  if (!runtime_schema || !SvROK(runtime_schema) || SvTYPE(SvRV(runtime_schema)) != SVt_PVHV || !typedef_sv || !SvOK(typedef_sv)) {
    return NULL;
  }
  schema_hv = (HV *)SvRV(runtime_schema);
  runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "runtime_cache", 13);
  if (!runtime_cache_sv || !SvROK(runtime_cache_sv) || SvTYPE(SvRV(runtime_cache_sv)) != SVt_PVHV) {
    return NULL;
  }
  runtime_cache_hv = (HV *)SvRV(runtime_cache_sv);
  name2type_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "name2type", 9);
  if (!name2type_sv || !SvROK(name2type_sv) || SvTYPE(SvRV(name2type_sv)) != SVt_PVHV) {
    return NULL;
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(typedef_sv);
  XPUSHs(name2type_sv);
  PUTBACK;
  count = call_pv("GraphQL::Houtou::Schema::lookup_type", G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV)) {
    SV *err = newSVsv(ERRSV);
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak_sv(err);
  }
  if (count > 0) {
    result = newSVsv(POPs);
  }
  PUTBACK;
  FREETMPS;
  LEAVE;
  return result;
}

static SV *
gql_runtime_vm_coerce_input_value_sv(pTHX_ SV *type_sv, SV *value_sv)
{
  dSP;
  SV *result = NULL;
  int count;

  if (!value_sv) {
    return newSV(0);
  }
  if (!type_sv || !SvOK(type_sv)) {
    return newSVsv(value_sv);
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(type_sv);
  XPUSHs(value_sv);
  PUTBACK;
  count = call_method("graphql_to_perl", G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV)) {
    SV *err = newSVsv(ERRSV);
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak_sv(err);
  }
  if (count > 0) {
    result = newSVsv(POPs);
  } else {
    result = newSV(0);
  }
  PUTBACK;
  FREETMPS;
  LEAVE;
  return result;
}

static SV *
gql_runtime_vm_specialize_arg_payload_sv(
  pTHX_
  const gql_runtime_vm_native_runtime_t *runtime,
  const gql_runtime_vm_native_slot_t *slot,
  const gql_runtime_vm_native_op_t *op,
  HV *variables_hv
)
{
  HV *coerced_hv;
  const gql_runtime_vm_native_args_payload_t *payload = op->args_payload_native;
  const gql_runtime_vm_native_slot_t *effective_slot = gql_runtime_vm_effective_slot(runtime, slot);
  IV i;

  coerced_hv = newHV();
  for (i = 0; effective_slot && i < effective_slot->arg_def_count; i++) {
    const gql_runtime_vm_native_arg_def_t *arg_def = &effective_slot->arg_defs[i];
    SV *raw_sv = NULL;
    SV *coerced_sv = NULL;
    gql_runtime_vm_native_dynamic_value_t *raw_value = NULL;
    IV j;

    if (payload) {
      for (j = 0; j < payload->count; j++) {
        if (payload->names && payload->names[j] && strEQ(payload->names[j], arg_def->name)) {
          raw_value = payload->values ? payload->values[j] : NULL;
          break;
        }
      }
    }

    if (raw_value) {
      if (op->args_mode_code == GQL_VM_ARGS_DYNAMIC) {
        raw_sv = gql_runtime_vm_native_dynamic_value_materialize_sv(aTHX_ raw_value, variables_hv);
      } else {
        raw_sv = gql_runtime_vm_native_dynamic_value_materialize_sv(aTHX_ raw_value, NULL);
      }
    } else if (arg_def->has_default && arg_def->default_native_value) {
      coerced_sv = gql_runtime_vm_native_value_materialize_sv(aTHX_ arg_def->default_native_value);
      hv_store(coerced_hv, arg_def->name, (I32)strlen(arg_def->name), coerced_sv, 0);
      continue;
    } else if (arg_def->has_default && arg_def->default_value_sv) {
      raw_sv = newSVsv(arg_def->default_value_sv);
    } else {
      continue;
    }

    coerced_sv = gql_runtime_vm_coerce_input_value_sv(aTHX_ arg_def->input_type_sv, raw_sv);
    SvREFCNT_dec(raw_sv);
    hv_store(coerced_hv, arg_def->name, (I32)strlen(arg_def->name), coerced_sv, 0);
  }

  if (HvUSEDKEYS(coerced_hv) == 0) {
    SvREFCNT_dec((SV *)coerced_hv);
    return NULL;
  }
  return newRV_noinc((SV *)coerced_hv);
}

static gql_runtime_vm_native_args_payload_t *
gql_runtime_vm_specialize_arg_payload_native(
  pTHX_
  const gql_runtime_vm_native_runtime_t *runtime,
  const gql_runtime_vm_native_slot_t *slot,
  const gql_runtime_vm_native_op_t *op,
  HV *variables_hv
)
{
  SV *specialized_sv = gql_runtime_vm_specialize_arg_payload_sv(aTHX_ runtime, slot, op, variables_hv);
  gql_runtime_vm_native_args_payload_t *payload = NULL;
  if (specialized_sv && SvOK(specialized_sv) && SvROK(specialized_sv) && SvTYPE(SvRV(specialized_sv)) == SVt_PVHV) {
    payload = gql_runtime_vm_native_args_payload_from_hv(aTHX_ (HV *)SvRV(specialized_sv));
  }
  if (specialized_sv) {
    SvREFCNT_dec(specialized_sv);
  }
  return payload;
}

static void
gql_runtime_vm_specialize_native_program_in_place(
  pTHX_
  gql_runtime_vm_native_runtime_t *runtime,
  gql_runtime_vm_native_program_t *program,
  HV *variables_hv
)
{
  IV i;

  if (!program) {
    return;
  }

  for (i = 0; i < program->block_count; i++) {
    gql_runtime_vm_native_block_t *block = &program->blocks[i];
    IV read_index;
    IV write_index = 0;

    for (read_index = 0; read_index < block->op_count; read_index++) {
      gql_runtime_vm_native_op_t *op = &block->ops[read_index];
      const gql_runtime_vm_native_slot_t *slot = NULL;
      int keep = 1;

      if (op->slot_index >= 0 && op->slot_index < block->slot_count) {
        slot = &block->slots[op->slot_index];
      }

      if (op->has_directives && op->directives_mode_code == GQL_VM_ARGS_DYNAMIC) {
        if (!gql_runtime_vm_evaluate_runtime_guards_native(
              aTHX_
              op->directives_payload_native,
              variables_hv
            )) {
          keep = 0;
        } else {
          op->has_directives = 0;
          op->directives_mode_code = GQL_VM_ARGS_NONE;
          gql_runtime_vm_native_directives_payload_destroy(aTHX_ op->directives_payload_native);
          op->directives_payload_native = NULL;
        }
      }

      if (keep && slot && (slot->arg_def_count > 0 || op->has_args)) {
        gql_runtime_vm_native_args_payload_t *specialized_payload = gql_runtime_vm_specialize_arg_payload_native(
          aTHX_ runtime, slot, op, variables_hv
        );
        gql_runtime_vm_native_args_payload_destroy(aTHX_ op->args_payload_native);
        op->args_payload_native = NULL;
        if (specialized_payload) {
          op->args_payload_native = specialized_payload;
          op->args_mode_code = GQL_VM_ARGS_STATIC;
          op->has_args = 1;
        } else {
          op->args_mode_code = GQL_VM_ARGS_NONE;
          op->has_args = 0;
        }
      }

      if (!keep) {
        Safefree(op->abstract_child_names);
        Safefree(op->abstract_child_indexes);
        gql_runtime_vm_native_args_payload_destroy(aTHX_ op->args_payload_native);
        op->args_payload_native = NULL;
        gql_runtime_vm_native_directives_payload_destroy(aTHX_ op->directives_payload_native);
        op->directives_payload_native = NULL;
        Zero(op, 1, gql_runtime_vm_native_op_t);
        continue;
      }

      if (write_index != read_index) {
        block->ops[write_index] = block->ops[read_index];
        Zero(&block->ops[read_index], 1, gql_runtime_vm_native_op_t);
      }
      write_index++;
    }
    block->op_count = write_index;
  }
}

#endif
