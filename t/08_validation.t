use strict;
use warnings;

use Test::More 0.98;

use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Interface;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($Boolean $String);
use GraphQL::Houtou::Schema qw(lookup_type);

use GraphQL::Houtou::Validation qw(validate);
use GraphQL::Houtou::XS::Validation qw(validate_xs);

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
  types => [ $User, $Node ],
);

sub messages {
  my ($errors) = @_;
  return [ map $_->{message}, @$errors ];
}

subtest 'XS validation entrypoint matches facade behavior' => sub {
  my $source = q|{
    viewer {
      id
      name
    }
  }|;

  is_deeply validate_xs($schema, $source), validate($schema, $source),
    'XS path currently matches the public facade';

  $source = q|
    query Q { viewer { id } }
    query Q { viewer { name } }
  |;

  is_deeply validate_xs($schema, $source), validate($schema, $source),
    'XS path matches duplicate-operation validation too';

  $source = q|
    subscription S {
      importantUser { id }
      otherUser { id }
    }
  |;

  is_deeply validate_xs($schema, $source), validate($schema, $source),
    'XS path matches subscription root-field validation too';

  $source = q|
    query Q { viewer { ...Loop } }
    fragment Loop on MissingType { ...Loop }
  |;

  is_deeply validate_xs($schema, $source), validate($schema, $source),
    'XS path matches fragment-cycle validation too';
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

done_testing;
