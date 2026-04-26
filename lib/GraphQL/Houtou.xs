#include "bootstrap.h"
#include "parser_core.h"
#include "graphqljs_runtime.h"
#include "graphqljs_convert.h"
#include "schema_compiler.h"
#include "validation.h"
#include "execution.h"
#include "ir_engine.h"
#include "ir_execution.h"
#include "greenfield_vm.h"
#include "legacy_compat.h"

static HV *
gql_greenfield_vm_expect_hashref(pTHX_ SV *sv, const char *what)
{
  if (!sv || !SvOK(sv) || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVHV) {
    croak("%s must be a hash reference", what);
  }
  return (HV *)SvRV(sv);
}

static AV *
gql_greenfield_vm_expect_arrayref(pTHX_ SV *sv, const char *what)
{
  if (!sv || !SvOK(sv) || !SvROK(sv) || SvTYPE(SvRV(sv)) != SVt_PVAV) {
    croak("%s must be an array reference", what);
  }
  return (AV *)SvRV(sv);
}

static SV *
gql_greenfield_vm_fetch_hash_entry_sv(pTHX_ HV *hv, const char *key, I32 keylen)
{
  SV **svp = hv_fetch(hv, key, keylen, 0);
  return (svp && SvOK(*svp)) ? *svp : NULL;
}

static const char *
gql_greenfield_vm_fetch_hash_entry_pv(pTHX_ HV *hv, const char *key, I32 keylen)
{
  SV *sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ hv, key, keylen);
  return sv ? SvPV_nolen(sv) : NULL;
}

static SV *
gql_greenfield_vm_fetch_runtime_slot_sv(pTHX_ SV *runtime_schema, IV schema_slot_index)
{
  HV *schema_hv;
  SV *catalog_sv;
  AV *catalog_av;
  SV **slot_svp;

  schema_hv = gql_greenfield_vm_expect_hashref(aTHX_ runtime_schema, "runtime schema");
  catalog_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_catalog", 12);
  if (!catalog_sv) {
    croak("runtime schema is missing slot_catalog");
  }
  catalog_av = gql_greenfield_vm_expect_arrayref(aTHX_ catalog_sv, "runtime schema slot_catalog");
  slot_svp = av_fetch(catalog_av, schema_slot_index, 0);
  if (!slot_svp || !SvOK(*slot_svp)) {
    croak("runtime schema slot_catalog entry %ld is missing", (long)schema_slot_index);
  }
  return *slot_svp;
}

static HV *
gql_greenfield_vm_fetch_runtime_cache_hv(pTHX_ SV *runtime_schema)
{
  HV *schema_hv;
  SV *runtime_cache_sv;

  schema_hv = gql_greenfield_vm_expect_hashref(aTHX_ runtime_schema, "runtime schema");
  runtime_cache_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "runtime_cache", 13);
  return runtime_cache_sv
    ? gql_greenfield_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime schema runtime_cache")
    : NULL;
}

static const char *
gql_greenfield_vm_type_name_from_sv(pTHX_ SV *type_sv);

static gql_greenfield_vm_native_runtime_t *
gql_greenfield_vm_native_runtime_from_runtime_schema_sv(pTHX_ SV *runtime_schema)
{
  gql_greenfield_vm_native_runtime_t *runtime;
  HV *schema_hv;
  SV *catalog_sv;
  AV *catalog_av;
  SV *runtime_cache_sv;
  IV i;

  schema_hv = gql_greenfield_vm_expect_hashref(aTHX_ runtime_schema, "runtime schema");
  catalog_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "slot_catalog", 12);
  if (!catalog_sv) {
    croak("runtime schema is missing slot_catalog");
  }
  catalog_av = gql_greenfield_vm_expect_arrayref(aTHX_ catalog_sv, "runtime schema slot_catalog");

  Newxz(runtime, 1, gql_greenfield_vm_native_runtime_t);
  runtime->runtime_slot_count = av_count(catalog_av);
  if (runtime->runtime_slot_count > 0) {
    Newxz(runtime->slot_resolvers, runtime->runtime_slot_count, SV *);
    Newxz(runtime->slot_return_types, runtime->runtime_slot_count, SV *);
    Newxz(runtime->slot_abstract_types, runtime->runtime_slot_count, SV *);
    Newxz(runtime->slot_tag_resolvers, runtime->runtime_slot_count, SV *);
    Newxz(runtime->slot_tag_maps, runtime->runtime_slot_count, HV *);
    Newxz(runtime->slot_resolve_types, runtime->runtime_slot_count, SV *);
    Newxz(runtime->slot_possible_types, runtime->runtime_slot_count, AV *);
    for (i = 0; i < runtime->runtime_slot_count; i++) {
      SV **slot_svp = av_fetch(catalog_av, i, 0);
      HV *slot_hv;
      SV *resolver_sv;
      SV *return_type_sv;
      if (!slot_svp || !SvOK(*slot_svp)) {
        gql_greenfield_vm_native_runtime_destroy(runtime);
        croak("runtime schema slot_catalog entry %ld is missing", (long)i);
      }
      slot_hv = gql_greenfield_vm_expect_hashref(aTHX_ *slot_svp, "runtime slot");
      resolver_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ slot_hv, "resolve", 7);
      return_type_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ slot_hv, "return_type", 11);
      if (resolver_sv) {
        runtime->slot_resolvers[i] = newSVsv(resolver_sv);
      }
      if (return_type_sv) {
        runtime->slot_return_types[i] = newSVsv(return_type_sv);
      }
    }
  }

  runtime_cache_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "runtime_cache", 13);
  if (runtime_cache_sv) {
    HV *runtime_cache_hv = gql_greenfield_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime schema runtime_cache");
    HV *tag_resolver_map_hv = NULL;
    HV *runtime_tag_map_hv = NULL;
    HV *resolve_type_map_hv = NULL;
    HV *possible_types_hv = NULL;
    runtime->runtime_cache_hv = (HV *)SvREFCNT_inc((SV *)runtime_cache_hv);

    if ((runtime_cache_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "name2type", 9))) {
      runtime->name2type_hv = gql_greenfield_vm_expect_hashref(aTHX_ SvREFCNT_inc(runtime_cache_sv), "runtime_cache name2type");
    }
    if ((runtime_cache_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "tag_resolver_map", 16))) {
      tag_resolver_map_hv = gql_greenfield_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime_cache tag_resolver_map");
    }
    if ((runtime_cache_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "runtime_tag_map", 15))) {
      runtime_tag_map_hv = gql_greenfield_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime_cache runtime_tag_map");
    }
    if ((runtime_cache_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "resolve_type_map", 16))) {
      resolve_type_map_hv = gql_greenfield_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime_cache resolve_type_map");
    }
    if ((runtime_cache_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "possible_types", 14))) {
      possible_types_hv = gql_greenfield_vm_expect_hashref(aTHX_ runtime_cache_sv, "runtime_cache possible_types");
    }
    if ((runtime_cache_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ runtime_cache_hv, "is_type_of_map", 14))) {
      runtime->is_type_of_map_hv = gql_greenfield_vm_expect_hashref(aTHX_ SvREFCNT_inc(runtime_cache_sv), "runtime_cache is_type_of_map");
    }

    if (runtime->runtime_slot_count > 0 && runtime->name2type_hv) {
      for (i = 0; i < runtime->runtime_slot_count; i++) {
        SV **abstract_type_svp;
        const char *return_type_name = runtime->slot_return_types[i]
          ? gql_greenfield_vm_type_name_from_sv(aTHX_ runtime->slot_return_types[i])
          : NULL;
        if (!return_type_name) {
          continue;
        }
        abstract_type_svp = hv_fetch(runtime->name2type_hv, return_type_name, (I32)strlen(return_type_name), 0);
        if (abstract_type_svp && SvOK(*abstract_type_svp)) {
          runtime->slot_abstract_types[i] = newSVsv(*abstract_type_svp);
        }
        if (tag_resolver_map_hv) {
          SV **svp = hv_fetch(tag_resolver_map_hv, return_type_name, (I32)strlen(return_type_name), 0);
          if (svp && SvOK(*svp)) {
            runtime->slot_tag_resolvers[i] = newSVsv(*svp);
          }
        }
        if (runtime_tag_map_hv) {
          SV **svp = hv_fetch(runtime_tag_map_hv, return_type_name, (I32)strlen(return_type_name), 0);
          if (svp && SvOK(*svp) && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVHV) {
            runtime->slot_tag_maps[i] = (HV *)SvREFCNT_inc(SvRV(*svp));
          }
        }
        if (resolve_type_map_hv) {
          SV **svp = hv_fetch(resolve_type_map_hv, return_type_name, (I32)strlen(return_type_name), 0);
          if (svp && SvOK(*svp)) {
            runtime->slot_resolve_types[i] = newSVsv(*svp);
          }
        }
        if (possible_types_hv) {
          SV **svp = hv_fetch(possible_types_hv, return_type_name, (I32)strlen(return_type_name), 0);
          if (svp && SvOK(*svp) && SvROK(*svp) && SvTYPE(SvRV(*svp)) == SVt_PVAV) {
            runtime->slot_possible_types[i] = (AV *)SvREFCNT_inc(SvRV(*svp));
          }
        }
      }
    }
  }

  runtime_cache_sv = gql_greenfield_vm_fetch_hash_entry_sv(aTHX_ schema_hv, "dispatch_index", 14);
  if (runtime_cache_sv) {
    runtime->dispatch_index_hv = gql_greenfield_vm_expect_hashref(aTHX_ SvREFCNT_inc(runtime_cache_sv), "runtime schema dispatch_index");
  }

  return runtime;
}

static SV *
gql_greenfield_vm_call_cb4(pTHX_ SV *cb, SV *arg0, SV *arg1, SV *arg2, SV *arg3)
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
    croak_sv(err);
  }
  if (count > 0) {
    ret = newSVsv(POPs);
  }
  PUTBACK;
  FREETMPS;
  LEAVE;
  return ret ? ret : newSVsv(&PL_sv_undef);
}

static IV
gql_greenfield_vm_find_abstract_child_block_index(const gql_greenfield_vm_native_op_t *op, const char *type_name)
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
gql_greenfield_vm_type_name_from_sv(pTHX_ SV *type_sv)
{
  if (!type_sv || !SvOK(type_sv)) {
    return NULL;
  }
  if (SvROK(type_sv) && SvTYPE(SvRV(type_sv)) == SVt_PVHV) {
    HV *hv = (HV *)SvRV(type_sv);
    return gql_greenfield_vm_fetch_hash_entry_pv(aTHX_ hv, "name", 4);
  }
  return SvPOK(type_sv) ? SvPV_nolen(type_sv) : NULL;
}

static SV *
gql_greenfield_vm_clone_value_sv(pTHX_ SV *value)
{
  return newSVsv(value ? value : &PL_sv_undef);
}

static SV *
gql_greenfield_vm_resolve_field_value(pTHX_ gql_greenfield_vm_native_runtime_t *runtime, const gql_greenfield_vm_native_slot_t *slot, SV *source, SV *context)
{
  SV *resolver_sv;
  SV *return_type_sv;

  if (!runtime || slot->schema_slot_index < 0 || slot->schema_slot_index >= runtime->runtime_slot_count) {
    croak("native VM schema slot index %ld is invalid", (long)slot->schema_slot_index);
  }
  resolver_sv = runtime->slot_resolvers ? runtime->slot_resolvers[slot->schema_slot_index] : NULL;
  return_type_sv = runtime->slot_return_types ? runtime->slot_return_types[slot->schema_slot_index] : NULL;

  if (resolver_sv && SvOK(resolver_sv)) {
    SV *args = sv_2mortal(newRV_noinc((SV *)newHV()));
    return gql_greenfield_vm_call_cb4(aTHX_ resolver_sv, source, args, context, return_type_sv ? return_type_sv : &PL_sv_undef);
  }

  if (source && SvROK(source) && SvTYPE(SvRV(source)) == SVt_PVHV) {
    HV *source_hv = (HV *)SvRV(source);
    SV **value_svp = hv_fetch(source_hv, slot->field_name, (I32)strlen(slot->field_name), 0);
    return gql_greenfield_vm_clone_value_sv(aTHX_ (value_svp && SvOK(*value_svp)) ? *value_svp : &PL_sv_undef);
  }

  return newSVsv(&PL_sv_undef);
}

static SV *gql_greenfield_vm_execute_block_sv(pTHX_ gql_greenfield_vm_native_runtime_t *runtime, gql_greenfield_vm_native_bundle_t *bundle, IV block_index, SV *source, SV *context);

static SV *
gql_greenfield_vm_complete_abstract_sv(pTHX_ gql_greenfield_vm_native_runtime_t *runtime, const gql_greenfield_vm_native_slot_t *slot, const gql_greenfield_vm_native_op_t *op, gql_greenfield_vm_native_bundle_t *bundle, SV *value, SV *context)
{
  IV child_block_index = -1;
  IV slot_index;

  if (!runtime || !runtime->runtime_cache_hv || !runtime->name2type_hv) {
    return newSVsv(&PL_sv_undef);
  }
  slot_index = slot->schema_slot_index;
  if (slot_index < 0 || slot_index >= runtime->runtime_slot_count) {
    return newSVsv(&PL_sv_undef);
  }
  if (op->dispatch_family_code == GQL_VM_DISPATCH_TAG) {
    SV *tag_resolver = runtime->slot_tag_resolvers ? runtime->slot_tag_resolvers[slot_index] : NULL;
    SV *abstract_type = runtime->slot_abstract_types ? runtime->slot_abstract_types[slot_index] : NULL;
    SV *tag_sv;
    HV *tag_map_hv = runtime->slot_tag_maps ? runtime->slot_tag_maps[slot_index] : NULL;
    HE *type_he;
    const char *type_name = NULL;
    if (!tag_resolver || !tag_map_hv) {
      return newSVsv(&PL_sv_undef);
    }
    tag_sv = gql_greenfield_vm_call_cb4(aTHX_ tag_resolver, value, context, abstract_type ? abstract_type : &PL_sv_undef, &PL_sv_undef);
    type_he = hv_fetch_ent(tag_map_hv, tag_sv, 0, 0);
    type_name = (type_he && SvOK(HeVAL(type_he))) ? gql_greenfield_vm_type_name_from_sv(aTHX_ HeVAL(type_he)) : NULL;
    child_block_index = gql_greenfield_vm_find_abstract_child_block_index(op, type_name);
    SvREFCNT_dec(tag_sv);
  } else if (op->dispatch_family_code == GQL_VM_DISPATCH_RESOLVE_TYPE) {
    SV *resolve_type = runtime->slot_resolve_types ? runtime->slot_resolve_types[slot_index] : NULL;
    SV *abstract_type = runtime->slot_abstract_types ? runtime->slot_abstract_types[slot_index] : NULL;
    SV *type_sv;
    const char *type_name = NULL;
    if (!resolve_type) {
      return newSVsv(&PL_sv_undef);
    }
    type_sv = gql_greenfield_vm_call_cb4(aTHX_ resolve_type, value, context, &PL_sv_undef, abstract_type ? abstract_type : &PL_sv_undef);
    type_name = gql_greenfield_vm_type_name_from_sv(aTHX_ type_sv);
    child_block_index = gql_greenfield_vm_find_abstract_child_block_index(op, type_name);
    SvREFCNT_dec(type_sv);
  } else {
    AV *possible_types_av = runtime->slot_possible_types ? runtime->slot_possible_types[slot_index] : NULL;
    if (possible_types_av && runtime->is_type_of_map_hv) {
      IV i;
      for (i = 0; i < av_count(possible_types_av); i++) {
        SV **type_svp = av_fetch(possible_types_av, i, 0);
        SV *type_sv;
        const char *type_name;
        SV **cb_svp;
        SV *cb;
        SV *ok_sv;
        if (!type_svp || !SvOK(*type_svp)) {
          continue;
        }
        type_sv = *type_svp;
        type_name = gql_greenfield_vm_type_name_from_sv(aTHX_ type_sv);
        if (!type_name) {
          continue;
        }
        cb_svp = hv_fetch(runtime->is_type_of_map_hv, type_name, (I32)strlen(type_name), 0);
        cb = (cb_svp && SvOK(*cb_svp)) ? *cb_svp : NULL;
        if (!cb) {
          continue;
        }
        ok_sv = gql_greenfield_vm_call_cb4(aTHX_ cb, value, context, &PL_sv_undef, type_sv);
        if (SvTRUE(ok_sv)) {
          child_block_index = gql_greenfield_vm_find_abstract_child_block_index(op, type_name);
          SvREFCNT_dec(ok_sv);
          break;
        }
        SvREFCNT_dec(ok_sv);
      }
    }
  }

  if (child_block_index < 0) {
    return newSVsv(&PL_sv_undef);
  }
  return gql_greenfield_vm_execute_block_sv(aTHX_ runtime, bundle, child_block_index, value, context);
}

static SV *
gql_greenfield_vm_complete_value_sv(pTHX_ gql_greenfield_vm_native_runtime_t *runtime, const gql_greenfield_vm_native_slot_t *slot, const gql_greenfield_vm_native_op_t *op, gql_greenfield_vm_native_bundle_t *bundle, SV *value, SV *context)
{
  if (op->complete_code == GQL_VM_COMPLETE_OBJECT && op->child_block_index >= 0) {
    return gql_greenfield_vm_execute_block_sv(aTHX_ runtime, bundle, op->child_block_index, value, context);
  }
  if (op->complete_code == GQL_VM_COMPLETE_LIST) {
    AV *in_av;
    AV *out_av;
    IV i;
    if (!value || !SvOK(value)) {
      return newSVsv(&PL_sv_undef);
    }
    in_av = gql_greenfield_vm_expect_arrayref(aTHX_ value, "list value");
    out_av = newAV();
    av_extend(out_av, av_count(in_av) > 0 ? av_count(in_av) - 1 : 0);
    for (i = 0; i < av_count(in_av); i++) {
      SV **item_svp = av_fetch(in_av, i, 0);
      SV *item = (item_svp && SvOK(*item_svp)) ? *item_svp : &PL_sv_undef;
      SV *completed = (op->child_block_index >= 0)
        ? gql_greenfield_vm_execute_block_sv(aTHX_ runtime, bundle, op->child_block_index, item, context)
        : gql_greenfield_vm_clone_value_sv(aTHX_ item);
      av_store(out_av, i, completed);
    }
    return newRV_noinc((SV *)out_av);
  }
  if (op->complete_code == GQL_VM_COMPLETE_ABSTRACT) {
    return gql_greenfield_vm_complete_abstract_sv(aTHX_ runtime, slot, op, bundle, value, context);
  }
  return gql_greenfield_vm_clone_value_sv(aTHX_ value);
}

static SV *
gql_greenfield_vm_execute_block_sv(pTHX_ gql_greenfield_vm_native_runtime_t *runtime, gql_greenfield_vm_native_bundle_t *bundle, IV block_index, SV *source, SV *context)
{
  gql_greenfield_vm_native_block_t *block;
  HV *data_hv;
  IV i;

  if (!bundle || block_index < 0 || block_index >= bundle->block_count) {
    croak("native VM block index %ld is invalid", (long)block_index);
  }

  block = &bundle->blocks[block_index];
  data_hv = newHV();

  for (i = 0; i < block->op_count; i++) {
    gql_greenfield_vm_native_op_t *op = &block->ops[i];
    gql_greenfield_vm_native_slot_t *slot;
    SV *resolved;
    SV *completed;

    if (op->slot_index < 0 || op->slot_index >= block->slot_count) {
      croak("native VM op slot_index %ld is invalid in block %ld", (long)op->slot_index, (long)block_index);
    }
    slot = &block->slots[op->slot_index];

    resolved = gql_greenfield_vm_resolve_field_value(aTHX_ runtime, slot, source, context);
    completed = gql_greenfield_vm_complete_value_sv(aTHX_ runtime, slot, op, bundle, resolved, context);
    SvREFCNT_dec(resolved);
    hv_store(data_hv, slot->result_name, (I32)strlen(slot->result_name), completed, 0);
  }

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
graphqljs_preprocess_xs(source)
    SV *source
  CODE:
    RETVAL = gql_graphqljs_preprocess(aTHX_ source);
  OUTPUT:
    RETVAL

SV *
graphqljs_parse_document_xs(source, no_location = &PL_sv_undef, lazy_location = &PL_sv_undef, compact_location = &PL_sv_undef)
    SV *source
    SV *no_location
    SV *lazy_location
    SV *compact_location
  CODE:
    RETVAL = gql_graphqljs_parse_document(aTHX_ source, no_location, lazy_location, compact_location);
  OUTPUT:
    RETVAL

SV *
graphqljs_parse_executable_document_xs(source, no_location = &PL_sv_undef, lazy_location = &PL_sv_undef, compact_location = &PL_sv_undef)
    SV *source
    SV *no_location
    SV *lazy_location
    SV *compact_location
  CODE:
    RETVAL = gql_graphqljs_parse_executable_document(aTHX_ source, no_location, lazy_location, compact_location);
  OUTPUT:
    RETVAL

SV *
_graphqljs_materialize_arguments_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gqljs_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_ARGUMENTS
      ));
    }
  OUTPUT:
    RETVAL

SV *
_graphqljs_materialize_directives_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gqljs_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_DIRECTIVES
      ));
    }
  OUTPUT:
    RETVAL

SV *
_graphqljs_materialize_variable_definitions_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gqljs_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_VARIABLE_DEFINITIONS
      ));
    }
  OUTPUT:
    RETVAL

SV *
_graphqljs_materialize_object_fields_xs(state, ptr)
    SV *state
    UV ptr
  CODE:
    {
      RETVAL = newRV_noinc((SV *)gqljs_materialize_lazy_array(
        aTHX_ state,
        ptr,
        GQLJS_LAZY_ARRAY_OBJECT_FIELDS
      ));
    }
  OUTPUT:
    RETVAL

SV *
parse_directives_xs(source)
    SV *source
  CODE:
    RETVAL = gql_parse_directives_only(aTHX_ source);
  OUTPUT:
    RETVAL

SV *
graphqljs_build_directives_xs(source)
    SV *source
  CODE:
    RETVAL = gql_graphqljs_build_directives_from_source(aTHX_ source);
  OUTPUT:
    RETVAL

SV *
tokenize_xs(source)
    SV *source
  CODE:
    RETVAL = gql_tokenize_source(aTHX_ source);
  OUTPUT:
    RETVAL

SV *
graphqlperl_find_legacy_empty_object_location_xs(source)
    SV *source
  CODE:
    RETVAL = gql_graphqlperl_find_legacy_empty_object_location(aTHX_ source);
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
        gqljs_lazy_state_t *state = INT2PTR(gqljs_lazy_state_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gqljs_lazy_state_destroy(state);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Parser

SV *
graphqljs_patch_document_xs(doc, meta)
    SV *doc
    SV *meta
  CODE:
    RETVAL = gql_graphqljs_patch_document(aTHX_ doc, meta);
  OUTPUT:
    RETVAL

SV *
graphqljs_build_executable_document_xs(legacy)
    SV *legacy
  CODE:
    RETVAL = gql_graphqljs_build_executable_document(aTHX_ legacy);
  OUTPUT:
    RETVAL

SV *
graphqljs_build_document_xs(legacy)
    SV *legacy
  CODE:
    RETVAL = gql_graphqljs_build_document(aTHX_ legacy);
  OUTPUT:
    RETVAL

SV *
graphqlperl_build_document_xs(doc)
    SV *doc
  CODE:
    RETVAL = gql_graphqlperl_build_document(aTHX_ doc);
  OUTPUT:
    RETVAL

SV *
graphqljs_apply_executable_loc_xs(doc, source)
    SV *doc
    SV *source
  CODE:
    RETVAL = gql_graphqljs_apply_executable_loc(aTHX_ doc, source);
  OUTPUT:
    RETVAL

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

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Execution

SV *
_prepare_executable_ir_xs(source)
    SV *source
  CODE:
    RETVAL = gql_ir_prepare_executable_handle_sv(aTHX_ source);
  OUTPUT:
    RETVAL

SV *
_compile_executable_ir_plan_xs(schema, handle, operation_name = NULL)
    SV *schema
    SV *handle
    SV *operation_name
  CODE:
    RETVAL = gql_ir_compile_executable_plan_handle_sv(aTHX_ schema, handle, operation_name);
  OUTPUT:
    RETVAL

SV *
_compiled_executable_ir_plan_xs(handle)
    SV *handle
  CODE:
    if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::CompiledIR")) {
      croak("expected a GraphQL::Houtou::XS::CompiledIR handle");
    }
    {
      SV *inner_sv = SvRV(handle);
      gql_ir_compiled_exec_t *compiled;

      if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
        croak("compiled IR handle is no longer valid");
      }

      compiled = INT2PTR(gql_ir_compiled_exec_t *, SvUV(inner_sv));
      RETVAL = gql_ir_compiled_plan_to_hv_sv(aTHX_ compiled);
    }
  OUTPUT:
    RETVAL

SV *
_prepared_executable_ir_stats_xs(handle)
    SV *handle
  CODE:
    if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::PreparedIR")) {
      croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
    }
    {
      SV *inner_sv = SvRV(handle);
      gql_ir_prepared_exec_t *prepared;

      if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
        croak("prepared IR handle is no longer valid");
      }

      prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
      RETVAL = newRV_noinc((SV *)gql_ir_prepare_executable_stats_hv(aTHX_ prepared));
    }
  OUTPUT:
    RETVAL

SV *
_prepared_executable_ir_plan_xs(handle, operation_name = NULL)
    SV *handle
    SV *operation_name
  CODE:
    if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::PreparedIR")) {
      croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
    }
    {
      SV *inner_sv = SvRV(handle);
      gql_ir_prepared_exec_t *prepared;

      if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
        croak("prepared IR handle is no longer valid");
      }

      prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
      RETVAL = newRV_noinc((SV *)gql_ir_prepare_executable_plan_hv(aTHX_ prepared, operation_name));
    }
  OUTPUT:
    RETVAL

SV *
_prepared_executable_ir_frontend_xs(handle, operation_name = NULL)
    SV *handle
    SV *operation_name
  CODE:
    if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::PreparedIR")) {
      croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
    }
    {
      SV *inner_sv = SvRV(handle);
      gql_ir_prepared_exec_t *prepared;

      if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
        croak("prepared IR handle is no longer valid");
      }

      prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
      RETVAL = newRV_noinc((SV *)gql_ir_prepare_executable_frontend_hv(aTHX_ prepared, operation_name));
    }
  OUTPUT:
    RETVAL

SV *
_prepared_executable_ir_context_seed_xs(schema, handle, operation_name = NULL, variable_values = NULL)
    SV *schema
    SV *handle
    SV *operation_name
    SV *variable_values
  CODE:
    if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::PreparedIR")) {
      croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
    }
    {
      SV *inner_sv = SvRV(handle);
      gql_ir_prepared_exec_t *prepared;

      if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
        croak("prepared IR handle is no longer valid");
      }

      prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
      RETVAL = newRV_noinc((SV *)gql_ir_prepare_executable_context_seed_hv(
        aTHX_ schema,
        prepared,
        operation_name,
        variable_values
      ));
    }
  OUTPUT:
    RETVAL

SV *
_prepared_executable_ir_operation_legacy_xs(handle, operation_name = NULL)
    SV *handle
    SV *operation_name
  CODE:
    if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::PreparedIR")) {
      croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
    }
    {
      SV *inner_sv = SvRV(handle);
      gql_ir_prepared_exec_t *prepared;
      gql_ir_operation_definition_t *selected;

      if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
        croak("prepared IR handle is no longer valid");
      }

      prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
      selected = gql_ir_prepare_select_operation(aTHX_ prepared, operation_name);
      RETVAL = gql_ir_operation_to_legacy_sv(aTHX_ prepared, selected, operation_name);
    }
  OUTPUT:
    RETVAL

SV *
_prepared_executable_ir_root_selection_plan_xs(handle, operation_name = NULL)
    SV *handle
    SV *operation_name
  CODE:
    if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::PreparedIR")) {
      croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
    }
    {
      SV *inner_sv = SvRV(handle);
      gql_ir_prepared_exec_t *prepared;

      if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
        croak("prepared IR handle is no longer valid");
      }

      prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
      RETVAL = newRV_noinc((SV *)gql_ir_prepare_executable_root_selection_plan_av(
        aTHX_ prepared,
        operation_name
      ));
    }
  OUTPUT:
    RETVAL

SV *
_prepared_executable_ir_root_field_buckets_xs(schema, handle, operation_name = NULL)
    SV *schema
    SV *handle
    SV *operation_name
  CODE:
    if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::PreparedIR")) {
      croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
    }
    {
      SV *inner_sv = SvRV(handle);
      gql_ir_prepared_exec_t *prepared;

      if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
        croak("prepared IR handle is no longer valid");
      }

      prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
      RETVAL = newRV_noinc((SV *)gql_ir_prepare_executable_root_field_buckets_hv(
        aTHX_ schema,
        prepared,
        operation_name
      ));
    }
  OUTPUT:
    RETVAL

SV *
_prepared_executable_ir_root_field_plan_xs(schema, handle, operation_name = NULL)
    SV *schema
    SV *handle
    SV *operation_name
  CODE:
    if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::PreparedIR")) {
      croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
    }
    {
      SV *inner_sv = SvRV(handle);
      gql_ir_prepared_exec_t *prepared;

      if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
        croak("prepared IR handle is no longer valid");
      }

      prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
      RETVAL = newRV_noinc((SV *)gql_ir_prepare_executable_root_field_plan_hv(
        aTHX_ schema,
        prepared,
        operation_name
      ));
    }
  OUTPUT:
    RETVAL

SV *
_prepared_executable_ir_root_legacy_fields_xs(schema, handle, operation_name = NULL)
    SV *schema
    SV *handle
    SV *operation_name
  CODE:
    if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::PreparedIR")) {
      croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
    }
    {
      SV *inner_sv = SvRV(handle);
      gql_ir_prepared_exec_t *prepared;

      if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
        croak("prepared IR handle is no longer valid");
      }

      prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
      RETVAL = gql_ir_prepare_executable_root_legacy_fields_sv(
        aTHX_ schema,
        prepared,
        operation_name
      );
    }
  OUTPUT:
    RETVAL

SV *
_prepared_executable_ir_execution_context_xs(schema, handle, root_value = NULL, context_value = NULL, variable_values = NULL, operation_name = NULL, field_resolver = NULL, promise_code = NULL)
    SV *schema
    SV *handle
    SV *root_value
    SV *context_value
    SV *variable_values
    SV *operation_name
    SV *field_resolver
    SV *promise_code
  CODE:
    if (!handle || !SvROK(handle) || !sv_derived_from(handle, "GraphQL::Houtou::XS::PreparedIR")) {
      croak("expected a GraphQL::Houtou::XS::PreparedIR handle");
    }
    {
      SV *inner_sv = SvRV(handle);
      gql_ir_prepared_exec_t *prepared;

      if (!SvIOK(inner_sv) || SvUV(inner_sv) == 0) {
        croak("prepared IR handle is no longer valid");
      }

      prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
      RETVAL = gql_ir_build_execution_context_sv(
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
    }
  OUTPUT:
    RETVAL

SV *
_execute_prepared_ir_xs(schema, handle, root_value = NULL, context_value = NULL, variable_values = NULL, operation_name = NULL, field_resolver = NULL, promise_code = NULL)
    SV *schema
    SV *handle
    SV *root_value
    SV *context_value
    SV *variable_values
    SV *operation_name
    SV *field_resolver
    SV *promise_code
  CODE:
    RETVAL = gql_execution_execute_prepared_ir_xs_impl(
      aTHX_
      schema,
      handle,
      root_value,
      context_value,
      variable_values,
      operation_name,
      field_resolver,
      promise_code
    );
  OUTPUT:
    RETVAL

SV *
_execute_compiled_ir_xs(handle, root_value = NULL, context_value = NULL, variable_values = NULL, field_resolver = NULL, promise_code = NULL)
    SV *handle
    SV *root_value
    SV *context_value
    SV *variable_values
    SV *field_resolver
    SV *promise_code
  CODE:
    RETVAL = gql_execution_execute_compiled_ir_xs_impl(
      aTHX_
      handle,
      root_value,
      context_value,
      variable_values,
      field_resolver,
      promise_code
    );
  OUTPUT:
    RETVAL

SV *
_execute_xs_raw(schema, document, root_value = NULL, context_value = NULL, variable_values = NULL, operation_name = NULL, field_resolver = NULL, promise_code = NULL)
    SV *schema
    SV *document
    SV *root_value
    SV *context_value
    SV *variable_values
    SV *operation_name
    SV *field_resolver
    SV *promise_code
  CODE:
    RETVAL = gql_execution_execute(
      aTHX_ schema,
      document,
      root_value,
      context_value,
      variable_values,
      operation_name,
      field_resolver,
      promise_code
    );
  OUTPUT:
    RETVAL

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::PreparedIR

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_ir_prepared_exec_t *prepared = INT2PTR(gql_ir_prepared_exec_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_ir_prepared_exec_destroy(prepared);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::CompiledIR

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_ir_compiled_exec_t *compiled = INT2PTR(gql_ir_compiled_exec_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_ir_compiled_exec_destroy(compiled);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Execution

SV *
_execute_fields_xs(context, parent_type, root_value, path, fields)
    SV *context
    SV *parent_type
    SV *root_value
    SV *path
    SV *fields
  CODE:
    RETVAL = gql_execution_execute_fields(aTHX_ context, parent_type, root_value, path, fields);
  OUTPUT:
    RETVAL

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::GreenfieldVM

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
      gql_greenfield_vm_native_bundle_t *bundle =
        gql_greenfield_vm_native_bundle_from_sv(aTHX_ descriptor);
      SV *inner = newSVuv(PTR2UV(bundle));
      RETVAL = newRV_noinc(inner);
      sv_bless(RETVAL, gv_stashpv("GraphQL::Houtou::XS::GreenfieldVM::NativeBundle", GV_ADD));
    }
  OUTPUT:
    RETVAL

SV *
native_bundle_summary_xs(bundle_sv)
    SV *bundle_sv
  CODE:
    {
      gql_greenfield_vm_native_bundle_t *bundle;
      HV *hv;
      AV *dispatch_codes;
      IV i;

      if (!bundle_sv || !SvROK(bundle_sv) || !sv_derived_from(bundle_sv, "GraphQL::Houtou::XS::GreenfieldVM::NativeBundle")) {
        croak("expected a GraphQL::Houtou::XS::GreenfieldVM::NativeBundle");
      }
      bundle = INT2PTR(gql_greenfield_vm_native_bundle_t *, SvUV(SvRV(bundle_sv)));
      if (!bundle) {
        croak("native VM bundle handle is no longer valid");
      }

      hv = newHV();
      hv_store(hv, "runtime_slot_count", 18, newSViv(bundle->runtime_slot_count), 0);
      hv_store(hv, "block_count", 11, newSViv(bundle->block_count), 0);
      hv_store(hv, "root_block_index", 16, newSViv(bundle->root_block_index), 0);
      hv_store(hv, "operation_type_code", 19, newSViv(bundle->operation_type_code), 0);

      if (bundle->root_block_index >= 0 && bundle->root_block_index < bundle->block_count) {
        gql_greenfield_vm_native_block_t *root = &bundle->blocks[bundle->root_block_index];
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
load_native_runtime_xs(runtime_schema)
    SV *runtime_schema
  CODE:
    {
      gql_greenfield_vm_native_runtime_t *runtime =
        gql_greenfield_vm_native_runtime_from_runtime_schema_sv(aTHX_ runtime_schema);
      SV *inner = newSVuv(PTR2UV(runtime));
      RETVAL = newRV_noinc(inner);
      sv_bless(RETVAL, gv_stashpv("GraphQL::Houtou::XS::GreenfieldVM::NativeRuntime", GV_ADD));
    }
  OUTPUT:
    RETVAL

SV *
native_runtime_summary_xs(runtime_sv)
    SV *runtime_sv
  CODE:
    {
      gql_greenfield_vm_native_runtime_t *runtime;
      HV *hv;

      if (!runtime_sv || !SvROK(runtime_sv) || !sv_derived_from(runtime_sv, "GraphQL::Houtou::XS::GreenfieldVM::NativeRuntime")) {
        croak("expected a GraphQL::Houtou::XS::GreenfieldVM::NativeRuntime");
      }
      runtime = INT2PTR(gql_greenfield_vm_native_runtime_t *, SvUV(SvRV(runtime_sv)));
      if (!runtime) {
        croak("native VM runtime handle is no longer valid");
      }

      hv = newHV();
      hv_store(hv, "runtime_slot_count", 18, newSViv(runtime->runtime_slot_count), 0);
      hv_store(hv, "has_runtime_cache", 17, newSViv(runtime->runtime_cache_hv ? 1 : 0), 0);
      hv_store(hv, "has_name2type", 13, newSViv(runtime->name2type_hv ? 1 : 0), 0);
      hv_store(hv, "has_dispatch_index", 18, newSViv(runtime->dispatch_index_hv ? 1 : 0), 0);
      RETVAL = newRV_noinc((SV *)hv);
    }
  OUTPUT:
    RETVAL

SV *
execute_native_bundle_xs(runtime_schema, bundle_sv, root_value = &PL_sv_undef, context_value = &PL_sv_undef)
    SV *runtime_schema
    SV *bundle_sv
    SV *root_value
    SV *context_value
  CODE:
    {
      gql_greenfield_vm_native_bundle_t *bundle;
      gql_greenfield_vm_native_runtime_t *runtime = NULL;
      int owns_runtime = 0;
      HV *hv;
      AV *errors;
      SV *data_sv;

      if (!bundle_sv || !SvROK(bundle_sv) || !sv_derived_from(bundle_sv, "GraphQL::Houtou::XS::GreenfieldVM::NativeBundle")) {
        croak("expected a GraphQL::Houtou::XS::GreenfieldVM::NativeBundle");
      }
      bundle = INT2PTR(gql_greenfield_vm_native_bundle_t *, SvUV(SvRV(bundle_sv)));
      if (!bundle) {
        croak("native VM bundle handle is no longer valid");
      }

      if (runtime_schema && SvROK(runtime_schema) && sv_derived_from(runtime_schema, "GraphQL::Houtou::XS::GreenfieldVM::NativeRuntime")) {
        runtime = INT2PTR(gql_greenfield_vm_native_runtime_t *, SvUV(SvRV(runtime_schema)));
        if (!runtime) {
          croak("native VM runtime handle is no longer valid");
        }
      } else {
        runtime = gql_greenfield_vm_native_runtime_from_runtime_schema_sv(aTHX_ runtime_schema);
        owns_runtime = 1;
      }

      data_sv = gql_greenfield_vm_execute_block_sv(
        aTHX_
        runtime,
        bundle,
        bundle->root_block_index,
        root_value,
        context_value
      );

      hv = newHV();
      hv_store(hv, "data", 4, data_sv, 0);
      errors = newAV();
      hv_store(hv, "errors", 6, newRV_noinc((SV *)errors), 0);
      RETVAL = newRV_noinc((SV *)hv);

      if (owns_runtime) {
        gql_greenfield_vm_native_runtime_destroy(runtime);
      }
    }
  OUTPUT:
    RETVAL

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::GreenfieldVM::NativeBundle

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_greenfield_vm_native_bundle_t *bundle =
          INT2PTR(gql_greenfield_vm_native_bundle_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_greenfield_vm_native_bundle_destroy(bundle);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::GreenfieldVM::NativeRuntime

void
DESTROY(self)
    SV *self
  CODE:
    if (self && SvROK(self)) {
      SV *inner_sv = SvRV(self);
      if (SvIOK(inner_sv) && SvUV(inner_sv) != 0) {
        gql_greenfield_vm_native_runtime_t *runtime =
          INT2PTR(gql_greenfield_vm_native_runtime_t *, SvUV(inner_sv));
        sv_setuv(inner_sv, 0);
        gql_greenfield_vm_native_runtime_destroy(runtime);
      }
    }

MODULE = GraphQL::Houtou    PACKAGE = GraphQL::Houtou::XS::Execution

SV *
_collect_fields_xs(context, parent_type, selections)
    SV *context
    SV *parent_type
    SV *selections
  CODE:
    RETVAL = gql_execution_collect_fields_xs(aTHX_ context, parent_type, selections);
  OUTPUT:
    RETVAL

SV *
_get_argument_values_xs(def, node, variable_values = NULL)
    SV *def
    SV *node
    SV *variable_values
  CODE:
    RETVAL = gql_execution_get_argument_values_xs_impl(aTHX_ def, node, variable_values);
  OUTPUT:
    RETVAL

SV *
_complete_value_catching_error_xs(context, return_type, nodes, info, path, result)
    SV *context
    SV *return_type
    SV *nodes
    SV *info
    SV *path
    SV *result
  CODE:
    RETVAL = gql_execution_complete_value_catching_error_xs_impl(
      aTHX_ context,
      return_type,
      nodes,
      info,
      path,
      result
    );
  OUTPUT:
    RETVAL

SV *
_promise_is_promise_xs(promise_code, value)
    SV *promise_code
    SV *value
  CODE:
    RETVAL = gql_promise_call_is_promise(aTHX_ promise_code, value);
  OUTPUT:
    RETVAL

SV *
_promise_all_xs(promise_code, values)
    SV *promise_code
    SV *values
  CODE:
    if (!SvROK(values) || SvTYPE(SvRV(values)) != SVt_PVAV) {
      croak("values must be an array reference");
    }
    RETVAL = gql_promise_call_all(aTHX_ promise_code, (AV *)SvRV(values));
  OUTPUT:
    RETVAL

SV *
_promise_then_xs(promise_code, promise, on_fulfilled, on_rejected = NULL)
    SV *promise_code
    SV *promise
    SV *on_fulfilled
    SV *on_rejected
  CODE:
    RETVAL = gql_promise_call_then(aTHX_ promise_code, promise, on_fulfilled, on_rejected);
  OUTPUT:
    RETVAL

SV *
_promise_resolve_xs(promise_code, value)
    SV *promise_code
    SV *value
  CODE:
    RETVAL = gql_promise_call_resolve(aTHX_ promise_code, value);
  OUTPUT:
    RETVAL

SV *
_promise_reject_xs(promise_code, value)
    SV *promise_code
    SV *value
  CODE:
    RETVAL = gql_promise_call_reject(aTHX_ promise_code, value);
  OUTPUT:
    RETVAL

SV *
_merge_completed_list_xs(list)
    SV *list
  CODE:
    if (!SvROK(list) || SvTYPE(SvRV(list)) != SVt_PVAV) {
      croak("list must be an array reference");
    }
    RETVAL = gql_execution_merge_completed_list(aTHX_ (AV *)SvRV(list));
  OUTPUT:
    RETVAL

SV *
_merge_completed_list_with_head_xs(head_data, indexes, values, errors)
    SV *head_data
    SV *indexes
    SV *values
    SV *errors
  CODE:
    if (!SvROK(head_data) || SvTYPE(SvRV(head_data)) != SVt_PVAV) {
      croak("head_data must be an array reference");
    }
    if (!SvROK(indexes) || SvTYPE(SvRV(indexes)) != SVt_PVAV) {
      croak("indexes must be an array reference");
    }
    if (!SvROK(values) || SvTYPE(SvRV(values)) != SVt_PVAV) {
      croak("values must be an array reference");
    }
    if (!SvROK(errors) || SvTYPE(SvRV(errors)) != SVt_PVAV) {
      croak("errors must be an array reference");
    }
    RETVAL = gql_execution_merge_completed_list_with_head(
      aTHX_
      (AV *)SvRV(head_data),
      (AV *)SvRV(indexes),
      (AV *)SvRV(values),
      (AV *)SvRV(errors)
    );
  OUTPUT:
    RETVAL

SV *
_merge_hash_xs(keys, values, errors)
    SV *keys
    SV *values
    SV *errors
  CODE:
    if (!SvROK(keys) || SvTYPE(SvRV(keys)) != SVt_PVAV) {
      croak("keys must be an array reference");
    }
    if (!SvROK(values) || SvTYPE(SvRV(values)) != SVt_PVAV) {
      croak("values must be an array reference");
    }
    if (!SvROK(errors) || SvTYPE(SvRV(errors)) != SVt_PVAV) {
      croak("errors must be an array reference");
    }
    RETVAL = gql_execution_merge_hash(aTHX_ (AV *)SvRV(keys), (AV *)SvRV(values), (AV *)SvRV(errors));
  OUTPUT:
    RETVAL

SV *
_merge_hash_with_head_xs(head_data, keys, values, errors)
    SV *head_data
    SV *keys
    SV *values
    SV *errors
  CODE:
    if (!SvROK(head_data) || SvTYPE(SvRV(head_data)) != SVt_PVHV) {
      croak("head_data must be a hash reference");
    }
    if (!SvROK(keys) || SvTYPE(SvRV(keys)) != SVt_PVAV) {
      croak("keys must be an array reference");
    }
    if (!SvROK(values) || SvTYPE(SvRV(values)) != SVt_PVAV) {
      croak("values must be an array reference");
    }
    if (!SvROK(errors) || SvTYPE(SvRV(errors)) != SVt_PVAV) {
      croak("errors must be an array reference");
    }
    RETVAL = gql_execution_merge_hash_with_head(
      aTHX_
      (HV *)SvRV(head_data),
      (AV *)SvRV(keys),
      (AV *)SvRV(values),
      (AV *)SvRV(errors)
    );
  OUTPUT:
    RETVAL

SV *
_build_response_xs(result, force_data = 0)
    SV *result
    int force_data
  CODE:
    RETVAL = gql_execution_build_response_xs(aTHX_ result, force_data);
  OUTPUT:
    RETVAL

SV *
_wrap_error_xs(error)
    SV *error
  CODE:
    RETVAL = gql_execution_wrap_error_xs(aTHX_ error);
  OUTPUT:
    RETVAL

SV *
_located_error_xs(error, nodes, path)
    SV *error
    SV *nodes
    SV *path
  CODE:
    RETVAL = gql_execution_located_error_xs(aTHX_ error, nodes, path);
  OUTPUT:
    RETVAL
