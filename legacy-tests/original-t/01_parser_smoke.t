use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;

use GraphQL::Houtou qw(parse parse_with_options);
use GraphQL::Houtou::GraphQLJS::Parser ();
use GraphQL::Houtou::GraphQLPerl::Parser ();

sub strip_loc {
    my ($value) = @_;
    if (ref $value eq 'HASH') {
        return +{
            map { ($_ => strip_loc($value->{$_})) }
            grep $_ ne 'loc' && $_ ne 'location', sort keys %$value
        };
    }
    if (ref $value eq 'ARRAY') {
        return [ map strip_loc($_), @$value ];
    }
    return $value;
}

subtest 'top-level parse keeps graphql-perl compatibility with XS by default', sub {
    my $got = parse('{ user { id } }');
    my $xs = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options(
        '{ user { id } }',
        { backend => 'xs' },
    );

    cmp_deeply $got, [
        {
            kind => 'operation',
            selections => [
                {
                    kind => 'field',
                    name => 'user',
                    selections => [
                        {
                            kind => 'field',
                            name => 'id',
                            location => ignore(),
                        },
                    ],
                    location => ignore(),
                },
            ],
            location => ignore(),
        },
    ];

    cmp_deeply $got, $xs, 'default top-level parse matches xs backend';
};

subtest 'graphql-perl xs backend is selectable', sub {
    my $got = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options(
        '{ user { id } }',
        { backend => 'xs' },
    );

    is $got->[0]{kind}, 'operation', 'xs backend returns legacy AST';
    is $got->[0]{selections}[0]{name}, 'user', 'field is parsed';
};

subtest 'graphql-js dialect is selectable through facade', sub {
    my $got = parse_with_options(
        'query Q($id: ID @fromContext) { user(id: $id) { id } }',
        { dialect => 'graphql-js' },
    );

    cmp_deeply strip_loc($got), {
        kind => 'Document',
        definitions => [
            {
                kind => 'OperationDefinition',
                operation => 'query',
                name => { kind => 'Name', value => 'Q' },
                variableDefinitions => [
                    {
                        kind => 'VariableDefinition',
                        variable => {
                            kind => 'Variable',
                            name => { kind => 'Name', value => 'id' },
                        },
                        type => {
                            kind => 'NamedType',
                            name => { kind => 'Name', value => 'ID' },
                        },
                        directives => [
                            {
                                kind => 'Directive',
                                name => { kind => 'Name', value => 'fromContext' },
                                arguments => [],
                            },
                        ],
                    },
                ],
                directives => [],
                selectionSet => {
                    kind => 'SelectionSet',
                    selections => [
                        {
                            kind => 'Field',
                            name => { kind => 'Name', value => 'user' },
                            arguments => [
                                {
                                    kind => 'Argument',
                                    name => { kind => 'Name', value => 'id' },
                                    value => {
                                        kind => 'Variable',
                                        name => { kind => 'Name', value => 'id' },
                                    },
                                },
                            ],
                            directives => [],
                            selectionSet => {
                                kind => 'SelectionSet',
                                selections => [
                                    {
                                        kind => 'Field',
                                        name => { kind => 'Name', value => 'id' },
                                        arguments => [],
                                        directives => [],
                                    },
                                ],
                            },
                        },
                    ],
                },
            },
        ],
    };
};

subtest 'string unicode escapes are decoded on XS paths', sub {
    my $legacy = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options(
        '{ user(arg: "\\u0041\\u03A9", emoji: "\\uD83D\\uDE00") }',
        { backend => 'xs' },
    );
    my $canonical = GraphQL::Houtou::GraphQLJS::Parser::parse(
        'query Q { user(arg: "\\u0041\\u03A9", emoji: "\\uD83D\\uDE00") }',
    );

    is $legacy->[0]{selections}[0]{arguments}{arg}, "A\x{03A9}", 'legacy XS decodes BMP unicode escapes';
    is $legacy->[0]{selections}[0]{arguments}{emoji}, "\x{1F600}", 'legacy XS decodes surrogate pair escapes';
    is $canonical->{definitions}[0]{selectionSet}{selections}[0]{arguments}[0]{value}{value}, "A\x{03A9}",
        'graphql-js XS decodes BMP unicode escapes';
    is $canonical->{definitions}[0]{selectionSet}{selections}[0]{arguments}[1]{value}{value}, "\x{1F600}",
        'graphql-js XS decodes surrogate pair escapes';
};

subtest 'invalid unicode escapes still die explicitly on XS paths', sub {
    dies_ok {
        GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options(
            '{ user(arg: "\\u00GG") }',
            { backend => 'xs' },
        );
    } 'legacy XS rejects invalid unicode escape';
    like $@->message, qr/Invalid Unicode escape sequence/, 'legacy XS preserves unicode escape error';

    dies_ok {
        GraphQL::Houtou::GraphQLJS::Parser::parse(
            'query Q { user(arg: "\\u00GG") }',
        );
    } 'graphql-js XS rejects invalid unicode escape';
    like $@->message, qr/Invalid Unicode escape sequence/, 'graphql-js XS preserves unicode escape error';
};

subtest 'invalid backend is rejected explicitly', sub {
    dies_ok {
        GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options('{ field }', {
            backend => 'unknown',
        });
    } 'unknown backend dies';
};

done_testing;
