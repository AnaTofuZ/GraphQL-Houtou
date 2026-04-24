use strict;
use warnings;

use Test::More 0.98;

use GraphQL::Houtou::Directive;
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Interface;
use GraphQL::Houtou::Type::List;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($Boolean $String);
use GraphQL::Houtou::Type::Union;

my $SearchResult;
my $TaggedNode;
my $TaggedUser;
my $TaggedSearchResult;

my $Node;
my $User;

$Node = GraphQL::Houtou::Type::Interface->new(
  name => 'Node',
  fields => {
    id => { type => $String->non_null },
  },
  resolve_type => sub { $User },
);

$User = GraphQL::Houtou::Type::Object->new(
  name => 'User',
  interfaces => [ $Node ],
  fields => {
    id => { type => $String->non_null },
    name => { type => $String },
    nickname => { type => $String },
  },
);

$SearchResult = GraphQL::Houtou::Type::Union->new(
  name => 'SearchResult',
  types => [ $User ],
  resolve_type => sub { $User },
);

$TaggedNode = GraphQL::Houtou::Type::Interface->new(
  name => 'TaggedNode',
  fields => {
    id => { type => $String->non_null },
  },
  tag_resolver => sub { $_[0]{kind} },
);

$TaggedUser = GraphQL::Houtou::Type::Object->new(
  name => 'TaggedUser',
  interfaces => [ $TaggedNode ],
  runtime_tag => 'tagged-user',
  fields => {
    id => { type => $String->non_null },
    name => { type => $String },
  },
);

$TaggedSearchResult = GraphQL::Houtou::Type::Union->new(
  name => 'TaggedSearchResult',
  types => [ $TaggedUser ],
  tag_resolver => sub { $_[0]{kind} },
  tag_map => {
    tagged => $TaggedUser,
  },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'Query',
    fields => {
      viewer => { type => $User },
      taggedViewer => { type => $TaggedUser },
    },
  ),
  types => [ $User, $Node, $TaggedUser, $TaggedNode, $TaggedSearchResult ],
);

subtest '_collect_fields merges aliases and fragment selections' => sub {
  my $context = {
    schema => $schema,
    fragments => {
      UserBits => {
        kind => 'fragment',
        name => 'UserBits',
        on => 'User',
        selections => [
          { kind => 'field', name => 'nickname' },
        ],
      },
    },
    variable_values => {},
  };
  my $selections = [
    { kind => 'field', name => 'id' },
    { kind => 'field', name => 'name', alias => 'displayName' },
    { kind => 'inline_fragment', on => 'User', selections => [
      { kind => 'field', name => 'name' },
    ] },
    { kind => 'fragment_spread', name => 'UserBits' },
  ];

  my ($fields) = $User->_collect_fields($context, $selections, [ [], {} ], {});
  is_deeply $fields->[0], [ 'id', 'displayName', 'name', 'nickname' ], 'field order is preserved';
  is scalar @{ $fields->[1]{name} }, 1, 'merged field nodes are grouped by response name';
  is scalar @{ $fields->[1]{displayName} }, 1, 'alias gets its own response slot';
};

subtest '_collect_fields honors include/skip directives' => sub {
  my $context = {
    schema => $schema,
    fragments => {},
    variable_values => {
      show_name => { value => 1, type => $Boolean->non_null },
      hide_nick => { value => 1, type => $Boolean->non_null },
    },
  };
  my $selections = [
    {
      kind => 'field',
      name => 'name',
      directives => [
        { name => 'include', arguments => { if => \'show_name' } },
      ],
    },
    {
      kind => 'field',
      name => 'nickname',
      directives => [
        { name => 'skip', arguments => { if => \'hide_nick' } },
      ],
    },
  ];

  my ($fields) = $User->_collect_fields($context, $selections, [ [], {} ], {});
  is_deeply $fields->[0], [ 'name' ], 'skip/include directives affect field collection';
};

subtest '_fragment_condition_match checks abstract compatibility' => sub {
  my $context = {
    schema => $schema,
    fragments => {},
    variable_values => {},
  };

  ok $User->_fragment_condition_match($context, { on => 'User' }), 'exact type matches';
  ok $User->_fragment_condition_match($context, { on => 'Node' }), 'implemented interface matches';
  ok !$User->_fragment_condition_match($context, { on => 'Query' }), 'non-overlapping type does not match';
};

subtest 'list runtime completion merges child values' => sub {
  my $list_type = GraphQL::Houtou::Type::List->new(of => $String);
  my $got;

  no warnings 'redefine';
  local *GraphQL::Houtou::Execution::PP::_complete_value_catching_error = sub {
    my ($context, $return_type, $nodes, $info, $path, $value) = @_;
    return +{ data => uc($value) };
  };

  $got = $list_type->_complete_value({}, [], {}, [], [ 'a', 'b' ]);
  is_deeply $got, { data => [ 'A', 'B' ] }, 'list completion merges child data';
};

subtest 'interface runtime completion resolves to object type' => sub {
  my $context = {
    schema => $schema,
    context_value => undef,
  };
  my $info = {
    parent_type => $schema->query,
    field_name => 'viewer',
  };
  my $got;

  no warnings 'redefine';
  local *GraphQL::Houtou::Execution::PP::_execute_fields = sub {
    my ($ctx, $type, $result) = @_;
    return +{ data => { runtime_type => $type->name, payload => $result->{name} } };
  };

  $got = $Node->_complete_value(
    $context,
    [ { selections => [] } ],
    $info,
    [ 'viewer' ],
    { kind => 'user', name => 'Ana' },
  );

  is_deeply $got, { data => { runtime_type => 'User', payload => 'Ana' } },
    'interface completion delegates to resolved runtime object';
};

subtest 'union runtime completion resolves to object type' => sub {
  my $context = {
    schema => $schema,
    context_value => undef,
  };
  my $info = {
    schema => $schema,
    parent_type => $schema->query,
    field_name => 'search',
  };
  my $got;

  no warnings 'redefine';
  local *GraphQL::Houtou::Execution::PP::_execute_fields = sub {
    my ($ctx, $type, $result) = @_;
    return +{ data => { runtime_type => $type->name, payload => $result->{name} } };
  };

  $got = $SearchResult->_complete_value(
    $context,
    [ { selections => [] } ],
    $info,
    [ 'search' ],
    { kind => 'user', name => 'Ana' },
  );

  is_deeply $got, { data => { runtime_type => 'User', payload => 'Ana' } },
    'union completion delegates to resolved runtime object';
};

subtest 'interface default resolve_type can dispatch by runtime_tag' => sub {
  my $context = {
    schema => $schema,
    context_value => undef,
  };
  my $info = {
    schema => $schema,
    parent_type => $schema->query,
    field_name => 'taggedViewer',
  };
  my $got;

  no warnings 'redefine';
  local *GraphQL::Houtou::Execution::PP::_execute_fields = sub {
    my ($ctx, $type, $result) = @_;
    return +{ data => { runtime_type => $type->name, payload => $result->{name} } };
  };

  $got = $TaggedNode->_complete_value(
    $context,
    [ { selections => [] } ],
    $info,
    [ 'taggedViewer' ],
    { kind => 'tagged-user', name => 'Taro' },
  );

  is_deeply $got, { data => { runtime_type => 'TaggedUser', payload => 'Taro' } },
    'interface default resolve_type uses runtime_tag dispatch';
};

subtest 'union default resolve_type can dispatch by tag_map override' => sub {
  my $context = {
    schema => $schema,
    context_value => undef,
  };
  my $info = {
    schema => $schema,
    parent_type => $schema->query,
    field_name => 'search',
  };
  my $got;

  no warnings 'redefine';
  local *GraphQL::Houtou::Execution::PP::_execute_fields = sub {
    my ($ctx, $type, $result) = @_;
    return +{ data => { runtime_type => $type->name, payload => $result->{name} } };
  };
  $schema->clear_runtime_cache;
  local *GraphQL::Houtou::Schema::prepare_runtime = sub {
    die "prepare_runtime should not run for explicit tag_map dispatch\n";
  };

  $got = $TaggedSearchResult->_complete_value(
    $context,
    [ { selections => [] } ],
    $info,
    [ 'search' ],
    { kind => 'tagged', name => 'Hanako' },
  );

  is_deeply $got, { data => { runtime_type => 'TaggedUser', payload => 'Hanako' } },
    'union default resolve_type uses explicit tag_map dispatch';
};

done_testing;
