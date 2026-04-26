use strict;
use warnings;
use Test::More;

use lib 'lib';
use GraphQL::Houtou qw(execute compile_runtime);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

my $Query = GraphQL::Houtou::Type::Object->new(
  name => 'PublicRuntimeQuery',
  fields => {
    hello => {
      type => $String,
      resolve => sub { return 'world' },
    },
    greet => {
      type => $String,
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

done_testing;
