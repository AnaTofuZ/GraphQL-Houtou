use strict;
use warnings;

use Test::More 0.98;

use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Runtime qw(execute_operation);
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

my $User = GraphQL::Houtou::Type::Object->new(
  name => 'User',
  fields => {
    id => { type => $String->non_null },
    name => { type => $String },
  },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'Query',
    fields => {
      hello => { type => $String },
      viewer => {
        type => $User,
        resolve => sub { +{ id => 'u1', name => 'Ana' } },
      },
      users => {
        type => $User->list,
        resolve => sub { [ +{ id => 'u1', name => 'Ana' }, +{ id => 'u2', name => 'Bob' } ] },
      },
    },
  ),
  types => [ $User ],
);

subtest 'schema can execute greenfield runtime program' => sub {
  my $runtime = $schema->compile_runtime;
  my $program = $runtime->compile_operation('{ viewer { id name } users { id } }');
  my $result = $runtime->execute_operation($program);

  is_deeply $result, {
    data => {
      viewer => { id => 'u1', name => 'Ana' },
      users => [
        { id => 'u1' },
        { id => 'u2' },
      ],
    },
    errors => [],
  }, 'runtime executes object/list program';
};

subtest 'schema helper can compile and execute in one call' => sub {
  my $result = $schema->execute_runtime('{ viewer { id } }');
  is_deeply $result, {
    data => {
      viewer => { id => 'u1' },
    },
    errors => [],
  }, 'schema helper executes greenfield runtime';
};

subtest 'default resolver path reads root hash values' => sub {
  my $result = $schema->execute_runtime('{ hello }', root_value => { hello => 'world' });
  is_deeply $result, {
    data => {
      hello => 'world',
    },
    errors => [],
  }, 'default resolver path works in greenfield runtime';
};

done_testing;
