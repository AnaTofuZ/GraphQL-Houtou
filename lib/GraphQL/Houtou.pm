package GraphQL::Houtou;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use XSLoader ();
use GraphQL::Houtou::Runtime::LazyInfo ();

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
  compile_native_program
  compile_native_bundle
  compile_native_bundle_descriptor
);

sub _bootstrap_xs {
  return 1 if $XS_BUNDLE_LOADED++;
  XSLoader::load('GraphQL::Houtou', $VERSION);
  return 1;
}

sub parse {
  my ($source) = @_;
  require GraphQL::Houtou::XS::Parser;
  return GraphQL::Houtou::XS::Parser::parse_xs($source, undef);
}

sub parse_with_options {
  my ($source, $options) = @_;
  $options ||= {};
  for my $key (keys %{$options}) {
    next if $key eq 'no_location';
    die "Unknown parser option '$key'.\n";
  }
  my $no_location = $options->{no_location};
  require GraphQL::Houtou::XS::Parser;
  return GraphQL::Houtou::XS::Parser::parse_xs($source, $no_location);
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

sub compile_native_program {
  my ($schema, $document, %opts) = @_;
  return $schema->compile_native_program($document, %opts);
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

  die "promise_code is no longer supported; Promise::XS is detected automatically.\n"
    if exists $opts{promise_code};

  if (!defined $opts{engine} || $opts{engine} ne 'perl') {
    my $runtime = $schema->build_native_runtime;
    return $runtime->execute_document($document, %opts);
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
    );
    use GraphQL::Houtou::Schema;
    use GraphQL::Houtou::Type;
    use GraphQL::Houtou::Type::Object;
    use GraphQL::Houtou::Type::Scalar;

    my $ast = parse('{ user { id } }');

    my $fast_ast = parse_with_options('{ user { id } }', {
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

=head1 DESCRIPTION

GraphQL::Houtou provides an XS-first GraphQL parser and runtime for Perl.
The parser surface returns the library's canonical Perl AST, while the
execution mainline is the compiled runtime / VM pipeline.

The current direction is:

=over 4

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

The default C<parse()> entry point returns the canonical parser AST used by
this library.

    my $ast = parse($source);

If you want to tune parser options explicitly, use C<parse_with_options()>.

    my $ast = parse_with_options($source, {
      no_location => 1,
    });

For throughput-sensitive parsing where you do not need location data, passing
C<no_location =E<gt> 1> is still recommended.

    my $doc = parse_with_options($source, {
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

a pre-parsed parser AST returned by C<parse()> or C<parse_with_options()>

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

This runtime-backed API is native-first on the sync path. Programs that stay
within the current native-safe subset are specialized into the native VM and
executed there. If a resolver yields a C<Promise::XS::Promise>, execution
automatically continues on the Promise::XS-backed async path.

The runtime-backed API above is the intended mainline. The public compiler and
validation facades now require XS. Older implementation tests and snapshots
live under C<legacy-tests/> and are no longer part of the active suite.

=head2 Promise Support

Async execution now targets C<Promise::XS> directly and is detected
automatically. If a resolver returns a C<Promise::XS::Promise>, the runtime
will continue on the async path and may return a C<Promise::XS::Promise> as
the top-level result.

Generic promise adapters and C<promise_code> injection are no longer part of
the active runtime path.

=head1 PARSER SURFACE

The public parser surface is fixed to the library's canonical parser AST.
C<parse_with_options()> only accepts parser-local knobs such as
C<no_location>.

=head1 PERFORMANCE NOTES

Computing location data costs real time. If you do not need C<location> or
C<loc> information, passing C<no_location =E<gt> 1> is more efficient and is
recommended for throughput-sensitive workloads.

Example:

    my $doc = parse_with_options($source, {
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

`fd72137` 時点の中央値は次のとおりです。

=over 4

=item *

sync `runtime_program`

  - `nested_variable_object`: `3266/s`
  - `list_of_objects`: `3266/s`
  - `abstract_with_fragment`: `3257/s`

=item *

sync `native_bundle`

  - `nested_variable_object`: `582772/s`
  - `list_of_objects`: `515525/s`
  - `abstract_with_fragment`: `576014/s`

=item *

async `Promise::XS` auto-detect path

  - `async_scalar`: `3083/s`
  - `async_list`: `3082/s`
  - `async_object`: `3082/s`
  - `async_abstract`: `3054/s`

=back

要点は、現在の最速経路は依然として `native_bundle` の specialized
sync fast lane であり、public の `runtime_program` / Promise::XS async
mainline はおおむね `3.0k/s` 前後に揃っている、ということです。
async path は undocumented な `Promise::XS` 内部 await hook には依存せず、
documented な `then` / `all` と Promise::XS 型判定だけを使います。

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
