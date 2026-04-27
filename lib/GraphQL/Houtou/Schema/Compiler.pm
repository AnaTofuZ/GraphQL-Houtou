package GraphQL::Houtou::Schema::Compiler;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use Scalar::Util qw(blessed);
use GraphQL::Houtou ();

our @EXPORT_OK = qw(
  compile_schema
);

sub compile_schema {
  my ($schema) = @_;

  die "compile_schema expects a GraphQL::Houtou::Schema or GraphQL::Schema instance\n"
    if !blessed($schema)
    || (!$schema->isa('GraphQL::Houtou::Schema') && !$schema->isa('GraphQL::Schema'));

  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::SchemaCompiler::compile_schema_xs($schema);
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
The current mainline requires the XS compiler and does not keep a pure-Perl
fallback in the active runtime path.

=cut
