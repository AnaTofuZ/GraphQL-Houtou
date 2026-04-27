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

#define GQL_VM_OPCODE(resolve_code, complete_code) (((resolve_code) * 16) + (complete_code))

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
  U8 has_args;
  U8 has_directives;
} gql_runtime_vm_native_slot_t;

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
  SV *args_payload_sv;
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
  SV **slot_resolvers;
  SV **slot_return_types;
  SV **slot_abstract_types;
  SV **slot_tag_resolvers;
  HV **slot_tag_maps;
  SV **slot_resolve_types;
  AV **slot_possible_types;
  HV *runtime_cache_hv;
  HV *name2type_hv;
  HV *dispatch_index_hv;
  HV *is_type_of_map_hv;
} gql_runtime_vm_native_runtime_t;

typedef struct {
  IV operation_type_code;
  IV root_block_index;
  IV runtime_slot_count;
  IV block_count;
  gql_runtime_vm_native_slot_t *runtime_slots;
  gql_runtime_vm_native_block_t *blocks;
} gql_runtime_vm_native_bundle_t;

typedef struct {
  gql_runtime_vm_native_runtime_t *runtime;
  gql_runtime_vm_native_bundle_t *bundle;
  SV *context;
  const gql_runtime_vm_native_block_t *block;
  const gql_runtime_vm_native_op_t *op;
  const gql_runtime_vm_native_slot_t *slot;
  IV block_index;
  IV op_index;
} gql_runtime_vm_exec_state_t;

static SV *
gql_runtime_vm_new_outcome_sv(pTHX_ const char *kind, STRLEN kind_len, SV *value, SV *error_records)
{
  AV *av = newAV();
  HV *stash = gv_stashpv("GraphQL::Houtou::Runtime::Outcome", GV_ADD);
  SV *errors_sv;

  av_extend(av, 4);
  av_store(av, 0, newSVpvn(kind, kind_len));
  if (kind_len == 6 && memEQ(kind, "SCALAR", 6)) {
    av_store(av, 1, value ? newSVsv(value) : newSV(0));
    av_store(av, 2, newSV(0));
    av_store(av, 3, newSV(0));
  }
  else if (kind_len == 6 && memEQ(kind, "OBJECT", 6)) {
    av_store(av, 1, newSV(0));
    av_store(av, 2, value ? newSVsv(value) : newSV(0));
    av_store(av, 3, newSV(0));
  }
  else if (kind_len == 4 && memEQ(kind, "LIST", 4)) {
    av_store(av, 1, newSV(0));
    av_store(av, 2, newSV(0));
    av_store(av, 3, value ? newSVsv(value) : newSV(0));
  }
  else {
    av_store(av, 1, newSV(0));
    av_store(av, 2, newSV(0));
    av_store(av, 3, newSV(0));
  }

  errors_sv = error_records ? newSVsv(error_records) : newRV_noinc((SV *)newAV());
  av_store(av, 4, errors_sv);
  return sv_bless(newRV_noinc((SV *)av), stash);
}

static void
gql_runtime_vm_consume_outcome_sv(pTHX_ HV *data_hv, SV *result_name_sv, SV *outcome_sv, AV *writer_errors_av)
{
  AV *outcome_av;
  SV **kind_svp;
  SV **value_svp = NULL;
  SV **errors_svp;
  AV *errors_av;
  const char *kind;
  STRLEN kind_len;
  SSize_t i;

  if (!data_hv || !result_name_sv || !outcome_sv || !SvOK(outcome_sv) || !SvROK(outcome_sv) || SvTYPE(SvRV(outcome_sv)) != SVt_PVAV) {
    return;
  }

  outcome_av = (AV *)SvRV(outcome_sv);
  kind_svp = av_fetch(outcome_av, 0, 0);
  if (!kind_svp || !SvOK(*kind_svp)) {
    return;
  }

  kind = SvPV(*kind_svp, kind_len);
  if (kind_len == 6 && memEQ(kind, "SCALAR", 6)) {
    value_svp = av_fetch(outcome_av, 1, 0);
  }
  else if (kind_len == 6 && memEQ(kind, "OBJECT", 6)) {
    value_svp = av_fetch(outcome_av, 2, 0);
  }
  else if (kind_len == 4 && memEQ(kind, "LIST", 4)) {
    value_svp = av_fetch(outcome_av, 3, 0);
  }

  hv_store_ent(
    data_hv,
    result_name_sv,
    (value_svp && *value_svp) ? newSVsv(*value_svp) : newSV(0),
    0
  );

  if (!writer_errors_av) {
    return;
  }

  errors_svp = av_fetch(outcome_av, 4, 0);
  if (!errors_svp || !SvOK(*errors_svp) || !SvROK(*errors_svp) || SvTYPE(SvRV(*errors_svp)) != SVt_PVAV) {
    return;
  }

  errors_av = (AV *)SvRV(*errors_svp);
  for (i = 0; i <= av_len(errors_av); i++) {
    SV **err_svp = av_fetch(errors_av, i, 0);
    if (err_svp && *err_svp) {
      av_push(writer_errors_av, newSVsv(*err_svp));
    }
  }
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
    for (i = 0; i < bundle->runtime_slot_count; i++) {
      Safefree(bundle->runtime_slots[i].field_name);
      Safefree(bundle->runtime_slots[i].result_name);
      Safefree(bundle->runtime_slots[i].return_type_name);
    }
  }
  Safefree(bundle->runtime_slots);
  if (bundle->blocks) {
    for (i = 0; i < bundle->block_count; i++) {
      Safefree(bundle->blocks[i].type_name);
      if (bundle->blocks[i].slots) {
        for (j = 0; j < bundle->blocks[i].slot_count; j++) {
          Safefree(bundle->blocks[i].slots[j].field_name);
          Safefree(bundle->blocks[i].slots[j].result_name);
          Safefree(bundle->blocks[i].slots[j].return_type_name);
        }
      }
      if (bundle->blocks[i].ops) {
        for (j = 0; j < bundle->blocks[i].op_count; j++) {
          Safefree(bundle->blocks[i].ops[j].abstract_child_names);
          Safefree(bundle->blocks[i].ops[j].abstract_child_indexes);
          if (bundle->blocks[i].ops[j].args_payload_sv) {
            SvREFCNT_dec(bundle->blocks[i].ops[j].args_payload_sv);
          }
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
gql_runtime_vm_native_runtime_destroy(gql_runtime_vm_native_runtime_t *runtime)
{
  IV i;
  if (!runtime) {
    return;
  }
  if (runtime->slot_resolvers) {
    for (i = 0; i < runtime->runtime_slot_count; i++) {
      if (runtime->slot_resolvers[i]) {
        SvREFCNT_dec(runtime->slot_resolvers[i]);
      }
      if (runtime->slot_return_types[i]) {
        SvREFCNT_dec(runtime->slot_return_types[i]);
      }
      if (runtime->slot_abstract_types && runtime->slot_abstract_types[i]) {
        SvREFCNT_dec(runtime->slot_abstract_types[i]);
      }
      if (runtime->slot_tag_resolvers && runtime->slot_tag_resolvers[i]) {
        SvREFCNT_dec(runtime->slot_tag_resolvers[i]);
      }
      if (runtime->slot_tag_maps && runtime->slot_tag_maps[i]) {
        SvREFCNT_dec((SV *)runtime->slot_tag_maps[i]);
      }
      if (runtime->slot_resolve_types && runtime->slot_resolve_types[i]) {
        SvREFCNT_dec(runtime->slot_resolve_types[i]);
      }
      if (runtime->slot_possible_types && runtime->slot_possible_types[i]) {
        SvREFCNT_dec((SV *)runtime->slot_possible_types[i]);
      }
    }
  }
  Safefree(runtime->slot_resolvers);
  Safefree(runtime->slot_return_types);
  Safefree(runtime->slot_abstract_types);
  Safefree(runtime->slot_tag_resolvers);
  Safefree(runtime->slot_tag_maps);
  Safefree(runtime->slot_resolve_types);
  Safefree(runtime->slot_possible_types);
  if (runtime->runtime_cache_hv) {
    SvREFCNT_dec((SV *)runtime->runtime_cache_hv);
  }
  if (runtime->name2type_hv) {
    SvREFCNT_dec((SV *)runtime->name2type_hv);
  }
  if (runtime->dispatch_index_hv) {
    SvREFCNT_dec((SV *)runtime->dispatch_index_hv);
  }
  if (runtime->is_type_of_map_hv) {
    SvREFCNT_dec((SV *)runtime->is_type_of_map_hv);
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
  return 1;
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
    out->args_payload_sv = (svp && SvOK(*svp)) ? newSVsv(*svp) : NULL;
    svp = av_fetch(av, 9, 0);
    out->has_args = (svp && SvOK(*svp) && SvTRUE(*svp)) ? 1 : 0;
    svp = av_fetch(av, 10, 0);
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
  out->args_payload_sv = (svp && SvOK(*svp)) ? newSVsv(*svp) : NULL;
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
      svp = av_fetch(op_av, 10, 0);
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

#endif
