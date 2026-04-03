use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;

BEGIN {
    eval {
        require GraphQL::Houtou::XS::Parser;
        GraphQL::Houtou::XS::Parser->import(qw(
            graphqljs_apply_executable_loc_xs
            graphqljs_build_executable_document_xs
            parse_xs
            graphqljs_preprocess_xs
            graphqljs_patch_document_xs
            parse_directives_xs
            tokenize_xs
        ));
        1;
    } or plan skip_all => 'XS parser is not built';
}

use GraphQL::Houtou::Adapter::GraphQLPerlToGraphQLJS qw(convert_document);
use GraphQL::Houtou::GraphQLJS::Canonical qw(parse_canonical_document);

sub var_ref {
    my ($name) = @_;
    return \$name;
}

subtest 'parse_xs handles executable documents', sub {
    my $got = parse_xs('query Q($id: ID = 1){ user(id:$id){ ... { name } } }');
    cmp_deeply $got, [
        {
            kind => 'operation',
            name => 'Q',
            operationType => 'query',
            variables => {
                id => {
                    type => 'ID',
                    default_value => 1,
                },
            },
            selections => [
                {
                    kind => 'field',
                    name => 'user',
                    arguments => {
                        id => var_ref('id'),
                    },
                    selections => [
                        {
                            kind => 'inline_fragment',
                            selections => [
                                {
                                    kind => 'field',
                                    name => 'name',
                                    location => ignore(),
                                },
                            ],
                            location => ignore(),
                        },
                    ],
                    location => ignore(),
                },
            ],
            location => ignore(),
        },
    ];
};

subtest 'parse_xs surfaces parser errors', sub {
    dies_ok { parse_xs('enum Hello { true }') } 'invalid enum still dies';
    like $@->message, qr/Invalid enum value/, 'message preserved';
    is_deeply [ map $@->locations->[0]{$_}, qw(line column) ], [1, 18], 'current location is stable';

    dies_ok { parse_xs('{ ...on }') } 'fragment spread named on still dies';
    like $@->message, qr/Unexpected Name "on"/, 'reserved on message preserved';
};

subtest 'parse_xs reports specific expected tokens', sub {
    dies_ok { parse_xs('query Q { field() }') } 'empty argument list still dies';
    like $@->message, qr/Expected name but got "\)"/, 'argument error names the unexpected token';
    unlike $@->message, qr/Parse document failed for some reason/, 'generic parser message is gone';
};

subtest 'graphqljs_preprocess_xs extracts rewrite metadata', sub {
    my $source = <<'EOF';
interface Resource implements Node {
  id: ID!
}

directive @delegateField repeatable on FIELD

query Q($id: ID @fromContext) {
  user(id: $id) { id }
}

extend type User {
  name: String
}
EOF
    my $meta = graphqljs_preprocess_xs($source);

    cmp_deeply $meta->{extensions}, [
        {
            kind => 'type',
            name => 'User',
            occurrence => 1,
        },
    ];

    cmp_deeply $meta->{interface_implements}, {
        Resource => 1,
    };

    cmp_deeply $meta->{repeatable_directives}, {
        delegateField => 1,
    };

    cmp_deeply $meta->{operation_variable_directives}, [
        {
            id => [
                '@fromContext',
            ],
        },
    ];

    ok scalar @{ $meta->{rewrites} } >= 3, 'rewrite spans are returned';
};

subtest 'graphqljs_preprocess_xs skips empty variable directive metadata', sub {
    my $meta = graphqljs_preprocess_xs('query Q($id: ID, $limit: Int) { user(id: $id) { id } }');

    cmp_deeply $meta->{operation_variable_directives}, [],
        'operations without variable directives do not get empty metadata entries';
};

subtest 'parse_directives_xs parses directive snippets directly', sub {
    my $got = parse_directives_xs(q(@fromContext @clamp(max: 100)));

    cmp_deeply $got, [
        {
            name => 'fromContext',
        },
        {
            name => 'clamp',
            arguments => {
                max => 100,
            },
        },
    ];
};

subtest 'parse_xs accepts empty object values at the core parser layer', sub {
    my $got = parse_xs('query Q($input: Filter = {}) { user(filter: {}) { id } }');

    cmp_deeply $got->[0]{variables}{input}{default_value}, {},
        'empty object default value is accepted';
    cmp_deeply $got->[0]{selections}[0]{arguments}{filter}, {},
        'empty object argument value is accepted';
};

subtest 'tokenize_xs exposes token locations directly', sub {
    my $got = tokenize_xs('query Q($id: ID = 1)');

    cmp_deeply $got, [
        {
            kind => 'NAME',
            text => 'query',
            start => 0,
            end => 5,
            loc => { line => 1, column => 1 },
        },
        {
            kind => 'NAME',
            text => 'Q',
            start => 6,
            end => 7,
            loc => { line => 1, column => 7 },
        },
        {
            kind => 'LPAREN',
            text => '(',
            start => 7,
            end => 8,
            loc => { line => 1, column => 8 },
        },
        {
            kind => 'DOLLAR',
            text => '$',
            start => 8,
            end => 9,
            loc => { line => 1, column => 9 },
        },
        {
            kind => 'NAME',
            text => 'id',
            start => 9,
            end => 11,
            loc => { line => 1, column => 10 },
        },
        {
            kind => 'COLON',
            text => ':',
            start => 11,
            end => 12,
            loc => { line => 1, column => 12 },
        },
        {
            kind => 'NAME',
            text => 'ID',
            start => 13,
            end => 15,
            loc => { line => 1, column => 14 },
        },
        {
            kind => 'EQUALS',
            text => '=',
            start => 16,
            end => 17,
            loc => { line => 1, column => 17 },
        },
        {
            kind => 'INT',
            text => '1',
            start => 18,
            end => 19,
            loc => { line => 1, column => 19 },
        },
        {
            kind => 'RPAREN',
            text => ')',
            start => 19,
            end => 20,
            loc => { line => 1, column => 20 },
        },
    ];
};

subtest 'graphqljs_build_executable_document_xs matches Perl adapter for executable documents', sub {
    my $source = 'query Q($id: ID = 1) @root { user(id: $id) { ...UserFields } } fragment UserFields on User { name }';
    my $legacy = parse_xs($source);
    my $built = graphqljs_build_executable_document_xs($legacy);
    my $expected = convert_document($legacy, {
        no_location => 1,
        skip_location_projection => 1,
    });

    cmp_deeply $built, $expected, 'xs executable builder matches the Perl adapter output';
};

subtest 'graphqljs_build_executable_document_xs matches Perl adapter for empty object values', sub {
    my $source = 'query Q($input: Filter = {}) { user(filter: {}) { id } }';
    my $legacy = parse_xs($source);
    my $built = graphqljs_build_executable_document_xs($legacy);
    my $expected = convert_document($legacy, {
        no_location => 1,
        skip_location_projection => 1,
    });

    cmp_deeply $built, $expected, 'xs executable builder handles empty object values';
};

subtest 'graphqljs_apply_executable_loc_xs locates executable documents directly', sub {
    my $source = 'query Q($id: ID = 1) @root { user(id: $id) { name } }';
    my $doc = parse_canonical_document($source, {
        backend => 'xs',
        no_location => 1,
    });
    my $located = graphqljs_apply_executable_loc_xs($doc, $source);

    isa_ok $located, 'HASH', 'xs helper returns a document hash';
    is_deeply [ map $located->{definitions}[0]{loc}{$_}, qw(line column) ], [1, 1],
        'operation loc is applied directly';
    is_deeply [ map $located->{definitions}[0]{variableDefinitions}[0]{loc}{$_}, qw(line column) ], [1, 9],
        'variable definition loc is applied directly';
    is_deeply [ map $located->{definitions}[0]{selectionSet}{selections}[0]{arguments}[0]{loc}{$_}, qw(line column) ], [1, 35],
        'argument loc is applied directly';
};

done_testing;
