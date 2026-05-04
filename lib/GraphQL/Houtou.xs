#include "bootstrap.h"
#include "parser_core.h"
#include "parser_graphqlperl_runtime.h"
#include "parser_shared_ast.h"
#include "parser_ast_runtime.h"
#include "parser_ir_runtime.h"
#include "schema_compiler.h"
#include "validation.h"
#include "vm_runtime.h"

static HV *
gql_runtime_vm_expect_hashref(pTHX_ SV *sv, const char *what)
{
  if (!sv || !SvOK(sv) || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVHV) {
    croak("%s must be a hash reference", what);
  }
  return (HV *)SvRV(sv);
}

static AV *
gql_runtime_vm_expect_arrayref(pTHX_ SV *sv, const char *what)
{
  if (!sv || !SvOK(sv) || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVAV) {
    croak("%s must be an array reference", what);
  }
  return (AV *)SvRV(sv);
}

static SV *
gql_runtime_vm_new_handle_sv(pTHX_ const char *pkg, void *ptr)
{
  SV *inner = newSVuv(PTR2UV(ptr));
  SV *rv = newRV_noinc(inner);
  return sv_bless(rv, gv_stashpv(pkg, GV_ADD));
}

static SV *
gql_runtime_vm_exec_state_materialize_response_sv(
  pTHX_ gql_runtime_vm_exec_state_handle_t *s,
  SV *data_sv
)
{
  HV *response_hv = newHV();
  hv_store(response_hv, "data", 4, data_sv ? newSVsv(data_sv) : newSV(0), 0);
  hv_store(
    response_hv,
    "errors",
    6,
    gql_runtime_vm_writer_materialize_errors_sv(aTHX_ s ? s->writer : NULL),
    0
  );
  return newRV_noinc((SV *)response_hv);
}

typedef struct {
  UV refcount;
  gql_runtime_vm_block_frame_t *frame;
  gql_runtime_vm_writer_t *writer;
} gql_runtime_vm_pending_merge_t;

typedef struct {
  SV *state_sv;
  SV *path_frame_sv;
  IV block_index;
  IV slot_index;
  IV op_index;
} gql_runtime_vm_complete_callback_ctx_t;

typedef struct {
  SV *path_frame_sv;
} gql_runtime_vm_error_callback_ctx_t;

typedef struct {
  gql_runtime_vm_pending_merge_t *merge;
} gql_runtime_vm_finalize_callback_ctx_t;

typedef struct {
  SV *state_sv;
} gql_runtime_vm_materialize_response_callback_ctx_t;

static SV *gql_runtime_vm_exec_state_execute_block_sync_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s, SV *block, IV block_index, SV *source, SV *base_path);
static gql_runtime_vm_outcome_t *gql_runtime_vm_exec_state_execute_current_op_sync_now(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s);
static SV *gql_runtime_vm_state_type_by_name_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *type_name_sv);
static gql_runtime_vm_native_runtime_t *gql_runtime_vm_native_runtime_from_runtime_schema_sv(pTHX_ SV *runtime_schema);
static gql_runtime_vm_native_runtime_t *gql_runtime_vm_exec_state_native_runtime(pTHX_ gql_runtime_vm_exec_state_handle_t *s);
static SV *gql_runtime_vm_exec_state_execute_block_async_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s, IV block_index, SV *source, SV *base_path);
static SV *gql_runtime_vm_exec_state_resolve_current_value_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s, SV *source_sv, SV *path_frame, SV **error_out);
static SV *gql_runtime_vm_exec_state_complete_async_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s, SV *path_frame_sv, IV block_index, IV slot_index, IV op_index, SV *resolved_sv);
static SV *gql_runtime_vm_exec_state_execute_current_op_async_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s);
static SV *gql_runtime_vm_new_lazy_info_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s, SV *path_frame);
static SV *gql_runtime_vm_lookup_type_object_by_name_sv(pTHX_ SV *runtime_schema, const char *type_name);
static SV *gql_runtime_vm_direct_slot_type_object_sv(const gql_runtime_vm_native_runtime_t *runtime, const gql_runtime_vm_native_slot_t *slot);
static SV *gql_runtime_vm_state_current_return_type_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *op_sv, SV *slot_sv);
static IV gql_runtime_vm_find_abstract_child_block_index(const gql_runtime_vm_native_op_t *op, const char *type_name);
static const char *gql_runtime_vm_type_name_from_sv(pTHX_ SV *type_sv);
static SV *gql_runtime_vm_new_complete_callback_sv(pTHX_ SV *state_sv, SV *path_frame_sv, IV block_index, IV slot_index, IV op_index);
static SV *gql_runtime_vm_new_error_callback_sv(pTHX_ SV *path_frame_sv);
static SV *gql_runtime_vm_new_finalize_callback_sv(pTHX_ gql_runtime_vm_pending_merge_t *merge);
static SV *gql_runtime_vm_new_materialize_response_callback_sv(pTHX_ SV *state_sv);
static XS(gql_runtime_vm_xs_complete_callback);
static XS(gql_runtime_vm_xs_error_callback);
static XS(gql_runtime_vm_xs_finalize_callback);
static XS(gql_runtime_vm_xs_materialize_response_callback);

static void
gql_runtime_vm_cursor_incref(gql_runtime_vm_cursor_t *cursor)
{
  if (cursor) {
    cursor->refcount++;
  }
}

static void
gql_runtime_vm_cursor_decref(pTHX_ gql_runtime_vm_cursor_t *cursor)
{
  if (!cursor) {
    return;
  }
  if (--cursor->refcount > 0) {
    return;
  }
  Safefree(cursor);
}

static void
gql_runtime_vm_free_field_frame(pTHX_ gql_runtime_vm_field_frame_t *frame)
{
  if (!frame) {
    return;
  }
  if (--frame->refcount > 0) {
    return;
  }
  SvREFCNT_dec(frame->source);
  gql_runtime_vm_path_frame_decref(frame->path_frame);
  SvREFCNT_dec(frame->resolved_value);
  gql_runtime_vm_outcome_decref(aTHX_ frame->outcome);
  Safefree(frame);
}

static void
gql_runtime_vm_free_block_frame(pTHX_ gql_runtime_vm_block_frame_t *frame)
{
  if (!frame) {
    return;
  }
  if (--frame->refcount > 0) {
    return;
  }
  gql_runtime_vm_native_value_destroy(aTHX_ frame->values_value);
  gql_runtime_vm_block_frame_clear_pending(aTHX_ frame);
  Safefree(frame);
}

static void
gql_runtime_vm_writer_incref(gql_runtime_vm_writer_t *writer)
{
  if (writer) {
    writer->refcount++;
  }
}

static void
gql_runtime_vm_writer_decref(pTHX_ gql_runtime_vm_writer_t *writer)
{
  if (!writer) {
    return;
  }
  if (--writer->refcount > 0) {
    return;
  }
  while (writer->error_record_count > 0) {
    gql_runtime_vm_error_record_decref(aTHX_ writer->error_records[--writer->error_record_count]);
  }
  Safefree(writer->error_records);
  Safefree(writer);
}

static void
gql_runtime_vm_pending_merge_incref(gql_runtime_vm_pending_merge_t *merge)
{
  if (merge) {
    merge->refcount++;
  }
}

static void
gql_runtime_vm_pending_merge_decref(pTHX_ gql_runtime_vm_pending_merge_t *merge)
{
  if (!merge) {
    return;
  }
  if (--merge->refcount > 0) {
    return;
  }
  gql_runtime_vm_free_block_frame(aTHX_ merge->frame);
  gql_runtime_vm_writer_decref(aTHX_ merge->writer);
  Safefree(merge);
}

static int
gql_runtime_vm_complete_callback_ctx_free(pTHX_ SV *sv, MAGIC *mg)
{
  gql_runtime_vm_complete_callback_ctx_t *ctx = mg && mg->mg_ptr
    ? INT2PTR(gql_runtime_vm_complete_callback_ctx_t *, mg->mg_ptr)
    : NULL;
  if (ctx) {
    SvREFCNT_dec(ctx->state_sv);
    SvREFCNT_dec(ctx->path_frame_sv);
    Safefree(ctx);
    mg->mg_ptr = NULL;
  }
  if (sv && SvTYPE(sv) == SVt_PVCV) {
    CvXSUBANY((CV *)sv).any_ptr = NULL;
  }
  return 0;
}

static int
gql_runtime_vm_error_callback_ctx_free(pTHX_ SV *sv, MAGIC *mg)
{
  gql_runtime_vm_error_callback_ctx_t *ctx = mg && mg->mg_ptr
    ? INT2PTR(gql_runtime_vm_error_callback_ctx_t *, mg->mg_ptr)
    : NULL;
  if (ctx) {
    SvREFCNT_dec(ctx->path_frame_sv);
    Safefree(ctx);
    mg->mg_ptr = NULL;
  }
  if (sv && SvTYPE(sv) == SVt_PVCV) {
    CvXSUBANY((CV *)sv).any_ptr = NULL;
  }
  return 0;
}

static int
gql_runtime_vm_finalize_callback_ctx_free(pTHX_ SV *sv, MAGIC *mg)
{
  gql_runtime_vm_finalize_callback_ctx_t *ctx = mg && mg->mg_ptr
    ? INT2PTR(gql_runtime_vm_finalize_callback_ctx_t *, mg->mg_ptr)
    : NULL;
  if (ctx) {
    gql_runtime_vm_pending_merge_decref(aTHX_ ctx->merge);
    Safefree(ctx);
    mg->mg_ptr = NULL;
  }
  if (sv && SvTYPE(sv) == SVt_PVCV) {
    CvXSUBANY((CV *)sv).any_ptr = NULL;
  }
  return 0;
}

static int
gql_runtime_vm_materialize_response_callback_ctx_free(pTHX_ SV *sv, MAGIC *mg)
{
  gql_runtime_vm_materialize_response_callback_ctx_t *ctx = mg && mg->mg_ptr
    ? INT2PTR(gql_runtime_vm_materialize_response_callback_ctx_t *, mg->mg_ptr)
    : NULL;
  if (ctx) {
    SvREFCNT_dec(ctx->state_sv);
    Safefree(ctx);
    mg->mg_ptr = NULL;
  }
  if (sv && SvTYPE(sv) == SVt_PVCV) {
    CvXSUBANY((CV *)sv).any_ptr = NULL;
  }
  return 0;
}

static MGVTBL gql_runtime_vm_complete_callback_ctx_vtbl = {
  NULL,
  NULL,
  NULL,
  NULL,
  gql_runtime_vm_complete_callback_ctx_free
#if PERL_VERSION_GE(5, 15, 0)
  ,NULL
  ,NULL
  ,NULL
#endif
};

static MGVTBL gql_runtime_vm_error_callback_ctx_vtbl = {
  NULL,
  NULL,
  NULL,
  NULL,
  gql_runtime_vm_error_callback_ctx_free
#if PERL_VERSION_GE(5, 15, 0)
  ,NULL
  ,NULL
  ,NULL
#endif
};

static MGVTBL gql_runtime_vm_finalize_callback_ctx_vtbl = {
  NULL,
  NULL,
  NULL,
  NULL,
  gql_runtime_vm_finalize_callback_ctx_free
#if PERL_VERSION_GE(5, 15, 0)
  ,NULL
  ,NULL
  ,NULL
#endif
};

static MGVTBL gql_runtime_vm_materialize_response_callback_ctx_vtbl = {
  NULL,
  NULL,
  NULL,
  NULL,
  gql_runtime_vm_materialize_response_callback_ctx_free
#if PERL_VERSION_GE(5, 15, 0)
  ,NULL
  ,NULL
  ,NULL
#endif
};

static void
gql_runtime_vm_attach_callback_magic_ptr(pTHX_ SV *sv, MGVTBL *vtbl, void *ptr)
{
  MAGIC *mg;

  if (!sv || !vtbl || !ptr) {
    return;
  }

  sv_magicext(sv, NULL, PERL_MAGIC_ext, vtbl, NULL, 0);
  mg = mg_findext(sv, PERL_MAGIC_ext, vtbl);
  if (!mg) {
    croak("failed to attach runtime callback state");
  }
  mg->mg_ptr = PTR2IV(ptr) ? INT2PTR(char *, ptr) : NULL;
}

static SV *
gql_runtime_vm_wrap_cursor_sv(pTHX_ gql_runtime_vm_cursor_t *cursor)
{
  if (!cursor) {
    return newSVsv(&PL_sv_undef);
  }
  gql_runtime_vm_cursor_incref(cursor);
  return gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::Cursor", cursor);
}

static SV *
gql_runtime_vm_wrap_block_frame_sv(pTHX_ gql_runtime_vm_block_frame_t *frame)
{
  if (!frame) {
    return newSVsv(&PL_sv_undef);
  }
  frame->refcount++;
  return gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::BlockFrame", frame);
}

static SV *
gql_runtime_vm_wrap_field_frame_sv(pTHX_ gql_runtime_vm_field_frame_t *frame)
{
  if (!frame) {
    return newSVsv(&PL_sv_undef);
  }
  frame->refcount++;
  return gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::FieldFrame", frame);
}

static SV *
gql_runtime_vm_wrap_writer_sv(pTHX_ gql_runtime_vm_writer_t *writer)
{
  if (!writer) {
    return newSVsv(&PL_sv_undef);
  }
  gql_runtime_vm_writer_incref(writer);
  return gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::Writer", writer);
}

static void *
gql_runtime_vm_expect_handle_ptr(pTHX_ SV *self, const char *what)
{
  SV *inner;
  if (!self || !SvROK(self)) {
    croak("%s must be a handle reference", what);
  }
  inner = SvRV(self);
  if (!SvIOK(inner) || SvUV(inner) == 0) {
    croak("%s handle is no longer valid", what);
  }
  return INT2PTR(void *, SvUV(inner));
}

static gql_runtime_vm_cursor_t *
gql_runtime_vm_expect_cursor(pTHX_ SV *self)
{
  return (gql_runtime_vm_cursor_t *)gql_runtime_vm_expect_handle_ptr(aTHX_ self, "cursor");
}

static gql_runtime_vm_field_frame_t *
gql_runtime_vm_expect_field_frame(pTHX_ SV *self)
{
  return (gql_runtime_vm_field_frame_t *)gql_runtime_vm_expect_handle_ptr(aTHX_ self, "field frame");
}

static gql_runtime_vm_path_frame_t *
gql_runtime_vm_expect_path_frame(pTHX_ SV *self)
{
  return (gql_runtime_vm_path_frame_t *)gql_runtime_vm_expect_handle_ptr(aTHX_ self, "path frame");
}

static gql_runtime_vm_block_frame_t *
gql_runtime_vm_expect_block_frame(pTHX_ SV *self)
{
  return (gql_runtime_vm_block_frame_t *)gql_runtime_vm_expect_handle_ptr(aTHX_ self, "block frame");
}

static gql_runtime_vm_error_record_t *
gql_runtime_vm_expect_error_record(pTHX_ SV *self)
{
  return (gql_runtime_vm_error_record_t *)gql_runtime_vm_expect_handle_ptr(aTHX_ self, "error record");
}

static gql_runtime_vm_outcome_t *
gql_runtime_vm_expect_outcome(pTHX_ SV *self)
{
  return (gql_runtime_vm_outcome_t *)gql_runtime_vm_expect_handle_ptr(aTHX_ self, "outcome");
}

static gql_runtime_vm_writer_t *
gql_runtime_vm_expect_writer(pTHX_ SV *self)
{
  return (gql_runtime_vm_writer_t *)gql_runtime_vm_expect_handle_ptr(aTHX_ self, "writer");
}

static gql_runtime_vm_pending_merge_t *
gql_runtime_vm_expect_pending_merge(pTHX_ SV *self)
{
  return (gql_runtime_vm_pending_merge_t *)gql_runtime_vm_expect_handle_ptr(aTHX_ self, "pending merge");
}

static gql_runtime_vm_exec_state_handle_t *
gql_runtime_vm_expect_exec_state_handle(pTHX_ SV *self)
{
  return (gql_runtime_vm_exec_state_handle_t *)gql_runtime_vm_expect_handle_ptr(aTHX_ self, "exec state");
}

static gql_runtime_vm_native_runtime_t *gql_runtime_vm_exec_state_native_runtime(pTHX_ gql_runtime_vm_exec_state_handle_t *s);

static SV *
gql_runtime_vm_new_error_outcome_sv(pTHX_ SV *message_sv, SV *path_frame_sv);

static SV *
gql_runtime_vm_wrap_outcome_sv(pTHX_ gql_runtime_vm_outcome_t *outcome)
{
  if (!outcome) {
    return newSVsv(&PL_sv_undef);
  }
  gql_runtime_vm_outcome_incref(outcome);
  return gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::Outcome", outcome);
}

static SV *
gql_runtime_vm_wrap_path_frame_sv(pTHX_ gql_runtime_vm_path_frame_t *path_frame)
{
  if (!path_frame) {
    return newSVsv(&PL_sv_undef);
  }
  path_frame->refcount++;
  return gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::PathFrame", path_frame);
}

static SV *
gql_runtime_vm_wrap_pending_merge_sv(pTHX_ gql_runtime_vm_pending_merge_t *merge)
{
  if (!merge) {
    return newSVsv(&PL_sv_undef);
  }
  gql_runtime_vm_pending_merge_incref(merge);
  return gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::PendingMerge", merge);
}

static gql_runtime_vm_path_frame_t *
gql_runtime_vm_new_path_frame_struct(pTHX_ gql_runtime_vm_path_frame_t *parent, SV *key)
{
  gql_runtime_vm_path_frame_t *frame;
  Newxz(frame, 1, gql_runtime_vm_path_frame_t);
  frame->refcount = 1;
  if (parent) {
    frame->parent = parent;
    frame->parent->refcount++;
  }
  if (key && SvOK(key)) {
    if (SvIOK(key) && !SvROK(key)) {
      frame->key_kind = 1;
      frame->key_iv = SvIV(key);
    } else {
      STRLEN len;
      const char *pv = SvPV(key, len);
      frame->key_kind = 2;
      Newx(frame->key_pv, len + 1, char);
      Copy(pv, frame->key_pv, len, char);
      frame->key_pv[len] = '\0';
    }
  }
  return frame;
}

static gql_runtime_vm_path_frame_t *
gql_runtime_vm_new_path_frame_struct_pvn(
  pTHX_
  gql_runtime_vm_path_frame_t *parent,
  const char *key_pv,
  STRLEN key_len
)
{
  gql_runtime_vm_path_frame_t *frame;
  Newxz(frame, 1, gql_runtime_vm_path_frame_t);
  frame->refcount = 1;
  if (parent) {
    frame->parent = parent;
    frame->parent->refcount++;
  }
  if (key_pv && key_len > 0) {
    frame->key_kind = 2;
    Newx(frame->key_pv, key_len + 1, char);
    Copy(key_pv, frame->key_pv, key_len, char);
    frame->key_pv[key_len] = '\0';
  }
  return frame;
}

static SV *
gql_runtime_vm_new_path_frame_handle(pTHX_ SV *parent, SV *key)
{
  gql_runtime_vm_path_frame_t *parent_ptr = NULL;
  gql_runtime_vm_path_frame_t *frame;
  if (parent && SvOK(parent) && SvROK(parent) && SvIOK(SvRV(parent)) && SvUV(SvRV(parent)) != 0) {
    parent_ptr = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(parent)));
  }
  frame = gql_runtime_vm_new_path_frame_struct(aTHX_ parent_ptr, key);
  return gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::PathFrame", frame);
}

static gql_runtime_vm_block_frame_t *
gql_runtime_vm_new_block_frame_struct(pTHX)
{
  gql_runtime_vm_block_frame_t *frame;
  Newxz(frame, 1, gql_runtime_vm_block_frame_t);
  frame->refcount = 1;
  frame->values_value = gql_runtime_vm_new_native_value_object();
  frame->pending_count = 0;
  frame->pending_capacity = 0;
  frame->pending_entries = NULL;
  return frame;
}

static SV *
gql_runtime_vm_new_block_frame_handle(pTHX)
{
  return gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::BlockFrame", gql_runtime_vm_new_block_frame_struct(aTHX));
}

static gql_runtime_vm_field_frame_t *
gql_runtime_vm_new_field_frame_struct(pTHX_ SV *source, gql_runtime_vm_path_frame_t *path_frame)
{
  gql_runtime_vm_field_frame_t *frame;
  Newxz(frame, 1, gql_runtime_vm_field_frame_t);
  frame->refcount = 1;
  frame->source = newSVsv(source ? source : &PL_sv_undef);
  if (path_frame) {
    frame->path_frame = path_frame;
    frame->path_frame->refcount++;
  }
  frame->resolved_value = newSVsv(&PL_sv_undef);
  frame->outcome = NULL;
  return frame;
}

static SV *
gql_runtime_vm_new_field_frame_handle(pTHX_ SV *source, SV *path_frame)
{
  gql_runtime_vm_path_frame_t *path_ptr = NULL;
  if (path_frame && SvOK(path_frame) && SvROK(path_frame) && SvIOK(SvRV(path_frame)) && SvUV(SvRV(path_frame)) != 0) {
    path_ptr = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(path_frame)));
  }
  return gql_runtime_vm_new_handle_sv(
    aTHX_ "GraphQL::Houtou::Runtime::FieldFrame",
    gql_runtime_vm_new_field_frame_struct(aTHX_ source, path_ptr)
  );
}

static void
gql_runtime_vm_enter_field_now(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *source, SV *base_path)
{
  const gql_runtime_vm_native_runtime_t *runtime;
  const gql_runtime_vm_native_slot_t *native_slot;
  const char *result_name_pv = NULL;
  STRLEN result_name_len = 0;
  gql_runtime_vm_path_frame_t *path_frame = NULL;
  gql_runtime_vm_field_frame_t *field_frame;

  if (!s || !s->cursor) {
    return;
  }

  runtime = gql_runtime_vm_exec_state_native_runtime(aTHX_ s);
  native_slot = gql_runtime_vm_cursor_current_native_slot(s->cursor);
  native_slot = gql_runtime_vm_effective_slot(runtime, native_slot);
  if (native_slot && native_slot->result_name && *native_slot->result_name) {
    result_name_pv = native_slot->result_name;
    result_name_len = (STRLEN)strlen(result_name_pv);
  }
  path_frame = result_name_pv
    ? gql_runtime_vm_new_path_frame_struct_pvn(
        aTHX_
        (base_path && SvOK(base_path) && SvROK(base_path) && SvIOK(SvRV(base_path)) && SvUV(SvRV(base_path)) != 0)
          ? INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(base_path)))
          : NULL,
        result_name_pv,
        result_name_len
      )
    : gql_runtime_vm_new_path_frame_struct(
        aTHX_
        (base_path && SvOK(base_path) && SvROK(base_path) && SvIOK(SvRV(base_path)) && SvUV(SvRV(base_path)) != 0)
          ? INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(base_path)))
          : NULL,
        &PL_sv_undef
      );
  field_frame = gql_runtime_vm_new_field_frame_struct(aTHX_ source, path_frame);
  gql_runtime_vm_path_frame_decref(path_frame);
  gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
  s->field_frame = field_frame;
}

static void
gql_runtime_vm_leave_field_now(pTHX_ gql_runtime_vm_exec_state_handle_t *s)
{
  if (!s) {
    return;
  }
  gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
  s->field_frame = NULL;
}

static gql_runtime_vm_outcome_t *
gql_runtime_vm_new_error_outcome_struct_for_path(pTHX_ SV *message_sv, gql_runtime_vm_path_frame_t *path_frame)
{
  SV *path_frame_sv = gql_runtime_vm_wrap_path_frame_sv(aTHX_ path_frame);
  SV *outcome_sv = gql_runtime_vm_new_error_outcome_sv(aTHX_ message_sv, path_frame_sv);
  gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_expect_outcome(aTHX_ outcome_sv);
  gql_runtime_vm_outcome_incref(outcome);
  SvREFCNT_dec(outcome_sv);
  SvREFCNT_dec(path_frame_sv);
  return outcome;
}

static void
gql_runtime_vm_consume_current_outcome_now(pTHX_ gql_runtime_vm_exec_state_handle_t *s, gql_runtime_vm_outcome_t *outcome)
{
  gql_runtime_vm_block_frame_t *frame;
  gql_runtime_vm_writer_t *writer;
  const gql_runtime_vm_native_runtime_t *runtime;
  const gql_runtime_vm_native_slot_t *native_slot;
  STRLEN result_name_len = 0;
  const char *result_name_pv = NULL;

  if (!s || !outcome || !s->frame || !s->writer) {
    gql_runtime_vm_leave_field_now(aTHX_ s);
    return;
  }

  frame = s->frame;
  writer = s->writer;
  runtime = gql_runtime_vm_exec_state_native_runtime(aTHX_ s);
  native_slot = s->cursor ? gql_runtime_vm_cursor_current_native_slot(s->cursor) : NULL;
  native_slot = gql_runtime_vm_effective_slot(runtime, native_slot);
  if (native_slot && native_slot->result_name && *native_slot->result_name) {
    result_name_pv = native_slot->result_name;
    result_name_len = (STRLEN)strlen(result_name_pv);
  }

  if (s->field_frame) {
    gql_runtime_vm_outcome_decref(aTHX_ s->field_frame->outcome);
    gql_runtime_vm_outcome_incref(outcome);
    s->field_frame->outcome = outcome;
  }

  gql_runtime_vm_consume_outcome_native_object(
    aTHX_ frame->values_value,
    result_name_pv ? result_name_pv : "",
    outcome,
    writer
  );
  gql_runtime_vm_leave_field_now(aTHX_ s);
}

static void
gql_runtime_vm_consume_current_result_now(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *result_sv)
{
  gql_runtime_vm_block_frame_t *frame;
  const gql_runtime_vm_native_runtime_t *runtime;
  const gql_runtime_vm_native_slot_t *native_slot;
  const char *result_name_pv = NULL;
  STRLEN result_name_len = 0;

  if (!s) {
    return;
  }

  if (result_sv && sv_derived_from(result_sv, "GraphQL::Houtou::Runtime::Outcome")) {
    gql_runtime_vm_consume_current_outcome_now(aTHX_ s, gql_runtime_vm_expect_outcome(aTHX_ result_sv));
    return;
  }

  frame = s->frame;
  runtime = gql_runtime_vm_exec_state_native_runtime(aTHX_ s);
  native_slot = s->cursor ? gql_runtime_vm_cursor_current_native_slot(s->cursor) : NULL;
  native_slot = gql_runtime_vm_effective_slot(runtime, native_slot);
  if (native_slot && native_slot->result_name && *native_slot->result_name) {
    result_name_pv = native_slot->result_name;
    result_name_len = (STRLEN)strlen(result_name_pv);
  }
  if (frame && result_name_pv && result_name_len > 0 && result_sv && SvOK(result_sv)) {
    gql_runtime_vm_block_frame_push_pending_pvn(
      aTHX_ frame,
      result_name_pv,
      result_name_len,
      result_sv
    );
  }
  gql_runtime_vm_leave_field_now(aTHX_ s);
}

static SV *
gql_runtime_vm_block_frame_finalize_sv(pTHX_ gql_runtime_vm_block_frame_t *frame, SV *promise_all_cb, SV *promise_then_cb, gql_runtime_vm_writer_t *writer);

static SV *
gql_runtime_vm_finalize_current_block_now(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *snapshot)
{
  gql_runtime_vm_block_frame_t *frame;
  gql_runtime_vm_block_frame_t *completed_frame;
  SV *result;

  if (!s || !s->frame) {
    return newSVsv(&PL_sv_undef);
  }

  frame = s->frame;
  completed_frame = frame;
  if (s->promise_code && SvOK(s->promise_code)) {
    result = gql_runtime_vm_block_frame_finalize_sv(
      aTHX_
      frame,
      s->promise_all_cb,
      s->promise_then_cb,
      s->writer
    );
  } else {
    result = gql_runtime_vm_native_value_materialize_sv(aTHX_ frame->values_value);
  }

  if (s->cursor && snapshot && SvOK(snapshot)) {
    gql_runtime_vm_cursor_restore_sv(aTHX_ s->cursor, snapshot);
  }

  if (s->frame_stack_count > 0) {
    s->frame_stack_count--;
    s->frame_stack[s->frame_stack_count] = NULL;
  }
  gql_runtime_vm_free_block_frame(aTHX_ completed_frame);
  s->frame = s->frame_stack_count > 0 ? s->frame_stack[s->frame_stack_count - 1] : NULL;

  return result;
}

static SV *
gql_runtime_vm_block_frame_finalize_sv(
  pTHX_
  gql_runtime_vm_block_frame_t *frame,
  SV *promise_all_cb,
  SV *promise_then_cb,
  gql_runtime_vm_writer_t *writer
)
{
  AV *pending_av;
  IV i;
  dSP;

  if (!frame) {
    return newSVsv(&PL_sv_undef);
  }
  if (frame->pending_count == 0) {
    return gql_runtime_vm_native_value_materialize_sv(aTHX_ frame->values_value);
  }
  if (!promise_all_cb || !SvOK(promise_all_cb) || !promise_then_cb || !SvOK(promise_then_cb)) {
    croak("pending async runtime blocks require promise all/then callbacks");
  }

  pending_av = newAV();
  for (i = 0; i < frame->pending_count; i++) {
    if (frame->pending_entries[i].payload_kind == GQL_VM_PENDING_OUTCOME_PTR) {
      gql_runtime_vm_outcome_t *outcome = frame->pending_entries[i].payload.outcome_ptr;
      gql_runtime_vm_outcome_incref(outcome);
      av_push(pending_av, gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::Outcome", outcome));
    } else if (frame->pending_entries[i].payload_kind == GQL_VM_PENDING_PROMISE_SV) {
      av_push(pending_av, newSVsv(frame->pending_entries[i].payload.promise_sv));
    }
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  for (i = 0; i <= av_len(pending_av); i++) {
    SV **svp = av_fetch(pending_av, i, 0);
    if (svp && *svp) {
      XPUSHs(*svp);
    }
  }
  PUTBACK;
  call_sv(promise_all_cb, G_SCALAR);
  SPAGAIN;
  {
    SV *aggregate = POPs;
    gql_runtime_vm_pending_merge_t *merge;
    SV *callback_sv;
    SV *retval;
    SvREFCNT_inc(aggregate);
    PUTBACK;
    FREETMPS;
    LEAVE;

    Newxz(merge, 1, gql_runtime_vm_pending_merge_t);
    merge->refcount = 1;
    merge->frame = frame;
    frame->refcount++;
    merge->writer = writer;
    gql_runtime_vm_writer_incref(writer);
    callback_sv = gql_runtime_vm_new_finalize_callback_sv(aTHX_ merge);
    gql_runtime_vm_pending_merge_decref(aTHX_ merge);

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(aggregate ? aggregate : &PL_sv_undef);
    XPUSHs(callback_sv ? callback_sv : &PL_sv_undef);
    PUTBACK;
    call_sv(promise_then_cb, G_SCALAR);
    SPAGAIN;
    retval = POPs;
    SvREFCNT_inc(retval);
    PUTBACK;
    FREETMPS;
    LEAVE;

    SvREFCNT_dec(aggregate);
    SvREFCNT_dec(callback_sv);
    SvREFCNT_dec((SV *)pending_av);
    return retval;
  }
}

static SV *
gql_runtime_vm_fetch_hash_entry_sv(pTHX_ HV *hv, const char *key, I32 keylen)
{
  SV **svp = hv_fetch(hv, key, keylen, 0);
  return (svp && SvOK(*svp)) ? *svp : NULL;
}

static SV *
gql_runtime_vm_promise_callback_from_code_sv(pTHX_ SV *promise_code, const char *key, I32 keylen)
{
  if (!promise_code || !SvOK(promise_code) || !SvROK(promise_code) || SvTYPE(SvRV(promise_code)) != SVt_PVHV) {
    return NULL;
  }
  return gql_runtime_vm_fetch_hash_entry_sv(aTHX_ (HV *)SvRV(promise_code), key, keylen);
}

static const char *
gql_runtime_vm_fetch_hash_entry_pv(pTHX_ HV *hv, const char *key, I32 keylen)
{
  SV *sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ hv, key, keylen);
  return sv ? SvPV_nolen(sv) : NULL;
}

static int
gql_runtime_vm_is_promise_value_sv(pTHX_ SV *is_promise_cb, SV *value)
{
  dSP;
  int is_promise = 0;

  if (!is_promise_cb || !SvOK(is_promise_cb)) {
    return 0;
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(value ? value : &PL_sv_undef);
  PUTBACK;
  call_sv(is_promise_cb, G_SCALAR | G_EVAL);
  SPAGAIN;
  if (!SvTRUE(ERRSV) && SP > PL_stack_base) {
    is_promise = SvTRUE(POPs) ? 1 : 0;
  } else if (SP > PL_stack_base) {
    (void)POPs;
  }
  if (SvTRUE(ERRSV)) {
    sv_setsv(ERRSV, &PL_sv_undef);
  }
  PUTBACK;
  FREETMPS;
  LEAVE;

  return is_promise;
}

static SV *
gql_runtime_vm_named_coderef_sv(pTHX_ const char *name)
{
  CV *cv = name ? get_cv(name, 0) : NULL;
  return cv ? newRV_inc((SV *)cv) : newSVsv(&PL_sv_undef);
}

static SV *
gql_runtime_vm_pending_merge_resolve_sv(pTHX_ gql_runtime_vm_pending_merge_t *state, SV *resolved)
{
  AV *resolved_av = gql_runtime_vm_expect_arrayref(aTHX_ resolved, "resolved outcomes");
  HV *merged_hv = newHV();
  SSize_t i;
  SV *base_sv = gql_runtime_vm_native_value_materialize_sv(aTHX_ state->frame->values_value);
  HV *base_hv = (base_sv && SvROK(base_sv) && SvTYPE(SvRV(base_sv)) == SVt_PVHV) ? (HV *)SvRV(base_sv) : NULL;
  HE *he;

  if (base_hv) {
    hv_iterinit(base_hv);
    while ((he = hv_iternext(base_hv))) {
      SV *key_sv = hv_iterkeysv(he);
      SV *val_sv = hv_iterval(base_hv, he);
      hv_store_ent(merged_hv, key_sv, val_sv ? newSVsv(val_sv) : newSV(0), 0);
    }
  }
  SvREFCNT_dec(base_sv);

  for (i = 0; i <= av_len(resolved_av) && i < state->frame->pending_count; i++) {
    SV **outcome_svp = av_fetch(resolved_av, i, 0);
    if (outcome_svp && *outcome_svp) {
      SV *result_name_sv = newSVpvn(
        state->frame->pending_entries[i].result_name_pv,
        state->frame->pending_entries[i].result_name_len
      );
      gql_runtime_vm_consume_outcome_struct(
        aTHX_
        merged_hv,
        result_name_sv,
        gql_runtime_vm_expect_outcome(aTHX_ *outcome_svp),
        state->writer
      );
      SvREFCNT_dec(result_name_sv);
    }
  }

  gql_runtime_vm_block_frame_clear_pending(aTHX_ state->frame);
  return newRV_noinc((SV *)merged_hv);
}

static XS(gql_runtime_vm_xs_complete_callback)
{
  dVAR;
  dXSARGS;
  gql_runtime_vm_complete_callback_ctx_t *ctx = INT2PTR(
    gql_runtime_vm_complete_callback_ctx_t *,
    CvXSUBANY(cv).any_ptr
  );
  SV *resolved_sv = &PL_sv_undef;
  SV *ret;
  SV *tmp_resolved = NULL;

  if (!ctx || !ctx->state_sv) {
    XSRETURN_UNDEF;
  }

  if (items == 1) {
    resolved_sv = ST(0) ? ST(0) : &PL_sv_undef;
  } else {
    AV *resolved_av = newAV();
    I32 i;
    for (i = 0; i < items; i++) {
      av_push(resolved_av, newSVsv(ST(i) ? ST(i) : &PL_sv_undef));
    }
    tmp_resolved = newRV_noinc((SV *)resolved_av);
    resolved_sv = tmp_resolved;
  }

  ret = gql_runtime_vm_exec_state_complete_async_sv(
    aTHX_
    ctx->state_sv,
    gql_runtime_vm_expect_exec_state_handle(aTHX_ ctx->state_sv),
    ctx->path_frame_sv ? ctx->path_frame_sv : &PL_sv_undef,
    ctx->block_index,
    ctx->slot_index,
    ctx->op_index,
    resolved_sv
  );
  if (tmp_resolved) {
    SvREFCNT_dec(tmp_resolved);
  }

  ST(0) = sv_2mortal(ret ? ret : newSVsv(&PL_sv_undef));
  XSRETURN(1);
}

static XS(gql_runtime_vm_xs_error_callback)
{
  dVAR;
  dXSARGS;
  gql_runtime_vm_error_callback_ctx_t *ctx = INT2PTR(
    gql_runtime_vm_error_callback_ctx_t *,
    CvXSUBANY(cv).any_ptr
  );
  SV *error_sv = items > 0 && ST(0) ? ST(0) : &PL_sv_undef;
  SV *ret = gql_runtime_vm_new_error_outcome_sv(
    aTHX_
    error_sv,
    (ctx && ctx->path_frame_sv) ? ctx->path_frame_sv : &PL_sv_undef
  );

  ST(0) = sv_2mortal(ret ? ret : newSVsv(&PL_sv_undef));
  XSRETURN(1);
}

static XS(gql_runtime_vm_xs_finalize_callback)
{
  dVAR;
  dXSARGS;
  gql_runtime_vm_finalize_callback_ctx_t *ctx = INT2PTR(
    gql_runtime_vm_finalize_callback_ctx_t *,
    CvXSUBANY(cv).any_ptr
  );
  SV *resolved_sv = &PL_sv_undef;
  SV *tmp_resolved = NULL;
  SV *ret;

  if (!ctx || !ctx->merge) {
    XSRETURN_UNDEF;
  }

  if (items == 1 && ST(0) && SvROK(ST(0)) && SvTYPE(SvRV(ST(0))) == SVt_PVAV) {
    resolved_sv = ST(0);
  } else {
    AV *resolved_av = newAV();
    I32 i;
    for (i = 0; i < items; i++) {
      av_push(resolved_av, newSVsv(ST(i) ? ST(i) : &PL_sv_undef));
    }
    tmp_resolved = newRV_noinc((SV *)resolved_av);
    resolved_sv = tmp_resolved;
  }

  ret = gql_runtime_vm_pending_merge_resolve_sv(aTHX_ ctx->merge, resolved_sv);
  if (tmp_resolved) {
    SvREFCNT_dec(tmp_resolved);
  }

  ST(0) = sv_2mortal(ret ? ret : newSVsv(&PL_sv_undef));
  XSRETURN(1);
}

static XS(gql_runtime_vm_xs_materialize_response_callback)
{
  dVAR;
  dXSARGS;
  gql_runtime_vm_materialize_response_callback_ctx_t *ctx = INT2PTR(
    gql_runtime_vm_materialize_response_callback_ctx_t *,
    CvXSUBANY(cv).any_ptr
  );
  SV *resolved_sv = &PL_sv_undef;
  SV *tmp_resolved = NULL;
  SV *ret;

  if (!ctx || !ctx->state_sv) {
    XSRETURN_UNDEF;
  }

  if (items == 1) {
    resolved_sv = ST(0) ? ST(0) : &PL_sv_undef;
  } else if (items > 1) {
    AV *resolved_av = newAV();
    I32 i;
    for (i = 0; i < items; i++) {
      av_push(resolved_av, newSVsv(ST(i) ? ST(i) : &PL_sv_undef));
    }
    tmp_resolved = newRV_noinc((SV *)resolved_av);
    resolved_sv = tmp_resolved;
  }

  ret = gql_runtime_vm_exec_state_materialize_response_sv(
    aTHX_
    gql_runtime_vm_expect_exec_state_handle(aTHX_ ctx->state_sv),
    resolved_sv
  );
  if (tmp_resolved) {
    SvREFCNT_dec(tmp_resolved);
  }

  ST(0) = sv_2mortal(ret ? ret : newSVsv(&PL_sv_undef));
  XSRETURN(1);
}

static SV *
gql_runtime_vm_new_complete_callback_sv(pTHX_ SV *state_sv, SV *path_frame_sv, IV block_index, IV slot_index, IV op_index)
{
  CV *cv;
  SV *rv;
  gql_runtime_vm_complete_callback_ctx_t *ctx;

  Newxz(ctx, 1, gql_runtime_vm_complete_callback_ctx_t);
  ctx->state_sv = state_sv ? SvREFCNT_inc_simple_NN(state_sv) : NULL;
  ctx->path_frame_sv = path_frame_sv ? SvREFCNT_inc_simple_NN(path_frame_sv) : NULL;
  ctx->block_index = block_index;
  ctx->slot_index = slot_index;
  ctx->op_index = op_index;

  cv = newXS(NULL, gql_runtime_vm_xs_complete_callback, __FILE__);
  CvXSUBANY(cv).any_ptr = ctx;
  gql_runtime_vm_attach_callback_magic_ptr(aTHX_ (SV *)cv, &gql_runtime_vm_complete_callback_ctx_vtbl, ctx);
  rv = newRV_noinc((SV *)cv);
  return rv;
}

static SV *
gql_runtime_vm_new_error_callback_sv(pTHX_ SV *path_frame_sv)
{
  CV *cv;
  SV *rv;
  gql_runtime_vm_error_callback_ctx_t *ctx;

  Newxz(ctx, 1, gql_runtime_vm_error_callback_ctx_t);
  ctx->path_frame_sv = path_frame_sv ? SvREFCNT_inc_simple_NN(path_frame_sv) : NULL;

  cv = newXS(NULL, gql_runtime_vm_xs_error_callback, __FILE__);
  CvXSUBANY(cv).any_ptr = ctx;
  gql_runtime_vm_attach_callback_magic_ptr(aTHX_ (SV *)cv, &gql_runtime_vm_error_callback_ctx_vtbl, ctx);
  rv = newRV_noinc((SV *)cv);
  return rv;
}

static SV *
gql_runtime_vm_new_finalize_callback_sv(pTHX_ gql_runtime_vm_pending_merge_t *merge)
{
  CV *cv;
  SV *rv;
  gql_runtime_vm_finalize_callback_ctx_t *ctx;

  Newxz(ctx, 1, gql_runtime_vm_finalize_callback_ctx_t);
  ctx->merge = merge;
  gql_runtime_vm_pending_merge_incref(merge);

  cv = newXS(NULL, gql_runtime_vm_xs_finalize_callback, __FILE__);
  CvXSUBANY(cv).any_ptr = ctx;
  gql_runtime_vm_attach_callback_magic_ptr(aTHX_ (SV *)cv, &gql_runtime_vm_finalize_callback_ctx_vtbl, ctx);
  rv = newRV_noinc((SV *)cv);
  return rv;
}

static SV *
gql_runtime_vm_new_materialize_response_callback_sv(pTHX_ SV *state_sv)
{
  CV *cv;
  SV *rv;
  gql_runtime_vm_materialize_response_callback_ctx_t *ctx;

  Newxz(ctx, 1, gql_runtime_vm_materialize_response_callback_ctx_t);
  ctx->state_sv = state_sv ? SvREFCNT_inc_simple_NN(state_sv) : NULL;

  cv = newXS(NULL, gql_runtime_vm_xs_materialize_response_callback, __FILE__);
  CvXSUBANY(cv).any_ptr = ctx;
  gql_runtime_vm_attach_callback_magic_ptr(aTHX_ (SV *)cv, &gql_runtime_vm_materialize_response_callback_ctx_vtbl, ctx);
  rv = newRV_noinc((SV *)cv);
  return rv;
}

static SV *
gql_runtime_vm_new_outcome_handle_sv(pTHX_ U8 kind_code, SV *value, SV *error_records)
{
  gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(
    aTHX_
    kind_code,
    value ? value : &PL_sv_undef,
    error_records ? error_records : &PL_sv_undef
  );
  SV *ret = gql_runtime_vm_wrap_outcome_sv(aTHX_ outcome);
  gql_runtime_vm_outcome_decref(aTHX_ outcome);
  return ret;
}

static SV *
gql_runtime_vm_call_then_promise_sv(
  pTHX_
  SV *promise_then_cb,
  SV *promise_sv,
  SV *callback_sv,
  SV *error_callback_sv,
  SV *path_frame_sv
)
{
  dSP;
  SV *ret = NULL;

  if (!promise_then_cb || !SvOK(promise_then_cb)) {
    croak("missing promise then callback");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(promise_sv ? promise_sv : &PL_sv_undef);
  XPUSHs(callback_sv ? callback_sv : &PL_sv_undef);
  if (error_callback_sv) {
    XPUSHs(error_callback_sv);
  }
  PUTBACK;
  call_sv(promise_then_cb, G_SCALAR | G_EVAL);
  SPAGAIN;
  if (!SvTRUE(ERRSV) && SP > PL_stack_base) {
    ret = POPs;
    ret = ret ? newSVsv(ret) : newSVsv(&PL_sv_undef);
  } else if (SP > PL_stack_base) {
    (void)POPs;
  }
  if (SvTRUE(ERRSV)) {
    ret = gql_runtime_vm_new_error_outcome_sv(
      aTHX_
      ERRSV,
      path_frame_sv ? path_frame_sv : &PL_sv_undef
    );
    sv_setsv(ERRSV, &PL_sv_undef);
  }
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret ? ret : newSVsv(&PL_sv_undef);
}

static SV *
gql_runtime_vm_call_all_promise_sv(
  pTHX_
  SV *promise_all_cb,
  AV *values_av,
  SV *path_frame_sv
)
{
  dSP;
  SV *ret = NULL;
  SSize_t i;

  if (!promise_all_cb || !SvOK(promise_all_cb)) {
    croak("missing promise all callback");
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  for (i = 0; values_av && i <= av_len(values_av); i++) {
    SV **svp = av_fetch(values_av, i, 0);
    XPUSHs((svp && *svp) ? *svp : &PL_sv_undef);
  }
  PUTBACK;
  call_sv(promise_all_cb, G_SCALAR | G_EVAL);
  SPAGAIN;
  if (!SvTRUE(ERRSV) && SP > PL_stack_base) {
    ret = POPs;
    ret = ret ? newSVsv(ret) : newSVsv(&PL_sv_undef);
  } else if (SP > PL_stack_base) {
    (void)POPs;
  }
  if (SvTRUE(ERRSV)) {
    ret = gql_runtime_vm_new_error_outcome_sv(
      aTHX_
      ERRSV,
      path_frame_sv ? path_frame_sv : &PL_sv_undef
    );
    sv_setsv(ERRSV, &PL_sv_undef);
  }
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret ? ret : newSVsv(&PL_sv_undef);
}

static SV *
gql_runtime_vm_exec_state_finalize_async_response_sv(
  pTHX_
  SV *state_sv,
  gql_runtime_vm_exec_state_handle_t *s,
  SV *data_sv
)
{
  dSP;

  if (
    s &&
    s->promise_then_cb && SvOK(s->promise_then_cb) &&
    s->promise_is_promise_cb && SvOK(s->promise_is_promise_cb) &&
    gql_runtime_vm_is_promise_value_sv(aTHX_ s->promise_is_promise_cb, data_sv)
  ) {
    SV *callback_sv = gql_runtime_vm_new_materialize_response_callback_sv(aTHX_ state_sv);
    SV *ret = NULL;

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(data_sv ? data_sv : &PL_sv_undef);
    XPUSHs(callback_sv ? callback_sv : &PL_sv_undef);
    PUTBACK;
    call_sv(s->promise_then_cb, G_SCALAR | G_EVAL);
    SPAGAIN;
    if (SvTRUE(ERRSV)) {
      SV *err = newSVsv(ERRSV);
      sv_setsv(ERRSV, &PL_sv_undef);
      PUTBACK;
      FREETMPS;
      LEAVE;
      SvREFCNT_dec(callback_sv);
      croak_sv(err);
    }
    if (SP > PL_stack_base) {
      ret = POPs;
      ret = ret ? newSVsv(ret) : newSVsv(&PL_sv_undef);
    }
    PUTBACK;
    FREETMPS;
    LEAVE;
    SvREFCNT_dec(callback_sv);
    return ret ? ret : newSVsv(&PL_sv_undef);
  }

  return gql_runtime_vm_exec_state_materialize_response_sv(aTHX_ s, data_sv);
}

static SV *
gql_runtime_vm_exec_state_resolve_runtime_type_current_sv(
  pTHX_
  SV *state_sv,
  gql_runtime_vm_exec_state_handle_t *s,
  SV *resolved_sv,
  SV *path_frame_sv,
  SV **error_out
)
{
  const gql_runtime_vm_native_runtime_t *runtime = gql_runtime_vm_exec_state_native_runtime(aTHX_ s);
  const gql_runtime_vm_native_slot_t *slot = (s && s->cursor) ? gql_runtime_vm_cursor_current_native_slot(s->cursor) : NULL;
  SV *abstract_type_sv = gql_runtime_vm_state_current_return_type_sv(aTHX_ s, NULL, NULL);
  SV *info_sv = NULL;
  HV *schema_hv;
  SV *runtime_cache_sv;
  SV *runtime_type_sv;

  if (error_out) {
    *error_out = NULL;
  }

  slot = gql_runtime_vm_effective_slot(runtime, slot);
  if (!slot || !slot->return_type_name || !*slot->return_type_name) {
    return NULL;
  }

  info_sv = gql_runtime_vm_new_lazy_info_sv(aTHX_ state_sv, s, path_frame_sv);
  schema_hv = gql_runtime_vm_expect_hashref(aTHX_ s->runtime_schema, "runtime schema");
  runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "runtime_cache", 13);
  runtime_type_sv = gql_runtime_vm_resolve_runtime_type_for_abstract_sv(
    aTHX_
    runtime_cache_sv,
    slot->return_type_name,
    resolved_sv,
    s->context,
    info_sv,
    abstract_type_sv,
    error_out
  );
  SvREFCNT_dec(info_sv);

  return runtime_type_sv;
}

static SV *
gql_runtime_vm_exec_state_complete_current_native_async_sv(
  pTHX_
  SV *state_sv,
  gql_runtime_vm_exec_state_handle_t *s,
  SV *path_frame_sv,
  SV *resolved_sv
)
{
  const gql_runtime_vm_native_runtime_t *runtime = gql_runtime_vm_exec_state_native_runtime(aTHX_ s);
  const gql_runtime_vm_native_op_t *op = (s && s->cursor) ? gql_runtime_vm_cursor_current_native_op(s->cursor) : NULL;
  const gql_runtime_vm_native_slot_t *slot = (s && s->cursor) ? gql_runtime_vm_cursor_current_native_slot(s->cursor) : NULL;
  IV complete_code = op ? op->complete_code : 0;

  slot = gql_runtime_vm_effective_slot(runtime, slot);

  switch (complete_code) {
    case GQL_VM_COMPLETE_OBJECT:
    {
      IV child_block_index = op ? op->child_block_index : -1;
      SV *child_value;

      if (!resolved_sv || !SvOK(resolved_sv)) {
        return gql_runtime_vm_new_outcome_handle_sv(aTHX_ GQL_VM_KIND_SCALAR, &PL_sv_undef, &PL_sv_undef);
      }
      if (child_block_index < 0) {
        return gql_runtime_vm_new_outcome_handle_sv(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv, &PL_sv_undef);
      }

      child_value = gql_runtime_vm_exec_state_execute_block_async_sv(
        aTHX_
        state_sv,
        s,
        child_block_index,
        resolved_sv,
        path_frame_sv
      );
      if (s->promise_is_promise_cb && SvOK(s->promise_is_promise_cb) && gql_runtime_vm_is_promise_value_sv(aTHX_ s->promise_is_promise_cb, child_value)) {
        SV *callback_sv = gql_runtime_vm_named_coderef_sv(
          aTHX_ "GraphQL::Houtou::XS::VM::wrap_object_outcome_callback_xs"
        );
        SV *ret = gql_runtime_vm_call_then_promise_sv(
          aTHX_
          s->promise_then_cb,
          child_value,
          callback_sv,
          NULL,
          path_frame_sv
        );
        SvREFCNT_dec(callback_sv);
        SvREFCNT_dec(child_value);
        return ret;
      }

      {
        SV *ret = gql_runtime_vm_new_outcome_handle_sv(aTHX_ GQL_VM_KIND_OBJECT, child_value, &PL_sv_undef);
        SvREFCNT_dec(child_value);
        return ret;
      }
    }
    case GQL_VM_COMPLETE_LIST:
    {
      IV child_block_index = op ? op->child_block_index : -1;
      AV *items_av;
      AV *resolved_items_av;
      SSize_t i;
      int has_promise = 0;

      if (!resolved_sv || !SvOK(resolved_sv)) {
        return gql_runtime_vm_new_outcome_handle_sv(aTHX_ GQL_VM_KIND_SCALAR, &PL_sv_undef, &PL_sv_undef);
      }
      if (!SvROK(resolved_sv) || SvTYPE(SvRV(resolved_sv)) != SVt_PVAV) {
        return gql_runtime_vm_new_outcome_handle_sv(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv, &PL_sv_undef);
      }

      items_av = (AV *)SvRV(resolved_sv);
      resolved_items_av = newAV();
      for (i = 0; i <= av_len(items_av); i++) {
        SV **item_svp = av_fetch(items_av, i, 0);
        SV *item_sv = (item_svp && *item_svp) ? *item_svp : &PL_sv_undef;
        SV *item_result;

        if (child_block_index >= 0) {
          SV *item_key = newSViv(i);
          SV *item_path = gql_runtime_vm_new_path_frame_handle(
            aTHX_
            path_frame_sv ? path_frame_sv : &PL_sv_undef,
            item_key
          );
          item_result = gql_runtime_vm_exec_state_execute_block_async_sv(
            aTHX_
            state_sv,
            s,
            child_block_index,
            item_sv,
            item_path
          );
          SvREFCNT_dec(item_path);
          SvREFCNT_dec(item_key);
        } else {
          item_result = newSVsv(item_sv);
        }

        if (s->promise_is_promise_cb && SvOK(s->promise_is_promise_cb) && gql_runtime_vm_is_promise_value_sv(aTHX_ s->promise_is_promise_cb, item_result)) {
          has_promise = 1;
        }
        av_push(resolved_items_av, item_result);
      }

      if (has_promise) {
        SV *aggregate = gql_runtime_vm_call_all_promise_sv(
          aTHX_
          s->promise_all_cb,
          resolved_items_av,
          path_frame_sv
        );
        SvREFCNT_dec((SV *)resolved_items_av);
        if (aggregate && sv_derived_from(aggregate, "GraphQL::Houtou::Runtime::Outcome")) {
          return aggregate;
        }
        {
          SV *callback_sv = gql_runtime_vm_named_coderef_sv(
            aTHX_ "GraphQL::Houtou::XS::VM::wrap_list_outcome_callback_xs"
          );
          SV *ret = gql_runtime_vm_call_then_promise_sv(
            aTHX_
            s->promise_then_cb,
            aggregate,
            callback_sv,
            NULL,
            path_frame_sv
          );
          SvREFCNT_dec(callback_sv);
          SvREFCNT_dec(aggregate);
          return ret;
        }
      }

      {
        SV *list_sv = newRV_noinc((SV *)resolved_items_av);
        SV *ret = gql_runtime_vm_new_outcome_handle_sv(aTHX_ GQL_VM_KIND_LIST, list_sv, &PL_sv_undef);
        SvREFCNT_dec(list_sv);
        return ret;
      }
    }
    case GQL_VM_COMPLETE_ABSTRACT:
    {
      SV *runtime_error_sv = NULL;
      SV *runtime_type_sv;
      IV child_block_index;

      if (!resolved_sv || !SvOK(resolved_sv)) {
        return gql_runtime_vm_new_outcome_handle_sv(aTHX_ GQL_VM_KIND_SCALAR, &PL_sv_undef, &PL_sv_undef);
      }

      runtime_type_sv = gql_runtime_vm_exec_state_resolve_runtime_type_current_sv(
        aTHX_
        state_sv,
        s,
        resolved_sv,
        path_frame_sv,
        &runtime_error_sv
      );
      if (runtime_error_sv && SvOK(runtime_error_sv)) {
        SV *ret = gql_runtime_vm_new_error_outcome_sv(
          aTHX_
          runtime_error_sv,
          path_frame_sv ? path_frame_sv : &PL_sv_undef
        );
        SvREFCNT_dec(runtime_error_sv);
        return ret;
      }
      if (!runtime_type_sv || !SvOK(runtime_type_sv)) {
        if (runtime_type_sv) {
          SvREFCNT_dec(runtime_type_sv);
        }
        return gql_runtime_vm_new_outcome_handle_sv(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv, &PL_sv_undef);
      }

      child_block_index = gql_runtime_vm_find_abstract_child_block_index(
        op,
        gql_runtime_vm_type_name_from_sv(aTHX_ runtime_type_sv)
      );
      SvREFCNT_dec(runtime_type_sv);
      if (child_block_index < 0) {
        return gql_runtime_vm_new_outcome_handle_sv(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv, &PL_sv_undef);
      }

      {
        SV *child_value = gql_runtime_vm_exec_state_execute_block_async_sv(
          aTHX_
          state_sv,
          s,
          child_block_index,
          resolved_sv,
          path_frame_sv
        );
        if (s->promise_is_promise_cb && SvOK(s->promise_is_promise_cb) && gql_runtime_vm_is_promise_value_sv(aTHX_ s->promise_is_promise_cb, child_value)) {
          SV *callback_sv = gql_runtime_vm_named_coderef_sv(
            aTHX_ "GraphQL::Houtou::XS::VM::wrap_object_outcome_callback_xs"
          );
          SV *ret = gql_runtime_vm_call_then_promise_sv(
            aTHX_
            s->promise_then_cb,
            child_value,
            callback_sv,
            NULL,
            path_frame_sv
          );
          SvREFCNT_dec(callback_sv);
          SvREFCNT_dec(child_value);
          return ret;
        }

        {
          SV *ret = gql_runtime_vm_new_outcome_handle_sv(aTHX_ GQL_VM_KIND_OBJECT, child_value, &PL_sv_undef);
          SvREFCNT_dec(child_value);
          return ret;
        }
      }
    }
    case GQL_VM_COMPLETE_GENERIC:
    default:
      return gql_runtime_vm_new_outcome_handle_sv(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv, &PL_sv_undef);
  }
}

static SV *
gql_runtime_vm_fetch_object_hash_entry_sv(pTHX_ SV *obj_sv, const char *key, I32 keylen)
{
  HV *hv;
  if (!obj_sv || !SvOK(obj_sv) || !SvROK(obj_sv) || SvTYPE(SvRV(obj_sv)) != SVt_PVHV) {
    return NULL;
  }
  hv = (HV *)SvRV(obj_sv);
  return gql_runtime_vm_fetch_hash_entry_sv(aTHX_ hv, key, keylen);
}

static SV *
gql_runtime_vm_state_current_return_type_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *op_sv, SV *slot_sv)
{
  const gql_runtime_vm_native_slot_t *native_slot;
  const char *type_name;
  SV *type_name_sv;

  native_slot = (s && s->cursor) ? gql_runtime_vm_cursor_current_native_slot(s->cursor) : NULL;
  if (native_slot && native_slot->return_type_name && *native_slot->return_type_name) {
    type_name_sv = newSVpv(native_slot->return_type_name, 0);
    type_name_sv = sv_2mortal(type_name_sv);
    return gql_runtime_vm_state_type_by_name_sv(aTHX_ s, type_name_sv);
  }

  type_name_sv = gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 8);
  if (!type_name_sv || !SvOK(type_name_sv)) {
    return NULL;
  }

  return gql_runtime_vm_state_type_by_name_sv(aTHX_ s, type_name_sv);
}

static SV *
gql_runtime_vm_state_current_resolver_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s)
{
  const gql_runtime_vm_native_runtime_t *runtime;
  const gql_runtime_vm_native_slot_t *slot;

  runtime = gql_runtime_vm_exec_state_native_runtime(aTHX_ s);
  slot = (s && s->cursor) ? gql_runtime_vm_cursor_current_native_slot(s->cursor) : NULL;

  if (!runtime || !runtime->callback_catalog || !slot) {
    return NULL;
  }
  if (!runtime->callback_catalog->slot_resolvers) {
    return NULL;
  }
  if (slot->schema_slot_index < 0 || slot->schema_slot_index >= runtime->runtime_slot_count) {
    return NULL;
  }
  return runtime->callback_catalog->slot_resolvers[slot->schema_slot_index];
}

static SV *
gql_runtime_vm_state_type_by_name_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *type_name_sv)
{
  SV *runtime_schema_sv;
  HV *schema_hv;
  SV *runtime_cache_sv;
  HV *runtime_cache_hv;
  SV *name2type_sv;
  HE *he;

  if (!type_name_sv || !SvOK(type_name_sv)) {
    return NULL;
  }

  runtime_schema_sv = s ? s->runtime_schema : NULL;
  if (!runtime_schema_sv || !SvOK(runtime_schema_sv) || !SvROK(runtime_schema_sv) || SvTYPE(SvRV(runtime_schema_sv)) != SVt_PVHV) {
    return NULL;
  }
  schema_hv = (HV *)SvRV(runtime_schema_sv);
  runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "runtime_cache", 13);
  if (!runtime_cache_sv || !SvOK(runtime_cache_sv) || !SvROK(runtime_cache_sv) || SvTYPE(SvRV(runtime_cache_sv)) != SVt_PVHV) {
    return NULL;
  }
  runtime_cache_hv = (HV *)SvRV(runtime_cache_sv);
  name2type_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "name2type", 9);
  if (!name2type_sv || !SvOK(name2type_sv) || !SvROK(name2type_sv) || SvTYPE(SvRV(name2type_sv)) != SVt_PVHV) {
    return NULL;
  }
  he = hv_fetch_ent((HV *)SvRV(name2type_sv), type_name_sv, 0, 0);
  return he ? HeVAL(he) : NULL;
}

static IV
gql_runtime_vm_program_find_block_index_sv(pTHX_ SV *program_sv, SV *block_sv)
{
  AV *program_av;
  SV **blocks_svp;
  AV *blocks_av;
  IV i;

  if (!program_sv || !SvOK(program_sv) || !SvROK(program_sv) || SvTYPE(SvRV(program_sv)) != SVt_PVAV) {
    return -1;
  }
  if (!block_sv || !SvOK(block_sv)) {
    return -1;
  }
  if (!SvROK(block_sv) && looks_like_number(block_sv)) {
    return SvIV(block_sv);
  }

  program_av = (AV *)SvRV(program_sv);
  blocks_svp = av_fetch(program_av, 4, 0);
  if (!blocks_svp || !*blocks_svp || !SvOK(*blocks_svp) || !SvROK(*blocks_svp) || SvTYPE(SvRV(*blocks_svp)) != SVt_PVAV) {
    return -1;
  }
  blocks_av = (AV *)SvRV(*blocks_svp);
  for (i = 0; i <= av_len(blocks_av); i++) {
    SV **svp = av_fetch(blocks_av, i, 0);
    if (svp && *svp && sv_eq(*svp, block_sv)) {
      return i;
    }
  }
  return -1;
}

static IV
gql_runtime_vm_block_index_from_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *block_sv)
{
  if (block_sv && SvOK(block_sv) && !SvROK(block_sv) && looks_like_number(block_sv)) {
    return SvIV(block_sv);
  }
  return gql_runtime_vm_program_find_block_index_sv(aTHX_ s ? s->program : NULL, block_sv);
}

static SV *
gql_runtime_vm_state_current_field_name_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s)
{
  const gql_runtime_vm_native_runtime_t *runtime;
  const gql_runtime_vm_native_slot_t *native_slot;

  if (!s || !s->cursor) {
    return NULL;
  }

  runtime = gql_runtime_vm_exec_state_native_runtime(aTHX_ s);
  native_slot = gql_runtime_vm_cursor_current_native_slot(s->cursor);
  native_slot = gql_runtime_vm_effective_slot(runtime, native_slot);
  if (native_slot && native_slot->field_name && *native_slot->field_name) {
    return newSVpv(native_slot->field_name, 0);
  }

  return NULL;
}

static SV *
gql_runtime_vm_state_current_parent_type_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s)
{
  const gql_runtime_vm_native_block_t *block;

  if (!s || !s->cursor) {
    return NULL;
  }

  block = gql_runtime_vm_cursor_current_native_block(s->cursor);
  if (block && block->type_name && *block->type_name) {
    SV *type_name_sv = sv_2mortal(newSVpv(block->type_name, 0));
    return gql_runtime_vm_state_type_by_name_sv(aTHX_ s, type_name_sv);
  }
  return NULL;
}

static char *
gql_runtime_vm_copy_cstr(const char *src)
{
  STRLEN len;
  char *dst;
  if (!src) {
    return NULL;
  }
  len = (STRLEN)strlen(src);
  Newx(dst, len + 1, char);
  Copy(src, dst, len, char);
  dst[len] = '\0';
  return dst;
}

static SV *
gql_runtime_vm_lazy_info_materialize_hash_sv(pTHX_ gql_runtime_vm_lazy_info_t *info)
{
  HV *info_hv;
  SV *runtime_cache_sv = &PL_sv_undef;
  SV *schema_sv = &PL_sv_undef;
  SV *parent_type_sv = NULL;
  SV *return_type_sv = NULL;
  SV *path_sv = &PL_sv_undef;

  if (!info) {
    return newRV_noinc((SV *)newHV());
  }
  if (info->materialized_sv) {
    return newSVsv(info->materialized_sv);
  }

  info_hv = newHV();

  if (info->field_name_sv && SvOK(info->field_name_sv)) {
    hv_store(info_hv, "field_name", 10, newSVsv(info->field_name_sv), 0);
  } else if (info->field_name_pv) {
    hv_store(info_hv, "field_name", 10, newSVpv(info->field_name_pv, 0), 0);
  }

  return_type_sv = info->return_type_sv;
  if (!return_type_sv && info->runtime_schema && info->return_type_name_pv) {
    return_type_sv = gql_runtime_vm_lookup_type_object_by_name_sv(
      aTHX_ info->runtime_schema,
      info->return_type_name_pv
    );
  }
  if (return_type_sv && SvOK(return_type_sv)) {
    hv_store(info_hv, "return_type", 11, newSVsv(return_type_sv), 0);
  } else if (info->return_type_name_pv) {
    hv_store(info_hv, "return_type_name", 16, newSVpv(info->return_type_name_pv, 0), 0);
  }

  parent_type_sv = info->parent_type_sv;
  if (!parent_type_sv && info->runtime_schema && info->parent_type_name_pv) {
    parent_type_sv = gql_runtime_vm_lookup_type_object_by_name_sv(
      aTHX_ info->runtime_schema,
      info->parent_type_name_pv
    );
  }
  if (parent_type_sv && SvOK(parent_type_sv)) {
    hv_store(info_hv, "parent_type", 11, newSVsv(parent_type_sv), 0);
  } else if (info->parent_type_name_pv) {
    hv_store(info_hv, "parent_type_name", 16, newSVpv(info->parent_type_name_pv, 0), 0);
  }

  if (info->path_frame) {
    path_sv = gql_runtime_vm_path_frame_to_path_sv(aTHX_ info->path_frame);
  }
  hv_store(info_hv, "path", 4, path_sv ? path_sv : newSVsv(&PL_sv_undef), 0);

  hv_store(info_hv, "field_nodes", 11, newSVsv(&PL_sv_undef), 0);
  hv_store(info_hv, "context_value", 13, newSVsv(info->context_value ? info->context_value : &PL_sv_undef), 0);
  hv_store(info_hv, "root_value", 10, newSVsv(info->root_value ? info->root_value : &PL_sv_undef), 0);
  hv_store(info_hv, "variable_values", 15, newSVsv(info->variable_values ? info->variable_values : &PL_sv_undef), 0);
  hv_store(info_hv, "operation", 9, newSVsv(info->operation ? info->operation : &PL_sv_undef), 0);
  hv_store(info_hv, "runtime_schema", 14, newSVsv(info->runtime_schema ? info->runtime_schema : &PL_sv_undef), 0);

  if (info->runtime_schema
      && SvROK(info->runtime_schema)
      && SvTYPE(SvRV(info->runtime_schema)) == SVt_PVHV) {
    HV *runtime_schema_hv = (HV *)SvRV(info->runtime_schema);
    SV *sv;

    sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_schema_hv, "runtime_cache", 13);
    if (sv && SvOK(sv)) {
      runtime_cache_sv = sv;
    }
    sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_schema_hv, "schema", 6);
    if (sv && SvOK(sv)) {
      schema_sv = sv;
    }
  }

  hv_store(info_hv, "runtime_cache", 13, newSVsv(runtime_cache_sv), 0);
  hv_store(info_hv, "schema", 6, newSVsv(schema_sv), 0);

  info->materialized_sv = newRV_noinc((SV *)info_hv);
  return newSVsv(info->materialized_sv);
}

static void
gql_runtime_vm_lazy_info_decref(pTHX_ gql_runtime_vm_lazy_info_t *info)
{
  if (!info) {
    return;
  }
  if (--info->refcount > 0) {
    return;
  }

  SvREFCNT_dec(info->field_name_sv);
  Safefree(info->field_name_pv);
  SvREFCNT_dec(info->parent_type_sv);
  Safefree(info->parent_type_name_pv);
  Safefree(info->return_type_name_pv);
  SvREFCNT_dec(info->return_type_sv);
  gql_runtime_vm_path_frame_decref(info->path_frame);
  SvREFCNT_dec(info->context_value);
  SvREFCNT_dec(info->root_value);
  SvREFCNT_dec(info->variable_values);
  SvREFCNT_dec(info->operation);
  SvREFCNT_dec(info->runtime_schema);
  SvREFCNT_dec(info->materialized_sv);
  Safefree(info);
}

static SV *
gql_runtime_vm_new_lazy_info_handle_sv(
  pTHX_
  SV *field_name_sv,
  const char *field_name_pv,
  SV *parent_type_sv,
  const char *parent_type_name_pv,
  const char *return_type_name_pv,
  SV *return_type_sv,
  gql_runtime_vm_path_frame_t *path_frame,
  SV *context_value,
  SV *root_value,
  SV *variable_values,
  SV *operation,
  SV *runtime_schema
)
{
  gql_runtime_vm_lazy_info_t *info;

  Newxz(info, 1, gql_runtime_vm_lazy_info_t);
  info->refcount = 1;
  info->field_name_sv = field_name_sv ? SvREFCNT_inc_simple_NN(field_name_sv) : NULL;
  info->field_name_pv = gql_runtime_vm_copy_cstr(field_name_pv);
  info->parent_type_sv = parent_type_sv ? SvREFCNT_inc_simple_NN(parent_type_sv) : NULL;
  info->parent_type_name_pv = gql_runtime_vm_copy_cstr(parent_type_name_pv);
  info->return_type_name_pv = gql_runtime_vm_copy_cstr(return_type_name_pv);
  info->return_type_sv = return_type_sv ? SvREFCNT_inc_simple_NN(return_type_sv) : NULL;
  if (path_frame) {
    path_frame->refcount++;
  }
  info->path_frame = path_frame;
  info->context_value = context_value ? SvREFCNT_inc_simple_NN(context_value) : NULL;
  info->root_value = root_value ? SvREFCNT_inc_simple_NN(root_value) : NULL;
  info->variable_values = variable_values ? SvREFCNT_inc_simple_NN(variable_values) : NULL;
  info->operation = operation ? SvREFCNT_inc_simple_NN(operation) : NULL;
  info->runtime_schema = runtime_schema ? SvREFCNT_inc_simple_NN(runtime_schema) : NULL;

  return gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::LazyInfo", info);
}

static SV *
gql_runtime_vm_new_lazy_info_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s, SV *path_frame)
{
  const gql_runtime_vm_native_block_t *block = (s && s->cursor)
    ? gql_runtime_vm_cursor_current_native_block(s->cursor)
    : NULL;
  const gql_runtime_vm_native_slot_t *slot = (s && s->cursor)
    ? gql_runtime_vm_cursor_current_native_slot(s->cursor)
    : NULL;
  const gql_runtime_vm_native_runtime_t *runtime = s
    ? gql_runtime_vm_exec_state_native_runtime(aTHX_ s)
    : NULL;
  gql_runtime_vm_native_callback_catalog_t *catalog = runtime ? runtime->callback_catalog : NULL;
  gql_runtime_vm_path_frame_t *path_ptr = NULL;
  SV *return_type_sv = NULL;
  SV *field_name_sv = NULL;

  PERL_UNUSED_ARG(state_sv);
  if (path_frame && SvOK(path_frame) && SvROK(path_frame) && SvIOK(SvRV(path_frame)) && SvUV(SvRV(path_frame)) != 0) {
    path_ptr = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(path_frame)));
  } else if (s && s->field_frame) {
    path_ptr = s->field_frame->path_frame;
  }
  if (runtime && slot) {
    return_type_sv = gql_runtime_vm_direct_slot_type_object_sv(runtime, slot);
  }
  if (catalog
      && catalog->slot_field_names
      && slot
      && slot->schema_slot_index >= 0
      && slot->schema_slot_index < runtime->runtime_slot_count) {
    field_name_sv = catalog->slot_field_names[slot->schema_slot_index];
  }

  return gql_runtime_vm_new_lazy_info_handle_sv(
    aTHX_
    field_name_sv,
    slot ? slot->field_name : NULL,
    block ? block->type_object_sv : NULL,
    block ? block->type_name : NULL,
    slot ? slot->return_type_name : NULL,
    return_type_sv,
    path_ptr,
    s ? s->context : &PL_sv_undef,
    s ? s->root_value : &PL_sv_undef,
    s ? s->variables : &PL_sv_undef,
    s ? s->program : &PL_sv_undef,
    s ? s->runtime_schema : &PL_sv_undef
  );
}

static SV *
gql_runtime_vm_new_error_record_sv(pTHX_ SV *message_sv, SV *path_frame_sv)
{
  SV *clean_message_sv = message_sv ? newSVsv(message_sv) : newSVsv(&PL_sv_undef);
  SV *ret;
  if (clean_message_sv && SvOK(clean_message_sv)) {
    STRLEN len;
    char *pv = SvPV(clean_message_sv, len);
    while (len > 0 && (pv[len - 1] == '\n' || pv[len - 1] == '\r')) {
      len--;
    }
    sv_setpvn(clean_message_sv, pv, len);
  }

  ret = gql_runtime_vm_new_handle_sv(
    aTHX_
    "GraphQL::Houtou::Runtime::ErrorRecord",
    gql_runtime_vm_new_error_record_struct(aTHX_ clean_message_sv, path_frame_sv ? path_frame_sv : &PL_sv_undef)
  );
  SvREFCNT_dec(clean_message_sv);
  return ret;
}

static SV *
gql_runtime_vm_new_error_outcome_sv(pTHX_ SV *message_sv, SV *path_frame_sv)
{
  SV *clean_message_sv = message_sv ? newSVsv(message_sv) : newSVsv(&PL_sv_undef);
  gql_runtime_vm_error_record_t *record;
  gql_runtime_vm_outcome_t *outcome;
  if (clean_message_sv && SvOK(clean_message_sv)) {
    STRLEN len;
    char *pv = SvPV(clean_message_sv, len);
    while (len > 0 && (pv[len - 1] == '\n' || pv[len - 1] == '\r')) {
      len--;
    }
    sv_setpvn(clean_message_sv, pv, len);
  }
  record = gql_runtime_vm_new_error_record_struct(aTHX_ clean_message_sv, path_frame_sv ? path_frame_sv : &PL_sv_undef);
  SvREFCNT_dec(clean_message_sv);
  Newxz(outcome, 1, gql_runtime_vm_outcome_t);
  outcome->refcount = 1;
  outcome->kind_code = GQL_VM_KIND_SCALAR;
  outcome->value = gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
  outcome->error_record_count = 1;
  Newxz(outcome->error_records, 1, gql_runtime_vm_error_record_t *);
  outcome->error_records[0] = record;
  return gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::Outcome", outcome);
}

static SV *
gql_runtime_vm_runtime_schema_exec_struct_sv(pTHX_ SV *runtime_schema);

static SV *
gql_runtime_vm_fetch_runtime_slot_sv(pTHX_ SV *runtime_schema, IV schema_slot_index)
{
  HV *schema_hv;
  SV *exec_struct_sv;
  SV *catalog_sv;
  AV *catalog_av;
  SV **slot_svp;

  exec_struct_sv = gql_runtime_vm_runtime_schema_exec_struct_sv(aTHX_ runtime_schema);
  schema_hv = exec_struct_sv
    ? gql_runtime_vm_expect_hashref(aTHX_ exec_struct_sv, "runtime exec schema")
    : gql_runtime_vm_expect_hashref(aTHX_ runtime_schema, "runtime schema");
  catalog_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_catalog_exec", 17);
  if (!catalog_sv) {
    catalog_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_catalog", 12);
  }
  if (!catalog_sv) {
    if (exec_struct_sv) {
      SvREFCNT_dec(exec_struct_sv);
    }
    croak("runtime schema is missing slot_catalog");
  }
  catalog_av = gql_runtime_vm_expect_arrayref(aTHX_ catalog_sv, "runtime schema slot_catalog");
  slot_svp = av_fetch(catalog_av, schema_slot_index, 0);
  if (!slot_svp || !SvOK(*slot_svp)) {
    if (exec_struct_sv) {
      SvREFCNT_dec(exec_struct_sv);
    }
    croak("runtime schema slot_catalog entry %ld is missing", (long)schema_slot_index);
  }
  if (exec_struct_sv) {
    SvREFCNT_dec(exec_struct_sv);
  }
  return *slot_svp;
}

static SV *
gql_runtime_vm_state_resolve_args_sv(pTHX_ SV *state_sv)
{
  gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state_sv);
  const gql_runtime_vm_native_runtime_t *runtime = gql_runtime_vm_exec_state_native_runtime(aTHX_ s);
  const gql_runtime_vm_native_slot_t *slot = (s && s->cursor) ? gql_runtime_vm_cursor_current_native_slot(s->cursor) : NULL;
  const gql_runtime_vm_native_op_t *op = (s && s->cursor) ? gql_runtime_vm_cursor_current_native_op(s->cursor) : NULL;
  HV *variables_hv = gql_runtime_vm_expect_hashref(aTHX_ s && s->variables ? s->variables : &PL_sv_undef, "variables");
  SV *args_sv;

  if (!runtime || !slot || !op) {
    return newSVsv(s && s->empty_args ? s->empty_args : &PL_sv_undef);
  }

  args_sv = gql_runtime_vm_specialize_arg_payload_sv(aTHX_ runtime, slot, op, variables_hv);
  return args_sv ? args_sv : newSVsv(s && s->empty_args ? s->empty_args : &PL_sv_undef);
}

static int
gql_runtime_vm_should_execute_op_now(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *op_sv)
{
  const gql_runtime_vm_native_op_t *native_op = (s && s->cursor) ? gql_runtime_vm_cursor_current_native_op(s->cursor) : NULL;
  if (native_op) {
    HV *variables_hv = gql_runtime_vm_expect_hashref(aTHX_ s && s->variables ? s->variables : &PL_sv_undef, "variables");
    if (native_op->directives_mode_code == 0 || !native_op->has_directives || !native_op->directives_payload_native) {
      return 1;
    }
    return gql_runtime_vm_evaluate_runtime_guards_native(aTHX_ native_op->directives_payload_native, variables_hv) ? 1 : 0;
  }

  SV *mode_sv;
  SV *guards_sv;
  HV *variables_hv;
  const char *mode;

  if (!op_sv || !SvOK(op_sv)) {
    return 0;
  }

  mode_sv = gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 16);
  mode = mode_sv ? SvPV_nolen(mode_sv) : "NONE";
  if (!mode || strEQ(mode, "NONE")) {
    return 1;
  }

  guards_sv = gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 17);
  if (!guards_sv || !SvOK(guards_sv)) {
    return 1;
  }

  variables_hv = gql_runtime_vm_expect_hashref(aTHX_ s && s->variables ? s->variables : &PL_sv_undef, "variables");
  return gql_runtime_vm_evaluate_runtime_guards_hv(aTHX_ guards_sv, variables_hv) ? 1 : 0;
}

static SV *
gql_runtime_vm_call_resolver_sv(pTHX_ SV *resolver_sv, SV *source_sv, SV *args_sv, SV *context_sv, SV *info_sv, SV *return_type_sv, SV **error_out)
{
  dSP;
  SV *result = NULL;
  if (error_out) {
    *error_out = NULL;
  }
  if (!resolver_sv || !SvOK(resolver_sv)) {
    return newSVsv(&PL_sv_undef);
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(source_sv ? source_sv : &PL_sv_undef);
  XPUSHs(args_sv ? args_sv : &PL_sv_undef);
  XPUSHs(context_sv ? context_sv : &PL_sv_undef);
  XPUSHs(info_sv ? info_sv : &PL_sv_undef);
  XPUSHs(return_type_sv ? return_type_sv : &PL_sv_undef);
  PUTBACK;

  if (call_sv(resolver_sv, G_SCALAR | G_EVAL) > 0) {
    SPAGAIN;
    result = (SP > PL_stack_base) ? POPs : NULL;
    result = result ? newSVsv(result) : newSVsv(&PL_sv_undef);
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
  return result ? result : newSVsv(&PL_sv_undef);
}

static SV *
gql_runtime_vm_exec_state_execute_block_sync_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s, SV *block, IV block_index, SV *source, SV *base_path)
{
  gql_runtime_vm_cursor_t snapshot;
  gql_runtime_vm_field_frame_t *saved_field_frame;
  gql_runtime_vm_path_frame_t *base_path_ptr = NULL;
  const gql_runtime_vm_native_block_t *block_ptr = NULL;

  Zero(&snapshot, 1, gql_runtime_vm_cursor_t);
  if (base_path && SvOK(base_path) && SvROK(base_path) && SvIOK(SvRV(base_path)) && SvUV(SvRV(base_path)) != 0) {
    base_path_ptr = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(base_path)));
  }
  saved_field_frame = s ? s->field_frame : NULL;
  gql_runtime_vm_cursor_snapshot_copy(aTHX_ &snapshot, (s && s->cursor) ? s->cursor : NULL);
  if (s->cursor) {
    gql_runtime_vm_cursor_t *dst = s->cursor;
    dst->block_index = block_index >= 0 ? block_index : gql_runtime_vm_block_index_from_sv(aTHX_ s, block);
    dst->slot_index = 0;
    dst->op_index = -1;
    block_ptr = gql_runtime_vm_cursor_current_native_block(dst);
  }
  if (!block_ptr) {
    return newSVsv(&PL_sv_undef);
  }

  if (s->frame_stack_count == s->frame_stack_capacity) {
    IV new_cap = s->frame_stack_capacity ? s->frame_stack_capacity * 2 : 4;
    Renew(s->frame_stack, new_cap, gql_runtime_vm_block_frame_t *);
    s->frame_stack_capacity = new_cap;
  }
  s->frame_stack[s->frame_stack_count++] = gql_runtime_vm_new_block_frame_struct(aTHX);
  s->frame = s->frame_stack[s->frame_stack_count - 1];

  while (1) {
    gql_runtime_vm_cursor_t *dst;
    IV next_index;
    const gql_runtime_vm_native_slot_t *slot;
    gql_runtime_vm_outcome_t *outcome;

    if (!s->cursor) {
      break;
    }
    dst = s->cursor;
    block_ptr = gql_runtime_vm_cursor_current_native_block(dst);
    if (!block_ptr) break;
    next_index = dst->op_index + 1;
    if (next_index >= block_ptr->op_count) {
      dst->op_index = next_index;
      dst->slot_index = 0;
      break;
    }
    dst->op_index = next_index;
    dst->slot_index = block_ptr->ops[next_index].slot_index;
    slot = gql_runtime_vm_cursor_current_native_slot(dst);
    slot = gql_runtime_vm_effective_slot(gql_runtime_vm_exec_state_native_runtime(aTHX_ s), slot);

    if (!gql_runtime_vm_should_execute_op_now(aTHX_ s, NULL)) {
      continue;
    }

    {
      SV *result_name_sv = (slot && slot->result_name) ? newSVpv(slot->result_name, 0) : newSVsv(&PL_sv_undef);
      gql_runtime_vm_path_frame_t *path_frame = gql_runtime_vm_new_path_frame_struct(
        aTHX_
        base_path_ptr,
        result_name_sv
      );
      SvREFCNT_dec(result_name_sv);
      gql_runtime_vm_field_frame_t *field_frame = gql_runtime_vm_new_field_frame_struct(aTHX_ source, path_frame);
      gql_runtime_vm_path_frame_decref(path_frame);
      if (s->field_frame && s->field_frame != saved_field_frame) {
        gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
      }
      s->field_frame = field_frame;
    }
    outcome = gql_runtime_vm_exec_state_execute_current_op_sync_now(aTHX_ state_sv, s);
    gql_runtime_vm_consume_current_outcome_now(aTHX_ s, outcome);
    gql_runtime_vm_outcome_decref(aTHX_ outcome);
  }

  {
    SV *result = newSVsv(&PL_sv_undef);
    if (s && s->frame) {
      gql_runtime_vm_block_frame_t *completed_frame = s->frame;
      result = gql_runtime_vm_native_value_materialize_sv(aTHX_ s->frame->values_value);
      if (s->frame_stack_count > 0) {
        s->frame_stack_count--;
      }
      s->frame = s->frame_stack_count > 0 ? s->frame_stack[s->frame_stack_count - 1] : NULL;
      gql_runtime_vm_free_block_frame(aTHX_ completed_frame);
    }
    if (s && s->cursor) {
      gql_runtime_vm_cursor_restore_copy(aTHX_ s->cursor, &snapshot);
    }
    gql_runtime_vm_cursor_destroy_copy(aTHX_ &snapshot);
    if (s->field_frame && s->field_frame != saved_field_frame) {
      gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
    }
    s->field_frame = saved_field_frame;
    return result;
  }
}

static SV *
gql_runtime_vm_exec_state_execute_block_async_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s, IV block_index, SV *source, SV *base_path)
{
  gql_runtime_vm_cursor_t snapshot;
  gql_runtime_vm_field_frame_t *saved_field_frame;
  gql_runtime_vm_path_frame_t *base_path_ptr = NULL;
  const gql_runtime_vm_native_block_t *block_ptr = NULL;

  Zero(&snapshot, 1, gql_runtime_vm_cursor_t);
  if (base_path && SvOK(base_path) && SvROK(base_path) && SvIOK(SvRV(base_path)) && SvUV(SvRV(base_path)) != 0) {
    base_path_ptr = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(base_path)));
  }
  saved_field_frame = s ? s->field_frame : NULL;
  gql_runtime_vm_cursor_snapshot_copy(aTHX_ &snapshot, (s && s->cursor) ? s->cursor : NULL);
  if (s->cursor) {
    gql_runtime_vm_cursor_t *dst = s->cursor;
    dst->block_index = block_index;
    dst->slot_index = 0;
    dst->op_index = -1;
    block_ptr = gql_runtime_vm_cursor_current_native_block(dst);
  }
  if (!block_ptr) {
    return newSVsv(&PL_sv_undef);
  }

  if (s->frame_stack_count == s->frame_stack_capacity) {
    IV new_cap = s->frame_stack_capacity ? s->frame_stack_capacity * 2 : 4;
    Renew(s->frame_stack, new_cap, gql_runtime_vm_block_frame_t *);
    s->frame_stack_capacity = new_cap;
  }
  s->frame_stack[s->frame_stack_count++] = gql_runtime_vm_new_block_frame_struct(aTHX);
  s->frame = s->frame_stack[s->frame_stack_count - 1];

  while (1) {
    gql_runtime_vm_cursor_t *dst;
    IV next_index;
    const gql_runtime_vm_native_slot_t *slot;

    if (!s->cursor) {
      break;
    }
    dst = s->cursor;
    block_ptr = gql_runtime_vm_cursor_current_native_block(dst);
    if (!block_ptr) break;
    next_index = dst->op_index + 1;
    if (next_index >= block_ptr->op_count) {
      dst->op_index = next_index;
      dst->slot_index = 0;
      break;
    }
    dst->op_index = next_index;
    dst->slot_index = block_ptr->ops[next_index].slot_index;
    slot = gql_runtime_vm_cursor_current_native_slot(dst);
    slot = gql_runtime_vm_effective_slot(gql_runtime_vm_exec_state_native_runtime(aTHX_ s), slot);

    if (!gql_runtime_vm_should_execute_op_now(aTHX_ s, NULL)) {
      continue;
    }

    {
      SV *result_name_sv = (slot && slot->result_name) ? newSVpv(slot->result_name, 0) : newSVsv(&PL_sv_undef);
      gql_runtime_vm_path_frame_t *path_frame = gql_runtime_vm_new_path_frame_struct(
        aTHX_
        base_path_ptr,
        result_name_sv
      );
      gql_runtime_vm_field_frame_t *field_frame;
      SV *result_sv;

      SvREFCNT_dec(result_name_sv);
      field_frame = gql_runtime_vm_new_field_frame_struct(aTHX_ source, path_frame);
      gql_runtime_vm_path_frame_decref(path_frame);
      if (s->field_frame && s->field_frame != saved_field_frame) {
        gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
      }
      s->field_frame = field_frame;

      result_sv = gql_runtime_vm_exec_state_execute_current_op_async_sv(aTHX_ state_sv, s);
      gql_runtime_vm_consume_current_result_now(aTHX_ s, result_sv);
      if (result_sv) {
        SvREFCNT_dec(result_sv);
      }
    }
  }

  {
    SV *result = gql_runtime_vm_finalize_current_block_now(aTHX_ s, &PL_sv_undef);
    if (s && s->cursor) {
      gql_runtime_vm_cursor_restore_copy(aTHX_ s->cursor, &snapshot);
    }
    gql_runtime_vm_cursor_destroy_copy(aTHX_ &snapshot);
    if (s->field_frame && s->field_frame != saved_field_frame) {
      gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
    }
    s->field_frame = saved_field_frame;
    return result;
  }
}

static gql_runtime_vm_outcome_t *
gql_runtime_vm_exec_state_execute_current_op_sync_now(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s)
{
  const gql_runtime_vm_native_block_t *block;
  const gql_runtime_vm_native_op_t *op;
  const gql_runtime_vm_native_slot_t *slot;
  SV *source_sv;
  SV *resolved_sv = NULL;
  SV *error_sv = NULL;
  IV resolve_code;
  IV complete_code;

  if (!s || !s->cursor || !s->field_frame) {
    return gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, &PL_sv_undef, &PL_sv_undef);
  }

  block = gql_runtime_vm_cursor_current_native_block(s->cursor);
  op = gql_runtime_vm_cursor_current_native_op(s->cursor);
  slot = gql_runtime_vm_cursor_current_native_slot(s->cursor);
  source_sv = s->field_frame->source;
  resolve_code = op ? op->resolve_code : 0;
  complete_code = op ? op->complete_code : 0;

  switch (resolve_code) {
    case GQL_VM_RESOLVE_DEFAULT:
    case GQL_VM_RESOLVE_EXPLICIT:
    {
      const char *field_name = slot ? slot->field_name : "";
      SV *field_name_sv = field_name ? newSVpv(field_name, 0) : newSVsv(&PL_sv_undef);
      SV *resolver_sv = gql_runtime_vm_state_current_resolver_sv(aTHX_ s);
      if (field_name && strEQ(field_name, "__typename")) {
        resolved_sv = (block && block->type_name && *block->type_name)
          ? newSVpv(block->type_name, 0)
          : newSVsv(&PL_sv_undef);
      } else if (resolver_sv && SvOK(resolver_sv)) {
        SV *args_sv = gql_runtime_vm_state_resolve_args_sv(aTHX_ state_sv);
        SV *info_sv = gql_runtime_vm_new_lazy_info_sv(aTHX_ state_sv, s, NULL);
        SV *return_type_sv = gql_runtime_vm_state_current_return_type_sv(aTHX_ s, NULL, NULL);
        resolved_sv = gql_runtime_vm_call_resolver_sv(
          aTHX_ resolver_sv, source_sv, args_sv, s->context, info_sv, return_type_sv, &error_sv
        );
        SvREFCNT_dec(args_sv);
        SvREFCNT_dec(info_sv);
      } else if (source_sv && SvOK(source_sv) && SvROK(source_sv) && SvTYPE(SvRV(source_sv)) == SVt_PVHV && field_name && *field_name) {
        HE *he = hv_fetch_ent((HV *)SvRV(source_sv), field_name_sv, 0, 0);
        resolved_sv = newSVsv(he ? HeVAL(he) : &PL_sv_undef);
      } else {
        resolved_sv = newSVsv(&PL_sv_undef);
      }
      SvREFCNT_dec(field_name_sv);
      break;
    }
    default:
      resolved_sv = newSVsv(&PL_sv_undef);
      break;
  }

  if (error_sv && SvOK(error_sv)) {
    gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_error_outcome_struct_for_path(aTHX_ error_sv, s->field_frame->path_frame);
    SvREFCNT_dec(error_sv);
    if (resolved_sv) SvREFCNT_dec(resolved_sv);
    return outcome;
  }

  if (s->field_frame) {
    SvREFCNT_dec(s->field_frame->resolved_value);
    s->field_frame->resolved_value = newSVsv(resolved_sv ? resolved_sv : &PL_sv_undef);
  }

  switch (complete_code) {
    case GQL_VM_COMPLETE_OBJECT:
    {
      IV child_block_index = -1;
      if (!resolved_sv || !SvOK(resolved_sv)) {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, &PL_sv_undef, &PL_sv_undef);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
      if (op) {
        child_block_index = op->child_block_index;
      }
      if (child_block_index < 0) {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv, &PL_sv_undef);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
      {
        SV *base_path_sv = gql_runtime_vm_wrap_path_frame_sv(aTHX_ s->field_frame->path_frame);
        SV *child_value = gql_runtime_vm_exec_state_execute_block_sync_sv(aTHX_ state_sv, s, &PL_sv_undef, child_block_index, resolved_sv, base_path_sv);
        SvREFCNT_dec(base_path_sv);
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_OBJECT, child_value, &PL_sv_undef);
        SvREFCNT_dec(child_value);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
    }
    case GQL_VM_COMPLETE_LIST:
    {
      IV child_block_index = -1;
      AV *items_av;
      AV *resolved_items_av;
      SSize_t i;
      if (!resolved_sv || !SvOK(resolved_sv)) {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, &PL_sv_undef, &PL_sv_undef);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
      if (!SvROK(resolved_sv) || SvTYPE(SvRV(resolved_sv)) != SVt_PVAV) {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv, &PL_sv_undef);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
      if (op) {
        child_block_index = op->child_block_index;
      }
      items_av = (AV *)SvRV(resolved_sv);
      resolved_items_av = newAV();
      for (i = 0; i <= av_len(items_av); i++) {
        SV **item_svp = av_fetch(items_av, i, 0);
        SV *item_sv = (item_svp && *item_svp) ? *item_svp : &PL_sv_undef;
        if (child_block_index >= 0) {
          SV *item_key = newSViv(i);
          SV *base_path_sv = gql_runtime_vm_wrap_path_frame_sv(aTHX_ s->field_frame->path_frame);
          SV *item_path = gql_runtime_vm_new_path_frame_handle(aTHX_ base_path_sv, item_key);
          SV *child_value = gql_runtime_vm_exec_state_execute_block_sync_sv(aTHX_ state_sv, s, &PL_sv_undef, child_block_index, item_sv, item_path);
          av_push(resolved_items_av, child_value);
          SvREFCNT_dec(base_path_sv);
          SvREFCNT_dec(item_key);
          SvREFCNT_dec(item_path);
        } else {
          av_push(resolved_items_av, newSVsv(item_sv));
        }
      }
      {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_LIST, newRV_noinc((SV *)resolved_items_av), &PL_sv_undef);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
    }
    case GQL_VM_COMPLETE_ABSTRACT:
    {
      SV *runtime_error_sv = NULL;
      SV *runtime_type_sv;
      IV child_block_index = -1;
      if (!resolved_sv || !SvOK(resolved_sv)) {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, &PL_sv_undef, &PL_sv_undef);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
      runtime_type_sv = gql_runtime_vm_exec_state_resolve_runtime_type_current_sv(
        aTHX_
        state_sv,
        s,
        resolved_sv,
        &PL_sv_undef,
        &runtime_error_sv
      );
      if (runtime_error_sv && SvOK(runtime_error_sv)) {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_error_outcome_struct_for_path(aTHX_ runtime_error_sv, s->field_frame->path_frame);
        SvREFCNT_dec(runtime_error_sv);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
      if (!runtime_type_sv || !SvOK(runtime_type_sv)) {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv, &PL_sv_undef);
        SvREFCNT_dec(resolved_sv);
        if (runtime_type_sv) SvREFCNT_dec(runtime_type_sv);
        return outcome;
      }
      child_block_index = gql_runtime_vm_find_abstract_child_block_index(
        op,
        gql_runtime_vm_type_name_from_sv(aTHX_ runtime_type_sv)
      );
      if (child_block_index < 0) {
        SvREFCNT_dec(runtime_type_sv);
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv, &PL_sv_undef);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
      SvREFCNT_dec(runtime_type_sv);
      {
        SV *base_path_sv = gql_runtime_vm_wrap_path_frame_sv(aTHX_ s->field_frame->path_frame);
        SV *child_value = gql_runtime_vm_exec_state_execute_block_sync_sv(aTHX_ state_sv, s, &PL_sv_undef, child_block_index, resolved_sv, base_path_sv);
        SvREFCNT_dec(base_path_sv);
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_OBJECT, child_value, &PL_sv_undef);
        SvREFCNT_dec(child_value);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
    }
    case GQL_VM_COMPLETE_GENERIC:
    default:
    {
      gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv ? resolved_sv : &PL_sv_undef, &PL_sv_undef);
      SvREFCNT_dec(resolved_sv);
      return outcome;
    }
  }
}

static SV *
gql_runtime_vm_exec_state_execute_current_op_sync_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s)
{
  gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_exec_state_execute_current_op_sync_now(aTHX_ state_sv, s);
  SV *ret = gql_runtime_vm_wrap_outcome_sv(aTHX_ outcome);
  gql_runtime_vm_outcome_decref(aTHX_ outcome);
  return ret;
}

static SV *
gql_runtime_vm_exec_state_resolve_current_value_sv(
  pTHX_
  SV *state_sv,
  gql_runtime_vm_exec_state_handle_t *s,
  SV *source_sv,
  SV *path_frame,
  SV **error_out
)
{
  const gql_runtime_vm_native_block_t *block;
  const gql_runtime_vm_native_slot_t *slot;
  const char *field_name;
  SV *resolver_sv;
  SV *resolved_sv = NULL;
  SV *field_name_sv = NULL;

  if (error_out) {
    *error_out = NULL;
  }

  if (!s || !s->cursor) {
    return newSVsv(&PL_sv_undef);
  }

  block = gql_runtime_vm_cursor_current_native_block(s->cursor);
  slot = gql_runtime_vm_cursor_current_native_slot(s->cursor);
  field_name = slot ? slot->field_name : "";
  resolver_sv = gql_runtime_vm_state_current_resolver_sv(aTHX_ s);

  if (field_name && strEQ(field_name, "__typename")) {
    return (block && block->type_name && *block->type_name)
      ? newSVpv(block->type_name, 0)
      : newSVsv(&PL_sv_undef);
  }

  if (resolver_sv && SvOK(resolver_sv)) {
    SV *args_sv = gql_runtime_vm_state_resolve_args_sv(aTHX_ state_sv);
    SV *info_sv = gql_runtime_vm_new_lazy_info_sv(aTHX_ state_sv, s, path_frame);
    SV *return_type_sv = gql_runtime_vm_state_current_return_type_sv(aTHX_ s, NULL, NULL);
    resolved_sv = gql_runtime_vm_call_resolver_sv(
      aTHX_ resolver_sv,
      source_sv,
      args_sv,
      s->context,
      info_sv,
      return_type_sv,
      error_out
    );
    SvREFCNT_dec(args_sv);
    SvREFCNT_dec(info_sv);
    return resolved_sv ? resolved_sv : newSVsv(&PL_sv_undef);
  }

  field_name_sv = field_name ? newSVpv(field_name, 0) : newSVsv(&PL_sv_undef);
  if (source_sv && SvOK(source_sv) && SvROK(source_sv) && SvTYPE(SvRV(source_sv)) == SVt_PVHV && field_name && *field_name) {
    HE *he = hv_fetch_ent((HV *)SvRV(source_sv), field_name_sv, 0, 0);
    resolved_sv = newSVsv(he ? HeVAL(he) : &PL_sv_undef);
  } else {
    resolved_sv = newSVsv(&PL_sv_undef);
  }
  SvREFCNT_dec(field_name_sv);
  return resolved_sv;
}

static SV *
gql_runtime_vm_exec_state_complete_async_sv(
  pTHX_
  SV *state_sv,
  gql_runtime_vm_exec_state_handle_t *s,
  SV *path_frame_sv,
  IV block_index,
  IV slot_index,
  IV op_index,
  SV *resolved_sv
)
{
  gql_runtime_vm_cursor_t snapshot;
  gql_runtime_vm_field_frame_t *saved_field_frame = NULL;
  gql_runtime_vm_path_frame_t *path_ptr = NULL;
  gql_runtime_vm_field_frame_t *field_frame = NULL;
  SV *result_sv = NULL;

  Zero(&snapshot, 1, gql_runtime_vm_cursor_t);
  if (!s || !s->cursor) {
    return newSVsv(&PL_sv_undef);
  }

  if (path_frame_sv && SvOK(path_frame_sv) && SvROK(path_frame_sv) && SvIOK(SvRV(path_frame_sv)) && SvUV(SvRV(path_frame_sv)) != 0) {
    path_ptr = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(path_frame_sv)));
  }

  saved_field_frame = s->field_frame;
  gql_runtime_vm_cursor_snapshot_copy(aTHX_ &snapshot, s->cursor);
  s->cursor->block_index = block_index;
  s->cursor->slot_index = slot_index;
  s->cursor->op_index = op_index;

  field_frame = gql_runtime_vm_new_field_frame_struct(aTHX_ &PL_sv_undef, path_ptr);
  SvREFCNT_dec(field_frame->resolved_value);
  field_frame->resolved_value = newSVsv(resolved_sv ? resolved_sv : &PL_sv_undef);
  if (s->field_frame && s->field_frame != saved_field_frame) {
    gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
  }
  s->field_frame = field_frame;

  result_sv = gql_runtime_vm_exec_state_complete_current_native_async_sv(
    aTHX_ state_sv,
    s,
    path_frame_sv ? path_frame_sv : &PL_sv_undef,
    resolved_sv
  );

  gql_runtime_vm_cursor_restore_copy(aTHX_ s->cursor, &snapshot);
  gql_runtime_vm_cursor_destroy_copy(aTHX_ &snapshot);
  if (s->field_frame && s->field_frame != saved_field_frame) {
    gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
  }
  s->field_frame = saved_field_frame;

  return result_sv ? result_sv : newSVsv(&PL_sv_undef);
}

static SV *
gql_runtime_vm_then_complete_current_sv(
  pTHX_
  SV *state_sv,
  gql_runtime_vm_exec_state_handle_t *s,
  SV *promise_sv,
  SV *path_frame_sv,
  IV block_index,
  IV slot_index,
  IV op_index
)
{
  dSP;
  SV *callback_sv;
  SV *error_callback_sv;
  SV *ret = NULL;

  callback_sv = gql_runtime_vm_new_complete_callback_sv(
    aTHX_ state_sv,
    path_frame_sv,
    block_index,
    slot_index,
    op_index
  );
  error_callback_sv = gql_runtime_vm_new_error_callback_sv(aTHX_ path_frame_sv);

  ret = gql_runtime_vm_call_then_promise_sv(
    aTHX_
    s ? s->promise_then_cb : NULL,
    promise_sv,
    callback_sv,
    error_callback_sv,
    path_frame_sv
  );

  if (callback_sv) {
    SvREFCNT_dec(callback_sv);
  }
  if (error_callback_sv) {
    SvREFCNT_dec(error_callback_sv);
  }

  return ret ? ret : newSVsv(&PL_sv_undef);
}

static SV *
gql_runtime_vm_exec_state_execute_current_op_async_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s)
{
  SV *path_frame_sv = NULL;
  SV *resolved_sv = NULL;
  SV *error_sv = NULL;
  SV *result_sv = NULL;

  if (!s || !s->field_frame || !s->cursor) {
    return newSVsv(&PL_sv_undef);
  }

  path_frame_sv = gql_runtime_vm_wrap_path_frame_sv(aTHX_ s->field_frame->path_frame);
  resolved_sv = gql_runtime_vm_exec_state_resolve_current_value_sv(
    aTHX_
    state_sv,
    s,
    s->field_frame->source,
    path_frame_sv,
    &error_sv
  );
  if (error_sv && SvOK(error_sv)) {
    result_sv = gql_runtime_vm_new_error_outcome_sv(aTHX_ error_sv, path_frame_sv);
    SvREFCNT_dec(error_sv);
    goto done_async_current_op;
  }

  SvREFCNT_dec(s->field_frame->resolved_value);
  s->field_frame->resolved_value = newSVsv(resolved_sv ? resolved_sv : &PL_sv_undef);

  if (s->promise_is_promise_cb && SvOK(s->promise_is_promise_cb) && gql_runtime_vm_is_promise_value_sv(aTHX_ s->promise_is_promise_cb, resolved_sv)) {
    result_sv = gql_runtime_vm_then_complete_current_sv(
      aTHX_
      state_sv,
      s,
      resolved_sv,
      path_frame_sv,
      s->cursor->block_index,
      s->cursor->slot_index,
      s->cursor->op_index
    );
    goto done_async_current_op;
  }

  result_sv = gql_runtime_vm_exec_state_complete_async_sv(
    aTHX_
    state_sv,
    s,
    path_frame_sv,
    s->cursor->block_index,
    s->cursor->slot_index,
    s->cursor->op_index,
    resolved_sv
  );

done_async_current_op:
  if (path_frame_sv) {
    SvREFCNT_dec(path_frame_sv);
  }
  if (resolved_sv) {
    SvREFCNT_dec(resolved_sv);
  }
  return result_sv ? result_sv : newSVsv(&PL_sv_undef);
}

static HV *
gql_runtime_vm_fetch_runtime_cache_hv(pTHX_ SV *runtime_schema)
{
  HV *schema_hv;
  SV *runtime_cache_sv;

  schema_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_schema, "runtime schema");
  runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "runtime_cache", 13);
  return runtime_cache_sv
    ? gql_runtime_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime schema runtime_cache")
    : NULL;
}

static SV *
gql_runtime_vm_runtime_schema_exec_struct_sv(pTHX_ SV *runtime_schema)
{
  HV *schema_hv;
  SV *catalog_sv;
  SV *exec_struct_sv;
  dSP;

  schema_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_schema, "runtime schema");
  catalog_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_catalog_exec", 17);
  if (catalog_sv && SvOK(catalog_sv)) {
    return NULL;
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(runtime_schema ? runtime_schema : &PL_sv_undef);
  PUTBACK;
  if (call_method("to_native_exec_struct", G_SCALAR | G_EVAL) != 1 || SvTRUE(ERRSV)) {
    (void)POPs;
    sv_setsv(ERRSV, &PL_sv_undef);
    FREETMPS;
    LEAVE;
    return NULL;
  }
  SPAGAIN;
  exec_struct_sv = (SP > PL_stack_base) ? POPs : NULL;
  exec_struct_sv = exec_struct_sv ? newSVsv(exec_struct_sv) : NULL;
  PUTBACK;
  FREETMPS;
  LEAVE;
  return exec_struct_sv;
}

static const char *
gql_runtime_vm_type_name_from_sv(pTHX_ SV *type_sv);

static gql_runtime_vm_native_runtime_t *
gql_runtime_vm_native_runtime_from_runtime_schema_sv(pTHX_ SV *runtime_schema)
{
  gql_runtime_vm_native_runtime_t *runtime;
  HV *schema_hv;
  SV *exec_struct_sv;
  SV *catalog_sv;
  SV *resolver_catalog_sv;
  AV *catalog_av;
  AV *resolver_catalog_av;
  SV *runtime_cache_sv;
  IV i;

  exec_struct_sv = gql_runtime_vm_runtime_schema_exec_struct_sv(aTHX_ runtime_schema);
  schema_hv = exec_struct_sv
    ? gql_runtime_vm_expect_hashref(aTHX_ exec_struct_sv, "runtime exec schema")
    : gql_runtime_vm_expect_hashref(aTHX_ runtime_schema, "runtime schema");
  catalog_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_catalog_exec", 17);
  if (!catalog_sv) {
    catalog_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_catalog", 12);
  }
  if (!catalog_sv) {
    if (exec_struct_sv) {
      SvREFCNT_dec(exec_struct_sv);
    }
    croak("runtime schema is missing slot_catalog");
  }
  catalog_av = gql_runtime_vm_expect_arrayref(aTHX_ catalog_sv, "runtime schema slot_catalog");
  resolver_catalog_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_resolvers", 14);
  resolver_catalog_av = (resolver_catalog_sv && SvOK(resolver_catalog_sv))
    ? gql_runtime_vm_expect_arrayref(aTHX_ resolver_catalog_sv, "runtime schema slot_resolvers")
    : NULL;

  Newxz(runtime, 1, gql_runtime_vm_native_runtime_t);
  Newxz(runtime->callback_catalog, 1, gql_runtime_vm_native_callback_catalog_t);
  runtime->callback_catalog->runtime_schema = newSVsv(runtime_schema ? runtime_schema : &PL_sv_undef);
  runtime->runtime_slot_count = av_count(catalog_av);
  if (runtime->runtime_slot_count > 0) {
    Newxz(runtime->runtime_slots, runtime->runtime_slot_count, gql_runtime_vm_native_slot_t);
    Newxz(runtime->callback_catalog->slot_field_names, runtime->runtime_slot_count, SV *);
    Newxz(runtime->callback_catalog->slot_resolvers, runtime->runtime_slot_count, SV *);
    Newxz(runtime->callback_catalog->slot_type_objects, runtime->runtime_slot_count, SV *);
    Newxz(runtime->callback_catalog->slot_tag_resolvers, runtime->runtime_slot_count, SV *);
    Newxz(runtime->callback_catalog->slot_resolve_types, runtime->runtime_slot_count, SV *);
    Newxz(runtime->callback_catalog->slot_tag_entries, runtime->runtime_slot_count, gql_runtime_vm_native_tag_entry_t *);
    Newxz(runtime->callback_catalog->slot_tag_entry_counts, runtime->runtime_slot_count, IV);
    Newxz(runtime->callback_catalog->slot_possible_type_entries, runtime->runtime_slot_count, gql_runtime_vm_native_possible_type_entry_t *);
    Newxz(runtime->callback_catalog->slot_possible_type_entry_counts, runtime->runtime_slot_count, IV);
    for (i = 0; i < runtime->runtime_slot_count; i++) {
      SV **slot_svp = av_fetch(catalog_av, i, 0);
      HV *slot_hv;
      SV *resolver_sv;
      if (!slot_svp || !SvOK(*slot_svp)) {
        if (exec_struct_sv) {
          SvREFCNT_dec(exec_struct_sv);
        }
        gql_runtime_vm_native_runtime_destroy(runtime);
        croak("runtime schema slot_catalog entry %ld is missing", (long)i);
      }
      if (!gql_runtime_vm_parse_native_slot(aTHX_ *slot_svp, &runtime->runtime_slots[i])) {
        if (exec_struct_sv) {
          SvREFCNT_dec(exec_struct_sv);
        }
        gql_runtime_vm_native_runtime_destroy(runtime);
        croak("runtime schema slot_catalog entry %ld is invalid", (long)i);
      }
      slot_hv = gql_runtime_vm_expect_hashref(aTHX_ *slot_svp, "runtime slot");
      resolver_sv = NULL;
      if (resolver_catalog_av && i <= av_count(resolver_catalog_av)) {
        SV **resolver_svp = av_fetch(resolver_catalog_av, i, 0);
        if (resolver_svp && SvOK(*resolver_svp)) {
          resolver_sv = *resolver_svp;
        }
      }
      if (!resolver_sv) {
        resolver_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ slot_hv, "resolve", 7);
      }
      if (resolver_sv) {
        runtime->callback_catalog->slot_resolvers[i] = newSVsv(resolver_sv);
      }
      if (runtime->runtime_slots[i].field_name && *runtime->runtime_slots[i].field_name) {
        runtime->callback_catalog->slot_field_names[i] = newSVpv(runtime->runtime_slots[i].field_name, 0);
      }
    }
  }

  runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "runtime_cache", 13);
  if (runtime_cache_sv) {
    HV *runtime_cache_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime schema runtime_cache");
    HV *name2type_hv = NULL;
    HV *tag_resolver_map_hv = NULL;
    HV *runtime_tag_map_hv = NULL;
    HV *resolve_type_map_hv = NULL;
    HV *possible_types_hv = NULL;
    HV *is_type_of_map_hv = NULL;

    if ((runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "name2type", 9))) {
      name2type_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime_cache name2type");
    }
    if ((runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "tag_resolver_map", 16))) {
      tag_resolver_map_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime_cache tag_resolver_map");
    }
    if ((runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "runtime_tag_map", 15))) {
      runtime_tag_map_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime_cache runtime_tag_map");
    }
    if ((runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "resolve_type_map", 16))) {
      resolve_type_map_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime_cache resolve_type_map");
    }
    if ((runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "possible_types", 14))) {
      possible_types_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime_cache possible_types");
    }
    if ((runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "is_type_of_map", 14))) {
      is_type_of_map_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime_cache is_type_of_map");
    }

    if (runtime->runtime_slot_count > 0 && name2type_hv) {
      for (i = 0; i < runtime->runtime_slot_count; i++) {
        const char *return_type_name = runtime->runtime_slots[i].return_type_name;
        gql_runtime_vm_native_slot_t *slot = &runtime->runtime_slots[i];
        IV arg_index;
        SV **type_svp;
        if (!return_type_name) {
          goto finalize_arg_defs;
        }
        type_svp = hv_fetch(name2type_hv, return_type_name, (I32)strlen(return_type_name), 0);
        if (type_svp && SvOK(*type_svp)) {
          runtime->callback_catalog->slot_type_objects[i] = newSVsv(*type_svp);
        }
        if (tag_resolver_map_hv) {
          SV **svp = hv_fetch(tag_resolver_map_hv, return_type_name, (I32)strlen(return_type_name), 0);
          if (svp && SvOK(*svp)) {
            runtime->callback_catalog->slot_tag_resolvers[i] = newSVsv(*svp);
          }
        }
        if (runtime_tag_map_hv) {
          SV **svp = hv_fetch(runtime_tag_map_hv, return_type_name, (I32)strlen(return_type_name), 0);
          if (svp && SvOK(*svp) && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVHV) {
            HV *tag_map_hv = (HV *)SvRV(*svp);
            IV count = hv_iterinit(tag_map_hv);
            if (count > 0) {
              HE *he;
              IV j = 0;
              Newxz(runtime->callback_catalog->slot_tag_entries[i], count, gql_runtime_vm_native_tag_entry_t);
              runtime->callback_catalog->slot_tag_entry_counts[i] = count;
              hv_iterinit(tag_map_hv);
              while ((he = hv_iternext(tag_map_hv))) {
                SV *val = HeVAL(he);
                const char *tag_name = HeKEY(he);
                const char *type_name = (val && SvOK(val)) ? gql_runtime_vm_type_name_from_sv(aTHX_ val) : NULL;
                runtime->callback_catalog->slot_tag_entries[i][j].tag_name = gql_runtime_vm_copy_cstr(tag_name);
                runtime->callback_catalog->slot_tag_entries[i][j].type_name = gql_runtime_vm_copy_cstr(type_name);
                j++;
              }
            }
          }
        }
        if (resolve_type_map_hv) {
          SV **svp = hv_fetch(resolve_type_map_hv, return_type_name, (I32)strlen(return_type_name), 0);
          if (svp && SvOK(*svp)) {
            runtime->callback_catalog->slot_resolve_types[i] = newSVsv(*svp);
          }
        }
        if (possible_types_hv && is_type_of_map_hv) {
          SV **svp = hv_fetch(possible_types_hv, return_type_name, (I32)strlen(return_type_name), 0);
          if (svp && SvOK(*svp) && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVAV) {
            AV *possible_types_av = (AV *)SvRV(*svp);
            IV count = av_count(possible_types_av);
            if (count > 0) {
              IV j;
              Newxz(runtime->callback_catalog->slot_possible_type_entries[i], count, gql_runtime_vm_native_possible_type_entry_t);
              runtime->callback_catalog->slot_possible_type_entry_counts[i] = count;
              for (j = 0; j < count; j++) {
                SV **type_entry_svp = av_fetch(possible_types_av, j, 0);
                SV *type_sv;
                const char *type_name;
                SV **cb_svp;
                if (!type_entry_svp || !SvOK(*type_entry_svp)) {
                  continue;
                }
                type_sv = *type_entry_svp;
                type_name = gql_runtime_vm_type_name_from_sv(aTHX_ type_sv);
                if (!type_name) {
                  continue;
                }
                cb_svp = hv_fetch(is_type_of_map_hv, type_name, (I32)strlen(type_name), 0);
                if (!cb_svp || !SvOK(*cb_svp)) {
                  continue;
                }
                runtime->callback_catalog->slot_possible_type_entries[i][j].type_name = gql_runtime_vm_copy_cstr(type_name);
                runtime->callback_catalog->slot_possible_type_entries[i][j].type_sv = newSVsv(type_sv);
                runtime->callback_catalog->slot_possible_type_entries[i][j].is_type_of_cb = newSVsv(*cb_svp);
              }
            }
          }
        }
finalize_arg_defs:
        for (arg_index = 0; arg_index < slot->arg_def_count; arg_index++) {
          gql_runtime_vm_finalize_native_arg_def(aTHX_ runtime_schema, &slot->arg_defs[arg_index]);
        }
      }
    }
  }

  if (exec_struct_sv) {
    SvREFCNT_dec(exec_struct_sv);
  }

  return runtime;
}

static gql_runtime_vm_native_runtime_t *
gql_runtime_vm_exec_state_native_runtime(pTHX_ gql_runtime_vm_exec_state_handle_t *s)
{
  if (!s) {
    return NULL;
  }
  if (!s->native_runtime && s->runtime_schema && SvOK(s->runtime_schema)) {
    s->native_runtime = gql_runtime_vm_native_runtime_from_runtime_schema_sv(aTHX_ s->runtime_schema);
  }
  return s->native_runtime;
}

static SV *
gql_runtime_vm_call_cb4(pTHX_ SV *cb, SV *arg0, SV *arg1, SV *arg2, SV *arg3)
{
  SV *error_sv = NULL;
  SV *ret = gql_runtime_vm_call_cb4_nonfatal(aTHX_ cb, arg0, arg1, arg2, arg3, &error_sv);
  if (error_sv) {
    croak_sv(error_sv);
  }
  return ret ? ret : newSVsv(&PL_sv_undef);
}

static SV *
gql_runtime_vm_call_cb4_nonfatal(pTHX_ SV *cb, SV *arg0, SV *arg1, SV *arg2, SV *arg3, SV **error_out)
{
  dSP;
  SV *ret = NULL;
  int count;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(arg0 ? arg0 : &PL_sv_undef);
  XPUSHs(arg1 ? arg1 : &PL_sv_undef);
  XPUSHs(arg2 ? arg2 : &PL_sv_undef);
  XPUSHs(arg3 ? arg3 : &PL_sv_undef);
  PUTBACK;
  count = call_sv(cb, G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV)) {
    SV *err = newSVsv(ERRSV);
    sv_setsv(ERRSV, &PL_sv_undef);
    if (error_out) {
      *error_out = err;
      err = NULL;
    }
    if (err) {
      croak_sv(err);
    }
  }
  if (count > 0) {
    ret = newSVsv(POPs);
  }
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret ? ret : newSVsv(&PL_sv_undef);
}

static SV *
gql_runtime_vm_call_cb5_nonfatal(pTHX_ SV *cb, SV *arg0, SV *arg1, SV *arg2, SV *arg3, SV *arg4, SV **error_out)
{
  dSP;
  SV *ret = NULL;
  int count;

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(arg0 ? arg0 : &PL_sv_undef);
  XPUSHs(arg1 ? arg1 : &PL_sv_undef);
  XPUSHs(arg2 ? arg2 : &PL_sv_undef);
  XPUSHs(arg3 ? arg3 : &PL_sv_undef);
  XPUSHs(arg4 ? arg4 : &PL_sv_undef);
  PUTBACK;
  count = call_sv(cb, G_SCALAR | G_EVAL);
  SPAGAIN;
  if (SvTRUE(ERRSV)) {
    SV *err = newSVsv(ERRSV);
    sv_setsv(ERRSV, &PL_sv_undef);
    if (error_out) {
      *error_out = err;
      err = NULL;
    }
    if (err) {
      croak_sv(err);
    }
  }
  if (count > 0) {
    ret = newSVsv(POPs);
  }
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret ? ret : newSVsv(&PL_sv_undef);
}

static int
gql_runtime_vm_slot_uses_native_fast_abi(const gql_runtime_vm_native_slot_t *slot)
{
  return slot && slot->resolver_mode_code == 2;
}

static SV *
gql_runtime_vm_lookup_type_object_by_name_sv(pTHX_ SV *runtime_schema, const char *type_name)
{
  HV *runtime_cache_hv;
  SV *name2type_sv;
  HV *name2type_hv;
  SV **svp;

  if (!runtime_schema || !SvOK(runtime_schema) || !type_name || !*type_name) {
    return NULL;
  }
  runtime_cache_hv = gql_runtime_vm_fetch_runtime_cache_hv(aTHX_ runtime_schema);
  if (!runtime_cache_hv) {
    return NULL;
  }
  name2type_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "name2type", 9);
  if (!name2type_sv || !SvROK(name2type_sv) || SvTYPE(SvRV(name2type_sv)) != SVt_PVHV) {
    return NULL;
  }
  name2type_hv = (HV *)SvRV(name2type_sv);
  svp = hv_fetch(name2type_hv, type_name, (I32)strlen(type_name), 0);
  return (svp && SvOK(*svp)) ? *svp : NULL;
}

static void
gql_runtime_vm_prepare_bundle_block_type_objects(
  pTHX_
  SV *runtime_schema,
  gql_runtime_vm_native_bundle_t *bundle
)
{
  IV i;

  if (!runtime_schema || !SvOK(runtime_schema) || !bundle || !bundle->blocks) {
    return;
  }

  for (i = 0; i < bundle->block_count; i++) {
    gql_runtime_vm_native_block_t *block = &bundle->blocks[i];
    SV *type_sv;

    if (block->type_object_sv || !block->type_name || !*block->type_name) {
      continue;
    }
    type_sv = gql_runtime_vm_lookup_type_object_by_name_sv(aTHX_ runtime_schema, block->type_name);
    if (type_sv && SvOK(type_sv)) {
      block->type_object_sv = SvREFCNT_inc_simple_NN(type_sv);
    }
  }
}

static SV *
gql_runtime_vm_lookup_slot_type_object_sv(
  pTHX_
  const gql_runtime_vm_native_runtime_t *runtime,
  SV *runtime_schema,
  const gql_runtime_vm_native_slot_t *slot
)
{
  IV slot_index;

  if (!runtime || !slot) {
    return NULL;
  }

  slot_index = slot->schema_slot_index;
  if (slot_index >= 0
      && slot_index < runtime->runtime_slot_count
      && runtime->callback_catalog
      && runtime->callback_catalog->slot_type_objects
      && runtime->callback_catalog->slot_type_objects[slot_index]
      && SvOK(runtime->callback_catalog->slot_type_objects[slot_index])) {
    return runtime->callback_catalog->slot_type_objects[slot_index];
  }

  if (slot->return_type_name && *slot->return_type_name) {
    return gql_runtime_vm_lookup_type_object_by_name_sv(
      aTHX_ runtime_schema,
      slot->return_type_name
    );
  }

  return NULL;
}

static SV *
gql_runtime_vm_direct_slot_type_object_sv(
  const gql_runtime_vm_native_runtime_t *runtime,
  const gql_runtime_vm_native_slot_t *slot
)
{
  IV slot_index;

  if (!runtime || !slot) {
    return NULL;
  }
  slot_index = slot->schema_slot_index;
  if (slot_index < 0 || slot_index >= runtime->runtime_slot_count) {
    return NULL;
  }
  if (!runtime->callback_catalog || !runtime->callback_catalog->slot_type_objects) {
    return NULL;
  }
  if (!runtime->callback_catalog->slot_type_objects[slot_index]
      || !SvOK(runtime->callback_catalog->slot_type_objects[slot_index])) {
    return NULL;
  }
  return runtime->callback_catalog->slot_type_objects[slot_index];
}

static SV *
gql_runtime_vm_new_callback_info_sv(pTHX_ const gql_runtime_vm_exec_state_t *state)
{
  SV *return_type_sv;
  const gql_runtime_vm_callback_context_t *ctx = state ? state->callback_ctx : NULL;
  const gql_runtime_vm_native_slot_t *slot = state ? state->slot : NULL;
  const gql_runtime_vm_native_block_t *block = state ? state->block : NULL;
  gql_runtime_vm_native_callback_catalog_t *catalog =
    (state && state->runtime) ? state->runtime->callback_catalog : NULL;
  SV *field_name_sv = NULL;

  if (!state) {
    return newRV_noinc((SV *)newHV());
  }

  return_type_sv = gql_runtime_vm_direct_slot_type_object_sv(state->runtime, slot);
  if (!return_type_sv) {
    return_type_sv = gql_runtime_vm_lookup_slot_type_object_sv(
      aTHX_
      state->runtime,
      ctx ? ctx->runtime_schema : &PL_sv_undef,
      slot
    );
  }
  if (catalog
      && catalog->slot_field_names
      && slot
      && slot->schema_slot_index >= 0
      && slot->schema_slot_index < state->runtime->runtime_slot_count) {
    field_name_sv = catalog->slot_field_names[slot->schema_slot_index];
  }

  return gql_runtime_vm_new_lazy_info_handle_sv(
    aTHX_
    field_name_sv,
    slot ? slot->field_name : NULL,
    block ? block->type_object_sv : NULL,
    block ? block->type_name : NULL,
    slot ? slot->return_type_name : NULL,
    return_type_sv,
    state->path_frame,
    (ctx && ctx->context) ? ctx->context : &PL_sv_undef,
    (ctx && ctx->root_value) ? ctx->root_value : &PL_sv_undef,
    (ctx && ctx->variables) ? ctx->variables : &PL_sv_undef,
    (ctx && ctx->program) ? ctx->program : &PL_sv_undef,
    (ctx && ctx->runtime_schema) ? ctx->runtime_schema : &PL_sv_undef
  );
}

static IV
gql_runtime_vm_find_abstract_child_block_index(const gql_runtime_vm_native_op_t *op, const char *type_name)
{
  IV i;
  if (!op || !type_name) {
    return -1;
  }
  for (i = 0; i < op->abstract_child_count; i++) {
    if (op->abstract_child_names[i] && strEQ(op->abstract_child_names[i], type_name)) {
      return op->abstract_child_indexes[i];
    }
  }
  return -1;
}

static const char *
gql_runtime_vm_type_name_from_sv(pTHX_ SV *type_sv)
{
  if (!type_sv || !SvOK(type_sv)) {
    return NULL;
  }
  if (SvROK(type_sv) && SvTYPE(SvRV(type_sv)) == SVt_PVHV) {
    HV *hv = (HV *)SvRV(type_sv);
    return gql_runtime_vm_fetch_hash_entry_pv(aTHX_ hv, "name", 4);
  }
  return SvPOK(type_sv) ? SvPV_nolen(type_sv) : NULL;
}

static SV *
gql_runtime_vm_clone_value_sv(pTHX_ SV *value)
{
  return newSVsv(value ? value : &PL_sv_undef);
}

static SV *
gql_runtime_vm_clone_args_payload_sv(pTHX_ SV *value)
{
  if (!value) {
    return newSVsv(&PL_sv_undef);
  }
  if (!SvROK(value)) {
    return newSVsv(value);
  }

  switch (SvTYPE(SvRV(value))) {
    case SVt_PVHV: {
      HV *src_hv = (HV *)SvRV(value);
      HV *dst_hv = newHV();
      HE *he;
      hv_iterinit(src_hv);
      while ((he = hv_iternext(src_hv))) {
        SV *keysv = hv_iterkeysv(he);
        SV *val = HeVAL(he);
        hv_store_ent(dst_hv, keysv, gql_runtime_vm_clone_args_payload_sv(aTHX_ val), 0);
      }
      return newRV_noinc((SV *)dst_hv);
    }
    case SVt_PVAV: {
      AV *src_av = (AV *)SvRV(value);
      AV *dst_av = newAV();
      IV i;
      av_extend(dst_av, av_count(src_av) > 0 ? av_count(src_av) - 1 : 0);
      for (i = 0; i < av_count(src_av); i++) {
        SV **item_svp = av_fetch(src_av, i, 0);
        av_store(dst_av, i, gql_runtime_vm_clone_args_payload_sv(aTHX_ (item_svp && SvOK(*item_svp)) ? *item_svp : &PL_sv_undef));
      }
      return newRV_noinc((SV *)dst_av);
    }
    default:
      return newSVsv(value);
  }
}

static SV *
gql_runtime_vm_build_current_args_sv(pTHX_ gql_runtime_vm_exec_state_t *state)
{
  const gql_runtime_vm_native_op_t *op = state->op;
  const gql_runtime_vm_native_slot_t *slot = state->slot;
  gql_runtime_vm_native_runtime_t *runtime = state->runtime;
  gql_runtime_vm_callback_context_t *callback_ctx = state->callback_ctx;
  HV *variables_hv = NULL;
  SV *specialized_sv;
  if (!op) {
    return newRV_noinc((SV *)newHV());
  }
  if (callback_ctx
      && callback_ctx->variables
      && SvROK(callback_ctx->variables)
      && SvTYPE(SvRV(callback_ctx->variables)) == SVt_PVHV) {
    variables_hv = (HV *)SvRV(callback_ctx->variables);
  }
  if (slot && (slot->arg_def_count > 0 || op->has_args)) {
    if (op->args_mode_code == GQL_VM_ARGS_STATIC && op->args_payload_native) {
      return gql_runtime_vm_native_args_payload_materialize_sv(aTHX_ op->args_payload_native);
    }
    specialized_sv = gql_runtime_vm_specialize_arg_payload_sv(aTHX_ runtime, slot, op, variables_hv);
    if (specialized_sv) {
      return specialized_sv;
    }
    return newRV_noinc((SV *)newHV());
  }
  if (op->args_mode_code == GQL_VM_ARGS_STATIC && op->args_payload_native) {
    return gql_runtime_vm_native_args_payload_materialize_sv(aTHX_ op->args_payload_native);
  }
  return newRV_noinc((SV *)newHV());
}

static SV *
gql_runtime_vm_resolve_current_field_default(pTHX_ gql_runtime_vm_exec_state_t *state, SV *source, SV **error_out)
{
  SV *resolver_sv;
  SV *return_type_sv;
  SV *info_sv;
  gql_runtime_vm_native_runtime_t *runtime = state->runtime;
  const gql_runtime_vm_native_slot_t *slot = state->slot;

  if (!runtime || slot->schema_slot_index < 0 || slot->schema_slot_index >= runtime->runtime_slot_count) {
    croak("native VM schema slot index %ld is invalid", (long)slot->schema_slot_index);
  }
  resolver_sv = (runtime->callback_catalog && runtime->callback_catalog->slot_resolvers)
    ? runtime->callback_catalog->slot_resolvers[slot->schema_slot_index]
    : NULL;
  return_type_sv = gql_runtime_vm_direct_slot_type_object_sv(runtime, slot);
  if (!return_type_sv) {
    return_type_sv = gql_runtime_vm_lookup_slot_type_object_sv(
      aTHX_ runtime, state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef, slot
    );
  }

  if (resolver_sv && SvOK(resolver_sv)) {
    SV *args = sv_2mortal(gql_runtime_vm_build_current_args_sv(aTHX_ state));
    info_sv = sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state));
    return gql_runtime_vm_call_cb5_nonfatal(
      aTHX_
      resolver_sv,
      source,
      args,
      state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
      info_sv,
      return_type_sv ? return_type_sv : &PL_sv_undef,
      error_out
    );
  }

  if (slot->field_name && strEQ(slot->field_name, "__typename")) {
    return newSVpv((state->block && state->block->type_name) ? state->block->type_name : "", 0);
  }

  if (source && SvROK(source) && SvTYPE(SvRV(source)) == SVt_PVHV) {
    HV *source_hv = (HV *)SvRV(source);
    SV **value_svp = hv_fetch(source_hv, slot->field_name, (I32)strlen(slot->field_name), 0);
    return gql_runtime_vm_clone_value_sv(aTHX_ (value_svp && SvOK(*value_svp)) ? *value_svp : &PL_sv_undef);
  }

  return newSVsv(&PL_sv_undef);
}

static SV *
gql_runtime_vm_resolve_current_field_default_fast_sv(
  pTHX_
  gql_runtime_vm_exec_state_t *state,
  SV *source,
  SV **error_out
)
{
  SV *resolver_sv;
  SV *return_type_sv = NULL;
  gql_runtime_vm_native_runtime_t *runtime = state->runtime;
  const gql_runtime_vm_native_slot_t *slot = state->slot;

  if (!runtime || slot->schema_slot_index < 0 || slot->schema_slot_index >= runtime->runtime_slot_count) {
    croak("native VM schema slot index %ld is invalid", (long)slot->schema_slot_index);
  }
  resolver_sv = (runtime->callback_catalog && runtime->callback_catalog->slot_resolvers)
    ? runtime->callback_catalog->slot_resolvers[slot->schema_slot_index]
    : NULL;

  if (resolver_sv && SvOK(resolver_sv)) {
    SV *args = sv_2mortal(gql_runtime_vm_build_current_args_sv(aTHX_ state));

    if (gql_runtime_vm_slot_uses_native_fast_abi(slot)) {
      return_type_sv = gql_runtime_vm_direct_slot_type_object_sv(runtime, slot);
      return gql_runtime_vm_call_cb4_nonfatal(
        aTHX_
        resolver_sv,
        source,
        args,
        state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
        return_type_sv ? return_type_sv : &PL_sv_undef,
        error_out
      );
    }

    return_type_sv = gql_runtime_vm_direct_slot_type_object_sv(runtime, slot);
    if (!return_type_sv) {
      return_type_sv = gql_runtime_vm_lookup_slot_type_object_sv(
        aTHX_ runtime,
        state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef,
        slot
      );
    }

    return gql_runtime_vm_call_cb5_nonfatal(
      aTHX_
      resolver_sv,
      source,
      args,
      state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
      sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state)),
      return_type_sv ? return_type_sv : &PL_sv_undef,
      error_out
    );
  }

  if (slot->field_name && strEQ(slot->field_name, "__typename")) {
    return newSVpv((state->block && state->block->type_name) ? state->block->type_name : "", 0);
  }

  if (source && SvROK(source) && SvTYPE(SvRV(source)) == SVt_PVHV) {
    HV *source_hv = (HV *)SvRV(source);
    SV **value_svp = hv_fetch(source_hv, slot->field_name, (I32)strlen(slot->field_name), 0);
    return gql_runtime_vm_clone_value_sv(aTHX_ (value_svp && SvOK(*value_svp)) ? *value_svp : &PL_sv_undef);
  }

  return newSVsv(&PL_sv_undef);
}

static gql_runtime_vm_native_value_t *gql_runtime_vm_execute_block_value(pTHX_ gql_runtime_vm_exec_state_t *state, IV block_index, SV *source);

static gql_runtime_vm_native_value_t *
gql_runtime_vm_complete_current_abstract(pTHX_ gql_runtime_vm_exec_state_t *state, SV *value, SV **error_out)
{
  IV child_block_index = -1;
  gql_runtime_vm_native_runtime_t *runtime = state->runtime;
  const gql_runtime_vm_native_slot_t *slot = state->slot;
  const gql_runtime_vm_native_op_t *op = state->op;
  gql_runtime_vm_native_callback_catalog_t *catalog = runtime ? runtime->callback_catalog : NULL;
  IV slot_index;
  SV *info_sv = NULL;
  SV *abstract_type = NULL;

  if (!runtime) {
    return gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
  }
  slot_index = slot->schema_slot_index;
  if (slot_index < 0 || slot_index >= runtime->runtime_slot_count) {
    return gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
  }
  if (op->dispatch_family_code == GQL_VM_DISPATCH_TAG) {
    SV *tag_resolver = (catalog && catalog->slot_tag_resolvers)
      ? catalog->slot_tag_resolvers[slot_index]
      : NULL;
    SV *tag_sv;
    const char *type_name = NULL;
    if (tag_resolver && catalog && catalog->slot_tag_entries && catalog->slot_tag_entry_counts[slot_index] > 0) {
      if (!abstract_type) {
        abstract_type = gql_runtime_vm_direct_slot_type_object_sv(runtime, slot);
        if (!abstract_type) {
          abstract_type = gql_runtime_vm_lookup_slot_type_object_sv(
            aTHX_ runtime, state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef, slot
          );
        }
      }
      if (!info_sv) {
        info_sv = sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state));
      }
      tag_sv = gql_runtime_vm_call_cb4_nonfatal(
        aTHX_
        tag_resolver,
        value,
        state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
        info_sv,
        abstract_type ? abstract_type : &PL_sv_undef,
        error_out
      );
      if (error_out && *error_out) {
        return NULL;
      }
      type_name = gql_runtime_vm_find_tagged_type_name(runtime, slot_index, tag_sv);
      child_block_index = gql_runtime_vm_find_abstract_child_block_index(op, type_name);
      SvREFCNT_dec(tag_sv);
    }
  }

  if (child_block_index < 0
      && (op->dispatch_family_code == GQL_VM_DISPATCH_RESOLVE_TYPE
          || op->dispatch_family_code == GQL_VM_DISPATCH_TAG)) {
    SV *resolve_type = (catalog && catalog->slot_resolve_types)
      ? catalog->slot_resolve_types[slot_index]
      : NULL;
    SV *type_sv;
    const char *type_name = NULL;
    if (!resolve_type) {
      return gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
    }
    if (!abstract_type) {
      abstract_type = gql_runtime_vm_direct_slot_type_object_sv(runtime, slot);
      if (!abstract_type) {
        abstract_type = gql_runtime_vm_lookup_slot_type_object_sv(
          aTHX_ runtime, state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef, slot
        );
      }
    }
    if (!info_sv) {
      info_sv = sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state));
    }
    type_sv = gql_runtime_vm_call_cb4_nonfatal(
      aTHX_
      resolve_type,
      value,
      state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
      info_sv,
      abstract_type ? abstract_type : &PL_sv_undef,
      error_out
    );
    if (error_out && *error_out) {
      return NULL;
    }
    type_name = gql_runtime_vm_type_name_from_sv(aTHX_ type_sv);
    child_block_index = gql_runtime_vm_find_abstract_child_block_index(op, type_name);
    SvREFCNT_dec(type_sv);
  }

  if (child_block_index < 0) {
    if (!info_sv) {
      info_sv = sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state));
    }
    gql_runtime_vm_native_possible_type_entry_t *entry =
      gql_runtime_vm_find_matching_possible_type(
        aTHX_
        runtime,
        slot_index,
        value,
        state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
        info_sv,
        error_out
      );
    if (error_out && *error_out) {
      return NULL;
    }
    if (entry) {
      child_block_index = gql_runtime_vm_find_abstract_child_block_index(op, entry->type_name);
    }
  }

  if (child_block_index < 0) {
    return gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
  }
  return gql_runtime_vm_execute_block_value(aTHX_ state, child_block_index, value);
}

static gql_runtime_vm_native_value_t *
gql_runtime_vm_complete_current_generic(pTHX_ gql_runtime_vm_exec_state_t *state, SV *value)
{
  PERL_UNUSED_ARG(state);
  return gql_runtime_vm_new_native_value_scalar(aTHX_ value);
}

static gql_runtime_vm_native_value_t *
gql_runtime_vm_complete_current_object(pTHX_ gql_runtime_vm_exec_state_t *state, SV *value)
{
  const gql_runtime_vm_native_op_t *op = state->op;
  if (op->complete_code == GQL_VM_COMPLETE_OBJECT && op->child_block_index >= 0) {
    return gql_runtime_vm_execute_block_value(aTHX_ state, op->child_block_index, value);
  }
  return gql_runtime_vm_new_native_value_scalar(aTHX_ value);
}

static gql_runtime_vm_native_value_t *
gql_runtime_vm_complete_current_list(pTHX_ gql_runtime_vm_exec_state_t *state, SV *value)
{
  const gql_runtime_vm_native_op_t *op = state->op;
  if (op->complete_code == GQL_VM_COMPLETE_LIST) {
    AV *in_av;
    gql_runtime_vm_native_value_t *out_list;
    IV i;
    if (!value || !SvOK(value)) {
      return gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
    }
    in_av = gql_runtime_vm_expect_arrayref(aTHX_ value, "list value");
    out_list = gql_runtime_vm_new_native_value_list();
    for (i = 0; i < av_count(in_av); i++) {
      SV **item_svp = av_fetch(in_av, i, 0);
      SV *item = (item_svp && SvOK(*item_svp)) ? *item_svp : &PL_sv_undef;
      gql_runtime_vm_native_value_t *completed = (op->child_block_index >= 0)
        ? gql_runtime_vm_execute_block_value(aTHX_ state, op->child_block_index, item)
        : gql_runtime_vm_new_native_value_scalar(aTHX_ item);
      gql_runtime_vm_native_list_push(out_list, completed);
    }
    return out_list;
  }
  return gql_runtime_vm_new_native_value_scalar(aTHX_ value);
}

static gql_runtime_vm_native_value_t *
gql_runtime_vm_complete_current_value(pTHX_ gql_runtime_vm_exec_state_t *state, SV *value)
{
  switch (state->op->complete_code) {
    case GQL_VM_COMPLETE_OBJECT:
      return gql_runtime_vm_complete_current_object(aTHX_ state, value);
    case GQL_VM_COMPLETE_LIST:
      return gql_runtime_vm_complete_current_list(aTHX_ state, value);
    case GQL_VM_COMPLETE_ABSTRACT:
      return gql_runtime_vm_complete_current_abstract(aTHX_ state, value, NULL);
    case GQL_VM_COMPLETE_GENERIC:
    default:
      return gql_runtime_vm_complete_current_generic(aTHX_ state, value);
  }
}

static SV *
gql_runtime_vm_resolve_current_field_explicit(pTHX_ gql_runtime_vm_exec_state_t *state, SV *source, SV **error_out)
{
  SV *resolver_sv;
  SV *return_type_sv;
  SV *info_sv;
  gql_runtime_vm_native_runtime_t *runtime = state->runtime;
  const gql_runtime_vm_native_slot_t *slot = state->slot;

  if (!runtime || slot->schema_slot_index < 0 || slot->schema_slot_index >= runtime->runtime_slot_count) {
    croak("native VM schema slot index %ld is invalid", (long)slot->schema_slot_index);
  }
  resolver_sv = (runtime->callback_catalog && runtime->callback_catalog->slot_resolvers)
    ? runtime->callback_catalog->slot_resolvers[slot->schema_slot_index]
    : NULL;
  return_type_sv = gql_runtime_vm_direct_slot_type_object_sv(runtime, slot);
  if (!return_type_sv) {
    return_type_sv = gql_runtime_vm_lookup_slot_type_object_sv(
      aTHX_ runtime, state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef, slot
    );
  }

  if (!resolver_sv || !SvOK(resolver_sv)) {
    return gql_runtime_vm_clone_value_sv(aTHX_ &PL_sv_undef);
  }

  {
    SV *args = sv_2mortal(gql_runtime_vm_build_current_args_sv(aTHX_ state));
    info_sv = sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state));
    return gql_runtime_vm_call_cb5_nonfatal(
      aTHX_
      resolver_sv,
      source,
      args,
      state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
      info_sv,
      return_type_sv ? return_type_sv : &PL_sv_undef,
      error_out
    );
  }
}

static SV *
gql_runtime_vm_resolve_current_field_explicit_fast_sv(
  pTHX_
  gql_runtime_vm_exec_state_t *state,
  SV *source,
  SV **error_out
)
{
  SV *resolver_sv;
  SV *return_type_sv = NULL;
  gql_runtime_vm_native_runtime_t *runtime = state->runtime;
  const gql_runtime_vm_native_slot_t *slot = state->slot;

  if (!runtime || slot->schema_slot_index < 0 || slot->schema_slot_index >= runtime->runtime_slot_count) {
    croak("native VM schema slot index %ld is invalid", (long)slot->schema_slot_index);
  }
  resolver_sv = (runtime->callback_catalog && runtime->callback_catalog->slot_resolvers)
    ? runtime->callback_catalog->slot_resolvers[slot->schema_slot_index]
    : NULL;

  if (!resolver_sv || !SvOK(resolver_sv)) {
    return gql_runtime_vm_clone_value_sv(aTHX_ &PL_sv_undef);
  }

  {
    SV *args = sv_2mortal(gql_runtime_vm_build_current_args_sv(aTHX_ state));

    if (gql_runtime_vm_slot_uses_native_fast_abi(slot)) {
      return_type_sv = gql_runtime_vm_direct_slot_type_object_sv(runtime, slot);
      return gql_runtime_vm_call_cb4_nonfatal(
        aTHX_
        resolver_sv,
        source,
        args,
        state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
        return_type_sv ? return_type_sv : &PL_sv_undef,
        error_out
      );
    }

    return_type_sv = gql_runtime_vm_direct_slot_type_object_sv(runtime, slot);
    if (!return_type_sv) {
      return_type_sv = gql_runtime_vm_lookup_slot_type_object_sv(
        aTHX_ runtime,
        state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef,
        slot
      );
    }

    return gql_runtime_vm_call_cb5_nonfatal(
      aTHX_
      resolver_sv,
      source,
      args,
      state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
      sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state)),
      return_type_sv ? return_type_sv : &PL_sv_undef,
      error_out
    );
  }
}

static IV
gql_runtime_vm_dispatch_index_from_opcode(IV opcode_code)
{
  switch (opcode_code) {
    case GQL_VM_OPCODE(GQL_VM_RESOLVE_DEFAULT, GQL_VM_COMPLETE_GENERIC): return 0;
    case GQL_VM_OPCODE(GQL_VM_RESOLVE_DEFAULT, GQL_VM_COMPLETE_OBJECT): return 1;
    case GQL_VM_OPCODE(GQL_VM_RESOLVE_DEFAULT, GQL_VM_COMPLETE_LIST): return 2;
    case GQL_VM_OPCODE(GQL_VM_RESOLVE_DEFAULT, GQL_VM_COMPLETE_ABSTRACT): return 3;
    case GQL_VM_OPCODE(GQL_VM_RESOLVE_EXPLICIT, GQL_VM_COMPLETE_GENERIC): return 4;
    case GQL_VM_OPCODE(GQL_VM_RESOLVE_EXPLICIT, GQL_VM_COMPLETE_OBJECT): return 5;
    case GQL_VM_OPCODE(GQL_VM_RESOLVE_EXPLICIT, GQL_VM_COMPLETE_LIST): return 6;
    case GQL_VM_OPCODE(GQL_VM_RESOLVE_EXPLICIT, GQL_VM_COMPLETE_ABSTRACT): return 7;
    default: return -1;
  }
}

static gql_runtime_vm_native_value_t *
gql_runtime_vm_execute_current_op_sv(pTHX_ gql_runtime_vm_exec_state_t *state, SV *source, gql_runtime_vm_outcome_t **error_outcome)
{
  SV *resolved = NULL;
  SV *error_sv = NULL;
  gql_runtime_vm_native_value_t *completed = NULL;
  IV dispatch_index = gql_runtime_vm_dispatch_index_from_opcode(state->op->opcode_code);

#if defined(__GNUC__) || defined(__clang__)
  static void *dispatch_table[] = {
    &&OP_DEFAULT_GENERIC,
    &&OP_DEFAULT_OBJECT,
    &&OP_DEFAULT_LIST,
    &&OP_DEFAULT_ABSTRACT,
    &&OP_EXPLICIT_GENERIC,
    &&OP_EXPLICIT_OBJECT,
    &&OP_EXPLICIT_LIST,
    &&OP_EXPLICIT_ABSTRACT
  };
#endif

  if (dispatch_index < 0) {
    croak("native VM opcode_code %ld is unsupported", (long)state->op->opcode_code);
  }

#if defined(__GNUC__) || defined(__clang__)
  goto *dispatch_table[dispatch_index];
OP_DEFAULT_GENERIC:
  resolved = gql_runtime_vm_resolve_current_field_default(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_generic(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_DEFAULT_OBJECT:
  resolved = gql_runtime_vm_resolve_current_field_default(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_object(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_DEFAULT_LIST:
  resolved = gql_runtime_vm_resolve_current_field_default(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_list(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_DEFAULT_ABSTRACT:
  resolved = gql_runtime_vm_resolve_current_field_default(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_abstract(aTHX_ state, resolved, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  goto DISPATCH_DONE;
OP_EXPLICIT_GENERIC:
  resolved = gql_runtime_vm_resolve_current_field_explicit(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_generic(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_EXPLICIT_OBJECT:
  resolved = gql_runtime_vm_resolve_current_field_explicit(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_object(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_EXPLICIT_LIST:
  resolved = gql_runtime_vm_resolve_current_field_explicit(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_list(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_EXPLICIT_ABSTRACT:
  resolved = gql_runtime_vm_resolve_current_field_explicit(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_abstract(aTHX_ state, resolved, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  goto DISPATCH_DONE;
DISPATCH_DONE:
#else
  switch (dispatch_index) {
    case 0:
      resolved = gql_runtime_vm_resolve_current_field_default(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_generic(aTHX_ state, resolved);
      break;
    case 1:
      resolved = gql_runtime_vm_resolve_current_field_default(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_object(aTHX_ state, resolved);
      break;
    case 2:
      resolved = gql_runtime_vm_resolve_current_field_default(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_list(aTHX_ state, resolved);
      break;
    case 3:
      resolved = gql_runtime_vm_resolve_current_field_default(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_abstract(aTHX_ state, resolved, &error_sv);
      break;
    case 4:
      resolved = gql_runtime_vm_resolve_current_field_explicit(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_generic(aTHX_ state, resolved);
      break;
    case 5:
      resolved = gql_runtime_vm_resolve_current_field_explicit(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_object(aTHX_ state, resolved);
      break;
    case 6:
      resolved = gql_runtime_vm_resolve_current_field_explicit(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_list(aTHX_ state, resolved);
      break;
    case 7:
      resolved = gql_runtime_vm_resolve_current_field_explicit(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_abstract(aTHX_ state, resolved, &error_sv);
      break;
  }
#endif

  if (resolved) {
    SvREFCNT_dec(resolved);
  }
  if (error_sv) {
    if (error_outcome) {
      *error_outcome = gql_runtime_vm_new_error_outcome_struct_for_path(aTHX_ error_sv, state->path_frame);
    }
    SvREFCNT_dec(error_sv);
    return NULL;
  }
  return completed ? completed : gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);

#if defined(__GNUC__) || defined(__clang__)
DISPATCH_ERROR:
  if (resolved) {
    SvREFCNT_dec(resolved);
    resolved = NULL;
  }
  if (error_sv) {
    if (error_outcome) {
      *error_outcome = gql_runtime_vm_new_error_outcome_struct_for_path(aTHX_ error_sv, state->path_frame);
    }
    SvREFCNT_dec(error_sv);
  }
  return NULL;
#endif
}

static gql_runtime_vm_native_value_t *
gql_runtime_vm_execute_block_value(pTHX_ gql_runtime_vm_exec_state_t *state, IV block_index, SV *source)
{
  gql_runtime_vm_native_block_t *block;
  gql_runtime_vm_native_value_t *data_value;
  IV i;
  gql_runtime_vm_native_block_t *saved_block = (gql_runtime_vm_native_block_t *)state->block;
  const gql_runtime_vm_native_op_t *saved_op = state->op;
  const gql_runtime_vm_native_slot_t *saved_slot = state->slot;
  gql_runtime_vm_path_frame_t *saved_path_frame = state->path_frame;
  IV saved_block_index = state->block_index;
  IV saved_op_index = state->op_index;

  if (!state->bundle || block_index < 0 || block_index >= state->bundle->block_count) {
    croak("native VM block index %ld is invalid", (long)block_index);
  }

  block = &state->bundle->blocks[block_index];
  state->block = block;
  state->block_index = block_index;
  data_value = gql_runtime_vm_new_native_value_object();

  for (i = 0; i < block->op_count; i++) {
    gql_runtime_vm_native_op_t *op = &block->ops[i];
    gql_runtime_vm_native_slot_t *slot;
    gql_runtime_vm_native_value_t *completed;
    gql_runtime_vm_outcome_t *error_outcome = NULL;
    gql_runtime_vm_path_frame_t *field_path;

    if (op->slot_index < 0 || op->slot_index >= block->slot_count) {
      croak("native VM op slot_index %ld is invalid in block %ld", (long)op->slot_index, (long)block_index);
    }
    slot = &block->slots[op->slot_index];
    state->op = op;
    state->slot = slot;
    state->op_index = i;
    if (slot->result_name) {
      SV *result_name_sv = newSVpv(slot->result_name, 0);
      field_path = gql_runtime_vm_new_path_frame_struct(aTHX_ saved_path_frame, result_name_sv);
      SvREFCNT_dec(result_name_sv);
    } else {
      field_path = gql_runtime_vm_new_path_frame_struct(aTHX_ saved_path_frame, &PL_sv_undef);
    }
    state->path_frame = field_path;
    completed = gql_runtime_vm_execute_current_op_sv(aTHX_ state, source, &error_outcome);
    state->path_frame = saved_path_frame;
    gql_runtime_vm_path_frame_decref(field_path);
    if (error_outcome) {
      if (state->writer) {
        IV j;
        for (j = 0; j < error_outcome->error_record_count; j++) {
          gql_runtime_vm_writer_push_error_record(state->writer, error_outcome->error_records[j]);
        }
      }
      gql_runtime_vm_outcome_decref(aTHX_ error_outcome);
      completed = gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
    }
    gql_runtime_vm_native_object_store(aTHX_ data_value, slot->result_name, completed);
  }

  state->block = saved_block;
  state->op = saved_op;
  state->slot = saved_slot;
  state->path_frame = saved_path_frame;
  state->block_index = saved_block_index;
  state->op_index = saved_op_index;

  return data_value;
}

static SV *gql_runtime_vm_execute_block_fast_sv(pTHX_ gql_runtime_vm_exec_state_t *state, IV block_index, SV *source);

static SV *
gql_runtime_vm_complete_current_abstract_fast_sv(
  pTHX_
  gql_runtime_vm_exec_state_t *state,
  SV *value,
  SV **error_out
)
{
  IV child_block_index = -1;
  gql_runtime_vm_native_runtime_t *runtime = state->runtime;
  const gql_runtime_vm_native_slot_t *slot = state->slot;
  const gql_runtime_vm_native_op_t *op = state->op;
  gql_runtime_vm_native_callback_catalog_t *catalog = runtime ? runtime->callback_catalog : NULL;
  IV slot_index;
  SV *info_sv = NULL;
  SV *abstract_type = NULL;
  int use_native_fast_abi = gql_runtime_vm_slot_uses_native_fast_abi(slot);

  if (!runtime) {
    return newSVsv(&PL_sv_undef);
  }
  slot_index = slot->schema_slot_index;
  if (slot_index < 0 || slot_index >= runtime->runtime_slot_count) {
    return newSVsv(&PL_sv_undef);
  }

  if (op->dispatch_family_code == GQL_VM_DISPATCH_TAG) {
    SV *tag_resolver = (catalog && catalog->slot_tag_resolvers)
      ? catalog->slot_tag_resolvers[slot_index]
      : NULL;
    SV *tag_sv;
    const char *type_name = NULL;

    if (tag_resolver
        && catalog
        && catalog->slot_tag_entries
        && catalog->slot_tag_entry_counts
        && catalog->slot_tag_entry_counts[slot_index] > 0) {
      abstract_type = gql_runtime_vm_direct_slot_type_object_sv(runtime, slot);
      if (!abstract_type) {
        abstract_type = gql_runtime_vm_lookup_slot_type_object_sv(
          aTHX_
          runtime,
          state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef,
          slot
        );
      }
      if (use_native_fast_abi) {
        tag_sv = gql_runtime_vm_call_cb4_nonfatal(
          aTHX_
          tag_resolver,
          value,
          state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
          abstract_type ? abstract_type : &PL_sv_undef,
          &PL_sv_undef,
          error_out
        );
      } else {
        if (!info_sv) {
          info_sv = sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state));
        }
        tag_sv = gql_runtime_vm_call_cb4_nonfatal(
          aTHX_
          tag_resolver,
          value,
          state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
          info_sv,
          abstract_type ? abstract_type : &PL_sv_undef,
          error_out
        );
      }
      if (error_out && *error_out) {
        return NULL;
      }
      type_name = gql_runtime_vm_find_tagged_type_name(runtime, slot_index, tag_sv);
      child_block_index = gql_runtime_vm_find_abstract_child_block_index(op, type_name);
      SvREFCNT_dec(tag_sv);
    }
  }

  if (child_block_index < 0
      && (op->dispatch_family_code == GQL_VM_DISPATCH_RESOLVE_TYPE
          || op->dispatch_family_code == GQL_VM_DISPATCH_TAG)) {
    SV *resolve_type = (catalog && catalog->slot_resolve_types)
      ? catalog->slot_resolve_types[slot_index]
      : NULL;
    SV *type_sv;
    const char *type_name = NULL;

    if (!resolve_type) {
      return newSVsv(&PL_sv_undef);
    }
    if (!abstract_type) {
      abstract_type = gql_runtime_vm_direct_slot_type_object_sv(runtime, slot);
    }
    if (!abstract_type) {
      abstract_type = gql_runtime_vm_lookup_slot_type_object_sv(
        aTHX_
        runtime,
        state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef,
        slot
      );
    }
    if (use_native_fast_abi) {
      type_sv = gql_runtime_vm_call_cb4_nonfatal(
        aTHX_
        resolve_type,
        value,
        state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
        &PL_sv_undef,
        abstract_type ? abstract_type : &PL_sv_undef,
        error_out
      );
    } else {
      if (!info_sv) {
        info_sv = sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state));
      }
      type_sv = gql_runtime_vm_call_cb4_nonfatal(
        aTHX_
        resolve_type,
        value,
        state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
        info_sv,
        abstract_type ? abstract_type : &PL_sv_undef,
        error_out
      );
    }
    if (error_out && *error_out) {
      return NULL;
    }
    type_name = gql_runtime_vm_type_name_from_sv(aTHX_ type_sv);
    child_block_index = gql_runtime_vm_find_abstract_child_block_index(op, type_name);
    SvREFCNT_dec(type_sv);
  }

  if (child_block_index < 0) {
    if (!use_native_fast_abi && !info_sv) {
      info_sv = sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state));
    }
    gql_runtime_vm_native_possible_type_entry_t *entry =
      gql_runtime_vm_find_matching_possible_type(
        aTHX_
        runtime,
        slot_index,
        value,
        state->callback_ctx ? state->callback_ctx->context : &PL_sv_undef,
        use_native_fast_abi ? NULL : info_sv,
        error_out
      );
    if (error_out && *error_out) {
      return NULL;
    }
    if (entry) {
      child_block_index = gql_runtime_vm_find_abstract_child_block_index(op, entry->type_name);
    }
  }

  if (child_block_index < 0) {
    return newSVsv(&PL_sv_undef);
  }
  return gql_runtime_vm_execute_block_fast_sv(aTHX_ state, child_block_index, value);
}

static SV *
gql_runtime_vm_complete_current_generic_fast_sv(pTHX_ gql_runtime_vm_exec_state_t *state, SV *value)
{
  PERL_UNUSED_ARG(state);
  return gql_runtime_vm_clone_value_sv(aTHX_ value);
}

static SV *
gql_runtime_vm_complete_current_object_fast_sv(pTHX_ gql_runtime_vm_exec_state_t *state, SV *value)
{
  const gql_runtime_vm_native_op_t *op = state->op;
  if (op->complete_code == GQL_VM_COMPLETE_OBJECT && op->child_block_index >= 0) {
    return gql_runtime_vm_execute_block_fast_sv(aTHX_ state, op->child_block_index, value);
  }
  return gql_runtime_vm_clone_value_sv(aTHX_ value);
}

static SV *
gql_runtime_vm_complete_current_list_fast_sv(pTHX_ gql_runtime_vm_exec_state_t *state, SV *value)
{
  const gql_runtime_vm_native_op_t *op = state->op;
  if (op->complete_code == GQL_VM_COMPLETE_LIST) {
    AV *in_av;
    AV *out_av;
    IV i;

    if (!value || !SvOK(value)) {
      return newSVsv(&PL_sv_undef);
    }
    in_av = gql_runtime_vm_expect_arrayref(aTHX_ value, "list value");
    out_av = newAV();
    av_extend(out_av, av_count(in_av) > 0 ? av_count(in_av) - 1 : 0);
    for (i = 0; i < av_count(in_av); i++) {
      SV **item_svp = av_fetch(in_av, i, 0);
      SV *item = (item_svp && SvOK(*item_svp)) ? *item_svp : &PL_sv_undef;
      SV *completed = (op->child_block_index >= 0)
        ? gql_runtime_vm_execute_block_fast_sv(aTHX_ state, op->child_block_index, item)
        : gql_runtime_vm_clone_value_sv(aTHX_ item);
      av_store(out_av, i, completed);
    }
    return newRV_noinc((SV *)out_av);
  }
  return gql_runtime_vm_clone_value_sv(aTHX_ value);
}

static SV *
gql_runtime_vm_execute_current_op_fast_sv(
  pTHX_
  gql_runtime_vm_exec_state_t *state,
  SV *source,
  SV **error_sv_out
)
{
  SV *resolved = NULL;
  SV *completed = NULL;
  SV *error_sv = NULL;
  IV dispatch_index = gql_runtime_vm_dispatch_index_from_opcode(state->op->opcode_code);

#if defined(__GNUC__) || defined(__clang__)
  static void *dispatch_table[] = {
    &&OP_DEFAULT_GENERIC,
    &&OP_DEFAULT_OBJECT,
    &&OP_DEFAULT_LIST,
    &&OP_DEFAULT_ABSTRACT,
    &&OP_EXPLICIT_GENERIC,
    &&OP_EXPLICIT_OBJECT,
    &&OP_EXPLICIT_LIST,
    &&OP_EXPLICIT_ABSTRACT
  };
#endif

  if (dispatch_index < 0) {
    croak("native VM opcode_code %ld is unsupported", (long)state->op->opcode_code);
  }

#if defined(__GNUC__) || defined(__clang__)
  goto *dispatch_table[dispatch_index];
OP_DEFAULT_GENERIC:
  resolved = gql_runtime_vm_resolve_current_field_default_fast_sv(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_generic_fast_sv(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_DEFAULT_OBJECT:
  resolved = gql_runtime_vm_resolve_current_field_default_fast_sv(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_object_fast_sv(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_DEFAULT_LIST:
  resolved = gql_runtime_vm_resolve_current_field_default_fast_sv(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_list_fast_sv(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_DEFAULT_ABSTRACT:
  resolved = gql_runtime_vm_resolve_current_field_default_fast_sv(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_abstract_fast_sv(aTHX_ state, resolved, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  goto DISPATCH_DONE;
OP_EXPLICIT_GENERIC:
  resolved = gql_runtime_vm_resolve_current_field_explicit_fast_sv(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_generic_fast_sv(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_EXPLICIT_OBJECT:
  resolved = gql_runtime_vm_resolve_current_field_explicit_fast_sv(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_object_fast_sv(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_EXPLICIT_LIST:
  resolved = gql_runtime_vm_resolve_current_field_explicit_fast_sv(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_list_fast_sv(aTHX_ state, resolved);
  goto DISPATCH_DONE;
OP_EXPLICIT_ABSTRACT:
  resolved = gql_runtime_vm_resolve_current_field_explicit_fast_sv(aTHX_ state, source, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  completed = gql_runtime_vm_complete_current_abstract_fast_sv(aTHX_ state, resolved, &error_sv);
  if (error_sv) goto DISPATCH_ERROR;
  goto DISPATCH_DONE;
DISPATCH_DONE:
#else
  switch (dispatch_index) {
    case 0:
      resolved = gql_runtime_vm_resolve_current_field_default_fast_sv(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_generic_fast_sv(aTHX_ state, resolved);
      break;
    case 1:
      resolved = gql_runtime_vm_resolve_current_field_default_fast_sv(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_object_fast_sv(aTHX_ state, resolved);
      break;
    case 2:
      resolved = gql_runtime_vm_resolve_current_field_default_fast_sv(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_list_fast_sv(aTHX_ state, resolved);
      break;
    case 3:
      resolved = gql_runtime_vm_resolve_current_field_default_fast_sv(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_abstract_fast_sv(aTHX_ state, resolved, &error_sv);
      break;
    case 4:
      resolved = gql_runtime_vm_resolve_current_field_explicit_fast_sv(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_generic_fast_sv(aTHX_ state, resolved);
      break;
    case 5:
      resolved = gql_runtime_vm_resolve_current_field_explicit_fast_sv(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_object_fast_sv(aTHX_ state, resolved);
      break;
    case 6:
      resolved = gql_runtime_vm_resolve_current_field_explicit_fast_sv(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_list_fast_sv(aTHX_ state, resolved);
      break;
    case 7:
      resolved = gql_runtime_vm_resolve_current_field_explicit_fast_sv(aTHX_ state, source, &error_sv);
      if (error_sv) break;
      completed = gql_runtime_vm_complete_current_abstract_fast_sv(aTHX_ state, resolved, &error_sv);
      break;
  }
#endif

  if (resolved) {
    SvREFCNT_dec(resolved);
  }
  if (error_sv) {
    if (completed) {
      SvREFCNT_dec(completed);
    }
    if (error_sv_out) {
      *error_sv_out = error_sv;
      error_sv = NULL;
    }
    SvREFCNT_dec(error_sv);
    return NULL;
  }
  return completed ? completed : newSVsv(&PL_sv_undef);

#if defined(__GNUC__) || defined(__clang__)
DISPATCH_ERROR:
  if (resolved) {
    SvREFCNT_dec(resolved);
    resolved = NULL;
  }
  if (completed) {
    SvREFCNT_dec(completed);
    completed = NULL;
  }
  if (error_sv) {
    if (error_sv_out) {
      *error_sv_out = error_sv;
      error_sv = NULL;
    }
    SvREFCNT_dec(error_sv);
  }
  return NULL;
#endif
}

static SV *
gql_runtime_vm_execute_block_fast_sv(pTHX_ gql_runtime_vm_exec_state_t *state, IV block_index, SV *source)
{
  gql_runtime_vm_native_block_t *block;
  HV *data_hv;
  IV i;
  gql_runtime_vm_native_block_t *saved_block = (gql_runtime_vm_native_block_t *)state->block;
  const gql_runtime_vm_native_op_t *saved_op = state->op;
  const gql_runtime_vm_native_slot_t *saved_slot = state->slot;
  gql_runtime_vm_path_frame_t *saved_path_frame = state->path_frame;
  IV saved_block_index = state->block_index;
  IV saved_op_index = state->op_index;

  if (!state->bundle || block_index < 0 || block_index >= state->bundle->block_count) {
    croak("native VM block index %ld is invalid", (long)block_index);
  }

  block = &state->bundle->blocks[block_index];
  state->block = block;
  state->block_index = block_index;
  data_hv = newHV();

  for (i = 0; i < block->op_count; i++) {
    gql_runtime_vm_native_op_t *op = &block->ops[i];
    gql_runtime_vm_native_slot_t *slot;
    SV *completed;
    SV *error_sv = NULL;
    gql_runtime_vm_outcome_t *error_outcome = NULL;
    gql_runtime_vm_path_frame_t *field_path = NULL;
    int eager_path_frame;

    if (op->slot_index < 0 || op->slot_index >= block->slot_count) {
      croak("native VM op slot_index %ld is invalid in block %ld", (long)op->slot_index, (long)block_index);
    }
    slot = &block->slots[op->slot_index];
    state->op = op;
    state->slot = slot;
    state->op_index = i;

    eager_path_frame = !gql_runtime_vm_slot_uses_native_fast_abi(slot)
      || op->complete_code != GQL_VM_COMPLETE_GENERIC;

    if (eager_path_frame) {
      if (slot->result_name) {
        field_path = gql_runtime_vm_new_path_frame_struct_pvn(
          aTHX_
          saved_path_frame,
          slot->result_name,
          strlen(slot->result_name)
        );
      } else {
        field_path = gql_runtime_vm_new_path_frame_struct(aTHX_ saved_path_frame, &PL_sv_undef);
      }
      state->path_frame = field_path;
    } else {
      state->path_frame = saved_path_frame;
    }

    completed = gql_runtime_vm_execute_current_op_fast_sv(aTHX_ state, source, &error_sv);
    state->path_frame = saved_path_frame;

    if (!eager_path_frame && error_sv) {
      if (slot->result_name) {
        field_path = gql_runtime_vm_new_path_frame_struct_pvn(
          aTHX_
          saved_path_frame,
          slot->result_name,
          strlen(slot->result_name)
        );
      } else {
        field_path = gql_runtime_vm_new_path_frame_struct(aTHX_ saved_path_frame, &PL_sv_undef);
      }
      error_outcome = gql_runtime_vm_new_error_outcome_struct_for_path(aTHX_ error_sv, field_path);
      SvREFCNT_dec(error_sv);
      error_sv = NULL;
    } else if (error_sv) {
      error_outcome = gql_runtime_vm_new_error_outcome_struct_for_path(aTHX_ error_sv, field_path);
      SvREFCNT_dec(error_sv);
      error_sv = NULL;
    }

    if (field_path) {
      gql_runtime_vm_path_frame_decref(field_path);
      field_path = NULL;
    }

    if (error_outcome) {
      if (state->writer) {
        IV j;
        for (j = 0; j < error_outcome->error_record_count; j++) {
          gql_runtime_vm_writer_push_error_record(state->writer, error_outcome->error_records[j]);
        }
      }
      gql_runtime_vm_outcome_decref(aTHX_ error_outcome);
      completed = newSVsv(&PL_sv_undef);
    }
    hv_store(data_hv, slot->result_name, (I32)strlen(slot->result_name), completed, 0);
  }

  state->block = saved_block;
  state->op = saved_op;
  state->slot = saved_slot;
  state->path_frame = saved_path_frame;
  state->block_index = saved_block_index;
  state->op_index = saved_op_index;

  return newRV_noinc((SV *)data_hv);
}

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Parser

SV *
parse_xs(source, no_location = &PL_sv_undef)
    SV *source
    SV *no_location
  CODE:
    RETVAL = gql_parse_document(aTHX_ source, no_location);
  OUTPUT:
    RETVAL

SV *
_materialize_arguments_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gql_parser_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_ARGUMENTS
      ));
    }
  OUTPUT:
    RETVAL

SV *
_materialize_directives_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gql_parser_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_DIRECTIVES
      ));
    }
  OUTPUT:
    RETVAL

SV *
_materialize_variable_definitions_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gql_parser_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_VARIABLE_DEFINITIONS
      ));
    }
  OUTPUT:
    RETVAL

SV *
_materialize_object_fields_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gql_parser_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_OBJECT_FIELDS
      ));
    }
  OUTPUT:
    RETVAL

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::LazyState

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_parser_lazy_state_t *state = INT2PTR(gql_parser_lazy_state_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_parser_lazy_state_destroy(state);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Parser

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::SchemaCompiler

SV *
compile_schema_xs(schema)
    SV *schema
  CODE:
    RETVAL = gql_schema_compile_schema(aTHX_ schema);
  OUTPUT:
    RETVAL

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Validation

SV *
validate_xs(schema, document, options = NULL)
    SV *schema
    SV *document
    SV *options
  CODE:
    RETVAL = gql_validation_validate(aTHX_ schema, document, options);
  OUTPUT:
    RETVAL

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::VM

SV *
native_codes_xs()
  CODE:
    {
      HV *hv = newHV();
      hv_store(hv, "resolve_default", 15, newSViv(GQL_VM_RESOLVE_DEFAULT), 0);
      hv_store(hv, "resolve_explicit", 16, newSViv(GQL_VM_RESOLVE_EXPLICIT), 0);
      hv_store(hv, "complete_generic", 16, newSViv(GQL_VM_COMPLETE_GENERIC), 0);
      hv_store(hv, "complete_object", 15, newSViv(GQL_VM_COMPLETE_OBJECT), 0);
      hv_store(hv, "complete_list", 13, newSViv(GQL_VM_COMPLETE_LIST), 0);
      hv_store(hv, "complete_abstract", 17, newSViv(GQL_VM_COMPLETE_ABSTRACT), 0);
      hv_store(hv, "family_generic", 14, newSViv(GQL_VM_FAMILY_GENERIC), 0);
      hv_store(hv, "family_object", 13, newSViv(GQL_VM_FAMILY_OBJECT), 0);
      hv_store(hv, "family_list", 11, newSViv(GQL_VM_FAMILY_LIST), 0);
      hv_store(hv, "family_abstract", 15, newSViv(GQL_VM_FAMILY_ABSTRACT), 0);
      hv_store(hv, "dispatch_generic", 16, newSViv(GQL_VM_DISPATCH_GENERIC), 0);
      hv_store(hv, "dispatch_resolve_type", 21, newSViv(GQL_VM_DISPATCH_RESOLVE_TYPE), 0);
      hv_store(hv, "dispatch_tag", 12, newSViv(GQL_VM_DISPATCH_TAG), 0);
      hv_store(hv, "dispatch_possible_types", 23, newSViv(GQL_VM_DISPATCH_POSSIBLE_TYPES), 0);
      hv_store(hv, "kind_scalar", 11, newSViv(GQL_VM_KIND_SCALAR), 0);
      hv_store(hv, "kind_object", 11, newSViv(GQL_VM_KIND_OBJECT), 0);
      hv_store(hv, "kind_list", 9, newSViv(GQL_VM_KIND_LIST), 0);
      hv_store(hv, "kind_interface", 14, newSViv(GQL_VM_KIND_INTERFACE), 0);
      hv_store(hv, "kind_union", 10, newSViv(GQL_VM_KIND_UNION), 0);
      hv_store(hv, "kind_enum", 9, newSViv(GQL_VM_KIND_ENUM), 0);
      hv_store(hv, "kind_input_object", 17, newSViv(GQL_VM_KIND_INPUT_OBJECT), 0);
      hv_store(hv, "kind_non_null", 13, newSViv(GQL_VM_KIND_NON_NULL), 0);
      hv_store(hv, "optype_query", 12, newSViv(GQL_VM_OPTYPE_QUERY), 0);
      hv_store(hv, "optype_mutation", 15, newSViv(GQL_VM_OPTYPE_MUTATION), 0);
      hv_store(hv, "optype_subscription", 18, newSViv(GQL_VM_OPTYPE_SUBSCRIPTION), 0);
      RETVAL = newRV_noinc((SV *)hv);
    }
  OUTPUT:
    RETVAL

SV *
load_native_bundle_xs(descriptor)
    SV *descriptor
  CODE:
    {
      gql_runtime_vm_native_bundle_t *bundle =
        gql_runtime_vm_native_bundle_from_sv(aTHX_ descriptor);
      SV *inner = newSVuv(PTR2UV(bundle));
      RETVAL = newRV_noinc(inner);
      sv_bless(RETVAL, gv_stashpv("GraphQL::Houtou::Runtime::NativeBundle", GV_ADD));
    }
  OUTPUT:
    RETVAL

SV *
load_native_bundle_parts_xs(runtime_descriptor, program_descriptor)
    SV *runtime_descriptor
    SV *program_descriptor
  CODE:
    {
      gql_runtime_vm_native_bundle_t *bundle =
        gql_runtime_vm_native_bundle_from_runtime_and_program_sv(
          aTHX_ runtime_descriptor, program_descriptor
        );
      SV *inner = newSVuv(PTR2UV(bundle));
      RETVAL = newRV_noinc(inner);
      sv_bless(RETVAL, gv_stashpv("GraphQL::Houtou::Runtime::NativeBundle", GV_ADD));
    }
  OUTPUT:
    RETVAL

SV *
native_bundle_summary_xs(bundle_sv)
    SV *bundle_sv
  CODE:
    {
      gql_runtime_vm_native_bundle_t *bundle;
      HV *hv;
      AV *dispatch_codes;
      IV i;

      if (!bundle_sv || !SvROK(bundle_sv) || !sv_derived_from(bundle_sv, "GraphQL::Houtou::Runtime::NativeBundle")) {
        croak("expected a GraphQL::Houtou::Runtime::NativeBundle");
      }
      bundle = INT2PTR(gql_runtime_vm_native_bundle_t *, SvUV(SvRV(bundle_sv)));
      if (!bundle) {
        croak("native VM bundle handle is no longer valid");
      }

      hv = newHV();
      hv_store(hv, "runtime_slot_count", 18, newSViv(bundle->runtime_slot_count), 0);
      hv_store(hv, "block_count", 11, newSViv(bundle->block_count), 0);
      hv_store(hv, "root_block_index", 16, newSViv(bundle->root_block_index), 0);
      hv_store(hv, "operation_type_code", 19, newSViv(bundle->operation_type_code), 0);

      if (bundle->root_block_index >= 0 && bundle->root_block_index < bundle->block_count) {
        gql_runtime_vm_native_block_t *root = &bundle->blocks[bundle->root_block_index];
        hv_store(hv, "root_family_code", 16, newSViv(root->family_code), 0);
        hv_store(hv, "root_slot_count", 15, newSViv(root->slot_count), 0);
        hv_store(hv, "root_op_count", 13, newSViv(root->op_count), 0);

        dispatch_codes = newAV();
        av_extend(dispatch_codes, root->op_count > 0 ? root->op_count - 1 : 0);
        for (i = 0; i < root->op_count; i++) {
          av_store(dispatch_codes, i, newSViv(root->ops[i].dispatch_family_code));
        }
        hv_store(hv, "root_dispatch_family_codes", 26, newRV_noinc((SV *)dispatch_codes), 0);
      }

      RETVAL = newRV_noinc((SV *)hv);
    }
  OUTPUT:
    RETVAL

SV *
load_native_program_xs(program_descriptor)
    SV *program_descriptor
  CODE:
    {
      gql_runtime_vm_native_program_t *program =
        gql_runtime_vm_native_program_from_sv(aTHX_ program_descriptor);
      SV *inner = newSVuv(PTR2UV(program));
      RETVAL = newRV_noinc(inner);
      sv_bless(RETVAL, gv_stashpv("GraphQL::Houtou::Runtime::NativeProgram", GV_ADD));
    }
  OUTPUT:
    RETVAL

SV *
native_program_descriptor_xs(program_sv)
    SV *program_sv
  CODE:
    {
      gql_runtime_vm_native_program_t *program =
        gql_runtime_vm_native_program_from_sv(aTHX_ program_sv);
      RETVAL = gql_runtime_vm_native_program_to_compact_sv(aTHX_ program);
    }
  OUTPUT:
    RETVAL

SV *
native_program_prepare_variables_xs(runtime_schema, program_sv, provided = &PL_sv_undef)
    SV *runtime_schema
    SV *program_sv
    SV *provided
  CODE:
    {
      gql_runtime_vm_native_program_t *program =
        gql_runtime_vm_native_program_from_sv(aTHX_ program_sv);
      HV *provided_hv = NULL;
      if (provided && SvOK(provided) && SvROK(provided) && SvTYPE(SvRV(provided)) == SVt_PVHV) {
        provided_hv = (HV *)SvRV(provided);
      }
      RETVAL = gql_runtime_vm_prepare_program_variables_sv(
        aTHX_ runtime_schema,
        program,
        provided_hv
      );
    }
  OUTPUT:
    RETVAL

IV
native_program_root_block_index_xs(program_sv)
    SV *program_sv
  CODE:
    {
      gql_runtime_vm_native_program_t *program =
        gql_runtime_vm_native_program_from_sv(aTHX_ program_sv);
      RETVAL = program->root_block_index;
    }
  OUTPUT:
    RETVAL

SV *
specialize_native_program_xs(runtime_sv, program_descriptor, variables = &PL_sv_undef)
    SV *runtime_sv
    SV *program_descriptor
    SV *variables
  CODE:
    {
      gql_runtime_vm_native_runtime_t *runtime;
      gql_runtime_vm_native_program_t *program;
      HV *variables_hv = NULL;
      SV *inner;

      if (!runtime_sv || !SvROK(runtime_sv) || !sv_derived_from(runtime_sv, "GraphQL::Houtou::Runtime::NativeRuntime")) {
        croak("expected a GraphQL::Houtou::Runtime::NativeRuntime");
      }
      runtime = INT2PTR(gql_runtime_vm_native_runtime_t *, SvUV(SvRV(runtime_sv)));
      if (!runtime) {
        croak("native VM runtime handle is no longer valid");
      }
      if (variables && SvOK(variables) && SvROK(variables) && SvTYPE(SvRV(variables)) == SVt_PVHV) {
        variables_hv = (HV *)SvRV(variables);
      }

      program = gql_runtime_vm_native_program_from_sv(aTHX_ program_descriptor);
      if (program_descriptor && SvROK(program_descriptor) && sv_derived_from(program_descriptor, "GraphQL::Houtou::Runtime::NativeProgram")) {
        program = gql_runtime_vm_clone_native_program(aTHX_ program);
      }
      gql_runtime_vm_specialize_native_program_in_place(aTHX_ runtime, program, variables_hv);

      inner = newSVuv(PTR2UV(program));
      RETVAL = newRV_noinc(inner);
      sv_bless(RETVAL, gv_stashpv("GraphQL::Houtou::Runtime::NativeProgram", GV_ADD));
    }
  OUTPUT:
    RETVAL

SV *
load_native_bundle_from_handles_xs(runtime_sv, program_sv)
    SV *runtime_sv
    SV *program_sv
  CODE:
    {
      gql_runtime_vm_native_runtime_t *runtime;
      gql_runtime_vm_native_program_t *program;
      gql_runtime_vm_native_bundle_t *bundle;
      if (!runtime_sv || !SvROK(runtime_sv) || !sv_derived_from(runtime_sv, "GraphQL::Houtou::Runtime::NativeRuntime")) {
        croak("expected a GraphQL::Houtou::Runtime::NativeRuntime");
      }
      runtime = INT2PTR(gql_runtime_vm_native_runtime_t *, SvUV(SvRV(runtime_sv)));
      if (!runtime) {
        croak("native VM runtime handle is no longer valid");
      }
      program = gql_runtime_vm_native_program_from_sv(aTHX_ program_sv);
      bundle = gql_runtime_vm_native_bundle_from_runtime_and_program_handles(runtime, program);
      SV *inner = newSVuv(PTR2UV(bundle));
      RETVAL = newRV_noinc(inner);
      sv_bless(RETVAL, gv_stashpv("GraphQL::Houtou::Runtime::NativeBundle", GV_ADD));
    }
  OUTPUT:
    RETVAL

SV *
native_program_summary_xs(program_sv)
    SV *program_sv
  CODE:
    {
      gql_runtime_vm_native_program_t *program;
      HV *hv;
      if (!program_sv || !SvROK(program_sv) || !sv_derived_from(program_sv, "GraphQL::Houtou::Runtime::NativeProgram")) {
        croak("expected a GraphQL::Houtou::Runtime::NativeProgram");
      }
      program = INT2PTR(gql_runtime_vm_native_program_t *, SvUV(SvRV(program_sv)));
      if (!program) {
        croak("native VM program handle is no longer valid");
      }
      hv = newHV();
      hv_store(hv, "block_count", 11, newSViv(program->block_count), 0);
      hv_store(hv, "root_block_index", 16, newSViv(program->root_block_index), 0);
      hv_store(hv, "operation_type_code", 19, newSViv(program->operation_type_code), 0);
      RETVAL = newRV_noinc((SV *)hv);
    }
  OUTPUT:
    RETVAL

SV *
load_native_runtime_xs(runtime_schema)
    SV *runtime_schema
  CODE:
    {
      gql_runtime_vm_native_runtime_t *runtime =
        gql_runtime_vm_native_runtime_from_runtime_schema_sv(aTHX_ runtime_schema);
      SV *inner = newSVuv(PTR2UV(runtime));
      RETVAL = newRV_noinc(inner);
      sv_bless(RETVAL, gv_stashpv("GraphQL::Houtou::Runtime::NativeRuntime", GV_ADD));
    }
  OUTPUT:
    RETVAL

SV *
native_runtime_summary_xs(runtime_sv)
    SV *runtime_sv
  CODE:
    {
      gql_runtime_vm_native_runtime_t *runtime;
      HV *hv;

      if (!runtime_sv || !SvROK(runtime_sv) || !sv_derived_from(runtime_sv, "GraphQL::Houtou::Runtime::NativeRuntime")) {
        croak("expected a GraphQL::Houtou::Runtime::NativeRuntime");
      }
      runtime = INT2PTR(gql_runtime_vm_native_runtime_t *, SvUV(SvRV(runtime_sv)));
      if (!runtime) {
        croak("native VM runtime handle is no longer valid");
      }

      hv = newHV();
      hv_store(hv, "runtime_slot_count", 18, newSViv(runtime->runtime_slot_count), 0);
      hv_store(hv, "has_slot_type_objects", 21, newSViv(runtime->callback_catalog && runtime->callback_catalog->slot_type_objects ? 1 : 0), 0);
      hv_store(hv, "has_tag_dispatch_tables", 23, newSViv(runtime->callback_catalog && runtime->callback_catalog->slot_tag_entries ? 1 : 0), 0);
      hv_store(hv, "has_possible_type_entries", 25, newSViv(runtime->callback_catalog && runtime->callback_catalog->slot_possible_type_entries ? 1 : 0), 0);
      RETVAL = newRV_noinc((SV *)hv);
    }
  OUTPUT:
    RETVAL

int
program_native_eligible_xs(program, has_promise = 0)
    SV *program
    int has_promise
  CODE:
    RETVAL = gql_runtime_vm_program_is_native_eligible_sv(aTHX_ program, has_promise);
  OUTPUT:
    RETVAL

void
resolve_runtime_type_xs(dispatch, runtime_cache, value, context, info, abstract_type)
    SV *dispatch
    SV *runtime_cache
    SV *value
    SV *context
    SV *info
    SV *abstract_type
  PPCODE:
    {
      SV *error = NULL;
      SV *runtime_type = gql_runtime_vm_resolve_runtime_type_sv(
        aTHX_ dispatch, runtime_cache, value, context, info, abstract_type, &error
      );
      EXTEND(SP, 2);
      PUSHs(sv_2mortal(runtime_type ? runtime_type : newSV(0)));
      PUSHs(sv_2mortal(error ? error : newSV(0)));
    }

void
resolve_runtime_type_for_abstract_xs(runtime_cache, abstract_name, value, context, info, abstract_type)
    SV *runtime_cache
    SV *abstract_name
    SV *value
    SV *context
    SV *info
    SV *abstract_type
  PPCODE:
    {
      SV *error = NULL;
      STRLEN abstract_name_len = 0;
      const char *abstract_name_pv = (abstract_name && SvOK(abstract_name))
        ? SvPV(abstract_name, abstract_name_len)
        : NULL;
      SV *runtime_type = gql_runtime_vm_resolve_runtime_type_for_abstract_sv(
        aTHX_ runtime_cache, abstract_name_pv, value, context, info, abstract_type, &error
      );
      EXTEND(SP, 2);
      PUSHs(sv_2mortal(runtime_type ? runtime_type : newSV(0)));
      PUSHs(sv_2mortal(error ? error : newSV(0)));
    }

SV *
outcome_scalar_xs(value, error_records = &PL_sv_undef)
    SV *value
    SV *error_records
  CODE:
    RETVAL = gql_runtime_vm_new_handle_sv(
      aTHX_
      "GraphQL::Houtou::Runtime::Outcome",
      gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, value, error_records)
    );
  OUTPUT:
    RETVAL

SV *
outcome_object_xs(value, error_records = &PL_sv_undef)
    SV *value
    SV *error_records
  CODE:
    RETVAL = gql_runtime_vm_new_handle_sv(
      aTHX_
      "GraphQL::Houtou::Runtime::Outcome",
      gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_OBJECT, value, error_records)
    );
  OUTPUT:
    RETVAL

SV *
outcome_list_xs(value, error_records = &PL_sv_undef)
    SV *value
    SV *error_records
  CODE:
    RETVAL = gql_runtime_vm_new_handle_sv(
      aTHX_
      "GraphQL::Houtou::Runtime::Outcome",
      gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_LIST, value, error_records)
    );
  OUTPUT:
    RETVAL

SV *
wrap_object_outcome_callback_xs(...)
  CODE:
    {
      SV *value = items > 0 ? ST(0) : &PL_sv_undef;
      RETVAL = gql_runtime_vm_new_outcome_handle_sv(
        aTHX_
        GQL_VM_KIND_OBJECT,
        value,
        &PL_sv_undef
      );
    }
  OUTPUT:
    RETVAL

SV *
wrap_list_outcome_callback_xs(...)
  PREINIT:
    AV *resolved_av;
    I32 i;
  CODE:
    {
      resolved_av = newAV();
      if (items == 1 && ST(0) && SvROK(ST(0)) && SvTYPE(SvRV(ST(0))) == SVt_PVAV) {
        AV *source_av = (AV *)SvRV(ST(0));
        SSize_t max = av_len(source_av);
        for (i = 0; i <= max; i++) {
          SV **svp = av_fetch(source_av, i, 0);
          av_push(resolved_av, newSVsv((svp && *svp) ? *svp : &PL_sv_undef));
        }
      } else {
        for (i = 0; i < items; i++) {
          av_push(resolved_av, newSVsv(ST(i) ? ST(i) : &PL_sv_undef));
        }
      }
      {
        SV *list_sv = newRV_noinc((SV *)resolved_av);
        RETVAL = gql_runtime_vm_new_outcome_handle_sv(
          aTHX_
          GQL_VM_KIND_LIST,
          list_sv,
          &PL_sv_undef
        );
        SvREFCNT_dec(list_sv);
      }
    }
  OUTPUT:
    RETVAL

SV *
writer_new_xs(class)
    SV *class
  CODE:
    RETVAL = gql_runtime_vm_new_handle_sv(
      aTHX_
      "GraphQL::Houtou::Runtime::Writer",
      gql_runtime_vm_new_writer_struct(aTHX)
    );
  OUTPUT:
    RETVAL

void
consume_outcome_xs(writer, data, result_name, outcome)
    SV *writer
    SV *data
    SV *result_name
    SV *outcome
  PPCODE:
    {
      HV *data_hv = NULL;
      gql_runtime_vm_writer_t *writer_state = gql_runtime_vm_expect_writer(aTHX_ writer);
      gql_runtime_vm_outcome_t *outcome_state = gql_runtime_vm_expect_outcome(aTHX_ outcome);
      if (data && SvOK(data) && SvROK(data) && SvTYPE(SvRV(data)) == SVt_PVHV) {
        data_hv = (HV *)SvRV(data);
      }
      gql_runtime_vm_consume_outcome_struct(aTHX_ data_hv, result_name, outcome_state, writer_state);
    }

SV *
outcome_kind_xs(outcome)
    SV *outcome
  CODE:
    RETVAL = gql_runtime_vm_outcome_kind_sv(aTHX_ gql_runtime_vm_expect_outcome(aTHX_ outcome));
  OUTPUT:
    RETVAL

SV *
outcome_value_xs(outcome)
    SV *outcome
  CODE:
    {
      gql_runtime_vm_outcome_t *state = gql_runtime_vm_expect_outcome(aTHX_ outcome);
      RETVAL = state->value ? gql_runtime_vm_native_value_materialize_sv(aTHX_ state->value) : newSV(0);
    }
  OUTPUT:
    RETVAL

SV *
outcome_error_records_xs(outcome)
    SV *outcome
  CODE:
    {
      gql_runtime_vm_outcome_t *state = gql_runtime_vm_expect_outcome(aTHX_ outcome);
      AV *ret = newAV();
      IV i;
      for (i = 0; i < state->error_record_count; i++) {
        gql_runtime_vm_error_record_incref(state->error_records[i]);
        av_push(ret, gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::ErrorRecord", state->error_records[i]));
      }
      RETVAL = newRV_noinc((SV *)ret);
    }
  OUTPUT:
    RETVAL

SV *
writer_error_records_xs(writer)
    SV *writer
  CODE:
    {
      gql_runtime_vm_writer_t *state = gql_runtime_vm_expect_writer(aTHX_ writer);
      AV *ret = newAV();
      IV i;
      for (i = 0; i < state->error_record_count; i++) {
        gql_runtime_vm_error_record_incref(state->error_records[i]);
        av_push(ret, gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::ErrorRecord", state->error_records[i]));
      }
      RETVAL = newRV_noinc((SV *)ret);
    }
  OUTPUT:
    RETVAL

SV *
cursor_new_xs(class, block, native_program = &PL_sv_undef, block_index = -1, slot_index = 0, op_index = 0, current_slot = &PL_sv_undef, current_op = &PL_sv_undef)
    SV *class
    SV *block
    SV *native_program
    IV block_index
    IV slot_index
    IV op_index
    SV *current_slot
    SV *current_op
  CODE:
    {
      gql_runtime_vm_cursor_t *cursor;
      const char *pkg = SvPV_nolen(class);
      (void)current_slot;
      (void)current_op;
      Newxz(cursor, 1, gql_runtime_vm_cursor_t);
      cursor->refcount = 1;
      cursor->native_program = (native_program && SvOK(native_program))
        ? gql_runtime_vm_native_program_from_sv(aTHX_ native_program)
        : NULL;
      if (block_index < 0 && block && SvOK(block) && !SvROK(block) && SvIOK(block)) {
        block_index = SvIV(block);
      }
      cursor->block_index = block_index;
      (void)block;
      cursor->slot_index = slot_index;
      cursor->op_index = op_index;
      RETVAL = gql_runtime_vm_new_handle_sv(aTHX_ pkg, cursor);
    }
  OUTPUT:
    RETVAL

SV *
cursor_snapshot_xs(cursor)
    SV *cursor
  CODE:
    RETVAL = gql_runtime_vm_cursor_snapshot_sv(aTHX_ cursor);
  OUTPUT:
    RETVAL

void
cursor_restore_xs(cursor, snapshot)
    SV *cursor
    SV *snapshot
  CODE:
    {
      gql_runtime_vm_cursor_t *dst = gql_runtime_vm_expect_cursor(aTHX_ cursor);
      gql_runtime_vm_cursor_restore_sv(aTHX_ dst, snapshot);
    }

void
cursor_enter_block_xs(cursor, block, block_index = -1)
    SV *cursor
    SV *block
    IV block_index
  CODE:
    {
      gql_runtime_vm_cursor_t *dst = gql_runtime_vm_expect_cursor(aTHX_ cursor);
      if (block_index < 0 && block && SvOK(block) && !SvROK(block) && SvIOK(block)) {
        block_index = SvIV(block);
      }
      (void)block;
      dst->block_index = block_index;
      dst->slot_index = 0;
      dst->op_index = -1;
    }

void
cursor_set_current_op_xs(cursor, op, index = -2147483647)
    SV *cursor
    SV *op
    IV index
  CODE:
    {
      gql_runtime_vm_cursor_t *dst = gql_runtime_vm_expect_cursor(aTHX_ cursor);
      (void)op;
      if (index != -2147483647) {
        dst->op_index = index;
      }
    }

SV *
cursor_advance_op_xs(cursor)
    SV *cursor
  CODE:
    {
      gql_runtime_vm_cursor_t *dst = gql_runtime_vm_expect_cursor(aTHX_ cursor);
      const gql_runtime_vm_native_block_t *block;
      const gql_runtime_vm_native_op_t *op;
      IV next_index;
      block = gql_runtime_vm_cursor_current_native_block(dst);
      if (!block) {
        RETVAL = &PL_sv_undef;
        goto done_cursor_advance;
      }
      next_index = dst->op_index + 1;
      if (next_index >= block->op_count) {
        dst->op_index = next_index;
        RETVAL = &PL_sv_undef;
        goto done_cursor_advance;
      }
      dst->op_index = next_index;
      op = &block->ops[next_index];
      dst->slot_index = op ? op->slot_index : 0;
      RETVAL = newSViv(next_index);
	done_cursor_advance:
	      ;
    }
  OUTPUT:
    RETVAL

SV *
cursor_block_xs(cursor)
    SV *cursor
  CODE:
    {
      RETVAL = newSVsv(&PL_sv_undef);
    }
  OUTPUT:
    RETVAL

IV
cursor_slot_index_xs(cursor)
    SV *cursor
  CODE:
    RETVAL = gql_runtime_vm_expect_cursor(aTHX_ cursor)->slot_index;
  OUTPUT:
    RETVAL

IV
cursor_op_index_xs(cursor)
    SV *cursor
  CODE:
    RETVAL = gql_runtime_vm_expect_cursor(aTHX_ cursor)->op_index;
  OUTPUT:
    RETVAL

SV *
cursor_current_slot_xs(cursor)
    SV *cursor
  CODE:
    {
      RETVAL = newSVsv(&PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
cursor_current_op_xs(cursor)
    SV *cursor
  CODE:
    {
      RETVAL = newSVsv(&PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
field_frame_new_xs(class, source = &PL_sv_undef, path_frame = &PL_sv_undef, resolved_value = &PL_sv_undef, outcome = &PL_sv_undef)
    SV *class
    SV *source
    SV *path_frame
    SV *resolved_value
    SV *outcome
  CODE:
    {
      gql_runtime_vm_field_frame_t *frame;
      const char *pkg = SvPV_nolen(class);
      frame = gql_runtime_vm_new_field_frame_struct(
        aTHX_
        source,
        (path_frame && SvOK(path_frame) && SvROK(path_frame) && SvIOK(SvRV(path_frame)) && SvUV(SvRV(path_frame)) != 0)
          ? INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(path_frame)))
          : NULL
      );
      SvREFCNT_dec(frame->resolved_value);
      frame->resolved_value = newSVsv(resolved_value ? resolved_value : &PL_sv_undef);
      if (outcome && SvOK(outcome)) {
        frame->outcome = gql_runtime_vm_expect_outcome(aTHX_ outcome);
        gql_runtime_vm_outcome_incref(frame->outcome);
      }
      RETVAL = gql_runtime_vm_new_handle_sv(aTHX_ pkg, frame);
    }
  OUTPUT:
    RETVAL

void
field_frame_set_resolved_value_xs(frame, value)
    SV *frame
    SV *value
  CODE:
    {
      gql_runtime_vm_field_frame_t *state = gql_runtime_vm_expect_field_frame(aTHX_ frame);
      SvREFCNT_dec(state->resolved_value);
      state->resolved_value = newSVsv(value ? value : &PL_sv_undef);
    }

void
field_frame_set_outcome_xs(frame, outcome)
    SV *frame
    SV *outcome
  CODE:
    {
      gql_runtime_vm_field_frame_t *state = gql_runtime_vm_expect_field_frame(aTHX_ frame);
      gql_runtime_vm_outcome_decref(aTHX_ state->outcome);
      state->outcome = NULL;
      if (outcome && SvOK(outcome)) {
        state->outcome = gql_runtime_vm_expect_outcome(aTHX_ outcome);
        gql_runtime_vm_outcome_incref(state->outcome);
      }
    }

SV *
field_frame_source_xs(frame)
    SV *frame
  CODE:
    {
      gql_runtime_vm_field_frame_t *state = gql_runtime_vm_expect_field_frame(aTHX_ frame);
      RETVAL = newSVsv(state->source ? state->source : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
field_frame_path_frame_xs(frame)
    SV *frame
  CODE:
    {
      gql_runtime_vm_field_frame_t *state = gql_runtime_vm_expect_field_frame(aTHX_ frame);
      if (state->path_frame) {
        state->path_frame->refcount++;
        RETVAL = gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::PathFrame", state->path_frame);
      } else {
        RETVAL = newSVsv(&PL_sv_undef);
      }
    }
  OUTPUT:
    RETVAL

SV *
field_frame_resolved_value_xs(frame)
    SV *frame
  CODE:
    {
      gql_runtime_vm_field_frame_t *state = gql_runtime_vm_expect_field_frame(aTHX_ frame);
      RETVAL = newSVsv(state->resolved_value ? state->resolved_value : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
field_frame_outcome_xs(frame)
    SV *frame
  CODE:
    {
      gql_runtime_vm_field_frame_t *state = gql_runtime_vm_expect_field_frame(aTHX_ frame);
      RETVAL = gql_runtime_vm_wrap_outcome_sv(aTHX_ state->outcome);
    }
  OUTPUT:
    RETVAL

SV *
path_frame_new_xs(class, parent = &PL_sv_undef, key = &PL_sv_undef)
    SV *class
    SV *parent
    SV *key
  CODE:
    {
      RETVAL = gql_runtime_vm_new_path_frame_handle(aTHX_ parent, key);
    }
  OUTPUT:
    RETVAL

SV *
path_frame_materialize_path_xs(path_frame)
    SV *path_frame
  CODE:
    {
      gql_runtime_vm_path_frame_t *frame = gql_runtime_vm_expect_path_frame(aTHX_ path_frame);
      RETVAL = gql_runtime_vm_path_frame_to_path_sv(aTHX_ frame);
    }
  OUTPUT:
    RETVAL

SV *
path_frame_parent_xs(path_frame)
    SV *path_frame
  CODE:
    {
      gql_runtime_vm_path_frame_t *state = gql_runtime_vm_expect_path_frame(aTHX_ path_frame);
      if (state->parent) {
        state->parent->refcount++;
        RETVAL = gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::PathFrame", state->parent);
      } else {
        RETVAL = newSVsv(&PL_sv_undef);
      }
    }
  OUTPUT:
    RETVAL

SV *
path_frame_key_xs(path_frame)
    SV *path_frame
  CODE:
    {
      gql_runtime_vm_path_frame_t *state = gql_runtime_vm_expect_path_frame(aTHX_ path_frame);
      RETVAL = gql_runtime_vm_path_frame_key_sv(aTHX_ state);
    }
  OUTPUT:
    RETVAL

SV *
lazy_info_hashref_xs(info_sv)
    SV *info_sv
  CODE:
    {
      gql_runtime_vm_lazy_info_t *info;

      if (!info_sv || !SvROK(info_sv) || !sv_derived_from(info_sv, "GraphQL::Houtou::Runtime::LazyInfo")) {
        croak("expected a GraphQL::Houtou::Runtime::LazyInfo");
      }
      info = INT2PTR(gql_runtime_vm_lazy_info_t *, SvUV(SvRV(info_sv)));
      if (!info) {
        croak("lazy info handle is no longer valid");
      }
      RETVAL = gql_runtime_vm_lazy_info_materialize_hash_sv(aTHX_ info);
    }
  OUTPUT:
    RETVAL

SV *
block_frame_new_xs(class, values = &PL_sv_undef, pending_names = &PL_sv_undef, pending_outcomes = &PL_sv_undef)
    SV *class
    SV *values
    SV *pending_names
    SV *pending_outcomes
  CODE:
    {
      gql_runtime_vm_block_frame_t *frame;
      const char *pkg = SvPV_nolen(class);
      frame = gql_runtime_vm_new_block_frame_struct(aTHX);
      if (values && SvOK(values) && SvROK(values) && SvTYPE(SvRV(values)) == SVt_PVHV) {
        gql_runtime_vm_native_value_destroy(aTHX_ frame->values_value);
        frame->values_value = gql_runtime_vm_native_value_from_sv(aTHX_ values);
      }
      if (pending_names && SvOK(pending_names) && SvROK(pending_names) && SvTYPE(SvRV(pending_names)) == SVt_PVAV &&
          pending_outcomes && SvOK(pending_outcomes) && SvROK(pending_outcomes) && SvTYPE(SvRV(pending_outcomes)) == SVt_PVAV) {
        AV *names_av = (AV *)SvRV(pending_names);
        AV *outcomes_av = (AV *)SvRV(pending_outcomes);
        SSize_t i;
        for (i = 0; i <= av_len(names_av); i++) {
          SV **name_svp = av_fetch(names_av, i, 0);
          SV **outcome_svp = av_fetch(outcomes_av, i, 0);
          if (name_svp && *name_svp && outcome_svp && *outcome_svp && SvOK(*outcome_svp)) {
            gql_runtime_vm_block_frame_push_pending(aTHX_ frame, *name_svp, *outcome_svp);
          }
        }
      }
      RETVAL = gql_runtime_vm_new_handle_sv(aTHX_ pkg, frame);
    }
  OUTPUT:
    RETVAL

void
block_frame_add_pending_xs(frame, result_name, outcome)
    SV *frame
    SV *result_name
    SV *outcome
  PPCODE:
    {
      gql_runtime_vm_block_frame_t *state = gql_runtime_vm_expect_block_frame(aTHX_ frame);
      gql_runtime_vm_block_frame_push_pending(aTHX_ state, result_name, outcome);
    }

void
block_frame_consume_outcome_xs(frame, writer, result_name, outcome)
    SV *frame
    SV *writer
    SV *result_name
    SV *outcome
  CODE:
    {
      gql_runtime_vm_block_frame_t *state = gql_runtime_vm_expect_block_frame(aTHX_ frame);
      gql_runtime_vm_writer_t *writer_state;
      STRLEN result_name_len = 0;
      const char *result_name_pv = NULL;
      if (!outcome || !SvOK(outcome)) {
        XSRETURN_EMPTY;
      }
      writer_state = gql_runtime_vm_expect_writer(aTHX_ writer);
      result_name_pv = (result_name && SvOK(result_name)) ? SvPV(result_name, result_name_len) : "";
      gql_runtime_vm_consume_outcome_native_object(
        aTHX_
        state->values_value,
        result_name_pv,
        gql_runtime_vm_expect_outcome(aTHX_ outcome),
        writer_state
      );
    }

SV *
block_frame_values_xs(frame)
    SV *frame
  CODE:
    {
      gql_runtime_vm_block_frame_t *state = gql_runtime_vm_expect_block_frame(aTHX_ frame);
      RETVAL = gql_runtime_vm_native_value_materialize_sv(aTHX_ state->values_value);
    }
  OUTPUT:
    RETVAL

SV *
block_frame_finalize_xs(frame, promise_code, writer)
    SV *frame
    SV *promise_code
    SV *writer
  CODE:
    {
      gql_runtime_vm_block_frame_t *state = gql_runtime_vm_expect_block_frame(aTHX_ frame);
      gql_runtime_vm_writer_t *writer_state = gql_runtime_vm_expect_writer(aTHX_ writer);
      SV *promise_all_cb = gql_runtime_vm_promise_callback_from_code_sv(aTHX_ promise_code, "all", 3);
      SV *promise_then_cb = gql_runtime_vm_promise_callback_from_code_sv(aTHX_ promise_code, "then", 4);
      RETVAL = gql_runtime_vm_block_frame_finalize_sv(
        aTHX_
        state,
        promise_all_cb,
        promise_then_cb,
        writer_state
      );
    }
  OUTPUT:
    RETVAL

IV
block_frame_has_pending_xs(frame)
    SV *frame
  CODE:
    {
      gql_runtime_vm_block_frame_t *state = gql_runtime_vm_expect_block_frame(aTHX_ frame);
      RETVAL = state->pending_count > 0 ? 1 : 0;
    }
  OUTPUT:
    RETVAL

SV *
block_frame_merge_pending_xs(frame, writer, resolved)
    SV *frame
    SV *writer
    SV *resolved
  CODE:
    {
      gql_runtime_vm_block_frame_t *state = gql_runtime_vm_expect_block_frame(aTHX_ frame);
      gql_runtime_vm_writer_t *writer_state = gql_runtime_vm_expect_writer(aTHX_ writer);
      AV *resolved_av = gql_runtime_vm_expect_arrayref(aTHX_ resolved, "resolved outcomes");
      HV *merged_hv = newHV();
      SSize_t i;
      SV *base_sv = gql_runtime_vm_native_value_materialize_sv(aTHX_ state->values_value);
      HV *base_hv = (base_sv && SvROK(base_sv) && SvTYPE(SvRV(base_sv)) == SVt_PVHV) ? (HV *)SvRV(base_sv) : NULL;
      HE *he;
      if (base_hv) {
        hv_iterinit(base_hv);
        while ((he = hv_iternext(base_hv))) {
          SV *key_sv = hv_iterkeysv(he);
          SV *val_sv = hv_iterval(base_hv, he);
          hv_store_ent(merged_hv, key_sv, val_sv ? newSVsv(val_sv) : newSV(0), 0);
        }
      }
      SvREFCNT_dec(base_sv);

      for (i = 0; i <= av_len(resolved_av) && i < state->pending_count; i++) {
        SV **outcome_svp = av_fetch(resolved_av, i, 0);
        if (outcome_svp && *outcome_svp) {
          SV *result_name_sv = newSVpvn(
            state->pending_entries[i].result_name_pv,
            state->pending_entries[i].result_name_len
          );
          gql_runtime_vm_consume_outcome_struct(
            aTHX_
            merged_hv,
            result_name_sv,
            gql_runtime_vm_expect_outcome(aTHX_ *outcome_svp),
            writer_state
          );
          SvREFCNT_dec(result_name_sv);
        }
      }

      RETVAL = newRV_noinc((SV *)merged_hv);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_new_xs(class, runtime_schema, program, cursor, writer, context = &PL_sv_undef, variables = &PL_sv_undef, root_value = &PL_sv_undef, promise_code = &PL_sv_undef, empty_args = &PL_sv_undef)
    SV *class
    SV *runtime_schema
    SV *program
    SV *cursor
    SV *writer
    SV *context
    SV *variables
    SV *root_value
    SV *promise_code
    SV *empty_args
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *state;
      SV *promise_then_cb;
      SV *promise_all_cb;
      SV *promise_is_promise_cb;
      const char *pkg = SvPV_nolen(class);
      Newxz(state, 1, gql_runtime_vm_exec_state_handle_t);
      state->runtime_schema = newSVsv(runtime_schema ? runtime_schema : &PL_sv_undef);
      state->program = newSVsv(program ? program : &PL_sv_undef);
      state->native_runtime = NULL;
      state->cursor = (cursor && SvOK(cursor)) ? gql_runtime_vm_expect_cursor(aTHX_ cursor) : NULL;
      gql_runtime_vm_cursor_incref(state->cursor);
      state->native_program = state->cursor ? state->cursor->native_program : NULL;
      state->frame = NULL;
      state->frame_stack_count = 0;
      state->frame_stack_capacity = 0;
      state->frame_stack = NULL;
      state->field_frame = NULL;
      state->writer = (writer && SvOK(writer)) ? gql_runtime_vm_expect_writer(aTHX_ writer) : NULL;
      gql_runtime_vm_writer_incref(state->writer);
      state->context = newSVsv(context ? context : &PL_sv_undef);
      state->variables = newSVsv(variables ? variables : &PL_sv_undef);
      state->root_value = newSVsv(root_value ? root_value : &PL_sv_undef);
      state->promise_code = newSVsv(promise_code ? promise_code : &PL_sv_undef);
      promise_then_cb = gql_runtime_vm_promise_callback_from_code_sv(aTHX_ promise_code, "then", 4);
      promise_all_cb = gql_runtime_vm_promise_callback_from_code_sv(aTHX_ promise_code, "all", 3);
      promise_is_promise_cb = gql_runtime_vm_promise_callback_from_code_sv(aTHX_ promise_code, "is_promise", 10);
      state->promise_then_cb = newSVsv(promise_then_cb ? promise_then_cb : &PL_sv_undef);
      state->promise_all_cb = newSVsv(promise_all_cb ? promise_all_cb : &PL_sv_undef);
      state->promise_is_promise_cb = newSVsv(promise_is_promise_cb ? promise_is_promise_cb : &PL_sv_undef);
      state->empty_args = newSVsv(empty_args ? empty_args : &PL_sv_undef);
      RETVAL = gql_runtime_vm_new_handle_sv(aTHX_ pkg, state);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_execute_block_async_xs(state, block_index, source = &PL_sv_undef, base_path = &PL_sv_undef)
    SV *state
    IV block_index
    SV *source
    SV *base_path
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = gql_runtime_vm_exec_state_execute_block_async_sv(aTHX_ state, s, block_index, source, base_path);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_run_program_xs(state, root_value = &PL_sv_undef)
    SV *state
    SV *root_value
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      SV *effective_root = root_value;
      SV *data_sv;
      IV root_block_index = -1;
      SV *root_block_sv;

      if (!s->cursor || !s->cursor->native_program) {
        croak("exec state cursor must hold a native program");
      }
      root_block_index = s->cursor->native_program->root_block_index;
      if (!effective_root || !SvOK(effective_root)) {
        effective_root = s->root_value;
      }
      root_block_sv = sv_2mortal(newSViv(root_block_index));

      data_sv = gql_runtime_vm_exec_state_execute_block_sync_sv(
        aTHX_
        state,
        s,
        root_block_sv,
        root_block_index,
        effective_root,
        &PL_sv_undef
      );
      RETVAL = gql_runtime_vm_exec_state_materialize_response_sv(aTHX_ s, data_sv);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_run_program_async_xs(state, root_value = &PL_sv_undef)
    SV *state
    SV *root_value
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      SV *effective_root = root_value;
      SV *data_sv;
      IV root_block_index = -1;

      if (!s->cursor || !s->cursor->native_program) {
        croak("exec state cursor must hold a native program");
      }
      root_block_index = s->cursor->native_program->root_block_index;
      if (!effective_root || !SvOK(effective_root)) {
        effective_root = s->root_value;
      }

      data_sv = gql_runtime_vm_exec_state_execute_block_async_sv(
        aTHX_
        state,
        s,
        root_block_index,
        effective_root,
        &PL_sv_undef
      );
      RETVAL = gql_runtime_vm_exec_state_finalize_async_response_sv(aTHX_ state, s, data_sv);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_materialize_response_xs(state, data = &PL_sv_undef)
    SV *state
    SV *data
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = gql_runtime_vm_exec_state_materialize_response_sv(aTHX_ s, data);
    }
  OUTPUT:
    RETVAL

SV *
execute_native_bundle_xs(runtime_schema, bundle_sv, root_value = &PL_sv_undef, context_value = &PL_sv_undef, variables = &PL_sv_undef)
    SV *runtime_schema
    SV *bundle_sv
    SV *root_value
    SV *context_value
    SV *variables
  CODE:
    {
      gql_runtime_vm_native_bundle_t *bundle;
      gql_runtime_vm_native_runtime_t *runtime = NULL;
      gql_runtime_vm_exec_state_t state;
      gql_runtime_vm_callback_context_t callback_ctx;
      int owns_runtime = 0;
      HV *hv;
      SV *data_sv;
      SV *errors_sv;
      gql_runtime_vm_writer_t *writer;

      if (!bundle_sv || !SvROK(bundle_sv) || !sv_derived_from(bundle_sv, "GraphQL::Houtou::Runtime::NativeBundle")) {
        croak("expected a GraphQL::Houtou::Runtime::NativeBundle");
      }
      bundle = INT2PTR(gql_runtime_vm_native_bundle_t *, SvUV(SvRV(bundle_sv)));
      if (!bundle) {
        croak("native VM bundle handle is no longer valid");
      }

      if (runtime_schema && SvROK(runtime_schema) && sv_derived_from(runtime_schema, "GraphQL::Houtou::Runtime::NativeRuntime")) {
        runtime = INT2PTR(gql_runtime_vm_native_runtime_t *, SvUV(SvRV(runtime_schema)));
        if (!runtime) {
          croak("native VM runtime handle is no longer valid");
        }
      } else {
        runtime = gql_runtime_vm_native_runtime_from_runtime_schema_sv(aTHX_ runtime_schema);
        owns_runtime = 1;
      }

      Zero(&state, 1, gql_runtime_vm_exec_state_t);
      Zero(&callback_ctx, 1, gql_runtime_vm_callback_context_t);
      state.runtime = runtime;
      state.bundle = bundle;
      callback_ctx.runtime_schema = (runtime_schema && !sv_derived_from(runtime_schema, "GraphQL::Houtou::Runtime::NativeRuntime"))
        ? runtime_schema
        : (runtime && runtime->callback_catalog && runtime->callback_catalog->runtime_schema ? runtime->callback_catalog->runtime_schema : &PL_sv_undef);
      gql_runtime_vm_prepare_bundle_block_type_objects(
        aTHX_
        callback_ctx.runtime_schema,
        bundle
      );
      callback_ctx.root_value = root_value;
      callback_ctx.context = context_value;
      callback_ctx.variables = variables;
      state.callback_ctx = &callback_ctx;
      writer = gql_runtime_vm_new_writer_struct(aTHX);
      state.writer = writer;
      state.path_frame = NULL;

      data_sv = gql_runtime_vm_execute_block_fast_sv(
        aTHX_
        &state,
        bundle->root_block_index,
        root_value
      );
      errors_sv = gql_runtime_vm_writer_materialize_errors_sv(aTHX_ writer);

      hv = newHV();
      hv_store(hv, "data", 4, data_sv, 0);
      hv_store(hv, "errors", 6, errors_sv, 0);
      RETVAL = newRV_noinc((SV *)hv);

      gql_runtime_vm_writer_decref(aTHX_ writer);
      if (owns_runtime) {
        gql_runtime_vm_native_runtime_destroy(runtime);
      }
    }
  OUTPUT:
    RETVAL

SV *
execute_native_program_xs(runtime_schema, runtime_descriptor, program_descriptor, root_value = &PL_sv_undef, context_value = &PL_sv_undef, variables = &PL_sv_undef)
    SV *runtime_schema
    SV *runtime_descriptor
    SV *program_descriptor
    SV *root_value
    SV *context_value
    SV *variables
  CODE:
    {
      gql_runtime_vm_native_bundle_t *bundle;
      gql_runtime_vm_native_runtime_t *runtime = NULL;
      gql_runtime_vm_exec_state_t state;
      gql_runtime_vm_callback_context_t callback_ctx;
      int owns_runtime = 0;
      HV *hv;
      SV *data_sv;
      SV *errors_sv;
      gql_runtime_vm_writer_t *writer;

      bundle = gql_runtime_vm_native_bundle_from_runtime_and_program_sv(
        aTHX_ runtime_descriptor, program_descriptor
      );

      if (runtime_schema && SvROK(runtime_schema) && sv_derived_from(runtime_schema, "GraphQL::Houtou::Runtime::NativeRuntime")) {
        runtime = INT2PTR(gql_runtime_vm_native_runtime_t *, SvUV(SvRV(runtime_schema)));
        if (!runtime) {
          gql_runtime_vm_native_bundle_destroy(bundle);
          croak("native VM runtime handle is no longer valid");
        }
      } else {
        runtime = gql_runtime_vm_native_runtime_from_runtime_schema_sv(aTHX_ runtime_schema);
        owns_runtime = 1;
      }

      Zero(&state, 1, gql_runtime_vm_exec_state_t);
      Zero(&callback_ctx, 1, gql_runtime_vm_callback_context_t);
      state.runtime = runtime;
      state.bundle = bundle;
      callback_ctx.runtime_schema = (runtime_schema && !sv_derived_from(runtime_schema, "GraphQL::Houtou::Runtime::NativeRuntime"))
        ? runtime_schema
        : (runtime && runtime->callback_catalog && runtime->callback_catalog->runtime_schema ? runtime->callback_catalog->runtime_schema : &PL_sv_undef);
      gql_runtime_vm_prepare_bundle_block_type_objects(
        aTHX_
        callback_ctx.runtime_schema,
        bundle
      );
      callback_ctx.root_value = root_value;
      callback_ctx.context = context_value;
      callback_ctx.variables = variables;
      state.callback_ctx = &callback_ctx;
      writer = gql_runtime_vm_new_writer_struct(aTHX);
      state.writer = writer;
      state.path_frame = NULL;

      data_sv = gql_runtime_vm_execute_block_fast_sv(
        aTHX_
        &state,
        bundle->root_block_index,
        root_value
      );
      errors_sv = gql_runtime_vm_writer_materialize_errors_sv(aTHX_ writer);

      hv = newHV();
      hv_store(hv, "data", 4, data_sv, 0);
      hv_store(hv, "errors", 6, errors_sv, 0);
      RETVAL = newRV_noinc((SV *)hv);

      gql_runtime_vm_writer_decref(aTHX_ writer);
      gql_runtime_vm_native_bundle_destroy(bundle);
      if (owns_runtime) {
        gql_runtime_vm_native_runtime_destroy(runtime);
      }
    }
  OUTPUT:
    RETVAL

SV *
execute_native_program_handle_xs(runtime_sv, program_sv, root_value = &PL_sv_undef, context_value = &PL_sv_undef, variables = &PL_sv_undef)
    SV *runtime_sv
    SV *program_sv
    SV *root_value
    SV *context_value
    SV *variables
  CODE:
    {
      gql_runtime_vm_native_runtime_t *runtime;
      gql_runtime_vm_native_program_t *program;
      gql_runtime_vm_native_bundle_t *bundle;
      gql_runtime_vm_exec_state_t state;
      gql_runtime_vm_callback_context_t callback_ctx;
      HV *hv;
      SV *data_sv;
      SV *errors_sv;
      gql_runtime_vm_writer_t *writer;

      if (!runtime_sv || !SvROK(runtime_sv) || !sv_derived_from(runtime_sv, "GraphQL::Houtou::Runtime::NativeRuntime")) {
        croak("expected a GraphQL::Houtou::Runtime::NativeRuntime");
      }
      runtime = INT2PTR(gql_runtime_vm_native_runtime_t *, SvUV(SvRV(runtime_sv)));
      if (!runtime) {
        croak("native VM runtime handle is no longer valid");
      }
      program = gql_runtime_vm_native_program_from_sv(aTHX_ program_sv);
      bundle = gql_runtime_vm_native_bundle_from_runtime_and_program_handles(runtime, program);

      Zero(&state, 1, gql_runtime_vm_exec_state_t);
      Zero(&callback_ctx, 1, gql_runtime_vm_callback_context_t);
      state.runtime = runtime;
      state.bundle = bundle;
      callback_ctx.runtime_schema = (runtime && runtime->callback_catalog && runtime->callback_catalog->runtime_schema) ? runtime->callback_catalog->runtime_schema : &PL_sv_undef;
      gql_runtime_vm_prepare_bundle_block_type_objects(
        aTHX_
        callback_ctx.runtime_schema,
        bundle
      );
      callback_ctx.root_value = root_value;
      callback_ctx.context = context_value;
      callback_ctx.variables = variables;
      state.callback_ctx = &callback_ctx;
      writer = gql_runtime_vm_new_writer_struct(aTHX);
      state.writer = writer;
      state.path_frame = NULL;

      data_sv = gql_runtime_vm_execute_block_fast_sv(
        aTHX_
        &state,
        bundle->root_block_index,
        root_value
      );
      errors_sv = gql_runtime_vm_writer_materialize_errors_sv(aTHX_ writer);

      hv = newHV();
      hv_store(hv, "data", 4, data_sv, 0);
      hv_store(hv, "errors", 6, errors_sv, 0);
      RETVAL = newRV_noinc((SV *)hv);

      gql_runtime_vm_writer_decref(aTHX_ writer);
      gql_runtime_vm_native_bundle_destroy(bundle);
    }
  OUTPUT:
    RETVAL

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::Cursor

void
DESTROY(self)
    SV *self
  CODE:
      if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_cursor_t *cursor = INT2PTR(gql_runtime_vm_cursor_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_cursor_decref(aTHX_ cursor);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::FieldFrame

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_field_frame_t *frame = INT2PTR(gql_runtime_vm_field_frame_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_free_field_frame(aTHX_ frame);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::LazyInfo

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_lazy_info_t *info = INT2PTR(gql_runtime_vm_lazy_info_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_lazy_info_decref(aTHX_ info);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::PathFrame

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_path_frame_t *frame = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_path_frame_decref(frame);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::BlockFrame

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_block_frame_t *frame = INT2PTR(gql_runtime_vm_block_frame_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_free_block_frame(aTHX_ frame);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::ErrorRecord

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_error_record_t *record = INT2PTR(gql_runtime_vm_error_record_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_error_record_decref(aTHX_ record);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::Outcome

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_outcome_t *outcome = INT2PTR(gql_runtime_vm_outcome_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_outcome_decref(aTHX_ outcome);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::Writer

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_writer_t *writer = INT2PTR(gql_runtime_vm_writer_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_writer_decref(aTHX_ writer);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::PendingMerge

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_pending_merge_t *merge = INT2PTR(gql_runtime_vm_pending_merge_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_pending_merge_decref(aTHX_ merge);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::ExecState

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_exec_state_handle_t *state = INT2PTR(gql_runtime_vm_exec_state_handle_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        SvREFCNT_dec(state->runtime_schema);
        SvREFCNT_dec(state->program);
        gql_runtime_vm_native_runtime_destroy(state->native_runtime);
        gql_runtime_vm_cursor_decref(aTHX_ state->cursor);
        if (state->frame && state->frame_stack_count == 0) {
          gql_runtime_vm_free_block_frame(aTHX_ state->frame);
        }
        while (state->frame_stack_count > 0) {
          gql_runtime_vm_free_block_frame(aTHX_ state->frame_stack[--state->frame_stack_count]);
          state->frame_stack[state->frame_stack_count] = NULL;
        }
        Safefree(state->frame_stack);
        state->frame = NULL;
        gql_runtime_vm_free_field_frame(aTHX_ state->field_frame);
        state->field_frame = NULL;
        gql_runtime_vm_writer_decref(aTHX_ state->writer);
        SvREFCNT_dec(state->context);
        SvREFCNT_dec(state->variables);
        SvREFCNT_dec(state->root_value);
        SvREFCNT_dec(state->promise_code);
        SvREFCNT_dec(state->promise_then_cb);
        SvREFCNT_dec(state->promise_all_cb);
        SvREFCNT_dec(state->promise_is_promise_cb);
        SvREFCNT_dec(state->empty_args);
        Safefree(state);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::NativeBundle

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_native_bundle_t *bundle =
          INT2PTR(gql_runtime_vm_native_bundle_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_native_bundle_destroy(bundle);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::NativeProgram

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_native_program_t *program =
          INT2PTR(gql_runtime_vm_native_program_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_native_program_destroy(program);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::Runtime::NativeRuntime

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_runtime_vm_native_runtime_t *runtime =
          INT2PTR(gql_runtime_vm_native_runtime_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_runtime_vm_native_runtime_destroy(runtime);
      }
    }
