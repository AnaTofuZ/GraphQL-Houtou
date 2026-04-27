package GraphQL::Houtou::Execution;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou ();

our @EXPORT_OK = qw(
  execute
);

sub execute {
  return GraphQL::Houtou::execute(@_);
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

This module is a compatibility facade for the older execution entry point.
Its implementation now delegates to the runtime-backed
L<GraphQL::Houtou/Executing Queries> API so that old call sites follow the
same mainline runtime path as the newer top-level interface.

=cut
