use strict;
use warnings;

use JSON::PP ();
use Test::More 0.98;

use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Runtime qw(execute_operation);
use GraphQL::Houtou::Type::Interface;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);
use GraphQL::Houtou::Type::Union;

my $User = GraphQL::Houtou::Type::Object->new(
  name => 'User',
  runtime_tag => 'user',
  fields => {
    id => { type => $String->non_null },
    name => { type => $String },
  },
);

my $Node = GraphQL::Houtou::Type::Interface->new(
  name => 'Node',
  fields => {
    id => { type => $String->non_null },
  },
  tag_resolver => sub { $_[0]{kind} },
);

my $SearchResult = GraphQL::Houtou::Type::Union->new(
  name => 'SearchResult',
  types => [ $User ],
  tag_resolver => sub { $_[0]{kind} },
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
      greet => {
        type => $String,
        args => {
          name => { type => $String },
        },
        resolve => sub {
          my ($source, $args) = @_;
          return "hello $args->{name}";
        },
      },
      search => {
        type => $SearchResult,
        resolve => sub { +{ kind => 'user', id => 'u3', name => 'Cara' } },
      },
    },
  ),
  types => [ $User, $Node, $SearchResult ],
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

subtest 'abstract fields dispatch through lowered child blocks' => sub {
  my $result = $schema->execute_runtime('{ search { ... on User { id name } } }');
  is_deeply $result, {
    data => {
      search => {
        id => 'u3',
        name => 'Cara',
      },
    },
    errors => [],
  }, 'abstract field resolves through runtime tag dispatch';
};

subtest 'static literal args are executed through lowered payloads' => sub {
  my $result = $schema->execute_runtime('{ greet(name: "Ana") }');
  is_deeply $result, {
    data => {
      greet => 'hello Ana',
    },
    errors => [],
  }, 'static args are passed to resolver';
};

subtest 'variable args are materialized at execution time' => sub {
  my $result = $schema->execute_runtime(
    'query Q($name: String) { greet(name: $name) }',
    variables => { name => 'Bob' },
  );
  is_deeply $result, {
    data => {
      greet => 'hello Bob',
    },
    errors => [],
  }, 'dynamic args are passed to resolver';
};

subtest 'variable defaults are materialized from lowered program metadata' => sub {
  my $result = $schema->execute_runtime(
    'query Q($name: String = "Ana") { greet(name: $name) }',
  );
  is_deeply $result, {
    data => {
      greet => 'hello Ana',
    },
    errors => [],
  }, 'variable defaults flow through execution program metadata';
};

subtest 'fragment spreads execute through lowered child blocks' => sub {
  my $result = $schema->execute_runtime(<<'GRAPHQL');
query Q {
  viewer { ...UserBits }
}

fragment UserBits on User {
  id
  name
}
GRAPHQL

  is_deeply $result, {
    data => {
      viewer => {
        id => 'u1',
        name => 'Ana',
      },
    },
    errors => [],
  }, 'fragment spread path executes in greenfield runtime';
};

subtest 'dynamic include directives execute through lowered runtime guards' => sub {
  my $result = $schema->execute_runtime(
    'query Q($show: Boolean) { viewer { id name @include(if: $show) } }',
    variables => { show => JSON::PP::true },
  );

  is_deeply $result, {
    data => {
      viewer => {
        id => 'u1',
        name => 'Ana',
      },
    },
    errors => [],
  }, 'dynamic include guard allows field';
};

subtest 'static skip directives prune fields during lowering' => sub {
  my $result = $schema->execute_runtime(
    '{ viewer { id name @skip(if: true) } }',
  );

  is_deeply $result, {
    data => {
      viewer => {
        id => 'u1',
      },
    },
    errors => [],
  }, 'static skip removes field from runtime output';
};

done_testing;
