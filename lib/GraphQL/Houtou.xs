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

typedef struct {
  UV refcount;
  gql_runtime_vm_block_frame_t *frame;
  gql_runtime_vm_writer_t *writer;
} gql_runtime_vm_pending_merge_t;

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
  SvREFCNT_dec(cursor->block);
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
  SV *op_sv;
  SV *result_name_sv;
  gql_runtime_vm_path_frame_t *path_frame = NULL;
  gql_runtime_vm_field_frame_t *field_frame;

  if (!s || !s->cursor) {
    return;
  }

  op_sv = gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ s->cursor);
  result_name_sv = gql_runtime_vm_op_result_name_sv(aTHX_ op_sv);
  path_frame = gql_runtime_vm_new_path_frame_struct(
    aTHX_
    (base_path && SvOK(base_path) && SvROK(base_path) && SvIOK(SvRV(base_path)) && SvUV(SvRV(base_path)) != 0)
      ? INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(base_path)))
      : NULL,
    result_name_sv ? result_name_sv : &PL_sv_undef
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
  SV *op_sv;
  SV *result_name_sv;
  STRLEN result_name_len = 0;
  const char *result_name_pv = NULL;

  if (!s || !outcome || !s->frame || !s->writer) {
    gql_runtime_vm_leave_field_now(aTHX_ s);
    return;
  }

  frame = s->frame;
  writer = s->writer;
  op_sv = s->cursor ? gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ s->cursor) : NULL;
  result_name_sv = gql_runtime_vm_op_result_name_sv(aTHX_ op_sv);
  if (result_name_sv && SvOK(result_name_sv)) {
    result_name_pv = SvPV(result_name_sv, result_name_len);
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
  SV *op_sv;
  SV *result_name_sv;

  if (!s) {
    return;
  }

  if (result_sv && sv_derived_from(result_sv, "GraphQL::Houtou::Runtime::Outcome")) {
    gql_runtime_vm_consume_current_outcome_now(aTHX_ s, gql_runtime_vm_expect_outcome(aTHX_ result_sv));
    return;
  }

  frame = s->frame;
  op_sv = s->cursor ? gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ s->cursor) : NULL;
  result_name_sv = gql_runtime_vm_op_result_name_sv(aTHX_ op_sv);
  if (frame && result_name_sv && SvOK(result_name_sv) && result_sv && SvOK(result_sv)) {
    gql_runtime_vm_block_frame_push_pending(aTHX_ frame, result_name_sv, result_sv);
  }
  gql_runtime_vm_leave_field_now(aTHX_ s);
}

static SV *
gql_runtime_vm_block_frame_finalize_sv(pTHX_ gql_runtime_vm_block_frame_t *frame, SV *promise_code, gql_runtime_vm_writer_t *writer);

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
    result = gql_runtime_vm_block_frame_finalize_sv(aTHX_ frame, s->promise_code, s->writer);
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
gql_runtime_vm_block_frame_finalize_sv(pTHX_ gql_runtime_vm_block_frame_t *frame, SV *promise_code, gql_runtime_vm_writer_t *writer)
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
  XPUSHs(sv_2mortal(newSVsv(promise_code ? promise_code : &PL_sv_undef)));
  for (i = 0; i <= av_len(pending_av); i++) {
    SV **svp = av_fetch(pending_av, i, 0);
    if (svp && *svp) {
      XPUSHs(*svp);
    }
  }
  PUTBACK;
  call_pv("GraphQL::Houtou::Promise::Adapter::all_promise", G_SCALAR);
  SPAGAIN;
  {
    SV *aggregate = POPs;
    gql_runtime_vm_pending_merge_t *merge;
    SV *merge_sv;
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
    merge_sv = gql_runtime_vm_wrap_pending_merge_sv(aTHX_ merge);
    gql_runtime_vm_pending_merge_decref(aTHX_ merge);

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVsv(merge_sv)));
    PUTBACK;
    call_pv("GraphQL::Houtou::Runtime::BlockFrame::_xs_finalize_callback", G_SCALAR);
    SPAGAIN;
    callback_sv = POPs;
    SvREFCNT_inc(callback_sv);
    PUTBACK;
    FREETMPS;
    LEAVE;
    SvREFCNT_dec(merge_sv);

    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVsv(promise_code ? promise_code : &PL_sv_undef)));
    XPUSHs(sv_2mortal(newSVsv(aggregate)));
    XPUSHs(sv_2mortal(newSVsv(callback_sv)));
    PUTBACK;
    call_pv("GraphQL::Houtou::Promise::Adapter::then_promise", G_SCALAR);
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

static const char *
gql_runtime_vm_fetch_hash_entry_pv(pTHX_ HV *hv, const char *key, I32 keylen)
{
  SV *sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ hv, key, keylen);
  return sv ? SvPV_nolen(sv) : NULL;
}

static SV *gql_runtime_vm_exec_state_execute_block_sync_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s, SV *block, SV *source, SV *base_path);
static gql_runtime_vm_outcome_t *gql_runtime_vm_exec_state_execute_current_op_sync_now(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s);
static SV *gql_runtime_vm_state_type_by_name_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *type_name_sv);

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
  SV *type_name_sv;

  type_name_sv = gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 8);
  if (!type_name_sv || !SvOK(type_name_sv)) {
    return NULL;
  }

  return gql_runtime_vm_state_type_by_name_sv(aTHX_ s, type_name_sv);
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

static SV *
gql_runtime_vm_state_current_field_name_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s)
{
  SV *op_sv;
  SV *slot_sv;
  SV *field_name_sv;

  if (!s || !s->cursor) {
    return NULL;
  }

  op_sv = gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ s->cursor);
  if (op_sv && SvOK(op_sv) && SvROK(op_sv) && SvTYPE(SvRV(op_sv)) == SVt_PVAV) {
    field_name_sv = gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 6);
    if (field_name_sv && SvOK(field_name_sv)) {
      return field_name_sv;
    }
  }

  slot_sv = gql_runtime_vm_cursor_current_slot_borrowed_sv(aTHX_ s->cursor);
  if (slot_sv && SvOK(slot_sv) && SvROK(slot_sv) && SvTYPE(SvRV(slot_sv)) == SVt_PVHV) {
    field_name_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ (HV *)SvRV(slot_sv), "field_name", 10);
    if (field_name_sv && SvOK(field_name_sv)) {
      return field_name_sv;
    }
  }

  return NULL;
}

static SV *
gql_runtime_vm_state_current_parent_type_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s)
{
  SV *block_sv;
  AV *block_av;
  SV **type_name_svp;

  if (!s || !s->cursor) {
    return NULL;
  }

  block_sv = s->cursor->block;
  if (!block_sv || !SvOK(block_sv) || !SvROK(block_sv) || SvTYPE(SvRV(block_sv)) != SVt_PVAV) {
    return NULL;
  }
  block_av = (AV *)SvRV(block_sv);
  type_name_svp = av_fetch(block_av, 1, 0);
  if (type_name_svp && *type_name_svp && SvOK(*type_name_svp)) {
    return gql_runtime_vm_state_type_by_name_sv(aTHX_ s, *type_name_svp);
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
gql_runtime_vm_call_state_method_scalar(pTHX_ SV *state_sv, const char *method)
{
  dSP;
  SV *result = NULL;
  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(state_sv ? state_sv : &PL_sv_undef)));
  PUTBACK;
  if (call_method(method, G_SCALAR | G_EVAL) > 0) {
    SPAGAIN;
    result = (SP > PL_stack_base) ? POPs : NULL;
    result = result ? newSVsv(result) : newSVsv(&PL_sv_undef);
    PUTBACK;
  }
  if (SvTRUE(ERRSV)) {
    sv_setsv(ERRSV, &PL_sv_undef);
    result = newSVsv(&PL_sv_undef);
  }
  FREETMPS;
  LEAVE;
  return result ? result : newSVsv(&PL_sv_undef);
}

static SV *
gql_runtime_vm_new_lazy_info_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s, SV *path_frame)
{
  dSP;
  SV *instruction_sv = s && s->cursor
    ? gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ s->cursor)
    : &PL_sv_undef;
  SV *block_sv = s && s->cursor
    ? s->cursor->block
    : &PL_sv_undef;
  SV *field_name_sv = s ? gql_runtime_vm_state_current_field_name_sv(aTHX_ s) : &PL_sv_undef;
  SV *parent_type_sv = s ? gql_runtime_vm_state_current_parent_type_sv(aTHX_ s) : &PL_sv_undef;
  SV *return_type_sv = s
    ? gql_runtime_vm_state_current_return_type_sv(aTHX_ s, instruction_sv, s && s->cursor ? gql_runtime_vm_cursor_current_slot_borrowed_sv(aTHX_ s->cursor) : NULL)
    : &PL_sv_undef;
  SV *path_sv = NULL;
  SV *path_value_sv = NULL;
  gql_runtime_vm_path_frame_t *path_ptr = NULL;
  SV *ret = NULL;

  if (path_frame && SvOK(path_frame) && SvROK(path_frame) && SvIOK(SvRV(path_frame)) && SvUV(SvRV(path_frame)) != 0) {
    path_ptr = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(path_frame)));
  } else if (s && s->field_frame) {
    path_ptr = s->field_frame->path_frame;
  }
  if (path_ptr) {
    path_ptr->refcount++;
    path_sv = gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::PathFrame", path_ptr);
    path_value_sv = gql_runtime_vm_path_frame_to_path_sv(aTHX_ path_ptr);
  } else {
    path_sv = newSVsv(&PL_sv_undef);
    path_value_sv = newSVsv(&PL_sv_undef);
  }

  if ((!parent_type_sv || !SvOK(parent_type_sv))
      && block_sv && SvOK(block_sv)) {
    dSP;
    SV *block_type_name_sv = NULL;
    ENTER;
    SAVETMPS;
    PUSHMARK(SP);
    XPUSHs(sv_2mortal(newSVsv(block_sv)));
    PUTBACK;
    if (call_method("type_name", G_SCALAR | G_EVAL) > 0) {
      SPAGAIN;
      block_type_name_sv = (SP > PL_stack_base) ? POPs : NULL;
      if (block_type_name_sv && SvOK(block_type_name_sv)) {
        parent_type_sv = gql_runtime_vm_state_type_by_name_sv(aTHX_ s, block_type_name_sv);
      }
      PUTBACK;
    }
    if (SvTRUE(ERRSV)) {
      sv_setsv(ERRSV, &PL_sv_undef);
    }
    FREETMPS;
    LEAVE;
  }

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVpv("GraphQL::Houtou::Runtime::LazyInfo", 0)));
  XPUSHs(sv_2mortal(newSVpv("state", 0)));
  XPUSHs(sv_2mortal(newSVsv(state_sv ? state_sv : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVpv("runtime_schema", 0)));
  XPUSHs(sv_2mortal(newSVsv(s && s->runtime_schema ? s->runtime_schema : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVpv("block", 0)));
  XPUSHs(sv_2mortal(newSVsv(block_sv ? block_sv : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVpv("instruction", 0)));
  XPUSHs(sv_2mortal(newSVsv(instruction_sv ? instruction_sv : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVpv("path_frame", 0)));
  XPUSHs(sv_2mortal(newSVsv(path_sv)));
  XPUSHs(sv_2mortal(newSVpv("field_name", 0)));
  XPUSHs(sv_2mortal(newSVsv(field_name_sv ? field_name_sv : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVpv("parent_type", 0)));
  XPUSHs(sv_2mortal(newSVsv(parent_type_sv ? parent_type_sv : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVpv("return_type", 0)));
  XPUSHs(sv_2mortal(newSVsv(return_type_sv ? return_type_sv : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVpv("path", 0)));
  XPUSHs(sv_2mortal(newSVsv(path_value_sv ? path_value_sv : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVpv("context_value", 0)));
  XPUSHs(sv_2mortal(newSVsv(s && s->context ? s->context : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVpv("root_value", 0)));
  XPUSHs(sv_2mortal(newSVsv(s && s->root_value ? s->root_value : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVpv("variable_values", 0)));
  XPUSHs(sv_2mortal(newSVsv(s && s->variables ? s->variables : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVpv("operation", 0)));
  XPUSHs(sv_2mortal(newSVsv(s && s->program ? s->program : &PL_sv_undef)));
  PUTBACK;
  if (call_method("new", G_SCALAR | G_EVAL) > 0) {
    SPAGAIN;
    ret = (SP > PL_stack_base) ? POPs : NULL;
    ret = ret ? newSVsv(ret) : newSVsv(&PL_sv_undef);
    PUTBACK;
  }
  if (SvTRUE(ERRSV)) {
    sv_setsv(ERRSV, &PL_sv_undef);
    ret = newSVsv(&PL_sv_undef);
  }
  FREETMPS;
  LEAVE;
  SvREFCNT_dec(path_sv);
  SvREFCNT_dec(path_value_sv);

  return ret ? ret : newSVsv(&PL_sv_undef);
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
gql_runtime_vm_current_child_block_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *op_sv)
{
  SV *child_sv = gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 20);
  if (child_sv && SvOK(child_sv)) {
    return child_sv;
  }
  return NULL;
}

static SV *
gql_runtime_vm_current_abstract_child_block_sv(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *op_sv, SV *runtime_type_sv)
{
  dSP;
  SV *bound_map_sv = gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 21);
  HV *bound_map_hv;
  SV *name_sv;
  HE *he;

  if (!runtime_type_sv || !SvOK(runtime_type_sv)) {
    return NULL;
  }
  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(runtime_type_sv)));
  PUTBACK;
  if (call_method("name", G_SCALAR | G_EVAL) > 0) {
    SPAGAIN;
    name_sv = (SP > PL_stack_base) ? POPs : NULL;
    name_sv = name_sv ? newSVsv(name_sv) : NULL;
    PUTBACK;
  } else {
    name_sv = NULL;
  }
  if (SvTRUE(ERRSV)) {
    sv_setsv(ERRSV, &PL_sv_undef);
    name_sv = NULL;
  }
  FREETMPS;
  LEAVE;

  if (!name_sv) {
    return NULL;
  }

  if (bound_map_sv && SvOK(bound_map_sv) && SvROK(bound_map_sv) && SvTYPE(SvRV(bound_map_sv)) == SVt_PVHV) {
    bound_map_hv = (HV *)SvRV(bound_map_sv);
    he = hv_fetch_ent(bound_map_hv, name_sv, 0, 0);
    if (he && HeVAL(he) && SvOK(HeVAL(he))) {
      SvREFCNT_dec(name_sv);
      return HeVAL(he);
    }
  }

  SvREFCNT_dec(name_sv);
  return NULL;
}

static SV *
gql_runtime_vm_fetch_runtime_slot_sv(pTHX_ SV *runtime_schema, IV schema_slot_index)
{
  HV *schema_hv;
  SV *catalog_sv;
  AV *catalog_av;
  SV **slot_svp;

  schema_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_schema, "runtime schema");
  catalog_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_catalog_exec", 17);
  if (!catalog_sv) {
    catalog_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_catalog", 12);
  }
  if (!catalog_sv) {
    croak("runtime schema is missing slot_catalog");
  }
  catalog_av = gql_runtime_vm_expect_arrayref(aTHX_ catalog_sv, "runtime schema slot_catalog");
  slot_svp = av_fetch(catalog_av, schema_slot_index, 0);
  if (!slot_svp || !SvOK(*slot_svp)) {
    croak("runtime schema slot_catalog entry %ld is missing", (long)schema_slot_index);
  }
  return *slot_svp;
}

static SV *
gql_runtime_vm_state_resolve_args_sv(pTHX_ SV *state_sv)
{
  return gql_runtime_vm_call_state_method_scalar(aTHX_ state_sv, "resolve_args_for_current_field");
}

static int
gql_runtime_vm_should_execute_op_now(pTHX_ gql_runtime_vm_exec_state_handle_t *s, SV *op_sv)
{
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
  XPUSHs(sv_2mortal(newSVsv(source_sv ? source_sv : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(args_sv ? args_sv : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(context_sv ? context_sv : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(info_sv ? info_sv : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(return_type_sv ? return_type_sv : &PL_sv_undef)));
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
gql_runtime_vm_exec_state_execute_block_sync_sv(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s, SV *block, SV *source, SV *base_path)
{
  gql_runtime_vm_cursor_t snapshot;
  gql_runtime_vm_field_frame_t *saved_field_frame;
  gql_runtime_vm_path_frame_t *base_path_ptr = NULL;

  Zero(&snapshot, 1, gql_runtime_vm_cursor_t);
  if (base_path && SvOK(base_path) && SvROK(base_path) && SvIOK(SvRV(base_path)) && SvUV(SvRV(base_path)) != 0) {
    base_path_ptr = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(base_path)));
  }
  saved_field_frame = s ? s->field_frame : NULL;
  gql_runtime_vm_cursor_snapshot_copy(aTHX_ &snapshot, (s && s->cursor) ? s->cursor : NULL);
  if (s->cursor) {
    gql_runtime_vm_cursor_t *dst = s->cursor;
    SvREFCNT_dec(dst->block);
    dst->block = newSVsv(block ? block : &PL_sv_undef);
    dst->slot_index = 0;
    dst->op_index = -1;
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
    AV *ops_av;
    IV next_index;
    SV *op_sv;
    gql_runtime_vm_outcome_t *outcome;

    if (!s->cursor) {
      break;
    }
    dst = s->cursor;
    ops_av = gql_runtime_vm_cursor_ops_av(aTHX_ dst);
    if (!ops_av) {
      break;
    }
    next_index = dst->op_index + 1;
    if (next_index > av_len(ops_av)) {
      dst->op_index = next_index;
      break;
    }
    dst->op_index = next_index;
    op_sv = gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ dst);

    if (!gql_runtime_vm_should_execute_op_now(aTHX_ s, op_sv)) {
      continue;
    }

    {
      gql_runtime_vm_path_frame_t *path_frame = gql_runtime_vm_new_path_frame_struct(
        aTHX_
        base_path_ptr,
        gql_runtime_vm_op_result_name_sv(aTHX_ op_sv)
      );
      gql_runtime_vm_field_frame_t *field_frame = gql_runtime_vm_new_field_frame_struct(aTHX_ source, path_frame);
      gql_runtime_vm_path_frame_decref(path_frame);
      gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
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

static gql_runtime_vm_outcome_t *
gql_runtime_vm_exec_state_execute_current_op_sync_now(pTHX_ SV *state_sv, gql_runtime_vm_exec_state_handle_t *s)
{
  SV *op_sv;
  SV *slot_sv;
  SV *source_sv;
  SV *resolved_sv = NULL;
  SV *error_sv = NULL;
  IV resolve_code;
  IV complete_code;

  if (!s || !s->cursor || !s->field_frame) {
    return gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, &PL_sv_undef, &PL_sv_undef);
  }

  op_sv = gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ s->cursor);
  slot_sv = gql_runtime_vm_cursor_current_slot_borrowed_sv(aTHX_ s->cursor);
  source_sv = s->field_frame->source;
  resolve_code = gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 3) ? SvIV(gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 3)) : 0;
  complete_code = gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 5) ? SvIV(gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 5)) : 0;

  switch (resolve_code) {
    case GQL_VM_RESOLVE_DEFAULT:
    case GQL_VM_RESOLVE_EXPLICIT:
    {
      SV *field_name_sv = gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 6);
      const char *field_name = field_name_sv ? SvPV_nolen(field_name_sv) : "";
      SV *resolver_sv = gql_runtime_vm_fetch_object_hash_entry_sv(aTHX_ slot_sv, "resolve", 7);
      if (field_name && strEQ(field_name, "__typename")) {
        AV *block_av = gql_runtime_vm_expect_arrayref(aTHX_ s->cursor->block, "current block");
        SV **type_svp = av_fetch(block_av, 1, 0);
        resolved_sv = newSVsv((type_svp && *type_svp) ? *type_svp : &PL_sv_undef);
      } else if (resolver_sv && SvOK(resolver_sv)) {
        SV *args_sv = gql_runtime_vm_state_resolve_args_sv(aTHX_ state_sv);
        SV *info_sv = gql_runtime_vm_new_lazy_info_sv(aTHX_ state_sv, s, NULL);
        SV *return_type_sv = gql_runtime_vm_state_current_return_type_sv(aTHX_ s, op_sv, slot_sv);
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
      SV *child_block_sv;
      if (!resolved_sv || !SvOK(resolved_sv)) {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, &PL_sv_undef, &PL_sv_undef);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
      child_block_sv = gql_runtime_vm_current_child_block_sv(aTHX_ s, op_sv);
      if (!child_block_sv || !SvOK(child_block_sv)) {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv, &PL_sv_undef);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
      {
        SV *base_path_sv = gql_runtime_vm_wrap_path_frame_sv(aTHX_ s->field_frame->path_frame);
        SV *child_value = gql_runtime_vm_exec_state_execute_block_sync_sv(aTHX_ state_sv, s, child_block_sv, resolved_sv, base_path_sv);
        SvREFCNT_dec(base_path_sv);
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_OBJECT, child_value, &PL_sv_undef);
        SvREFCNT_dec(child_value);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
    }
    case GQL_VM_COMPLETE_LIST:
    {
      SV *child_block_sv;
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
      child_block_sv = gql_runtime_vm_current_child_block_sv(aTHX_ s, op_sv);
      items_av = (AV *)SvRV(resolved_sv);
      resolved_items_av = newAV();
      for (i = 0; i <= av_len(items_av); i++) {
        SV **item_svp = av_fetch(items_av, i, 0);
        SV *item_sv = (item_svp && *item_svp) ? *item_svp : &PL_sv_undef;
        if (child_block_sv && SvOK(child_block_sv)) {
          SV *item_key = newSViv(i);
          SV *base_path_sv = gql_runtime_vm_wrap_path_frame_sv(aTHX_ s->field_frame->path_frame);
          SV *item_path = gql_runtime_vm_new_path_frame_handle(aTHX_ base_path_sv, item_key);
          SV *child_value = gql_runtime_vm_exec_state_execute_block_sync_sv(aTHX_ state_sv, s, child_block_sv, item_sv, item_path);
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
      SV *dispatch_sv = gql_runtime_vm_op_slot_sv(aTHX_ op_sv, 22);
      SV *abstract_type_sv = gql_runtime_vm_state_current_return_type_sv(aTHX_ s, op_sv, slot_sv);
      SV *info_sv = gql_runtime_vm_new_lazy_info_sv(aTHX_ state_sv, s, NULL);
      SV *runtime_schema_sv = s->runtime_schema;
      HV *schema_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_schema_sv, "runtime schema");
      SV *runtime_cache_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "runtime_cache", 13);
      SV *runtime_error_sv = NULL;
      SV *runtime_type_sv;
      SV *child_block_sv;
      if (!resolved_sv || !SvOK(resolved_sv)) {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, &PL_sv_undef, &PL_sv_undef);
        SvREFCNT_dec(info_sv);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
      runtime_type_sv = gql_runtime_vm_resolve_runtime_type_sv(
        aTHX_ dispatch_sv, runtime_cache_sv, resolved_sv, s->context, info_sv, abstract_type_sv, &runtime_error_sv
      );
      SvREFCNT_dec(info_sv);
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
      child_block_sv = gql_runtime_vm_current_abstract_child_block_sv(aTHX_ s, op_sv, runtime_type_sv);
      SvREFCNT_dec(runtime_type_sv);
      if (!child_block_sv || !SvOK(child_block_sv)) {
        gql_runtime_vm_outcome_t *outcome = gql_runtime_vm_new_outcome_struct(aTHX_ GQL_VM_KIND_SCALAR, resolved_sv, &PL_sv_undef);
        SvREFCNT_dec(resolved_sv);
        return outcome;
      }
      {
        SV *base_path_sv = gql_runtime_vm_wrap_path_frame_sv(aTHX_ s->field_frame->path_frame);
        SV *child_value = gql_runtime_vm_exec_state_execute_block_sync_sv(aTHX_ state_sv, s, child_block_sv, resolved_sv, base_path_sv);
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

static const char *
gql_runtime_vm_type_name_from_sv(pTHX_ SV *type_sv);

static gql_runtime_vm_native_runtime_t *
gql_runtime_vm_native_runtime_from_runtime_schema_sv(pTHX_ SV *runtime_schema)
{
  gql_runtime_vm_native_runtime_t *runtime;
  HV *schema_hv;
  SV *catalog_sv;
  AV *catalog_av;
  SV *runtime_cache_sv;
  IV i;

  schema_hv = gql_runtime_vm_expect_hashref(aTHX_ runtime_schema, "runtime schema");
  catalog_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_catalog_exec", 17);
  if (!catalog_sv) {
    catalog_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_catalog", 12);
  }
  if (!catalog_sv) {
    croak("runtime schema is missing slot_catalog");
  }
  catalog_av = gql_runtime_vm_expect_arrayref(aTHX_ catalog_sv, "runtime schema slot_catalog");

  Newxz(runtime, 1, gql_runtime_vm_native_runtime_t);
  Newxz(runtime->callback_catalog, 1, gql_runtime_vm_native_callback_catalog_t);
  runtime->callback_catalog->runtime_schema = newSVsv(runtime_schema ? runtime_schema : &PL_sv_undef);
  runtime->runtime_slot_count = av_count(catalog_av);
  if (runtime->runtime_slot_count > 0) {
    Newxz(runtime->runtime_slots, runtime->runtime_slot_count, gql_runtime_vm_native_slot_t);
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
        gql_runtime_vm_native_runtime_destroy(runtime);
        croak("runtime schema slot_catalog entry %ld is missing", (long)i);
      }
      if (!gql_runtime_vm_parse_native_slot(aTHX_ *slot_svp, &runtime->runtime_slots[i])) {
        gql_runtime_vm_native_runtime_destroy(runtime);
        croak("runtime schema slot_catalog entry %ld is invalid", (long)i);
      }
      slot_hv = gql_runtime_vm_expect_hashref(aTHX_ *slot_svp, "runtime slot");
      resolver_sv = gql_runtime_vm_fetch_hash_entry_sv(aTHX_ slot_hv, "resolve", 7);
      if (resolver_sv) {
        runtime->callback_catalog->slot_resolvers[i] = newSVsv(resolver_sv);
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
          gql_runtime_vm_native_arg_def_t *arg_def = &slot->arg_defs[arg_index];
          if (arg_def->type_def_sv && !arg_def->input_type_sv) {
            arg_def->input_type_sv = gql_runtime_vm_lookup_input_type_by_typedef_sv(
              aTHX_ runtime_schema, arg_def->type_def_sv
            );
          }
          if (arg_def->has_default
              && arg_def->default_value_sv
              && arg_def->input_type_sv
              && !arg_def->default_native_value) {
            SV *raw_sv = newSVsv(arg_def->default_value_sv);
            SV *coerced_sv = gql_runtime_vm_coerce_input_value_sv(aTHX_ arg_def->input_type_sv, raw_sv);
            SvREFCNT_dec(raw_sv);
            arg_def->default_native_value = gql_runtime_vm_native_value_from_sv(aTHX_ coerced_sv);
            SvREFCNT_dec(coerced_sv);
          }
        }
      }
    }
  }

  return runtime;
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
  XPUSHs(sv_2mortal(newSVsv(arg0 ? arg0 : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(arg1 ? arg1 : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(arg2 ? arg2 : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(arg3 ? arg3 : &PL_sv_undef)));
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
  XPUSHs(sv_2mortal(newSVsv(arg0 ? arg0 : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(arg1 ? arg1 : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(arg2 ? arg2 : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(arg3 ? arg3 : &PL_sv_undef)));
  XPUSHs(sv_2mortal(newSVsv(arg4 ? arg4 : &PL_sv_undef)));
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
gql_runtime_vm_new_callback_info_sv(pTHX_ const gql_runtime_vm_exec_state_t *state)
{
  HV *info_hv;
  SV *field_name_sv;
  SV *return_type_lookup;
  SV *return_type_sv;
  SV *parent_type_sv;
  SV *path_sv;
  const gql_runtime_vm_callback_context_t *ctx = state ? state->callback_ctx : NULL;

  if (!state) {
    return newRV_noinc((SV *)newHV());
  }

  info_hv = newHV();
  field_name_sv = (state->slot && state->slot->field_name)
    ? newSVpv(state->slot->field_name, 0)
    : newSVsv(&PL_sv_undef);
  return_type_lookup = gql_runtime_vm_lookup_slot_type_object_sv(
    aTHX_
    state->runtime,
    ctx ? ctx->runtime_schema : &PL_sv_undef,
    state->slot
  );
  return_type_sv = newSVsv(return_type_lookup ? return_type_lookup : &PL_sv_undef);
  if (state->block && state->block->type_name) {
    SV *parent_type_lookup = gql_runtime_vm_lookup_type_object_by_name_sv(
      aTHX_ ctx ? ctx->runtime_schema : &PL_sv_undef,
      state->block->type_name
    );
    parent_type_sv = newSVsv(parent_type_lookup ? parent_type_lookup : &PL_sv_undef);
  } else {
    parent_type_sv = newSVsv(&PL_sv_undef);
  }
  path_sv = state->path_frame
    ? gql_runtime_vm_path_frame_to_path_sv(aTHX_ state->path_frame)
    : newSVsv(&PL_sv_undef);

  hv_store(info_hv, "field_name", 10, field_name_sv, 0);
  hv_store(info_hv, "field_nodes", 11, newSVsv(&PL_sv_undef), 0);
  hv_store(info_hv, "return_type", 11, return_type_sv, 0);
  hv_store(info_hv, "parent_type", 11, parent_type_sv, 0);
  hv_store(info_hv, "path", 4, path_sv, 0);
  hv_store(info_hv, "context_value", 13, newSVsv((ctx && ctx->context) ? ctx->context : &PL_sv_undef), 0);
  hv_store(info_hv, "root_value", 10, newSVsv((ctx && ctx->root_value) ? ctx->root_value : &PL_sv_undef), 0);
  hv_store(info_hv, "variable_values", 15, newSVsv((ctx && ctx->variables) ? ctx->variables : &PL_sv_undef), 0);
  hv_store(info_hv, "operation", 9, newSVsv((ctx && ctx->program) ? ctx->program : &PL_sv_undef), 0);
  hv_store(info_hv, "runtime_schema", 14, newSVsv((ctx && ctx->runtime_schema) ? ctx->runtime_schema : &PL_sv_undef), 0);

  return newRV_noinc((SV *)info_hv);
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
  return_type_sv = gql_runtime_vm_lookup_slot_type_object_sv(
    aTHX_ runtime, state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef, slot
  );

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

static gql_runtime_vm_native_value_t *gql_runtime_vm_execute_block_value(pTHX_ gql_runtime_vm_exec_state_t *state, IV block_index, SV *source);

static gql_runtime_vm_native_value_t *
gql_runtime_vm_complete_current_abstract(pTHX_ gql_runtime_vm_exec_state_t *state, SV *value, SV **error_out)
{
  IV child_block_index = -1;
  gql_runtime_vm_native_runtime_t *runtime = state->runtime;
  const gql_runtime_vm_native_slot_t *slot = state->slot;
  const gql_runtime_vm_native_op_t *op = state->op;
  IV slot_index;

  if (!runtime) {
    return gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
  }
  slot_index = slot->schema_slot_index;
  if (slot_index < 0 || slot_index >= runtime->runtime_slot_count) {
    return gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
  }
  if (op->dispatch_family_code == GQL_VM_DISPATCH_TAG) {
    SV *tag_resolver = (runtime->callback_catalog && runtime->callback_catalog->slot_tag_resolvers)
      ? runtime->callback_catalog->slot_tag_resolvers[slot_index]
      : NULL;
    SV *abstract_type = gql_runtime_vm_lookup_slot_type_object_sv(
      aTHX_ runtime, state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef, slot
    );
    SV *info_sv;
    SV *tag_sv;
    const char *type_name = NULL;
    if (tag_resolver
        && runtime->callback_catalog
        && runtime->callback_catalog->slot_tag_entries
        && runtime->callback_catalog->slot_tag_entry_counts[slot_index] > 0) {
      info_sv = sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state));
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
    SV *resolve_type = (runtime->callback_catalog && runtime->callback_catalog->slot_resolve_types)
      ? runtime->callback_catalog->slot_resolve_types[slot_index]
      : NULL;
    SV *abstract_type = gql_runtime_vm_lookup_slot_type_object_sv(
      aTHX_ runtime, state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef, slot
    );
    SV *info_sv;
    SV *type_sv;
    const char *type_name = NULL;
    if (!resolve_type) {
      return gql_runtime_vm_new_native_value_scalar(aTHX_ &PL_sv_undef);
    }
    info_sv = sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state));
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
    SV *info_sv = sv_2mortal(gql_runtime_vm_new_callback_info_sv(aTHX_ state));
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
  return_type_sv = gql_runtime_vm_lookup_slot_type_object_sv(
    aTHX_ runtime, state->callback_ctx ? state->callback_ctx->runtime_schema : &PL_sv_undef, slot
  );

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

SV *
materialize_dynamic_value_xs(value, variables)
    SV *value
    SV *variables
  CODE:
    {
      HV *variables_hv = NULL;
      if (variables && SvOK(variables) && SvROK(variables) && SvTYPE(SvRV(variables)) == SVt_PVHV) {
        variables_hv = (HV *)SvRV(variables);
      }
      RETVAL = gql_runtime_vm_materialize_dynamic_value_sv(aTHX_ value, variables_hv);
    }
  OUTPUT:
    RETVAL

int
evaluate_runtime_guards_xs(guards, variables)
    SV *guards
    SV *variables
  CODE:
    {
      HV *variables_hv = NULL;
      if (variables && SvOK(variables) && SvROK(variables) && SvTYPE(SvRV(variables)) == SVt_PVHV) {
        variables_hv = (HV *)SvRV(variables);
      }
      RETVAL = gql_runtime_vm_evaluate_runtime_guards_hv(aTHX_ guards, variables_hv);
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
writer_materialize_errors_xs(writer)
    SV *writer
  CODE:
    {
      gql_runtime_vm_writer_t *state = gql_runtime_vm_expect_writer(aTHX_ writer);
      RETVAL = gql_runtime_vm_writer_materialize_errors_sv(aTHX_ state);
    }
  OUTPUT:
    RETVAL

SV *
error_record_new_xs(class, message = &PL_sv_undef, path_frame = &PL_sv_undef)
    SV *class
    SV *message
    SV *path_frame
  CODE:
    {
      RETVAL = gql_runtime_vm_new_handle_sv(
        aTHX_
        SvPV_nolen(class),
        gql_runtime_vm_new_error_record_struct(aTHX_ message, path_frame)
      );
    }
  OUTPUT:
    RETVAL

SV *
error_record_message_xs(record)
    SV *record
  CODE:
    {
      gql_runtime_vm_error_record_t *state = gql_runtime_vm_expect_error_record(aTHX_ record);
      RETVAL = state->message_pv ? newSVpv(state->message_pv, 0) : newSVsv(&PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
error_record_path_frame_xs(record)
    SV *record
  CODE:
    {
      gql_runtime_vm_error_record_t *state = gql_runtime_vm_expect_error_record(aTHX_ record);
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
error_record_to_error_xs(record)
    SV *record
  CODE:
    {
      gql_runtime_vm_error_record_t *state = gql_runtime_vm_expect_error_record(aTHX_ record);
      RETVAL = gql_runtime_vm_error_record_to_error_sv(aTHX_ state);
    }
  OUTPUT:
    RETVAL

SV *
cursor_new_xs(class, block, slot_index = 0, op_index = 0, current_slot = &PL_sv_undef, current_op = &PL_sv_undef)
    SV *class
    SV *block
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
      cursor->block = newSVsv(block ? block : &PL_sv_undef);
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
cursor_enter_block_xs(cursor, block)
    SV *cursor
    SV *block
  CODE:
    {
      gql_runtime_vm_cursor_t *dst = gql_runtime_vm_expect_cursor(aTHX_ cursor);
      SvREFCNT_dec(dst->block);
      dst->block = newSVsv(block ? block : &PL_sv_undef);
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
      if (index != -2147483647) {
        dst->op_index = index;
      }
      if (index == -2147483647 && op && SvOK(op) && SvROK(op) && SvTYPE(SvRV(op)) == SVt_PVAV && dst->block && SvOK(dst->block)) {
        AV *ops_av = gql_runtime_vm_cursor_ops_av(aTHX_ dst);
        IV i;
        if (ops_av) {
          for (i = 0; i <= av_len(ops_av); i++) {
            SV **svp = av_fetch(ops_av, i, 0);
            if (svp && *svp && sv_eq(*svp, op)) {
              dst->op_index = i;
              break;
            }
          }
        }
      }
    }

SV *
cursor_advance_op_xs(cursor)
    SV *cursor
  CODE:
    {
      gql_runtime_vm_cursor_t *dst = gql_runtime_vm_expect_cursor(aTHX_ cursor);
      AV *block_av;
      AV *ops_av;
      IV next_index;
      SV *op_sv;
      ops_av = gql_runtime_vm_cursor_ops_av(aTHX_ dst);
      if (!ops_av) {
        RETVAL = &PL_sv_undef;
        goto done_cursor_advance;
      }
      next_index = dst->op_index + 1;
      if (next_index > av_len(ops_av)) {
        dst->op_index = next_index;
        RETVAL = &PL_sv_undef;
        goto done_cursor_advance;
      }
      dst->op_index = next_index;
      op_sv = gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ dst);
      RETVAL = newSVsv(op_sv ? op_sv : &PL_sv_undef);
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
      gql_runtime_vm_cursor_t *state = gql_runtime_vm_expect_cursor(aTHX_ cursor);
      RETVAL = newSVsv(state->block ? state->block : &PL_sv_undef);
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
      gql_runtime_vm_cursor_t *state = gql_runtime_vm_expect_cursor(aTHX_ cursor);
      SV *slot_sv = gql_runtime_vm_cursor_current_slot_borrowed_sv(aTHX_ state);
      RETVAL = newSVsv(slot_sv ? slot_sv : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
cursor_current_op_xs(cursor)
    SV *cursor
  CODE:
    {
      gql_runtime_vm_cursor_t *state = gql_runtime_vm_expect_cursor(aTHX_ cursor);
      SV *op_sv = gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ state);
      RETVAL = newSVsv(op_sv ? op_sv : &PL_sv_undef);
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
      RETVAL = gql_runtime_vm_block_frame_finalize_sv(
        aTHX_
        state,
        promise_code,
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
block_frame_merge_pending_state_xs(merge, resolved)
    SV *merge
    SV *resolved
  CODE:
    {
      gql_runtime_vm_pending_merge_t *state = gql_runtime_vm_expect_pending_merge(aTHX_ merge);
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
      const char *pkg = SvPV_nolen(class);
      Newxz(state, 1, gql_runtime_vm_exec_state_handle_t);
      state->runtime_schema = newSVsv(runtime_schema ? runtime_schema : &PL_sv_undef);
      state->program = newSVsv(program ? program : &PL_sv_undef);
      state->cursor = (cursor && SvOK(cursor)) ? gql_runtime_vm_expect_cursor(aTHX_ cursor) : NULL;
      gql_runtime_vm_cursor_incref(state->cursor);
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
      state->empty_args = newSVsv(empty_args ? empty_args : &PL_sv_undef);
      RETVAL = gql_runtime_vm_new_handle_sv(aTHX_ pkg, state);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_runtime_schema_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = newSVsv(s->runtime_schema ? s->runtime_schema : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_program_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = newSVsv(s->program ? s->program : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_cursor_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = gql_runtime_vm_wrap_cursor_sv(aTHX_ s->cursor);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_frame_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = gql_runtime_vm_wrap_block_frame_sv(aTHX_ s->frame);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_frame_stack_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      AV *ret = newAV();
      IV i;
      for (i = 0; i < s->frame_stack_count; i++) {
        av_push(ret, gql_runtime_vm_wrap_block_frame_sv(aTHX_ s->frame_stack[i]));
      }
      RETVAL = newRV_noinc((SV *)ret);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_field_frame_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = gql_runtime_vm_wrap_field_frame_sv(aTHX_ s->field_frame);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_writer_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = gql_runtime_vm_wrap_writer_sv(aTHX_ s->writer);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_context_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = newSVsv(s->context ? s->context : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_variables_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = newSVsv(s->variables ? s->variables : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_root_value_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = newSVsv(s->root_value ? s->root_value : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_current_field_name_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      SV *value = gql_runtime_vm_state_current_field_name_sv(aTHX_ s);
      RETVAL = newSVsv(value ? value : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_current_return_type_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      SV *op_sv = (s && s->cursor) ? gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ s->cursor) : NULL;
      SV *slot_sv = (s && s->cursor) ? gql_runtime_vm_cursor_current_slot_borrowed_sv(aTHX_ s->cursor) : NULL;
      SV *value = gql_runtime_vm_state_current_return_type_sv(aTHX_ s, op_sv, slot_sv);
      RETVAL = newSVsv(value ? value : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_current_parent_type_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      SV *value = gql_runtime_vm_state_current_parent_type_sv(aTHX_ s);
      RETVAL = newSVsv(value ? value : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_current_path_xs(state, path_frame = &PL_sv_undef)
    SV *state
    SV *path_frame
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      gql_runtime_vm_path_frame_t *path_ptr = NULL;
      if (path_frame && SvOK(path_frame) && SvROK(path_frame) && SvIOK(SvRV(path_frame)) && SvUV(SvRV(path_frame)) != 0) {
        path_ptr = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(path_frame)));
      } else if (s->field_frame) {
        path_ptr = s->field_frame->path_frame;
      }
      RETVAL = path_ptr
        ? gql_runtime_vm_path_frame_to_path_sv(aTHX_ path_ptr)
        : newSVsv(&PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_promise_code_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = newSVsv(s->promise_code ? s->promise_code : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_empty_args_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = newSVsv(s->empty_args ? s->empty_args : &PL_sv_undef);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_push_frame_xs(state, frame)
    SV *state
    SV *frame
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      gql_runtime_vm_block_frame_t *frame_ptr = (frame && SvOK(frame))
        ? gql_runtime_vm_expect_block_frame(aTHX_ frame)
        : NULL;
      if (s->frame_stack_count == s->frame_stack_capacity) {
        IV new_cap = s->frame_stack_capacity ? s->frame_stack_capacity * 2 : 4;
        Renew(s->frame_stack, new_cap, gql_runtime_vm_block_frame_t *);
        s->frame_stack_capacity = new_cap;
      }
      if (frame_ptr) {
        frame_ptr->refcount++;
      }
      s->frame_stack[s->frame_stack_count++] = frame_ptr;
      s->frame = frame_ptr;
      RETVAL = gql_runtime_vm_wrap_block_frame_sv(aTHX_ frame_ptr);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_pop_frame_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_block_frame_t *popped = NULL;
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      if (s->frame_stack_count > 0) {
        popped = s->frame_stack[--s->frame_stack_count];
      }
      s->frame = s->frame_stack_count > 0 ? s->frame_stack[s->frame_stack_count - 1] : NULL;
      RETVAL = gql_runtime_vm_wrap_block_frame_sv(aTHX_ popped);
      if (popped) {
        gql_runtime_vm_free_block_frame(aTHX_ popped);
      }
    }
  OUTPUT:
    RETVAL

void
exec_state_set_field_frame_xs(state, field_frame = &PL_sv_undef)
    SV *state
    SV *field_frame
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
      s->field_frame = (field_frame && SvOK(field_frame))
        ? gql_runtime_vm_expect_field_frame(aTHX_ field_frame)
        : NULL;
      if (s->field_frame) {
        s->field_frame->refcount++;
      }
    }

SV *
exec_state_advance_current_op_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      gql_runtime_vm_cursor_t *dst;
      AV *ops_av;
      IV next_index;
      SV *op_sv;
      if (!s->cursor) {
        RETVAL = newSVsv(&PL_sv_undef);
        goto done_exec_state_advance;
      }
      dst = s->cursor;
      ops_av = gql_runtime_vm_cursor_ops_av(aTHX_ dst);
      if (!ops_av) {
        RETVAL = newSVsv(&PL_sv_undef);
        goto done_exec_state_advance;
      }
      next_index = dst->op_index + 1;
      if (next_index > av_len(ops_av)) {
        dst->op_index = next_index;
        RETVAL = newSVsv(&PL_sv_undef);
        goto done_exec_state_advance;
      }
      dst->op_index = next_index;
      op_sv = gql_runtime_vm_cursor_current_op_borrowed_sv(aTHX_ dst);
      RETVAL = newSVsv(op_sv ? op_sv : &PL_sv_undef);
done_exec_state_advance:
      ;
    }
  OUTPUT:
    RETVAL

SV *
exec_state_enter_field_xs(state, source, path_frame)
    SV *state
    SV *source
    SV *path_frame
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      gql_runtime_vm_field_frame_t *frame;
      Newxz(frame, 1, gql_runtime_vm_field_frame_t);
      frame->refcount = 1;
      frame->source = newSVsv(source ? source : &PL_sv_undef);
      if (path_frame && SvOK(path_frame) && SvROK(path_frame) && SvIOK(SvRV(path_frame)) && SvUV(SvRV(path_frame)) != 0) {
        frame->path_frame = INT2PTR(gql_runtime_vm_path_frame_t *, SvUV(SvRV(path_frame)));
        frame->path_frame->refcount++;
      }
      frame->resolved_value = newSVsv(&PL_sv_undef);
      frame->outcome = NULL;
      gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
      s->field_frame = frame;
      RETVAL = gql_runtime_vm_wrap_field_frame_sv(aTHX_ frame);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_enter_current_field_xs(state, source = &PL_sv_undef, base_path = &PL_sv_undef)
    SV *state
    SV *source
    SV *base_path
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      gql_runtime_vm_enter_field_now(aTHX_ s, source, base_path);
      RETVAL = gql_runtime_vm_wrap_field_frame_sv(aTHX_ s->field_frame);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_leave_field_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = gql_runtime_vm_wrap_field_frame_sv(aTHX_ s->field_frame);
      gql_runtime_vm_free_field_frame(aTHX_ s->field_frame);
      s->field_frame = NULL;
    }
  OUTPUT:
    RETVAL

void
exec_state_consume_current_field_outcome_xs(state, outcome)
    SV *state
    SV *outcome
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      gql_runtime_vm_consume_current_outcome_now(aTHX_ s, gql_runtime_vm_expect_outcome(aTHX_ outcome));
    }

void
exec_state_consume_current_result_xs(state, result)
    SV *state
    SV *result
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      gql_runtime_vm_consume_current_result_now(aTHX_ s, result);
    }

SV *
exec_state_enter_block_xs(state, block, frame = &PL_sv_undef)
    SV *state
    SV *block
    SV *frame
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      SV *snapshot;
      SV *frame_sv = frame;
      gql_runtime_vm_block_frame_t *frame_ptr;
      if (s->cursor) {
        gql_runtime_vm_cursor_t *snapshot_ptr;
        Newxz(snapshot_ptr, 1, gql_runtime_vm_cursor_t);
        snapshot_ptr->refcount = 1;
        gql_runtime_vm_cursor_snapshot_copy(aTHX_ snapshot_ptr, s->cursor);
        snapshot = gql_runtime_vm_new_handle_sv(aTHX_ "GraphQL::Houtou::Runtime::Cursor", snapshot_ptr);
      } else {
        snapshot = newSVsv(&PL_sv_undef);
      }
      if (!frame_sv || !SvOK(frame_sv)) {
        frame_ptr = gql_runtime_vm_new_block_frame_struct(aTHX);
      } else {
        frame_ptr = gql_runtime_vm_expect_block_frame(aTHX_ frame_sv);
        frame_ptr->refcount++;
      }
      if (s->cursor) {
        gql_runtime_vm_cursor_t *dst = s->cursor;
        SvREFCNT_dec(dst->block);
        dst->block = newSVsv(block ? block : &PL_sv_undef);
        dst->slot_index = 0;
        dst->op_index = -1;
      }
      if (s->frame_stack_count == s->frame_stack_capacity) {
        IV new_cap = s->frame_stack_capacity ? s->frame_stack_capacity * 2 : 4;
        Renew(s->frame_stack, new_cap, gql_runtime_vm_block_frame_t *);
        s->frame_stack_capacity = new_cap;
      }
      s->frame_stack[s->frame_stack_count++] = frame_ptr;
      s->frame = frame_ptr;
      RETVAL = snapshot;
    }
  OUTPUT:
    RETVAL

SV *
exec_state_leave_block_xs(state, snapshot = &PL_sv_undef)
    SV *state
    SV *snapshot
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      gql_runtime_vm_block_frame_t *popped = NULL;
      if (s->frame_stack_count > 0) {
        popped = s->frame_stack[--s->frame_stack_count];
      }
      s->frame = s->frame_stack_count > 0 ? s->frame_stack[s->frame_stack_count - 1] : NULL;
      if (s->cursor && snapshot && SvOK(snapshot)) {
        gql_runtime_vm_cursor_restore_sv(aTHX_ s->cursor, snapshot);
      }
      RETVAL = gql_runtime_vm_wrap_block_frame_sv(aTHX_ popped);
      if (popped) {
        gql_runtime_vm_free_block_frame(aTHX_ popped);
      }
    }
  OUTPUT:
    RETVAL

SV *
exec_state_finalize_current_block_xs(state, snapshot = &PL_sv_undef)
    SV *state
    SV *snapshot
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = gql_runtime_vm_finalize_current_block_now(aTHX_ s, snapshot);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_execute_block_xs(state, block, source = &PL_sv_undef, base_path = &PL_sv_undef)
    SV *state
    SV *block
    SV *source
    SV *base_path
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = gql_runtime_vm_exec_state_execute_block_sync_sv(aTHX_ state, s, block, source, base_path);
    }
  OUTPUT:
    RETVAL

SV *
exec_state_execute_current_op_xs(state)
    SV *state
  CODE:
    {
      gql_runtime_vm_exec_state_handle_t *s = gql_runtime_vm_expect_exec_state_handle(aTHX_ state);
      RETVAL = gql_runtime_vm_exec_state_execute_current_op_sync_sv(aTHX_ state, s);
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
      AV *program_av;
      SV **root_block_svp;
      SV *root_block_sv;
      SV *effective_root = root_value;
      SV *data_sv;
      HV *response_hv;

      if (!s->program || !SvOK(s->program) || !SvROK(s->program) || SvTYPE(SvRV(s->program)) != SVt_PVAV) {
        croak("exec state program must be a VMProgram array handle");
      }
      program_av = (AV *)SvRV(s->program);
      root_block_svp = av_fetch(program_av, 5, 0);
      root_block_sv = (root_block_svp && *root_block_svp) ? *root_block_svp : &PL_sv_undef;
      if (!effective_root || !SvOK(effective_root)) {
        effective_root = s->root_value;
      }

      data_sv = gql_runtime_vm_exec_state_execute_block_sync_sv(
        aTHX_
        state,
        s,
        root_block_sv,
        effective_root,
        &PL_sv_undef
      );

      response_hv = newHV();
      hv_store(response_hv, "data", 4, data_sv ? newSVsv(data_sv) : newSV(0), 0);
      hv_store(
        response_hv,
        "errors",
        6,
        gql_runtime_vm_writer_materialize_errors_sv(aTHX_ s->writer),
        0
      );
      RETVAL = newRV_noinc((SV *)response_hv);
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
      gql_runtime_vm_native_value_t *data_value;
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
      callback_ctx.root_value = root_value;
      callback_ctx.context = context_value;
      callback_ctx.variables = variables;
      state.callback_ctx = &callback_ctx;
      writer = gql_runtime_vm_new_writer_struct(aTHX);
      state.writer = writer;
      state.path_frame = NULL;

      data_value = gql_runtime_vm_execute_block_value(
        aTHX_
        &state,
        bundle->root_block_index,
        root_value
      );
      data_sv = gql_runtime_vm_native_value_materialize_sv(aTHX_ data_value);
      gql_runtime_vm_native_value_destroy(aTHX_ data_value);
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
      gql_runtime_vm_native_value_t *data_value;
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
      callback_ctx.root_value = root_value;
      callback_ctx.context = context_value;
      callback_ctx.variables = variables;
      state.callback_ctx = &callback_ctx;
      writer = gql_runtime_vm_new_writer_struct(aTHX);
      state.writer = writer;
      state.path_frame = NULL;

      data_value = gql_runtime_vm_execute_block_value(
        aTHX_
        &state,
        bundle->root_block_index,
        root_value
      );
      data_sv = gql_runtime_vm_native_value_materialize_sv(aTHX_ data_value);
      gql_runtime_vm_native_value_destroy(aTHX_ data_value);
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
      gql_runtime_vm_native_value_t *data_value;
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
      callback_ctx.root_value = root_value;
      callback_ctx.context = context_value;
      callback_ctx.variables = variables;
      state.callback_ctx = &callback_ctx;
      writer = gql_runtime_vm_new_writer_struct(aTHX);
      state.writer = writer;
      state.path_frame = NULL;

      data_value = gql_runtime_vm_execute_block_value(
        aTHX_
        &state,
        bundle->root_block_index,
        root_value
      );
      data_sv = gql_runtime_vm_native_value_materialize_sv(aTHX_ data_value);
      gql_runtime_vm_native_value_destroy(aTHX_ data_value);
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
