use strict;
use warnings;

use Test::More 0.98;

use GraphQL::Schema;
use GraphQL::Type::Interface;
use GraphQL::Type::Object;
use GraphQL::Type::Scalar qw($Boolean $String);

use GraphQL::Houtou::Validation qw(validate);

my $Node;
my $User;

$Node = GraphQL::Type::Interface->new(
  name => 'Node',
  fields => {
    id => { type => $String->non_null },
  },
  resolve_type => sub { $User },
);

$User = GraphQL::Type::Object->new(
  name => 'User',
  interfaces => [ $Node ],
  fields => {
    id => { type => $String->non_null },
    name => { type => $String },
  },
);

my $Mutation = GraphQL::Type::Object->new(
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

my $Subscription = GraphQL::Type::Object->new(
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

my $schema = GraphQL::Schema->new(
  query => GraphQL::Type::Object->new(
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

subtest 'valid query passes' => sub {
  my $errors = validate($schema, q|{
    viewer {
      id
      name
    }
  }|);

  is_deeply $errors, [], 'no validation errors';
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
