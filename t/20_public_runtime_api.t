use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);

use lib 'lib';
use GraphQL::Houtou qw(execute compile_runtime build_runtime build_native_runtime);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

my $Query = GraphQL::Houtou::Type::Object->new(
  name => 'PublicRuntimeQuery',
  fields => {
    hello => {
      type => $String,
      resolver_mode => 'native',
      resolve => sub { return 'world' },
    },
    greet => {
      type => $String,
      resolver_mode => 'native',
      args => {
        name => { type => $String },
      },
      resolve => sub {
        my ($source, $args) = @_;
        return 'hello ' . ($args->{name} || 'nobody');
      },
    },
  },
);

my $schema = GraphQL::Houtou::Schema->new(query => $Query);

subtest 'top-level execute uses runtime-backed API' => sub {
  my $result = execute($schema, '{ hello }');
  is_deeply $result, {
    data => { hello => 'world' },
    errors => [],
  }, 'top-level execute returns runtime result';
};

subtest 'top-level execute accepts variable hashref as third arg' => sub {
  my $result = execute(
    $schema,
    'query($name: String){ greet(name: $name) }',
    { name => 'alice' },
  );
  is_deeply $result, {
    data => { greet => 'hello alice' },
    errors => [],
  }, 'top-level execute treats third hashref as variables';
};

subtest 'top-level compile_runtime returns schema runtime' => sub {
  my $runtime = compile_runtime($schema);
  isa_ok $runtime, 'GraphQL::Houtou::Runtime::SchemaGraph';
  my $program = $runtime->compile_operation('{ hello }');
  my $result = $runtime->execute_operation($program);
  is_deeply $result, {
    data => { hello => 'world' },
    errors => [],
  }, 'compiled runtime can execute operation';
};

subtest 'top-level build_runtime returns cached schema runtime' => sub {
  my $first = build_runtime($schema);
  my $second = build_runtime($schema);

  isa_ok $first, 'GraphQL::Houtou::Runtime::SchemaGraph';
  is $second, $first, 'top-level build_runtime reuses cached runtime graph';
};

subtest 'schema build_runtime caches no-opt runtime graph' => sub {
  my $first = $schema->build_runtime;
  my $second = $schema->build_runtime;

  is $second, $first, 'build_runtime reuses cached runtime graph';

  $schema->clear_runtime_cache;
  my $third = $schema->build_runtime;
  isnt $third, $first, 'clear_runtime_cache drops cached runtime graph';
};

subtest 'top-level build_native_runtime returns cached native runtime wrapper' => sub {
  my $native = build_native_runtime($schema);
  isa_ok $native, 'GraphQL::Houtou::Runtime::NativeRuntime';

  my $program = $native->compile_program(
    'query Q($name: String = "bob") { greet(name: $name) }',
  );
  my $result = $native->execute_program($program, variables => { name => 'cached' });

  is_deeply $result, {
    data => { greet => 'hello cached' },
    errors => [],
  }, 'cached native runtime executes request-specialized program';
};

subtest 'schema build_native_runtime caches no-opt native wrapper' => sub {
  my $first = $schema->build_native_runtime;
  my $second = $schema->build_native_runtime;

  is $second, $first, 'build_native_runtime reuses cached native wrapper';

  $schema->clear_runtime_cache;
  my $third = $schema->build_native_runtime;
  isnt $third, $first, 'clear_runtime_cache drops cached native wrapper';
};

subtest 'native runtime can compile reusable bundle from cached program' => sub {
  my $native = $schema->build_native_runtime;
  my $program = $native->compile_program('{ hello }');
  my $bundle = $native->compile_bundle($program);

  isa_ok $bundle, 'GraphQL::Houtou::Runtime::NativeBundle';
  my $result = $bundle->execute;

  is_deeply $result, {
    data => { hello => 'world' },
    errors => [],
  }, 'compiled native bundle executes through wrapper';
};

subtest 'native runtime can round-trip bundle descriptors' => sub {
  my $native = $schema->build_native_runtime;
  my $program = $native->compile_program(
    'query Q($name: String = "bob") { greet(name: $name) }',
  );
  my ($fh, $path) = tempfile();
  close $fh;

  my $descriptor = $native->dump_bundle_descriptor(
    $program,
    $path,
    variables => { name => 'persisted' },
  );
  my $bundle = $native->load_bundle_descriptor_file($path);
  my $result = $bundle->execute;

  ok $descriptor->{program}, 'bundle descriptor keeps native program payload';
  is_deeply $result, {
    data => { greet => 'hello persisted' },
    errors => [],
  }, 'dumped and loaded native bundle descriptor still executes';
};

subtest 'schema execute_native_runtime reuses cached native runtime handle' => sub {
  my $load_count = 0;
  my $orig = \&GraphQL::Houtou::Native::load_native_runtime;

  {
    no warnings 'redefine';
    local *GraphQL::Houtou::Native::load_native_runtime = sub {
      $load_count++;
      goto &$orig;
    };

    my $first = $schema->execute_native_runtime('{ hello }');
    my $second = $schema->execute_native_runtime('{ hello }');

    is_deeply $first, {
      data => { hello => 'world' },
      errors => [],
    }, 'first native runtime execution succeeds';
    is_deeply $second, {
      data => { hello => 'world' },
      errors => [],
    }, 'second native runtime execution succeeds';
  }

  is $load_count, 1, 'execute_native_runtime reuses cached native runtime handle';
};

done_testing;
