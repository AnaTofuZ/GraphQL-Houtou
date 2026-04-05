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
gql_execution_execute(pTHX_ SV *schema, SV *document, SV *root_value, SV *context_value, SV *variable_values, SV *operation_name, SV *field_resolver, SV *promise_code) {
  dSP;
  int count;
  SV *ret;

  gql_execution_require_pp(aTHX);

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(schema)));
  XPUSHs(sv_2mortal(newSVsv(document)));
  XPUSHs(sv_2mortal(root_value ? newSVsv(root_value) : newSV(0)));
  XPUSHs(sv_2mortal(context_value ? newSVsv(context_value) : newSV(0)));
  XPUSHs(sv_2mortal(variable_values ? newSVsv(variable_values) : newSV(0)));
  XPUSHs(sv_2mortal(operation_name ? newSVsv(operation_name) : newSV(0)));
  XPUSHs(sv_2mortal(field_resolver ? newSVsv(field_resolver) : newSV(0)));
  XPUSHs(sv_2mortal(promise_code ? newSVsv(promise_code) : newSV(0)));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::Execution::PP::execute", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::Execution::PP::execute did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}
