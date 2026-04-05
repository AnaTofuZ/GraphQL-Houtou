use strict;
use warnings;
use Test::More;

use GraphQL::Houtou::Execution qw(execute);
use GraphQL::Houtou::GraphQLPerl::Parser qw(parse_with_options);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String $ID);

my $User = GraphQL::Houtou::Type::Object->new(
  name => 'User',
  fields => {
    id => { type => $ID->non_null },
    name => { type => $String->non_null },
  },
);

my $Query = GraphQL::Houtou::Type::Object->new(
  name => 'Query',
  fields => {
    hello => {
      type => $String->non_null,
      resolve => sub { 'world' },
    },
    greet => {
      type => $String->non_null,
      args => {
        name => {
          type => $String->non_null,
        },
      },
      resolve => sub {
        my ($root, $args) = @_;
        return "hello $args->{name}";
      },
    },
    user => {
      type => $User,
      args => {
        id => {
          type => $ID->non_null,
        },
      },
      resolve => sub {
        my ($root, $args) = @_;
        return {
          id => $args->{id},
          name => "user:$args->{id}",
        };
      },
    },
  },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => $Query,
  types => [ $User ],
);

subtest 'execute simple query from source' => sub {
  my $result = execute($schema, '{ hello }');
  is_deeply $result, { data => { hello => 'world' } }, 'simple query executes';
};

subtest 'execute query with variables and nested object' => sub {
  my $result = execute(
    $schema,
    'query q($id: ID!) { user(id: $id) { id name } }',
    undef,
    undef,
    { id => '42' },
    'q',
  );

  is_deeply $result, {
    data => {
      user => {
        id => '42',
        name => 'user:42',
      },
    },
  }, 'variables and nested completion work';
};

subtest 'execute parsed ast and typename meta field' => sub {
  my $ast = parse_with_options('{ __typename }', { backend => 'xs' });
  my $result = execute($schema, $ast);
  is_deeply $result, { data => { __typename => 'Query' } }, '__typename works through parsed ast';
};

subtest 'xs facade matches public facade' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ greet(name: "houtou") }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'xs entrypoint matches facade result';
};

subtest 'xs facade selects named operation' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = <<'GRAPHQL';
query first { hello }
query second($id: ID!) { user(id: $id) { id } }
GRAPHQL

  my $result = GraphQL::Houtou::XS::Execution::execute_xs(
    $schema,
    $query,
    undef,
    undef,
    { id => '7' },
    'second',
  );

  is_deeply $result, {
    data => {
      user => {
        id => '7',
      },
    },
  }, 'xs path chooses the requested operation';
};

done_testing;
