package GraphQL::Houtou::Validation;

use 5.014;
use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
  validate
);

sub validate {
  require GraphQL::Houtou::Validation::PP;
  return GraphQL::Houtou::Validation::PP::validate(@_);
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

This module is the public entry point for GraphQL validation.
It currently delegates to the pure-Perl implementation while the
validation ruleset and normalized error shape are stabilized.

=cut
