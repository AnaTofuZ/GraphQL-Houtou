use strict;
use warnings;

use Test::More 0.98;

use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Directive;
use GraphQL::Houtou::Type::Interface;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($Boolean $String);
use GraphQL::Houtou::Schema qw(lookup_type);

use GraphQL::Houtou::Validation qw(validate);

my $Node;
my $User;
my $Page;

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
  },
);

$Page = GraphQL::Houtou::Type::Object->new(
  name => 'Page',
  interfaces => [ $Node ],
  fields => {
    id => { type => $String->non_null },
    title => { type => $String },
  },
);

my $Mutation = GraphQL::Houtou::Type::Object->new(
  name => 'Mutation',
  fields => {
    renameUser => {
      type => $User,
      args => {
        id => { type => $String->non_null },
        name => { type => $String->non_null },
      },
      resolve => sub { +{} },
    },
  },
);

my $Subscription = GraphQL::Houtou::Type::Object->new(
  name => 'Subscription',
  fields => {
    importantUser => {
      type => $User,
      resolve => sub { +{} },
    },
    otherUser => {
      type => $User,
      resolve => sub { +{} },
    },
  },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'Query',
    fields => {
      viewer => {
        type => $User,
        directives => [],
        resolve => sub { +{} },
      },
      node => {
        type => $Node,
        args => {
          id => { type => $String->non_null },
        },
        resolve => sub { +{} },
      },
    },
  ),
  mutation => $Mutation,
  subscription => $Subscription,
  types => [ $User, $Page, $Node ],
  directives => [
    @GraphQL::Houtou::Directive::SPECIFIED_DIRECTIVES,
    GraphQL::Houtou::Directive->new(
      name => 'mask',
      locations => [ qw(FIELD) ],
      args => {
        enabled => { type => $Boolean->non_null },
      },
    ),
    GraphQL::Houtou::Directive->new(
      name => 'tag',
      repeatable => 1,
      locations => [ qw(FIELD) ],
      args => {
        name => { type => $String->non_null },
      },
    ),
  ],
);

sub messages {
  my ($errors) = @_;
  return [ map $_->{message}, @$errors ];
}

subtest 'validation facade stays minimal' => sub {
  is_deeply [ sort @GraphQL::Houtou::Validation::EXPORT_OK ], [qw(validate)],
    'only validate is exported as public API';
  ok(
    GraphQL::Houtou::Validation->can('validate'),
    'public validate entrypoint exists',
  );
  ok(
    !GraphQL::Houtou::Validation->can('validate_xs'),
    'internal XS symbol is not exposed as public facade method',
  );
};

subtest 'valid query passes' => sub {
  my $errors = validate($schema, q|{
    viewer {
      id
      name
    }
  }|);

  is_deeply $errors, [], 'no validation errors';
};

subtest 'lookup_type resolves Houtou wrappers' => sub {
  my $type = lookup_type(
    { type => [ list => { type => [ non_null => { type => 'String' } ] } ] },
    $schema->name2type,
  );

  isa_ok $type, 'GraphQL::Houtou::Type::List';
  isa_ok $type->of, 'GraphQL::Houtou::Type::NonNull';
  isa_ok $type->of->of, 'GraphQL::Houtou::Type::Scalar';
  is $type->of->of->name, 'String', 'named leaf stays Houtou scalar';
};

subtest 'duplicate operation names are rejected' => sub {
  my $errors = validate($schema, q|
    query Q { viewer { id } }
    query Q { viewer { name } }
  |);

  is_deeply messages($errors), [
    "Operation 'Q' is defined more than once.",
  ];
};

subtest 'duplicate fragment names are rejected' => sub {
  my $errors = validate($schema, q|
    query Q { viewer { ...UserFields } }
    fragment UserFields on User { id }
    fragment UserFields on User { name }
  |);

  is_deeply messages($errors), [
    "Fragment 'UserFields' is defined more than once.",
  ];
};

subtest 'duplicate arguments and variables are rejected before hash overwrite' => sub {
  my $errors = validate($schema, q|{
    node(id: "first", id: "second") { id }
  }|);
  is_deeply messages($errors), [
    "Argument 'id' is provided more than once.",
  ], 'duplicate field arguments are retained as validation diagnostics';

  $errors = validate($schema, q|
    query Q($id: String!, $id: String!) { node(id: $id) { id } }
  |);
  is_deeply messages($errors), [
    "Variable '\$id' is defined more than once.",
  ], 'duplicate variable definitions are retained as validation diagnostics';
};

subtest 'leaf and composite fields require the correct selection shape' => sub {
  my $errors = validate($schema, q|{
    viewer
  }|);
  is_deeply messages($errors), [
    "Field 'viewer' of type 'User' must have a selection of subfields.",
  ], 'composite field without a selection is rejected';

  $errors = validate($schema, q|{
    viewer { name { id } }
  }|);
  is_deeply messages($errors), [
    "Field 'name' must not have a selection since type 'String' has no subfields.",
  ], 'leaf field with a selection is rejected without cascading errors';
};

subtest 'direct fields with the same response key must merge' => sub {
  my $errors = validate($schema, q|{
    viewer { value: id value: name }
  }|);
  is_deeply messages($errors), [
    "Fields 'value' conflict because they select different fields or arguments.",
  ], 'aliases cannot merge different fields';

  $errors = validate($schema, q|{
    first: node(id: "1") { id }
    first: node(id: "2") { id }
  }|);
  is_deeply messages($errors), [
    "Fields 'first' conflict because they select different fields or arguments.",
  ], 'the same field with different arguments conflicts';

  $errors = validate($schema, q|{
    viewer { value: name value: name }
  }|);
  is_deeply $errors, [], 'identical fields can merge';

  my $duplicate_flood = join ' ', ('value: name') x 1_000;
  $errors = validate($schema, "{ viewer { $duplicate_flood } }");
  is_deeply $errors, [], 'same-key duplicate floods stay mergeable';
};

subtest 'field merging expands fragments and respects exclusive types' => sub {
  my $errors = validate($schema, q|
    query Q { viewer { ...A ...B } }
    fragment A on User { value: id }
    fragment B on User { value: name }
  |);
  is_deeply messages($errors), [
    "Fields 'value' conflict because they select different fields or arguments.",
  ], 'conflicts across fragment spreads are rejected';

  $errors = validate($schema, q|{
    node(id: "1") {
      ... on User { value: name }
      ... on Page { value: title }
    }
  }|);
  is_deeply $errors, [], 'different object type conditions are mutually exclusive'
    or diag explain $errors;

  $errors = validate($schema, q|{
    node(id: "1") {
      ... on User { value: name }
      ... on Page { value: id }
    }
  }|);
  is_deeply messages($errors), [
    "Fields 'value' conflict because they select different fields or arguments.",
  ], 'exclusive fields must still have the same response shape';
};

subtest 'merged composite fields validate their combined subfields' => sub {
  my $errors = validate($schema, q|{
    first: viewer { value: id }
    first: viewer { value: name }
  }|);
  is_deeply messages($errors), [
    "Fields 'value' conflict because they select different fields or arguments.",
  ], 'subfield conflicts split across composite fields are rejected';

  $errors = validate($schema, q|{
    first: viewer { id }
    first: viewer { name }
  }|);
  is_deeply $errors, [], 'compatible composite selections merge';

  my $composite_flood = join ' ', ('first: viewer { id }') x 1_000;
  $errors = validate($schema, "{ $composite_flood }");
  is_deeply $errors, [], 'same-key composite floods stay mergeable';
};

subtest 'anonymous operation must be alone' => sub {
  my $errors = validate($schema, q|
    { viewer { id } }
    query Q { viewer { id } }
  |);

  is_deeply messages($errors), [
    'Anonymous operations must be the only operation in the document.',
  ];
};

subtest 'unknown field and missing required argument are rejected' => sub {
  my $errors = validate($schema, q|{
    viewer {
      missing
    }
    node {
      id
    }
  }|);

  is_deeply messages($errors), [
    "Field 'missing' does not exist on type 'User'.",
    "Required argument 'id' was not provided.",
  ];
};

subtest 'output types cannot be used as variables' => sub {
  my $errors = validate($schema, q|
    query Q($user: User) {
      viewer { id }
    }
  |);

  is_deeply messages($errors), [
    "Variable '\$user' is never used in operation 'Q'.",
    "Variable '\$user' is type 'User' which cannot be used as an input type.",
  ];
};

subtest 'undefined variable use is rejected' => sub {
  my $errors = validate($schema, q|{
    node(id: $id) {
      id
    }
  }|);

  is_deeply messages($errors), [
    "Variable '\$id' is used but not defined.",
  ];
};

subtest 'field arguments enforce variable positions in XS' => sub {
  my $errors = validate($schema, q|
    query Q($id: Boolean) { node(id: $id) { id } }
  |);
  is_deeply messages($errors), [
    "Variable '\$id' cannot be used for argument 'id' because its type is incompatible.",
  ];

  $errors = validate($schema, q|
    query Q($id: String = "1") { node(id: $id) { id } }
  |);
  is_deeply $errors, [], 'a non-null variable default permits a nullable variable';
};

subtest 'built-in scalar literals are validated in XS' => sub {
  my $errors = validate($schema, q|{
    node(id: true) { id }
  }|);
  is_deeply messages($errors), [
    'Value is not a valid String literal.',
  ];
};

subtest 'variable default values are validated in XS' => sub {
  my $errors = validate($schema, q|
    query Q($id: String = true) { node(id: $id) { id } }
  |);
  is_deeply messages($errors), [
    'Value is not a valid String literal.',
  ], 'a variable default must match its declared input type';

  $errors = validate($schema, q|
    query Q($id: String = "1") { node(id: $id) { id } }
  |);
  is_deeply $errors, [], 'a correctly typed variable default is accepted';
};

subtest 'unused variables are rejected, including fragment-aware usage' => sub {
  my $errors = validate($schema, q|
    query Q($used: String!, $unused: String) {
      node(id: "1") { ...UserName }
    }
    fragment UserName on User { name @include(if: $used) }
  |);

  is_deeply messages($errors), [
    "Variable '\$unused' is never used in operation 'Q'.",
  ], 'a variable used through a fragment counts as used';
};

subtest 'unused fragments are rejected using transitive operation reachability' => sub {
  my $errors = validate($schema, q|
    query Q { viewer { ...Outer } }
    fragment Outer on User { ...Inner }
    fragment Inner on User { id }
    fragment Unused on User { name }
  |);

  is_deeply messages($errors), [
    "Fragment 'Unused' is never used.",
  ], 'transitively reached fragments are used';
};

subtest 'unknown fragment targets and cycles are rejected' => sub {
  my $errors = validate($schema, q|
    query Q { viewer { ...Loop } }
    fragment Loop on MissingType { ...Loop }
  |);

  is_deeply messages($errors), [
    "Fragment 'Loop' references unknown type 'MissingType'.",
    "Fragment 'Loop' participates in a cycle.",
  ];
};

subtest 'fragment spreads must be type-compatible' => sub {
  my $errors = validate($schema, q|
    query Q {
      viewer {
        ...OnQuery
      }
    }

    fragment OnQuery on Query {
      viewer { id }
    }
  |);

  is_deeply messages($errors), [
    "Fragment 'OnQuery' cannot be spread here because type 'Query' can never apply to 'User'.",
  ];
};

subtest 'inline fragments must be type-compatible' => sub {
  my $errors = validate($schema, q|
    query Q {
      viewer {
        ... on Query {
          viewer { id }
        }
      }
    }
  |);

  is_deeply messages($errors), [
    "Inline fragment on 'Query' cannot be used where type 'User' is expected.",
  ];
};

subtest 'subscription must have a single top-level field' => sub {
  my $errors = validate($schema, q|
    subscription S {
      importantUser { id }
      otherUser { id }
    }
  |);

  is_deeply messages($errors), [
    'Subscription needs to have only one field; got (importantUser otherUser)',
  ];
};

subtest 'directive validation rejects unknown directives and invalid locations' => sub {
  my $errors = validate($schema, q|
    query Q @skip(if: true) {
      viewer {
        id @unknown
      }
    }
  |);

  is_deeply messages($errors), [
    "Directive '\@skip' may not be used on QUERY.",
    "Unknown directive '\@unknown'.",
  ];
};

subtest 'directive validation rejects duplicate non-repeatable directives' => sub {
  my $errors = validate($schema, q|
    {
      viewer {
        id @mask(enabled: true) @mask(enabled: false)
        name @tag(name: "a") @tag(name: "b")
      }
    }
  |);

  is_deeply messages($errors), [
    "Directive '\@mask' is not repeatable and cannot be used more than once at this location.",
  ];
};

subtest 'directive validation checks required and unknown arguments' => sub {
  my $errors = validate($schema, q|
    {
      viewer {
        id @skip
        name @mask(enabled: true, extra: false)
      }
    }
  |);

  is_deeply messages($errors), [
    "Required argument 'if' was not provided to directive '\@skip'.",
    "Unknown argument 'extra' on directive '\@mask'.",
  ];
};

subtest 'directive validation checks literal argument types' => sub {
  my $errors = validate($schema, q|
    {
      viewer {
        id @skip(if: "nope")
      }
    }
  |);

  is_deeply messages($errors), [
    q{Argument 'if' on directive '@skip' has invalid value: Not a Boolean.},
  ];
};

done_testing;
