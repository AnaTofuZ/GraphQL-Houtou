package GraphQL::Houtou;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Houtou::GraphQLJS::Parser ();
use GraphQL::Houtou::GraphQLPerl::Parser ();
use GraphQL::Houtou::Runtime ();
use GraphQL::Houtou::Promise::Adapter qw(
  set_default_promise_code
  get_default_promise_code
  clear_default_promise_code
);

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  parse
  parse_with_options
  execute
  compile_runtime
  build_runtime
  build_native_runtime
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

sub compile_runtime {
  my ($schema, %opts) = @_;
  return GraphQL::Houtou::Runtime::compile_schema($schema, %opts);
}

sub build_runtime {
  my ($schema, %opts) = @_;
  return $schema->build_runtime(%opts);
}

sub build_native_runtime {
  my ($schema, %opts) = @_;
  return GraphQL::Houtou::Runtime::build_native_runtime($schema, %opts);
}

sub execute {
  my ($schema, $document, $variables_or_opts, @rest) = @_;
  my %opts;
  my %known_option = map { ($_ => 1) } qw(
    variables
    vars
    root_value
    context
    operation_name
    promise_code
    engine
    vm_engine
  );

  if (@rest) {
    %opts = ($variables_or_opts ? (%{$variables_or_opts}) : (), @rest);
  } elsif (ref($variables_or_opts) eq 'HASH') {
    if (grep { $known_option{$_} } keys %{$variables_or_opts}) {
      %opts = %{$variables_or_opts};
      if (!exists $opts{variables}) {
        $opts{variables} = delete $opts{vars} if exists $opts{vars};
      } elsif (exists $opts{vars} && !exists $opts{variables}) {
        $opts{variables} = delete $opts{vars};
      }
    } else {
      $opts{variables} = $variables_or_opts;
    }
  } elsif (defined $variables_or_opts) {
    $opts{variables} = $variables_or_opts;
  }

  my $runtime = %opts ? compile_runtime($schema, %opts) : $schema->build_runtime;
  my $program = $runtime->compile_operation($document, %opts);
  return $runtime->execute_operation($program, %opts);
}

1;
__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou - XS-backed GraphQL parser and execution toolkit for Perl

=head1 SYNOPSIS

    use GraphQL::Houtou qw(
      parse
      parse_with_options
      execute
      compile_runtime
      set_default_promise_code
    );
    use GraphQL::Houtou::Schema;
    use GraphQL::Houtou::Type;
    use GraphQL::Houtou::Type::Object;
    use GraphQL::Houtou::Type::Scalar;

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

    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          hello => {
            type => GraphQL::Houtou::Type::Scalar->new(
              name => 'String',
              graphql_to_perl => sub { $_[0] },
              perl_to_graphql => sub { $_[0] },
            ),
            resolve => sub { 'world' },
          },
        },
      ),
    );

    my $result = execute($schema, '{ hello }');
    my $runtime = compile_runtime($schema);

    set_default_promise_code({
      resolve => sub { ... },
      reject  => sub { ... },
      all     => sub { ... },
      then    => sub { my ($promise, $ok, $ng) = @_; ... },
      is_promise => sub { my ($value) = @_; ... },
    });

=head1 DESCRIPTION

GraphQL::Houtou provides XS-backed GraphQL parsing and execution with
compatibility layers for both the legacy C<graphql-perl> AST and a
C<graphql-js>-style AST.

This distribution was split out from local parser work that originally lived
in a fork of L<graphql-perl|https://github.com/graphql-perl/graphql-perl>.
It still uses the upstream C<GraphQL> distribution as a dependency for some
compatibility behavior, while making the XS path the normal fast path for both
parser and execution work.

=head1 USAGE

=head2 Parsing

The default C<parse()> entry point returns the traditional
C<graphql-perl>-compatible AST.

    my $ast = parse($source);

If you want to choose the dialect explicitly, use C<parse_with_options()>.

    my $legacy = parse_with_options($source, {
      dialect => 'graphql-perl',
      backend => 'xs',
    });

    my $graphql_js = parse_with_options($source, {
      dialect => 'graphql-js',
      backend => 'xs',
    });

For throughput-sensitive parsing where you do not need location data, passing
C<no_location =E<gt> 1> is still recommended.

    my $doc = parse_with_options($source, {
      dialect => 'graphql-js',
      backend => 'xs',
      no_location => 1,
    });

=head2 Executing Queries

The top-level runtime API is:

    my $result = GraphQL::Houtou::execute($schema, $document, \%vars);

Where C<$document> can be either:

=over 4

=item *

a source string

=item *

a pre-parsed C<graphql-perl>-compatible AST

=back

If you need a reusable compiled runtime, use:

    my $runtime = GraphQL::Houtou::compile_runtime($schema);
    my $program = $runtime->compile_operation($document);
    my $result  = $runtime->execute_operation($program, variables => \%vars);

This runtime-backed API prefers the native XS engine when the lowered program
stays within the current native-safe subset. Programs that still require
features not yet lowered into the native engine automatically fall back to the
Perl VM. The Perl VM remains available as an explicit cold path via
C<execute_runtime_perl(...)>/C<execute_program_perl(...)>.

The runtime-backed API above is the intended mainline. Older execution
compatibility tests live under C<legacy-tests/> and are no longer part of the
active suite.

=head2 Promise Hooks

Promise support is configured by user-supplied hooks rather than by naming a
specific promise library. You can set global defaults via:

    set_default_promise_code({
      resolve => sub { ... },
      reject  => sub { ... },
      all     => sub { ... },
      then    => sub { my ($promise, $ok, $ng) = @_; ... },    # optional
      is_promise => sub { my ($value) = @_; ... },             # optional
    });

The intended contract is:

=over 4

=item *

C<resolve($value)> returns a fulfilled promise

=item *

C<reject($error)> returns a rejected promise

=item *

C<all(@promises)> returns an aggregate promise that fulfills to the resolved
values

=item *

C<then($promise, $on_fulfilled, $on_rejected)> chains a promise

=item *

C<is_promise($value)> returns true when the value should be treated as a
promise

=back

Per-request overrides are also supported by the execution layer. The public
API keeps the hook contract generic so that adapters can be supplied by user
code for C<Promises>, C<Future>, C<Promise::XS>, C<Promise::ES6>,
C<Mojo::Promise>, or any other library with a suitable wrapper.

=head1 DIALECTS

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

As of 2026-04-06, practical execution benchmarks using
C<util/execution-benchmark.pl --count=-3> produced the following snapshot:

=over 4

=item *

C<simple_scalar> AST execution:
C<houtou_xs_ast> about 139,565/s, C<houtou_compiled_ir> about 139,515/s,
C<upstream_ast> about 41,261/s

=item *

C<nested_variable_object> AST execution:
C<houtou_compiled_ir> about 79,130/s, C<houtou_xs_ast> about 77,441/s,
C<upstream_ast> about 25,041/s

=item *

C<list_of_objects> AST execution:
C<houtou_xs_ast> about 58,659/s, C<houtou_compiled_ir> about 57,941/s,
C<upstream_ast> about 17,816/s

=item *

C<abstract_with_fragment> AST execution:
C<houtou_xs_ast> about 41,687/s, C<houtou_compiled_ir> about 41,647/s,
C<upstream_ast> about 23,641/s

=item *

C<async_scalar> AST execution:
C<houtou_facade_ast> about 78,946/s, C<houtou_compiled_ir> about 77,535/s,
C<upstream_ast> about 41,389/s

=item *

C<async_list> AST execution:
C<houtou_compiled_ir> about 43,671/s, C<houtou_facade_ast> about 43,260/s,
C<upstream_ast> about 26,131/s

=back

This confirms several practical points:

=over 4

=item *

the XS path is now materially faster than upstream execution in the benchmarked
AST and source-string cases

=item *

compiled IR plans are now a real execution path, not just parser metadata; they
already improve over prepared IR and are competitive with, or better than, the
best AST-based Houtou path in several practical cases

=item *

the execution XS work is paying off not only for nested/list/object workloads
but also for promise-backed scalar and list cases

=item *

turning off parser location handling still materially improves parse-only
throughput when you do not need C<loc> or C<location> data

=back

The exact benchmark command and more detailed performance notes are kept in
C<docs/execution-benchmark.md> and C<docs/current-context.md>.

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
