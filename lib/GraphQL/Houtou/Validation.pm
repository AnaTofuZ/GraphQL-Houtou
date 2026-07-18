package GraphQL::Houtou::Validation;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou ();

our @EXPORT_OK = qw(validate);

sub validate {
  my ($schema, $source_or_ast, @rest) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  # Loading the parser module installs the boolean/string factories used by
  # the validation parser. The source itself is still parsed exactly once,
  # inside validate_xs, so parser-time duplicate diagnostics are preserved.
  require GraphQL::Houtou::XS::Parser if !ref($source_or_ast);
  return GraphQL::Houtou::XS::Validation::validate_xs(
    $schema, $source_or_ast, @rest,
  );
}

1;

__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou::Validation - GraphQL document validation facade

=head1 SYNOPSIS

    use GraphQL::Houtou::Validation qw(validate);

    my $errors = validate($schema, $source_or_ast);

=head1 DESCRIPTION

This module is the public entry point for GraphQL validation. Validation is
implemented by the shared XS bundle; there is no Pure Perl validation pass.

=cut
