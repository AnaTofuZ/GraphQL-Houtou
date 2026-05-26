use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use File::Spec;

BEGIN {
  my $root = File::Spec->catdir($Bin, '..');
  for my $path (
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', 'darwin-2level'),
  ) {
    unshift @INC, $path if -d $path;
  }
}

use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String $Int);
use GraphQL::Houtou::Runtime::NativeRuntime;

my $compile_count = 0;

my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'CacheQuery',
    fields => {
      hello => { type => $String, resolve => sub { 'world' } },
      greet => {
        type => $String,
        args => { name => { type => $String } },
        resolve => sub { my ($src, $args) = @_; 'hi ' . ($args->{name} // 'x') },
      },
    },
  ),
);

subtest 'program is cached after first compile' => sub {
  my $runtime = $schema->build_native_runtime;

  is $runtime->program_cache_size, 0, 'cache empty initially';

  $runtime->execute_document('{ hello }');
  is $runtime->program_cache_size, 1, 'one entry cached after first execute';

  $runtime->execute_document('{ hello }');
  is $runtime->program_cache_size, 1, 'cache size unchanged on second execute';

  $runtime->execute_document('{ greet(name: "world") }');
  is $runtime->program_cache_size, 2, 'different query adds second entry';
};

subtest 'cached program produces correct results' => sub {
  my $runtime = $schema->build_native_runtime;

  my $r1 = $runtime->execute_document('{ hello }');
  my $r2 = $runtime->execute_document('{ hello }');

  is_deeply $r1, { data => { hello => 'world' }, errors => [] }, 'first call correct';
  is_deeply $r2, { data => { hello => 'world' }, errors => [] }, 'second call (cached) correct';
};

subtest 'variables do not affect cache key – compiled once, executed with different vars' => sub {
  my $runtime = $schema->build_native_runtime;

  $runtime->execute_document('{ greet(name: "alice") }');
  my $size_before = $runtime->program_cache_size;

  $runtime->execute_document('{ greet(name: "bob") }');
  is $runtime->program_cache_size, $size_before + 1,
    'different argument literals = different query string = different cache entry';
};

subtest 'pre-parsed AST is not cached' => sub {
  my $runtime = $schema->build_native_runtime;
  $runtime->clear_program_cache;

  my $ast = GraphQL::Houtou::parse('{ hello }');
  $runtime->execute_document($ast);
  is $runtime->program_cache_size, 0, 'AST ref is not cached (no string key)';
};

subtest 'clear_program_cache empties the cache' => sub {
  my $runtime = $schema->build_native_runtime;
  $runtime->execute_document('{ hello }');
  ok $runtime->program_cache_size > 0, 'cache has entries';

  $runtime->clear_program_cache;
  is $runtime->program_cache_size, 0, 'cache is empty after clear';

  my $result = $runtime->execute_document('{ hello }');
  is_deeply $result, { data => { hello => 'world' }, errors => [] },
    'execution still works after clear';
};

subtest 'program_cache_max limits cache size with FIFO eviction' => sub {
  my $runtime = GraphQL::Houtou::Runtime::NativeRuntime->new(
    runtime_schema => $schema->build_runtime,
    program_cache_max => 2,
  );

  my $q1 = '{ hello }';
  my $q2 = '{ greet(name: "a") }';
  my $q3 = '{ greet(name: "b") }';

  $runtime->execute_document($q1);
  $runtime->execute_document($q2);
  is $runtime->program_cache_size, 2, 'cache at max';

  $runtime->execute_document($q3);
  is $runtime->program_cache_size, 2, 'cache stays at max after eviction';
  ok !exists $runtime->{_program_cache}{$q1}, 'oldest entry evicted';
  ok  exists $runtime->{_program_cache}{$q3}, 'newest entry present';
};

subtest 'program_cache_max => 0 disables caching' => sub {
  my $runtime = GraphQL::Houtou::Runtime::NativeRuntime->new(
    runtime_schema => $schema->build_runtime,
    program_cache_max => 0,
  );

  $runtime->execute_document('{ hello }');
  is $runtime->program_cache_size, 0, 'nothing cached when max is 0';
};

subtest 'schema->build_native_runtime passes program_cache_max' => sub {
  my $runtime = $schema->build_native_runtime(program_cache_max => 5);
  is $runtime->{_program_cache_max}, 5, 'program_cache_max forwarded from Schema';
};

done_testing;
