package GraphQL::Houtou;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use XSLoader ();
use GraphQL::Houtou::Promise::Adapter qw(
  set_default_promise_code
  get_default_promise_code
  clear_default_promise_code
);

our $VERSION = '0.01';
our $XS_BUNDLE_LOADED = 0;
our @EXPORT_OK = qw(
  parse
  parse_with_options
  execute
  execute_native
  compile_runtime
  build_runtime
  build_native_runtime
  compile_native_bundle
  compile_native_bundle_descriptor
  set_default_promise_code
  get_default_promise_code
  clear_default_promise_code
);

sub _bootstrap_xs {
  return 1 if $XS_BUNDLE_LOADED++;
  XSLoader::load('GraphQL::Houtou', $VERSION);
  return 1;
}

sub parse {
  require GraphQL::Houtou::GraphQLPerl::Parser;
  return GraphQL::Houtou::GraphQLPerl::Parser::parse(@_);
}

sub parse_with_options {
  my ($source, $options) = @_;
  $options ||= {};
  my $dialect = $options->{dialect} || 'graphql-perl';

  if ($dialect eq 'graphql-perl') {
    require GraphQL::Houtou::GraphQLPerl::Parser;
    return GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, $options);
  }
  if ($dialect eq 'graphql-js') {
    require GraphQL::Houtou::GraphQLJS::Parser;
    return GraphQL::Houtou::GraphQLJS::Parser::parse($source, $options);
  }

  die "Unknown parser dialect '$dialect'.\n";
}

sub compile_runtime {
  my ($schema, %opts) = @_;
  return $schema->compile_runtime(%opts);
}

sub build_runtime {
  my ($schema, %opts) = @_;
  return $schema->build_runtime(%opts);
}

sub build_native_runtime {
  my ($schema, %opts) = @_;
  return $schema->build_native_runtime(%opts);
}

sub compile_native_bundle {
  my ($schema, $document, %opts) = @_;
  return $schema->compile_native_bundle($document, %opts);
}

sub compile_native_bundle_descriptor {
  my ($schema, $document, %opts) = @_;
  return $schema->compile_native_bundle_descriptor($document, %opts);
}

sub execute_native {
  my ($schema, $document, %opts) = @_;
  return $schema->execute_native($document, %opts);
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

  my $runtime = $schema->build_runtime;
  my $program = $runtime->compile_program($document, %opts);
  return $runtime->execute_program($program, %opts);
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
      compile_native_bundle
      execute_native
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
    my $bundle = compile_native_bundle($schema, '{ hello }');
    my $native = execute_native($schema, '{ hello }');

    set_default_promise_code({
      resolve => sub { ... },
      reject  => sub { ... },
      all     => sub { ... },
      then    => sub { my ($promise, $ok, $ng) = @_; ... },
      is_promise => sub { my ($value) = @_; ... },
    });

=head1 DESCRIPTION

GraphQL::Houtou provides an XS-first GraphQL parser and runtime for Perl.
The parser still exposes both a legacy C<graphql-perl> AST and a
C<graphql-js>-style AST, but the execution mainline is the compiled
runtime / VM pipeline.

The current direction is:

=over 4

=item *

parser compatibility where the public API still needs it

=item *

XS-required public compiler / validation facades

=item *

runtime-first execution through compiled programs and native bundles

=item *

legacy implementation tests and snapshots preserved under C<legacy-tests/>
instead of shaping the active mainline

=back

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
    my $program = $runtime->compile_program($document);
    my $result  = $runtime->execute_program($program, variables => \%vars);

If you want a boot-time native artifact, use:

    my $bundle = GraphQL::Houtou::compile_native_bundle($schema, $document);
    my $runtime = GraphQL::Houtou::build_native_runtime($schema);
    my $result = $runtime->execute_bundle($bundle);

Or execute directly through the cached native runtime:

    my $result = GraphQL::Houtou::execute_native($schema, $document);

This runtime-backed API prefers the native XS engine when the lowered program
stays within the current native-safe subset. Programs that still require
features not yet lowered into the native engine automatically fall back to the
Perl VM. The Perl VM remains available as an explicit cold path via
C<engine =E<gt> 'perl'>.

The runtime-backed API above is the intended mainline. The public compiler and
validation facades now require XS. Older implementation tests and snapshots
live under C<legacy-tests/> and are no longer part of the active suite.

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

現在の比較対象は旧 executor ではなく、runtime/VM mainline です。

主な評価軸は次の 2 系統です。

=over 4

=item *

cached runtime (Perl VM)

=item *

cached native bundle (XS VM)

=back

ベンチマークでは resolver の結果をキャッシュするのではなく、
schema/runtime/program のコンパイル済み実行計画を再利用した時の
スループットを見ます。

典型的なコマンドは次です。

    perl util/execution-benchmark.pl --count=-3
    perl util/execution-benchmark-checkpoint.pl --repeat=5 --count=-3

詳細な評価軸は C<docs/execution-benchmark.md>、現在の実装前提は
C<docs/current-context.md> と C<docs/runtime-vm-architecture.md> にあります。

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
