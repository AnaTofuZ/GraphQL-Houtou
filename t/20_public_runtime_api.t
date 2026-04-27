use strict;
use warnings;
use Test::More;

use lib 'lib';
use GraphQL::Houtou qw(execute compile_runtime build_native_runtime);
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

done_testing;
