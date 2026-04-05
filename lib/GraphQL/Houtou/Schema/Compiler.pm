package GraphQL::Houtou::Schema::Compiler;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use Scalar::Util qw(blessed);

our @EXPORT_OK = qw(
  compile_schema
);

my $HAS_XS;

sub compile_schema {
  my ($schema) = @_;

  die "compile_schema expects a GraphQL::Schema instance\n"
    if !blessed($schema) || !$schema->isa('GraphQL::Schema');

  if (!defined $HAS_XS) {
    $HAS_XS = eval {
      require GraphQL::Houtou::XS::SchemaCompiler;
      1;
    } ? 1 : 0;
  }

  return GraphQL::Houtou::XS::SchemaCompiler::compile_schema_xs($schema)
    if $HAS_XS;

  require GraphQL::Houtou::Schema::Compiler::PP;
  return GraphQL::Houtou::Schema::Compiler::PP::compile_schema($schema);
}

1;

__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou::Schema::Compiler - Compile graphql-perl schema objects into a normalized internal form

=head1 SYNOPSIS

    use GraphQL::Houtou::Schema::Compiler qw(compile_schema);

    my $compiled = compile_schema($schema);

=head1 DESCRIPTION

This module is the public facade for schema compilation.
It prefers the XS implementation when available and falls back to the
pure-Perl implementation otherwise.

The returned structure is intentionally shared between the XS and PP
implementations so it can act as a stable boundary for future execution
and validation work.

=cut
