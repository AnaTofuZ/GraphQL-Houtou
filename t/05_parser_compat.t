use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;
use JSON::PP ();

use GraphQL::Houtou qw(parse);

BEGIN {
    eval {
        require GraphQL::Houtou::XS::Parser;
        GraphQL::Houtou::XS::Parser->import('parse_xs');
        1;
    };
}

sub var_ref {
    my ($name) = @_;
    return \$name;
}

sub enum_ref {
    my ($name) = @_;
    my $value = \$name;
    return \$value;
}

sub strip_location {
    my ($value) = @_;
    if (ref $value eq 'HASH') {
        return +{
            map { ($_ => strip_location($value->{$_})) }
            grep $_ ne 'location', sort keys %$value
        };
    }
    if (ref $value eq 'ARRAY') {
        return [ map strip_location($_), @$value ];
    }
    return $value;
}

subtest 'executable document AST stays compatible', sub {
    my $got = parse(<<'EOF');
query Q($id: ID = 1, $flag: Boolean = false) @root {
  user: node(id: $id) @include(if: $flag) {
    ...F
    ... on User @skip(if: false) {
      name
      role
    }
  }
}

fragment F on User {
  role(status: ACTIVE)
}
EOF

    my $expected = [
        {
            kind => 'operation',
            location => { line => 11, column => 1 },
            name => 'Q',
            operationType => 'query',
            directives => [
                { name => 'root' },
            ],
            variables => {
                id => {
                    type => 'ID',
                    default_value => 1,
                },
                flag => {
                    type => 'Boolean',
                    default_value => JSON::PP::false,
                },
            },
            selections => [
                {
                    kind => 'field',
                    location => { line => 9, column => 1 },
                    alias => 'user',
                    name => 'node',
                    arguments => {
                        id => var_ref('id'),
                    },
                    directives => [
                        {
                            name => 'include',
                            arguments => {
                                if => var_ref('flag'),
                            },
                        },
                    ],
                    selections => [
                        {
                            kind => 'fragment_spread',
                            location => { line => 4, column => 5 },
                            name => 'F',
                        },
                        {
                            kind => 'inline_fragment',
                            location => { line => 8, column => 3 },
                            on => 'User',
                            directives => [
                                {
                                    name => 'skip',
                                    arguments => {
                                        if => JSON::PP::false,
                                    },
                                },
                            ],
                            selections => [
                                {
                                    kind => 'field',
                                    location => { line => 6, column => 7 },
                                    name => 'name',
                                },
                                {
                                    kind => 'field',
                                    location => { line => 7, column => 5 },
                                    name => 'role',
                                },
                            ],
                        },
                    ],
                },
            ],
        },
        {
            kind => 'fragment',
            location => { line => 14, column => 1 },
            name => 'F',
            on => 'User',
            selections => [
                {
                    kind => 'field',
                    location => { line => 13, column => 1 },
                    name => 'role',
                    arguments => {
                        status => enum_ref('ACTIVE'),
                    },
                },
            ],
        },
    ];

    cmp_deeply $got, $expected;
};

subtest 'type system AST stays compatible', sub {
    my $got = parse(<<'EOF');
"Type doc"
type User implements Node & Actor @entity {
  "Role doc"
  role(status: Status = ACTIVE): String @deprecated
}

enum Status { ACTIVE INACTIVE }

extend type User { name: String }

directive @entity on OBJECT | INTERFACE

schema { query: Query mutation: Mutation }
EOF

    my $expected = [
        {
            kind => 'type',
            location => { line => 5, column => 0 },
            description => 'Type doc',
            name => 'User',
            interfaces => [qw(Node Actor)],
            directives => [
                { name => 'entity' },
            ],
            fields => {
                role => {
                    description => 'Role doc',
                    type => 'String',
                    directives => [
                        { name => 'deprecated' },
                    ],
                    args => {
                        status => {
                            type => 'Status',
                            default_value => enum_ref('ACTIVE'),
                        },
                    },
                },
            },
        },
        {
            kind => 'enum',
            location => { line => 7, column => 0 },
            name => 'Status',
            values => {
                ACTIVE => {},
                INACTIVE => {},
            },
        },
        {
            kind => 'type',
            location => { line => 9, column => 0 },
            name => 'User',
            fields => {
                name => {
                    type => 'String',
                },
            },
        },
        {
            kind => 'directive',
            location => { line => 11, column => 0 },
            name => 'entity',
            locations => [qw(OBJECT INTERFACE)],
        },
        {
            kind => 'schema',
            location => { line => 13, column => 0 },
            query => 'Query',
            mutation => 'Mutation',
        },
    ];

    cmp_deeply $got, $expected;
};

subtest 'errors keep message fragments and positions', sub {
    dies_ok { parse('fragment on on on { on }') } 'reserved on remains rejected';
    like $@->message, qr/Unexpected Name "on"/, 'reserved on message';
    is_deeply [ map $@->locations->[0]{$_}, qw(line column) ], [1, 12], 'reserved on location';

    dies_ok { parse('enum Hello { true }') } 'enum true remains rejected';
    like $@->message, qr/Invalid enum value/, 'enum true message';
    is_deeply [ map $@->locations->[0]{$_}, qw(line column) ], [1, 18], 'enum true location';
};

subtest 'strict grammar edge cases stay compatible', sub {
    dies_ok { parse('{}') } 'empty selection set stays rejected';
    like $@->message, qr/Expected name/, 'empty selection set message';

    dies_ok { parse('query Q()') } 'empty variable definitions stay rejected';
    like $@->message, qr/Expected \$argument: Type/, 'empty variable definitions message';

    dies_ok { parse('query Q { f(arg: {}) }') } 'empty object literal stays rejected';
    like $@->message, qr/Expected name/, 'empty object literal message';
    is_deeply [ map $@->locations->[0]{$_}, qw(line column) ], [1, 19], 'empty object literal location';
};

subtest 'noLocation flag stays ignored for compatibility', sub {
    my $source = <<'EOF';
query Q {
  user {
    id
  }
}
EOF

    my $pegex_with_locations = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, {
        backend => 'pegex',
        no_location => 0,
    });
    my $pegex_without_locations = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, {
        backend => 'pegex',
        no_location => 1,
    });
    cmp_deeply $pegex_without_locations, $pegex_with_locations,
        'Pegex ignores noLocation and keeps locations';

    SKIP: {
        skip 'XS parser is not built', 1 unless defined &parse_xs;

        my $xs_with_locations = parse_xs($source, 0);
        my $xs_without_locations = parse_xs($source, 1);
        cmp_deeply $xs_without_locations, $xs_with_locations,
            'parse_xs also ignores noLocation';
    }
};

subtest 'canonical-xs can reproduce graphql-perl compatibility shape', sub {
    my $source = <<'EOF';
query Q($id: ID = 1, $flag: Boolean = false) @root {
  user: node(id: $id) @include(if: $flag) {
    ...F
    ... on User @skip(if: false) {
      name
      role
    }
  }
}

fragment F on User {
  role(status: ACTIVE)
}
EOF

    my $legacy_xs = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, {
        backend => 'xs',
    });
    my $canonical_xs = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, {
        backend => 'canonical-xs',
    });

    cmp_deeply strip_location($canonical_xs), strip_location($legacy_xs),
        'canonical-xs matches xs on executable document shape';
};

subtest 'canonical-xs can reproduce graphql-perl type system shape', sub {
    my $source = <<'EOF';
"Type doc"
type User implements Node & Actor @entity {
  "Role doc"
  role(status: Status = ACTIVE): String @deprecated
}

enum Status { ACTIVE INACTIVE }

extend type User { name: String }

directive @entity on OBJECT | INTERFACE

schema { query: Query mutation: Mutation }
EOF

    my $legacy_xs = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, {
        backend => 'xs',
    });
    my $canonical_xs = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, {
        backend => 'canonical-xs',
    });

    cmp_deeply strip_location($canonical_xs), strip_location($legacy_xs),
        'canonical-xs matches xs on type system shape';
};

done_testing;
