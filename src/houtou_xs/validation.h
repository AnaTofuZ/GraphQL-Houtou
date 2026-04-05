/*
 * Responsibility: provide the initial XS validation entrypoint so the public
 * validation facade can route through XS while rule implementations migrate
 * from PP to C incrementally.
 */

static void
gql_validation_require_pp(pTHX) {
  eval_pv("require GraphQL::Houtou::Validation::PP; 1;", TRUE);
}

static SV *
gql_validation_validate(pTHX_ SV *schema, SV *document, SV *options) {
  dSP;
  int count;
  SV *ret;

  gql_validation_require_pp(aTHX);

  ENTER;
  SAVETMPS;
  PUSHMARK(SP);
  XPUSHs(sv_2mortal(newSVsv(schema)));
  XPUSHs(sv_2mortal(newSVsv(document)));
  XPUSHs(sv_2mortal(options ? newSVsv(options) : newSV(0)));
  PUTBACK;

  count = call_pv("GraphQL::Houtou::Validation::PP::validate", G_SCALAR);
  SPAGAIN;
  if (count != 1) {
    PUTBACK;
    FREETMPS;
    LEAVE;
    croak("GraphQL::Houtou::Validation::PP::validate did not return a scalar");
  }

  ret = newSVsv(POPs);
  PUTBACK;
  FREETMPS;
  LEAVE;

  return ret;
}
