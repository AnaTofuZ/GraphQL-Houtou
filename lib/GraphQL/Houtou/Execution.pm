package GraphQL::Houtou::Execution;

use 5.014;
use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
  execute
);

my $HAS_XS;

sub execute {
  if (@_ >= 8 && defined $_[7]) {
    require GraphQL::Houtou::Execution::PP;
    return GraphQL::Houtou::Execution::PP::execute(@_);
  }

  if (!defined $HAS_XS) {
    $HAS_XS = eval {
      require GraphQL::Houtou::XS::Execution;
      1;
    } ? 1 : 0;
  }

  if ($HAS_XS) {
    return GraphQL::Houtou::XS::Execution::execute_xs(@_);
  }

  require GraphQL::Houtou::Execution::PP;
  return GraphQL::Houtou::Execution::PP::execute(@_);
}

1;

__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou::Execution - GraphQL execution facade

=head1 SYNOPSIS

    use GraphQL::Houtou::Execution qw(execute);

    my $result = execute($schema, '{ hello }', $root_value);

=head1 DESCRIPTION

This module is the public entry point for GraphQL execution.
It prefers an XS implementation when available and otherwise falls back
to the pure-Perl executor.

=cut
