#ifndef GQL_GREENFIELD_VM_H
#define GQL_GREENFIELD_VM_H

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
  IV completion_family_code;
  IV dispatch_family_code;
  IV return_type_kind_code;
  U8 has_args;
  U8 has_directives;
} gql_greenfield_vm_native_slot_t;

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
  U8 has_args;
  U8 has_directives;
} gql_greenfield_vm_native_op_t;

typedef struct {
  IV family_code;
  IV slot_count;
  IV op_count;
  gql_greenfield_vm_native_slot_t *slots;
  gql_greenfield_vm_native_op_t *ops;
} gql_greenfield_vm_native_block_t;

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
} gql_greenfield_vm_native_runtime_t;

typedef struct {
  IV operation_type_code;
  IV root_block_index;
  IV runtime_slot_count;
  IV block_count;
  gql_greenfield_vm_native_slot_t *runtime_slots;
  gql_greenfield_vm_native_block_t *blocks;
} gql_greenfield_vm_native_bundle_t;

typedef struct {
  gql_greenfield_vm_native_runtime_t *runtime;
  gql_greenfield_vm_native_bundle_t *bundle;
  SV *context;
  const gql_greenfield_vm_native_block_t *block;
  const gql_greenfield_vm_native_op_t *op;
  const gql_greenfield_vm_native_slot_t *slot;
  IV block_index;
  IV op_index;
} gql_greenfield_vm_exec_state_t;

static void
gql_greenfield_vm_native_bundle_destroy(gql_greenfield_vm_native_bundle_t *bundle)
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
gql_greenfield_vm_native_runtime_destroy(gql_greenfield_vm_native_runtime_t *runtime)
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
gql_greenfield_vm_fetch_hv_string(pTHX_ HV *hv, const char *key, I32 keylen, char **out)
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
gql_greenfield_vm_fetch_hv_iv(pTHX_ HV *hv, const char *key, I32 keylen, IV *out)
{
  SV **svp = hv_fetch(hv, key, keylen, 0);
  if (!svp || !SvOK(*svp)) {
    return 0;
  }
  *out = SvIV(*svp);
  return 1;
}

static int
gql_greenfield_vm_fetch_hv_bool(pTHX_ HV *hv, const char *key, I32 keylen, U8 *out)
{
  IV value = 0;
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ hv, key, keylen, &value)) {
    return 0;
  }
  *out = value ? 1 : 0;
  return 1;
}

static int
gql_greenfield_vm_sv_to_hv(pTHX_ SV *sv, HV **out)
{
  if (!sv || !SvOK(sv) || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVHV) {
    return 0;
  }
  *out = (HV *)SvRV(sv);
  return 1;
}

static int
gql_greenfield_vm_sv_to_av(pTHX_ SV *sv, AV **out)
{
  if (!sv || !SvOK(sv) || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVAV) {
    return 0;
  }
  *out = (AV *)SvRV(sv);
  return 1;
}

static int
gql_greenfield_vm_parse_native_slot(pTHX_ SV *sv, gql_greenfield_vm_native_slot_t *out)
{
  HV *hv;
  if (!gql_greenfield_vm_sv_to_hv(aTHX_ sv, &hv)) {
    croak("native VM slot entry must be a hash reference");
  }
  if (!gql_greenfield_vm_fetch_hv_string(aTHX_ hv, "field_name", 10, &out->field_name)) {
    croak("native VM slot entry is missing field_name");
  }
  if (!gql_greenfield_vm_fetch_hv_string(aTHX_ hv, "result_name", 11, &out->result_name)) {
    croak("native VM slot entry is missing result_name");
  }
  if (!gql_greenfield_vm_fetch_hv_string(aTHX_ hv, "return_type_name", 16, &out->return_type_name)) {
    croak("native VM slot entry is missing return_type_name");
  }
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ hv, "schema_slot_index", 17, &out->schema_slot_index)) {
    croak("native VM slot entry is missing schema_slot_index");
  }
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ hv, "resolver_shape_code", 19, &out->resolver_shape_code)) {
    croak("native VM slot entry is missing resolver_shape_code");
  }
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ hv, "completion_family_code", 22, &out->completion_family_code)) {
    croak("native VM slot entry is missing completion_family_code");
  }
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ hv, "dispatch_family_code", 20, &out->dispatch_family_code)) {
    croak("native VM slot entry is missing dispatch_family_code");
  }
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ hv, "return_type_kind_code", 21, &out->return_type_kind_code)) {
    croak("native VM slot entry is missing return_type_kind_code");
  }
  if (!gql_greenfield_vm_fetch_hv_bool(aTHX_ hv, "has_args", 8, &out->has_args)) {
    croak("native VM slot entry is missing has_args");
  }
  if (!gql_greenfield_vm_fetch_hv_bool(aTHX_ hv, "has_directives", 14, &out->has_directives)) {
    croak("native VM slot entry is missing has_directives");
  }
  return 1;
}

static int
gql_greenfield_vm_parse_native_op(pTHX_ SV *sv, gql_greenfield_vm_native_op_t *out)
{
  HV *hv;
  HV *children_hv;
  HE *he;
  SV **svp;
  IV idx;
  if (!gql_greenfield_vm_sv_to_hv(aTHX_ sv, &hv)) {
    croak("native VM op entry must be a hash reference");
  }
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ hv, "opcode_code", 11, &out->opcode_code)) {
    croak("native VM op entry is missing opcode_code");
  }
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ hv, "resolve_code", 12, &out->resolve_code)) {
    croak("native VM op entry is missing resolve_code");
  }
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ hv, "complete_code", 13, &out->complete_code)) {
    croak("native VM op entry is missing complete_code");
  }
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ hv, "dispatch_family_code", 20, &out->dispatch_family_code)) {
    croak("native VM op entry is missing dispatch_family_code");
  }
  svp = hv_fetch(hv, "slot_index", 10, 0);
  out->slot_index = (svp && SvOK(*svp)) ? SvIV(*svp) : -1;
  svp = hv_fetch(hv, "child_block_index", 17, 0);
  out->child_block_index = (svp && SvOK(*svp)) ? SvIV(*svp) : -1;
  if (!gql_greenfield_vm_fetch_hv_bool(aTHX_ hv, "has_args", 8, &out->has_args)) {
    croak("native VM op entry is missing has_args");
  }
  if (!gql_greenfield_vm_fetch_hv_bool(aTHX_ hv, "has_directives", 14, &out->has_directives)) {
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
  return 1;
}

static int
gql_greenfield_vm_parse_native_block(pTHX_ SV *sv, gql_greenfield_vm_native_block_t *out)
{
  HV *hv;
  AV *slots_av;
  AV *ops_av;
  IV i;
  SV **svp;
  if (!gql_greenfield_vm_sv_to_hv(aTHX_ sv, &hv)) {
    return 0;
  }
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ hv, "family_code", 11, &out->family_code)) {
    return 0;
  }
  svp = hv_fetch(hv, "slots", 5, 0);
  if (!svp || !gql_greenfield_vm_sv_to_av(aTHX_ *svp, &slots_av)) {
    return 0;
  }
  svp = hv_fetch(hv, "ops", 3, 0);
  if (!svp || !gql_greenfield_vm_sv_to_av(aTHX_ *svp, &ops_av)) {
    return 0;
  }
  out->slot_count = av_count(slots_av);
  out->op_count = av_count(ops_av);
  out->slots = NULL;
  out->ops = NULL;
  if (out->slot_count > 0) {
    Newxz(out->slots, out->slot_count, gql_greenfield_vm_native_slot_t);
    for (i = 0; i < out->slot_count; i++) {
      SV **slot_svp = av_fetch(slots_av, i, 0);
      if (!slot_svp || !gql_greenfield_vm_parse_native_slot(aTHX_ *slot_svp, &out->slots[i])) {
        return 0;
      }
    }
  }
  if (out->op_count > 0) {
    Newxz(out->ops, out->op_count, gql_greenfield_vm_native_op_t);
    for (i = 0; i < out->op_count; i++) {
      SV **op_svp = av_fetch(ops_av, i, 0);
      if (!op_svp || !gql_greenfield_vm_parse_native_op(aTHX_ *op_svp, &out->ops[i])) {
        return 0;
      }
    }
  }
  return 1;
}

static gql_greenfield_vm_native_bundle_t *
gql_greenfield_vm_native_bundle_from_sv(pTHX_ SV *sv)
{
  HV *bundle_hv;
  HV *runtime_hv;
  HV *program_hv;
  AV *runtime_slots_av;
  AV *blocks_av;
  IV i;
  SV **svp;
  gql_greenfield_vm_native_bundle_t *bundle;

  if (!gql_greenfield_vm_sv_to_hv(aTHX_ sv, &bundle_hv)) {
    croak("native VM bundle descriptor must be a hash reference");
  }

  svp = hv_fetch(bundle_hv, "runtime", 7, 0);
  if (!svp || !gql_greenfield_vm_sv_to_hv(aTHX_ *svp, &runtime_hv)) {
    croak("native VM bundle descriptor is missing runtime");
  }
  svp = hv_fetch(bundle_hv, "program", 7, 0);
  if (!svp || !gql_greenfield_vm_sv_to_hv(aTHX_ *svp, &program_hv)) {
    croak("native VM bundle descriptor is missing program");
  }

  Newxz(bundle, 1, gql_greenfield_vm_native_bundle_t);

  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ program_hv, "operation_type_code", 19, &bundle->operation_type_code)) {
    gql_greenfield_vm_native_bundle_destroy(bundle);
    croak("native VM program descriptor is missing operation_type_code");
  }
  if (!gql_greenfield_vm_fetch_hv_iv(aTHX_ program_hv, "root_block_index", 16, &bundle->root_block_index)) {
    gql_greenfield_vm_native_bundle_destroy(bundle);
    croak("native VM program descriptor is missing root_block_index");
  }

  svp = hv_fetch(runtime_hv, "slot_catalog", 12, 0);
  if (!svp || !gql_greenfield_vm_sv_to_av(aTHX_ *svp, &runtime_slots_av)) {
    gql_greenfield_vm_native_bundle_destroy(bundle);
    croak("native VM runtime descriptor is missing slot_catalog");
  }
  bundle->runtime_slot_count = av_count(runtime_slots_av);
  if (bundle->runtime_slot_count > 0) {
    Newxz(bundle->runtime_slots, bundle->runtime_slot_count, gql_greenfield_vm_native_slot_t);
    for (i = 0; i < bundle->runtime_slot_count; i++) {
      SV **slot_svp = av_fetch(runtime_slots_av, i, 0);
      if (!slot_svp) {
        gql_greenfield_vm_native_bundle_destroy(bundle);
        croak("native VM runtime slot entry %ld is missing", (long)i);
      }
      if (!gql_greenfield_vm_parse_native_slot(aTHX_ *slot_svp, &bundle->runtime_slots[i])) {
        gql_greenfield_vm_native_bundle_destroy(bundle);
        croak("native VM runtime slot entry %ld is invalid", (long)i);
      }
    }
  }

  svp = hv_fetch(program_hv, "blocks", 6, 0);
  if (!svp || !gql_greenfield_vm_sv_to_av(aTHX_ *svp, &blocks_av)) {
    gql_greenfield_vm_native_bundle_destroy(bundle);
    croak("native VM program descriptor is missing blocks");
  }
  bundle->block_count = av_count(blocks_av);
  if (bundle->block_count > 0) {
    Newxz(bundle->blocks, bundle->block_count, gql_greenfield_vm_native_block_t);
    for (i = 0; i < bundle->block_count; i++) {
      SV **block_svp = av_fetch(blocks_av, i, 0);
      if (!block_svp) {
        gql_greenfield_vm_native_bundle_destroy(bundle);
        croak("native VM block entry %ld is missing", (long)i);
      }
      if (!gql_greenfield_vm_parse_native_block(aTHX_ *block_svp, &bundle->blocks[i])) {
        gql_greenfield_vm_native_bundle_destroy(bundle);
        croak("native VM block entry %ld is invalid", (long)i);
      }
    }
  }

  return bundle;
}

#endif
