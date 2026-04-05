package GraphQL::Houtou;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Houtou::GraphQLJS::Parser ();
use GraphQL::Houtou::GraphQLPerl::Parser ();
use GraphQL::Houtou::Promise::Adapter qw(
  set_default_promise_code
  get_default_promise_code
  clear_default_promise_code
);

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  parse
  parse_with_options
  set_default_promise_code
  get_default_promise_code
  clear_default_promise_code
);

sub parse {
  return GraphQL::Houtou::GraphQLPerl::Parser::parse(@_);
}

sub parse_with_options {
  my ($source, $options) = @_;
  $options ||= {};
  my $dialect = $options->{dialect} || 'graphql-perl';

  if ($dialect eq 'graphql-perl') {
    return GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, $options);
  }
  if ($dialect eq 'graphql-js') {
    return GraphQL::Houtou::GraphQLJS::Parser::parse($source, $options);
  }

  die "Unknown parser dialect '$dialect'.\n";
}

1;
__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou - XS recursive-descent GraphQL parser toolkit for Perl

=head1 SYNOPSIS

    use GraphQL::Houtou qw(parse parse_with_options);

    my $legacy_ast = parse('{ user { id } }');

    my $js_ast = parse_with_options('{ user { id } }', {
      dialect => 'graphql-js',
      backend => 'xs',
    });

    my $legacy_xs_ast = parse_with_options('{ user { id } }', {
      dialect => 'graphql-perl',
      backend => 'xs',
    });

    my $fast_js_ast = parse_with_options('{ user { id } }', {
      dialect => 'graphql-js',
      backend => 'xs',
      no_location => 1,
    });

=head1 DESCRIPTION

GraphQL::Houtou provides an XS recursive-descent GraphQL parser plus
compatibility layers for both the legacy C<graphql-perl> AST and a
C<graphql-js>-style AST.

This distribution was split out from local parser work that originally lived
in a fork of L<graphql-perl|https://github.com/graphql-perl/graphql-perl>.
It still uses the upstream C<GraphQL> distribution as a dependency for some
compatibility behavior, while making the XS parser path the normal fast path.

=head1 DIALECTS AND USAGE

=head2 graphql-perl compatible layer

The default C<parse()> entry point returns the traditional C<graphql-perl>
compatible AST.

    my $ast = parse($source);

If you want to be explicit about the backend, use C<parse_with_options()>.

    my $ast = parse_with_options($source, {
      dialect => 'graphql-perl',
      backend => 'xs',
    });

The C<pegex> backend is still available for compatibility, but the intended
default path is C<xs>.

=head2 graphql-js compatible layer

If you want a C<graphql-js>-style AST, select the C<graphql-js> dialect.

    my $doc = parse_with_options($source, {
      dialect => 'graphql-js',
      backend => 'xs',
    });

The C<graphql-js> parser currently supports only the C<xs> backend.

=head1 PERFORMANCE NOTES

Computing location data costs real time. If you do not need C<location> or
C<loc> information, passing C<no_location =E<gt> 1> is more efficient and is
recommended for throughput-sensitive workloads.

Example:

    my $doc = parse_with_options($source, {
      dialect => 'graphql-js',
      backend => 'xs',
      no_location => 1,
    });

=head1 BENCHMARK SNAPSHOT

As of 2026-04-03, a local benchmark on C<t/kitchen-sink.graphql> produced the
following rough results:

=over 4

=item *

C<graphql_perl_pegex>: about 485 parses/sec

=item *

C<graphql_perl_canonical_xs>: about 13,524 parses/sec

=item *

C<graphql_js_xs>: about 22,756 parses/sec

=item *

C<graphql_js_xs_noloc>: about 35,076 parses/sec

=item *

C<graphql_perl_xs>: about 56,879 parses/sec

=back

This confirms two practical points:

=over 4

=item *

the XS parser path is substantially faster than the Pegex path

=item *

turning off location handling materially improves throughput

=back

The exact benchmark command and more detailed performance notes are kept in
C<docs/current-context.md> and C<docs/performance.md>.

=head1 NAME ORIGIN

The name C<Houtou> comes from several overlapping references:

=over 4

=item *

Japanese C<hotou> / "treasured sword" (宝刀)

=item *

Yamanashi's noodle dish C<houtou> (ほうとう)

=item *

the VTuber C<宝灯桃汁> (Houtou Momojiru)

=back

=head1 LICENSE

Copyright (C) anatofuz.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

anatofuz E<lt>anatofuz@gmail.comE<gt>

=cut
