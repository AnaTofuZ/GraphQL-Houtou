use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;

BEGIN {
    eval {
        require GraphQL::Houtou::XS::Parser;
        GraphQL::Houtou::XS::Parser->import(qw(
            parse_xs
            graphqljs_preprocess_xs
            graphqljs_patch_document_xs
            parse_directives_xs
            tokenize_xs
        ));
        1;
    } or plan skip_all => 'XS parser is not built';
}

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

done_testing;
