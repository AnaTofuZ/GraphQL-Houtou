use strict;
use warnings;

use Test::More;

use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Interface;
use GraphQL::Houtou::Type::InputObject;
use GraphQL::Houtou::Type::Union;
use GraphQL::Houtou::Type::Scalar qw($String $Int $ID);

my $Node = GraphQL::Houtou::Type::Interface->new(
  name => 'Node',
  fields => { id => { type => $ID } },
);

my $Pet;
$Pet = GraphQL::Houtou::Type::Interface->new(
  name => 'Pet',
  fields => sub { {
    name => { type => $String->non_null },
    friend => { type => $Pet },
  } },
);

sub query_with {
  my (%fields) = @_;
  return GraphQL::Houtou::Type::Object->new(name => 'Query', fields => { %fields });
}

sub build_errors {
  my ($schema) = @_;
  eval { $schema->build_runtime };
  return $@;
}

subtest 'a valid schema passes and memoizes' => sub {
  my $Dog = GraphQL::Houtou::Type::Object->new(
    name => 'Dog',
    interfaces => [ $Node ],
    fields => { id => { type => $ID->non_null }, bark => { type => $String } },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(dog => { type => $Dog, resolve => sub { {} } }),
  );
  is_deeply $schema->validation_errors, [], 'no validation errors';
  ok eval { $schema->build_runtime; 1 }, 'build_runtime succeeds' or diag $@;
  ok $schema->{_schema_validated}, 'validation result is memoized';
};

subtest 'non-null covariance against nullable interface field is allowed' => sub {
  my $Dog = GraphQL::Houtou::Type::Object->new(
    name => 'Dog',
    interfaces => [ $Node ],
    fields => { id => { type => $ID->non_null } },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(dog => { type => $Dog }),
  );
  is_deeply $schema->validation_errors, [], 'ID! satisfies interface field of type ID';
};

subtest 'missing interface field is rejected' => sub {
  my $Cat = GraphQL::Houtou::Type::Object->new(
    name => 'Cat',
    interfaces => [ $Node ],
    fields => { meow => { type => $String } },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(cat => { type => $Cat }),
  );
  my $error = build_errors($schema);
  like $error, qr/Interface field Node\.id expected but Cat does not provide it/,
    'missing field reported';
};

subtest 'field type mismatch is rejected' => sub {
  my $Cat = GraphQL::Houtou::Type::Object->new(
    name => 'Cat',
    interfaces => [ $Node ],
    fields => { id => { type => $Int } },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(cat => { type => $Cat }),
  );
  like build_errors($schema),
    qr/Interface field Node\.id expects type ID but Cat\.id is type Int/,
    'incompatible field type reported';
};

subtest 'covariant object field type against interface-typed field' => sub {
  my $Dog; $Dog = GraphQL::Houtou::Type::Object->new(
    name => 'Dog',
    interfaces => [ $Pet ],
    fields => sub { {
      name => { type => $String->non_null },
      friend => { type => $Dog },
    } },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(dog => { type => $Dog }),
    types => [ $Dog, $Pet ],
  );
  is_deeply $schema->validation_errors, [],
    'Dog.friend: Dog satisfies Pet.friend: Pet because Dog implements Pet';
};

subtest 'missing interface field argument is rejected' => sub {
  my $Sized = GraphQL::Houtou::Type::Interface->new(
    name => 'Sized',
    fields => {
      size => { type => $Int, args => { unit => { type => $String } } },
    },
  );
  my $Box = GraphQL::Houtou::Type::Object->new(
    name => 'Box',
    interfaces => [ $Sized ],
    fields => { size => { type => $Int } },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(box => { type => $Box }),
  );
  like build_errors($schema),
    qr/Interface field argument Sized\.size\(unit:\) expected but Box\.size does not provide it/,
    'missing argument reported';
};

subtest 'interface argument type must match invariantly' => sub {
  my $Sized = GraphQL::Houtou::Type::Interface->new(
    name => 'Sized',
    fields => {
      size => { type => $Int, args => { unit => { type => $String } } },
    },
  );
  my $Box = GraphQL::Houtou::Type::Object->new(
    name => 'Box',
    interfaces => [ $Sized ],
    fields => {
      size => { type => $Int, args => { unit => { type => $Int } } },
    },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(box => { type => $Box }),
  );
  like build_errors($schema),
    qr/Interface field argument Sized\.size\(unit:\) expects type String but Box\.size\(unit:\) is type Int/,
    'argument type mismatch reported';
};

subtest 'additional required argument on object field is rejected' => sub {
  my $Sized = GraphQL::Houtou::Type::Interface->new(
    name => 'Sized',
    fields => { size => { type => $Int } },
  );
  my $Box = GraphQL::Houtou::Type::Object->new(
    name => 'Box',
    interfaces => [ $Sized ],
    fields => {
      size => { type => $Int, args => { unit => { type => $String->non_null } } },
    },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(box => { type => $Box }),
  );
  like build_errors($schema),
    qr/Object field Box\.size includes required argument unit that is missing from the Interface field Sized\.size/,
    'extra required argument reported';

  my $BoxWithDefault = GraphQL::Houtou::Type::Object->new(
    name => 'BoxWithDefault',
    interfaces => [ $Sized ],
    fields => {
      size => {
        type => $Int,
        args => { unit => { type => $String->non_null, default_value => 'cm' } },
      },
    },
  );
  my $ok_schema = GraphQL::Houtou::Schema->new(
    query => query_with(box => { type => $BoxWithDefault }),
  );
  is_deeply $ok_schema->validation_errors, [],
    'extra required argument with default value is allowed';
};

subtest 'input object fields must be input types' => sub {
  my $Payload = GraphQL::Houtou::Type::Object->new(
    name => 'Payload',
    fields => { ok => { type => $String } },
  );
  my $BadInput = GraphQL::Houtou::Type::InputObject->new(
    name => 'BadInput',
    fields => { payload => { type => $Payload } },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(
      find => { type => $String, args => { input => { type => $BadInput } } },
    ),
  );
  like build_errors($schema),
    qr/The type of BadInput\.payload must be Input Type but got: Payload/,
    'output type in input position reported';
};

subtest 'argument types must be input types' => sub {
  my $Payload = GraphQL::Houtou::Type::Object->new(
    name => 'Payload',
    fields => { ok => { type => $String } },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(
      find => { type => $String, args => { payload => { type => $Payload } } },
    ),
  );
  like build_errors($schema),
    qr/The type of Query\.find\(payload:\) must be Input Type but got: Payload/,
    'object type as argument reported';
};

subtest 'union members must be object types' => sub {
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(
      thing => {
        type => GraphQL::Houtou::Type::Union->new(
          name => 'Thing',
          types => [ $String ],
        ),
      },
    ),
  );
  like build_errors($schema),
    qr/Union type Thing can only include Object types, found String/,
    'scalar union member reported';
};

subtest 'validation errors accumulate' => sub {
  my $Cat = GraphQL::Houtou::Type::Object->new(
    name => 'Cat',
    interfaces => [ $Node, $Pet ],
    fields => { meow => { type => $String } },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(cat => { type => $Cat }),
  );
  my $errors = $schema->validation_errors;
  cmp_ok scalar(@$errors), '>=', 3, 'reports all missing interface fields at once';
};

subtest 'root operation types must be distinct objects' => sub {
  my $shared = query_with(value => { type => $String });
  my $same_roots = GraphQL::Houtou::Schema->new(
    query => $shared,
    mutation => $shared,
  );
  like join("\n", @{ $same_roots->validation_errors }),
    qr/root types must be different; Query is used more than once/,
    'the same object cannot be used for two operation roots';

  my $scalar_root = GraphQL::Houtou::Schema->new(query => $String);
  like join("\n", @{ $scalar_root->validation_errors }),
    qr/query root type must be an Object type, found String/,
    'query root must be an object type';
};

subtest 'user-defined type-system names cannot use the introspection prefix' => sub {
  my $Bad = GraphQL::Houtou::Type::Object->new(
    name => '__Bad',
    fields => { __field => { type => $String } },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => query_with(
      bad => {
        type => $Bad,
        args => { __arg => { type => $String } },
      },
    ),
    types => [ $Bad ],
  );
  my $errors = join("\n", @{ $schema->validation_errors });
  like $errors, qr/Type must not begin with '__'/, 'reserved type name rejected';
  like $errors, qr/Field __Bad\.__field must not begin with '__'/,
    'reserved field name rejected';
  like $errors, qr/Argument Query\.bad\(__arg:\) must not begin with '__'/,
    'reserved argument name rejected';
};

done_testing;
