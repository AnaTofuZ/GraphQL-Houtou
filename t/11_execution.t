use strict;
use warnings;
use Test::More;

use GraphQL::Houtou::Execution qw(execute);
use GraphQL::Houtou::GraphQLPerl::Parser qw(parse_with_options);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Interface;
use GraphQL::Houtou::Type::Union;
use GraphQL::Houtou::Type::Scalar qw($String $ID);

my $User = GraphQL::Houtou::Type::Object->new(
  name => 'User',
  fields => {
    id => { type => $ID->non_null },
    name => { type => $String->non_null },
  },
);

my $CheckedUser = GraphQL::Houtou::Type::Object->new(
  name => 'CheckedUser',
  is_type_of => sub { ref($_[0]) eq 'HASH' && exists $_[0]{id} },
  fields => {
    id => { type => $ID->non_null },
    name => { type => $String->non_null },
  },
);

my $NamedEntity = GraphQL::Houtou::Type::Interface->new(
  name => 'NamedEntity',
  resolve_type => sub { 'User' },
  fields => {
    name => { type => $String->non_null },
  },
);

my $SearchResult = GraphQL::Houtou::Type::Union->new(
  name => 'SearchResult',
  resolve_type => sub { 'User' },
  types => [ $User ],
);

my $AutoNamedEntity = GraphQL::Houtou::Type::Interface->new(
  name => 'AutoNamedEntity',
  fields => {
    name => { type => $String->non_null },
  },
);

my $AutoCheckedUser = GraphQL::Houtou::Type::Object->new(
  name => 'AutoCheckedUser',
  interfaces => [ $AutoNamedEntity ],
  is_type_of => sub { ref($_[0]) eq 'HASH' && exists $_[0]{id} && ($_[0]{name} || '') =~ /^auto/ },
  fields => {
    id => { type => $ID->non_null },
    name => { type => $String->non_null },
  },
);

my $AutoSearchResult = GraphQL::Houtou::Type::Union->new(
  name => 'AutoSearchResult',
  types => [ $AutoCheckedUser ],
);

my $ThrowingCheckedUser = GraphQL::Houtou::Type::Object->new(
  name => 'ThrowingCheckedUser',
  is_type_of => sub { die "is_type_of exploded\n" },
  fields => {
    id => { type => $ID->non_null },
  },
);

my $ThrowingNamedEntity = GraphQL::Houtou::Type::Interface->new(
  name => 'ThrowingNamedEntity',
  resolve_type => sub { die "resolve_type exploded\n" },
  fields => {
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
    tags => {
      type => $String->non_null->list->non_null,
      resolve => sub { [ 'alpha', 'beta' ] },
    },
    users => {
      type => $User->list->non_null,
      resolve => sub {
        return [
          { id => '21', name => 'user:21' },
          { id => '22', name => 'user:22' },
        ];
      },
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
    checked_user => {
      type => $CheckedUser,
      resolve => sub {
        return {
          id => '11',
          name => 'checked:11',
        };
      },
    },
    checked_user_bad => {
      type => $CheckedUser,
      resolve => sub {
        return 'not-a-user';
      },
    },
    throwing_checked_user => {
      type => $ThrowingCheckedUser,
      resolve => sub {
        return { id => '31' };
      },
    },
    named_entity => {
      type => $NamedEntity,
      resolve => sub {
        return {
          id => '12',
          name => 'named:12',
        };
      },
    },
    auto_named_entity => {
      type => $AutoNamedEntity,
      resolve => sub {
        return {
          id => '14',
          name => 'auto:14',
        };
      },
    },
    search_result => {
      type => $SearchResult,
      resolve => sub {
        return {
          id => '13',
          name => 'search:13',
        };
      },
    },
    auto_search_result => {
      type => $AutoSearchResult,
      resolve => sub {
        return {
          id => '15',
          name => 'auto-search:15',
        };
      },
    },
    throwing_named_entity => {
      type => $ThrowingNamedEntity,
      resolve => sub {
        return {
          id => '32',
          name => 'throwing:32',
        };
      },
    },
    boom => {
      type => $String,
      resolve => sub { die "boom\n" },
    },
  },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => $Query,
  types => [ $User, $CheckedUser, $NamedEntity, $SearchResult, $AutoNamedEntity, $AutoCheckedUser, $AutoSearchResult, $ThrowingCheckedUser, $ThrowingNamedEntity ],
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

subtest 'xs field loop matches pp field loop' => sub {
  require GraphQL::Houtou::XS::Execution;
  require GraphQL::Houtou::Execution::PP;

  my $ast = parse_with_options('{ user(id: "9") { id name } }', { backend => 'xs' });
  my $context = GraphQL::Houtou::Execution::PP::_build_context(
    $schema,
    $ast,
    undef,
    undef,
    {},
    undef,
    undef,
    undef,
  );
  my ($fields) = $schema->query->_collect_fields(
    $context,
    $context->{operation}{selections},
    [ [], {} ],
    {},
  );

  my $pp = GraphQL::Houtou::Execution::PP::_execute_fields_pp(
    $context,
    $schema->query,
    undef,
    [],
    $fields,
  );
  my $xs = GraphQL::Houtou::XS::Execution::_execute_fields_xs(
    $context,
    $schema->query,
    undef,
    [],
    $fields,
  );

  is_deeply $xs, $pp, 'xs field loop matches pp field loop';
};

subtest 'xs execution coerces resolver exceptions into graphql errors' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $result = GraphQL::Houtou::XS::Execution::execute_xs($schema, '{ boom }');

  is $result->{data}{boom}, undef, 'errored field becomes undef';
  is ref($result->{errors}), 'ARRAY', 'errors array is present';
  is scalar @{ $result->{errors} }, 1, 'single error is returned';
  like $result->{errors}[0]{message}, qr/boom/, 'resolver error message is preserved';
};

subtest 'xs argument helper fast-path matches pp for no-arg field' => sub {
  require GraphQL::Houtou::XS::Execution;
  require GraphQL::Houtou::Execution::PP;

  my $field_def = $schema->query->fields->{hello};
  my $node = { name => 'hello' };
  my $pp = GraphQL::Houtou::Execution::PP::_get_argument_values_pp($field_def, $node, {});
  my $xs = GraphQL::Houtou::XS::Execution::_get_argument_values_xs($field_def, $node, {});

  is_deeply $xs, $pp, 'no-arg field is handled identically';
};

subtest 'xs argument helper fast-path matches pp for scalar literal arg' => sub {
  require GraphQL::Houtou::XS::Execution;
  require GraphQL::Houtou::Execution::PP;

  my $field_def = $schema->query->fields->{greet};
  my $node = {
    name => 'greet',
    arguments => {
      name => 'houtou',
    },
  };
  my $pp = GraphQL::Houtou::Execution::PP::_get_argument_values_pp($field_def, $node, {});
  my $xs = GraphQL::Houtou::XS::Execution::_get_argument_values_xs($field_def, $node, {});

  is_deeply $xs, $pp, 'scalar literal arg is handled identically';
};

subtest 'xs argument helper fast-path matches pp for provided variable arg' => sub {
  require GraphQL::Houtou::XS::Execution;
  require GraphQL::Houtou::Execution::PP;

  my $field_def = $schema->query->fields->{user};
  my $node = {
    name => 'user',
    arguments => {
      id => \'id',
    },
  };
  my $vars = {
    id => {
      value => '77',
      type => $ID->non_null,
    },
  };
  my $pp = GraphQL::Houtou::Execution::PP::_get_argument_values_pp($field_def, $node, $vars);
  my $xs = GraphQL::Houtou::XS::Execution::_get_argument_values_xs($field_def, $node, $vars);

  is_deeply $xs, $pp, 'provided variable arg is handled identically';
};

subtest 'xs completion helper fast-path matches pp for leaf and null cases' => sub {
  require GraphQL::Houtou::XS::Execution;
  require GraphQL::Houtou::Execution::PP;
  require GraphQL::Error;

  my $context = {
    schema => $schema,
    variable_values => {},
    fragments => {},
  };
  my $nodes = [ { location => undef } ];
  my $info = {
    parent_type => $schema->query,
    field_name => 'hello',
  };
  my $path = ['hello'];

  my $pp_leaf = GraphQL::Houtou::Execution::PP::_complete_value_catching_error(
    $context,
    $String->non_null,
    $nodes,
    $info,
    $path,
    'world',
  );
  my $xs_leaf = GraphQL::Houtou::XS::Execution::_complete_value_catching_error_xs(
    $context,
    $String->non_null,
    $nodes,
    $info,
    $path,
    'world',
  );
  is_deeply $xs_leaf, $pp_leaf, 'leaf completion is handled identically';

  my $pp_null = GraphQL::Houtou::Execution::PP::_complete_value_catching_error(
    $context,
    $String,
    $nodes,
    $info,
    $path,
    undef,
  );
  my $xs_null = GraphQL::Houtou::XS::Execution::_complete_value_catching_error_xs(
    $context,
    $String,
    $nodes,
    $info,
    $path,
    undef,
  );
  is_deeply $xs_null, $pp_null, 'nullable null completion is handled identically';

  my $pp_list = GraphQL::Houtou::Execution::PP::_complete_value_catching_error(
    $context,
    $String->non_null->list->non_null,
    $nodes,
    $info,
    $path,
    [ 'alpha', 'beta' ],
  );
  my $xs_list = GraphQL::Houtou::XS::Execution::_complete_value_catching_error_xs(
    $context,
    $String->non_null->list->non_null,
    $nodes,
    $info,
    $path,
    [ 'alpha', 'beta' ],
  );
  is_deeply $xs_list, $pp_list, 'leaf list completion is handled identically';
};

subtest 'execute list field through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $public = execute($schema, '{ tags }');
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, '{ tags }');

  is_deeply $xs, $public, 'list field result matches public facade';
};

subtest 'execute object list field through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $public = execute($schema, '{ users { id name } }');
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, '{ users { id name } }');

  is_deeply $xs, $public, 'object list field result matches public facade';
};

subtest 'xs completion helper fast-path matches pp for simple object case' => sub {
  require GraphQL::Houtou::XS::Execution;
  require GraphQL::Houtou::Execution::PP;

  my $ast = parse_with_options('{ user(id: "9") { id name } }', { backend => 'xs' });
  my $context = GraphQL::Houtou::Execution::PP::_build_context(
    $schema,
    $ast,
    undef,
    undef,
    {},
    undef,
    undef,
    undef,
  );
  my $node = $context->{operation}{selections}[0];
  my $info = {
    parent_type => $schema->query,
    field_name => 'user',
  };

  my $pp = GraphQL::Houtou::Execution::PP::_complete_value_catching_error(
    $context,
    $User,
    [ $node ],
    $info,
    ['user'],
    { id => '9', name => 'user:9' },
  );
  my $xs = GraphQL::Houtou::XS::Execution::_complete_value_catching_error_xs(
    $context,
    $User,
    [ $node ],
    $info,
    ['user'],
    { id => '9', name => 'user:9' },
  );

  is_deeply $xs, $pp, 'simple object completion is handled identically';
};

subtest 'execute object field with simple directives through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ user(id: "9") { id name @skip(if: false) } }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'object field with simple directives matches public facade';
};

subtest 'execute object field with simple inline fragment through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ user(id: "9") { ... on User { id name } } }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'object field with simple inline fragment matches public facade';
};

subtest 'execute object field with simple fragment spread through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = <<'GRAPHQL';
query {
  user(id: "9") {
    ...UserFields
  }
}

fragment UserFields on User {
  id
  name
}
GRAPHQL

  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'object field with simple fragment spread matches public facade';
};

subtest 'execute object field with skipped concrete fragments through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = <<'GRAPHQL';
query {
  user(id: "9") {
    ... on CheckedUser { id }
    ...UserFields
  }
}

fragment UserFields on User {
  id
  name
}
GRAPHQL

  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'irrelevant concrete fragments are skipped without PP fallback';
};

subtest 'execute object field with is_type_of through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ checked_user { id name } }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'object field with is_type_of matches public facade';
};

subtest 'execute object field with failing is_type_of through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ checked_user_bad { id } }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'object field with failing is_type_of matches public facade';
};

subtest 'execute object field with dying is_type_of through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ throwing_checked_user { id } }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'object field with dying is_type_of matches public facade';
};

subtest 'execute interface field with resolve_type through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ named_entity { ... on User { id name } } }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'interface field with resolve_type matches public facade';
};

subtest 'execute interface field with dying resolve_type through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ throwing_named_entity { name } }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'interface field with dying resolve_type matches public facade';
};

subtest 'execute union field with resolve_type through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ search_result { ... on User { id name } } }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'union field with resolve_type matches public facade';
};

subtest 'execute interface field with default resolve_type through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ auto_named_entity { ... on AutoCheckedUser { id name } } }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'interface field with default resolve_type matches public facade';
};

subtest 'execute union field with default resolve_type through xs path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ auto_search_result { ... on AutoCheckedUser { id name } } }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'union field with default resolve_type matches public facade';
};

subtest 'execute abstract fragment condition through xs object completion path' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $query = '{ auto_search_result { ... on AutoNamedEntity { name } ... on AutoCheckedUser { id } } }';
  my $public = execute($schema, $query);
  my $xs = GraphQL::Houtou::XS::Execution::execute_xs($schema, $query);

  is_deeply $xs, $public, 'abstract fragment condition is handled in xs object completion';
};

subtest 'prepare executable ir handle' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    'query Q { hello } fragment F on Query { hello }'
  );

  isa_ok $prepared, 'GraphQL::Houtou::XS::PreparedIR';
  is_deeply(
    GraphQL::Houtou::XS::Execution::_prepared_executable_ir_stats_xs($prepared),
    {
      definitions => 2,
      operations => 1,
      fragments => 1,
    },
    'prepared ir handle reports executable definition counts',
  );

  is_deeply(
    GraphQL::Houtou::XS::Execution::_prepared_executable_ir_plan_xs($prepared, 'Q'),
    {
      operation_type => 'query',
      operation_name => 'Q',
      selection_count => 1,
      variable_definition_count => 0,
      directive_count => 0,
      fragment_count => 1,
      fragment_names => ['F'],
    },
    'prepared ir handle reports selected operation plan metadata',
  );

  is_deeply(
    GraphQL::Houtou::XS::Execution::_prepared_executable_ir_frontend_xs($prepared, 'Q'),
    {
      operation => {
        operation_type => 'query',
        operation_name => 'Q',
        selection_count => 1,
        directive_count => 0,
        variables => {},
      },
      fragments => {
        F => {
          type_condition => 'Query',
          selection_count => 1,
          directive_count => 0,
        },
      },
    },
    'prepared ir handle exposes minimal frontend metadata without AST materialization',
  );
};

subtest 'prepare executable ir frontend variable metadata' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    'query Q($id: ID = 1, $flag: Boolean = false, $names: [String!]) { hello }'
  );

  is_deeply(
    GraphQL::Houtou::XS::Execution::_prepared_executable_ir_frontend_xs($prepared, 'Q')->{operation}{variables},
    {
      id => {
        type => 'ID',
        has_default => 1,
        directive_count => 0,
      },
      flag => {
        type => 'Boolean',
        has_default => 1,
        directive_count => 0,
      },
      names => {
        type => '[String!]',
        has_default => 0,
        directive_count => 0,
      },
    },
    'prepared ir frontend exposes lightweight variable metadata without AST materialization',
  );
};

subtest 'prepare executable ir context seed metadata' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    'query Q($id: ID) { hello ...F } fragment F on Query { greet(name: "x") }'
  );
  my $seed = GraphQL::Houtou::XS::Execution::_prepared_executable_ir_context_seed_xs(
    $schema,
    $prepared,
    'Q',
    { id => '42' },
  );

  is $seed->{operation_type}, 'query', 'context seed exposes selected operation type';
  isa_ok $seed->{root_type}, 'GraphQL::Houtou::Type::Object';
  is $seed->{root_type}->name, 'Query', 'context seed resolves schema root type';
  is_deeply $seed->{variable_values}, { id => '42' }, 'context seed carries runtime variable bag';
  is $seed->{frontend}{operation}{operation_name}, 'Q', 'context seed reuses lightweight frontend metadata';
  is $seed->{frontend}{fragments}{F}{type_condition}, 'Query', 'context seed keeps fragment metadata';
};

subtest 'prepare executable ir root selection plan' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    'query Q($id: ID) { hello user(id: $id) { id } ...F ... on Query { greet(name: "x") } } fragment F on Query { hello }'
  );

  is_deeply(
    GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_selection_plan_xs($prepared, 'Q'),
    [
      {
        kind => 'field',
        name => 'hello',
        alias => undef,
        argument_count => 0,
        directive_count => 0,
        selection_count => 0,
      },
      {
        kind => 'field',
        name => 'user',
        alias => undef,
        argument_count => 1,
        directive_count => 0,
        selection_count => 1,
        selections => [
          {
            kind => 'field',
            name => 'id',
            alias => undef,
            argument_count => 0,
            directive_count => 0,
            selection_count => 0,
          },
        ],
      },
      {
        kind => 'fragment_spread',
        name => 'F',
        directive_count => 0,
        type_condition => 'Query',
        selection_count => 1,
        selections => [
          {
            kind => 'field',
            name => 'hello',
            alias => undef,
            argument_count => 0,
            directive_count => 0,
            selection_count => 0,
          },
        ],
      },
      {
        kind => 'inline_fragment',
        type_condition => 'Query',
        directive_count => 0,
        selection_count => 1,
        selections => [
          {
            kind => 'field',
            name => 'greet',
            alias => undef,
            argument_count => 1,
            directive_count => 0,
            selection_count => 0,
          },
        ],
      },
    ],
    'prepared ir handle exposes root selection plan without AST materialization',
  );
};

subtest 'prepare executable ir root field buckets' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    'query Q { hello user(id: "42") { id } ...F ... on Query { hello } } fragment F on Query { hello }'
  );

  is_deeply(
    GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_field_buckets_xs($schema, $prepared, 'Q'),
    {
      operation_type => 'query',
      root_type => $Query,
      field_names => [ 'hello', 'user' ],
      field_counts => {
        hello => 3,
        user => 1,
      },
    },
    'prepared ir handle collects simple root field buckets directly from IR',
  );
};

subtest 'prepare executable ir root field plan' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    'query Q { hello user(id: "42") { id } ...F } fragment F on Query { hello }'
  );
  my $plan = GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_field_plan_xs(
    $schema,
    $prepared,
    'Q',
  );

  is $plan->{operation_type}, 'query', 'root field plan keeps operation type';
  isa_ok $plan->{root_type}, 'GraphQL::Houtou::Type::Object';
  is_deeply $plan->{field_order}, [ 'hello', 'user' ], 'root field plan preserves result name order';
  is $plan->{fields}{hello}{field_name}, 'hello', 'root field plan keeps underlying field name';
  is $plan->{fields}{hello}{node_count}, 2, 'root field plan counts merged root field nodes';
  is $plan->{fields}{user}{argument_count}, 1, 'root field plan keeps argument count';
  is $plan->{fields}{user}{selection_count}, 1, 'root field plan keeps child selection count';
  ok(ref($plan->{fields}{user}{field_def}) eq 'HASH', 'root field plan resolves field definition');
};

subtest 'prepare executable ir root legacy fields bridge' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    'query Q($id: ID) { hello user(id: $id) { id ... on User { name } } ...F } fragment F on Query { hello }'
  );
  my $fields = GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_legacy_fields_xs(
    $schema,
    $prepared,
    'Q',
  );

  is_deeply $fields->[0], [ 'hello', 'user' ], 'legacy bridge preserves root result name order';
  is scalar @{ $fields->[1]{hello} }, 2, 'legacy bridge merges duplicate hello root nodes';
  is $fields->[1]{user}[0]{kind}, 'field', 'legacy bridge materializes field node';
  is $fields->[1]{user}[0]{name}, 'user', 'legacy bridge keeps field name';
  is ${ $fields->[1]{user}[0]{arguments}{id} }, 'id', 'legacy bridge keeps variable argument refs';
  is $fields->[1]{user}[0]{selections}[0]{kind}, 'field', 'legacy bridge materializes nested field selection';
  is $fields->[1]{user}[0]{selections}[1]{kind}, 'inline_fragment', 'legacy bridge materializes nested inline fragment';
};

subtest 'execute prepared ir simple query' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    '{ hello user(id: "42") { id name } }'
  );

  is_deeply(
    GraphQL::Houtou::XS::Execution::execute_prepared_ir_xs($schema, $prepared),
    {
      data => {
        hello => 'world',
        user => {
          id => '42',
          name => 'user:42',
        },
      },
    },
    'prepared ir executes through existing XS field loop without full AST materialization',
  );
};

subtest 'execute prepared ir with variables and fragments' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    'query Q($id: ID!) { user(id: $id) { ...Bits } } fragment Bits on User { id name }'
  );

  is_deeply(
    GraphQL::Houtou::XS::Execution::execute_prepared_ir_xs($schema, $prepared, undef, undef, { id => '51' }, 'Q'),
    {
      data => {
        user => {
          id => '51',
          name => 'user:51',
        },
      },
    },
    'prepared ir executes variables and nested fragments via shared execution machinery',
  );
};

subtest 'execute compiled ir simple query' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    '{ hello user(id: "42") { id name } }'
  );
  my $compiled = GraphQL::Houtou::XS::Execution::_compile_executable_ir_plan_xs(
    $schema,
    $prepared,
  );

  is_deeply(
    GraphQL::Houtou::XS::Execution::execute_compiled_ir_xs($compiled),
    {
      data => {
        hello => 'world',
        user => {
          id => '42',
          name => 'user:42',
        },
      },
    },
    'compiled ir plan executes through cached frontend artifacts',
  );
};

subtest 'execute compiled ir with variables and fragments' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    'query Q($id: ID!) { user(id: $id) { ...Bits } } fragment Bits on User { id name }'
  );
  my $compiled = GraphQL::Houtou::XS::Execution::_compile_executable_ir_plan_xs(
    $schema,
    $prepared,
    'Q',
  );

  is_deeply(
    GraphQL::Houtou::XS::Execution::execute_compiled_ir_xs($compiled, undef, undef, { id => '51' }),
    {
      data => {
        user => {
          id => '51',
          name => 'user:51',
        },
      },
    },
    'compiled ir plan executes variables and fragments with cached frontend state',
  );
};

subtest 'compiled ir plan caches nested selection metadata' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    'query Q($id: ID!) { user(id: $id) { ...Bits extra: name } } fragment Bits on User { id profile { bio } }'
  );
  my $compiled = GraphQL::Houtou::XS::Execution::_compile_executable_ir_plan_xs(
    $schema,
    $prepared,
    'Q',
  );
  my $plan = GraphQL::Houtou::XS::Execution::_compiled_executable_ir_plan_xs($compiled);

  is(
    $plan->{root_field_plan}{fields}{user}{field_name},
    'user',
    'compiled plan exposes cached root field metadata',
  );

  is_deeply(
    $plan->{root_selection_plan},
    [
      {
        kind => 'field',
        name => 'user',
        alias => undef,
        argument_count => 1,
        directive_count => 0,
        selection_count => 2,
        selections => [
          {
            kind => 'fragment_spread',
            name => 'Bits',
            directive_count => 0,
            type_condition => 'User',
            selection_count => 2,
            selections => [
              {
                kind => 'field',
                name => 'id',
                alias => undef,
                argument_count => 0,
                directive_count => 0,
                selection_count => 0,
              },
              {
                kind => 'field',
                name => 'profile',
                alias => undef,
                argument_count => 0,
                directive_count => 0,
                selection_count => 1,
                selections => [
                  {
                    kind => 'field',
                    name => 'bio',
                    alias => undef,
                    argument_count => 0,
                    directive_count => 0,
                    selection_count => 0,
                  },
                ],
              },
            ],
          },
          {
            kind => 'field',
            name => 'name',
            alias => 'extra',
            argument_count => 0,
            directive_count => 0,
            selection_count => 0,
          },
        ],
      },
    ],
    'compiled plan caches nested selection metadata for root fields and fragment expansions',
  );
};

subtest 'prepared ir legacy field bridge caches plain nested field buckets' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    '{ user(id: "42") { id profile { bio } } }'
  );
  my $fields = GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_legacy_fields_xs(
    $schema,
    $prepared,
  );
  my $user_nodes = $fields->[1]{user};
  my $user_node = $user_nodes->[0];

  ok $user_node->{compiled_fields}, 'plain nested selection exposes compiled field buckets';
  is_deeply(
    $user_node->{compiled_fields},
    [
      [ 'id', 'profile' ],
      {
        id => [
          {
            kind => 'field',
            name => 'id',
          },
        ],
        profile => [
          {
            kind => 'field',
            name => 'profile',
            selections => [
              {
                kind => 'field',
                name => 'bio',
              },
            ],
            compiled_fields => [
              [ 'bio' ],
              {
                bio => [
                  {
                    kind => 'field',
                    name => 'bio',
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
    'compiled field buckets are attached recursively for plain nested selections',
  );
};

subtest 'prepared ir legacy field bridge folds unconditional inline fragments into compiled buckets' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    '{ user(id: "42") { ... { id profile { ... { bio } } } } }'
  );
  my $fields = GraphQL::Houtou::XS::Execution::_prepared_executable_ir_root_legacy_fields_xs(
    $schema,
    $prepared,
  );
  my $user_node = $fields->[1]{user}[0];

  is_deeply(
    $user_node->{compiled_fields},
    [
      [ 'id', 'profile' ],
      {
        id => [
          {
            kind => 'field',
            name => 'id',
          },
        ],
        profile => [
          {
            kind => 'field',
            name => 'profile',
            selections => [
              {
                kind => 'inline_fragment',
                compiled_fields => [
                  [ 'bio' ],
                  {
                    bio => [
                      {
                        kind => 'field',
                        name => 'bio',
                      },
                    ],
                  },
                ],
                selections => [
                  {
                    kind => 'field',
                    name => 'bio',
                  },
                ],
              },
            ],
            compiled_fields => [
              [ 'bio' ],
              {
                bio => [
                  {
                    kind => 'field',
                    name => 'bio',
                  },
                ],
              },
            ],
          },
        ],
      },
    ],
    'compiled field buckets absorb unconditional inline fragments recursively',
  );
};

subtest 'execute compiled ir reuses compiled fragment buckets' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    'query Q($id: ID!) { user(id: $id) { ...Bits ... { name } } } fragment Bits on User { id }'
  );
  my $compiled = GraphQL::Houtou::XS::Execution::_compile_executable_ir_plan_xs(
    $schema,
    $prepared,
    'Q',
  );

  is_deeply(
    GraphQL::Houtou::XS::Execution::execute_compiled_ir_xs($compiled, undef, undef, { id => '61' }),
    {
      data => {
        user => {
          id => '61',
          name => 'user:61',
        },
      },
    },
    'compiled ir executes nested fragment and inline-fragment buckets correctly',
  );
};

subtest 'execute compiled ir reuses concrete subfields for abstract selections' => sub {
  require GraphQL::Houtou::XS::Execution;

  my $prepared = GraphQL::Houtou::XS::Execution::_prepare_executable_ir_xs(
    '{ auto_search_result { ... on AutoNamedEntity { name } ... on AutoCheckedUser { id } } }'
  );
  my $compiled = GraphQL::Houtou::XS::Execution::_compile_executable_ir_plan_xs(
    $schema,
    $prepared,
  );

  is_deeply(
    GraphQL::Houtou::XS::Execution::execute_compiled_ir_xs($compiled),
    {
      data => {
        auto_search_result => {
          name => 'auto-search:15',
          id => '15',
        },
      },
    },
    'compiled ir executes abstract selections through cached concrete subfield buckets',
  );
};

done_testing;
