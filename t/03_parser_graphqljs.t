use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;

use GraphQL::Houtou qw(parse_with_options);
use GraphQL::Houtou::GraphQLJS::Parser qw(parse);

sub strip_loc {
    my ($value) = @_;
    if (ref $value eq 'HASH') {
        return +{
            map { ($_ => strip_loc($value->{$_})) }
            grep $_ ne 'loc', sort keys %$value
        };
    }
    if (ref $value eq 'ARRAY') {
        return [ map strip_loc($_), @$value ];
    }
    return $value;
}

subtest 'graphql-js dialect converts executable documents', sub {
    my $got = parse(q(query Q($id: ID = 1) @root { user(id: $id) { name } }));

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
                        defaultValue => {
                            kind => 'IntValue',
                            value => '1',
                        },
                        directives => [],
                    },
                ],
                directives => [
                    {
                        kind => 'Directive',
                        name => { kind => 'Name', value => 'root' },
                        arguments => [],
                    },
                ],
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
                                        name => { kind => 'Name', value => 'name' },
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

subtest 'graphql-js dialect supports repeatable and variable directives', sub {
    my $directive = parse(q(directive @delegateField(name: String!) repeatable on OBJECT | INTERFACE));
    my $query = parse(q(query Q($id: ID @fromContext, $limit: Int = 10 @clamp(max: 100)) { user(id: $id) { id } }));

    cmp_deeply strip_loc($directive), {
        kind => 'Document',
        definitions => [
            {
                kind => 'DirectiveDefinition',
                name => { kind => 'Name', value => 'delegateField' },
                arguments => [
                    {
                        kind => 'InputValueDefinition',
                        name => { kind => 'Name', value => 'name' },
                        type => {
                            kind => 'NonNullType',
                            type => {
                                kind => 'NamedType',
                                name => { kind => 'Name', value => 'String' },
                            },
                        },
                        directives => [],
                    },
                ],
                repeatable => 1,
                locations => [
                    { kind => 'Name', value => 'OBJECT' },
                    { kind => 'Name', value => 'INTERFACE' },
                ],
            },
        ],
    };

    cmp_deeply strip_loc($query->{definitions}[0]{variableDefinitions}), [
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
        {
            kind => 'VariableDefinition',
            variable => {
                kind => 'Variable',
                name => { kind => 'Name', value => 'limit' },
            },
            type => {
                kind => 'NamedType',
                name => { kind => 'Name', value => 'Int' },
            },
            defaultValue => {
                kind => 'IntValue',
                value => '10',
            },
            directives => [
                {
                    kind => 'Directive',
                    name => { kind => 'Name', value => 'clamp' },
                    arguments => [
                        {
                            kind => 'Argument',
                            name => { kind => 'Name', value => 'max' },
                            value => {
                                kind => 'IntValue',
                                value => '100',
                            },
                        },
                    ],
                },
            ],
        },
    ];
};

subtest 'graphql-js dialect accepts empty object values', sub {
    my $got = parse(q(query Q($input: Filter = {}) { user(filter: {}) { id } }));

    cmp_deeply strip_loc($got->{definitions}[0]{variableDefinitions}), [
        {
            kind => 'VariableDefinition',
            variable => {
                kind => 'Variable',
                name => { kind => 'Name', value => 'input' },
            },
            type => {
                kind => 'NamedType',
                name => { kind => 'Name', value => 'Filter' },
            },
            defaultValue => {
                kind => 'ObjectValue',
                fields => [],
            },
            directives => [],
        },
    ];

    cmp_deeply strip_loc($got->{definitions}[0]{selectionSet}{selections}[0]{arguments}), [
        {
            kind => 'Argument',
            name => { kind => 'Name', value => 'filter' },
            value => {
                kind => 'ObjectValue',
                fields => [],
            },
        },
    ];
};

subtest 'graphql-js dialect converts extension nodes', sub {
    my $got = parse(<<'EOF');
extend schema @wired {
  query: Query
}

extend type User @entity {
  name: String
}
EOF

    cmp_deeply strip_loc($got), {
        kind => 'Document',
        definitions => [
            {
                kind => 'SchemaExtension',
                directives => [
                    {
                        kind => 'Directive',
                        name => { kind => 'Name', value => 'wired' },
                        arguments => [],
                    },
                ],
                operationTypes => [
                    {
                        kind => 'OperationTypeDefinition',
                        operation => 'query',
                        type => {
                            kind => 'NamedType',
                            name => { kind => 'Name', value => 'Query' },
                        },
                    },
                ],
            },
            {
                kind => 'ObjectTypeExtension',
                name => { kind => 'Name', value => 'User' },
                interfaces => [],
                directives => [
                    {
                        kind => 'Directive',
                        name => { kind => 'Name', value => 'entity' },
                        arguments => [],
                    },
                ],
                fields => [
                    {
                        kind => 'FieldDefinition',
                        name => { kind => 'Name', value => 'name' },
                        arguments => [],
                        type => {
                            kind => 'NamedType',
                            name => { kind => 'Name', value => 'String' },
                        },
                        directives => [],
                    },
                ],
            },
        ],
    };
};

subtest 'graphql-js dialect converts directive extensions', sub {
    my $source = q(extend directive @tag on FIELD | FRAGMENT_SPREAD);
    my $got = parse($source);

    cmp_deeply strip_loc($got), {
        kind => 'Document',
        definitions => [
            {
                kind => 'DirectiveExtension',
                name => { kind => 'Name', value => 'tag' },
                arguments => [],
                repeatable => 0,
                locations => [
                    { kind => 'Name', value => 'FIELD' },
                    { kind => 'Name', value => 'FRAGMENT_SPREAD' },
                ],
            },
        ],
    };

    is_deeply [ map $got->{definitions}[0]{loc}{$_}, qw(line column) ], [1, 1],
        'directive extension loc points at extend keyword';
};

subtest 'graphql-js no_location strips loc recursively', sub {
    my $source = 'query Q($id: ID @fromContext) { user(id: $id) { id } }';
    my $with_loc = parse($source);
    my $without_loc = parse($source, { no_location => 1 });

    ok exists $with_loc->{loc}, 'document has loc by default';
    ok !exists $without_loc->{loc}, 'document loc can be stripped';
    ok !exists $without_loc->{definitions}[0]{loc}, 'nested loc is stripped';
    ok !exists $without_loc->{definitions}[0]{variableDefinitions}[0]{directives}[0]{loc}, 'patched directive loc is stripped too';
};

subtest 'graphql-js directive materialization returns independent AST nodes', sub {
    my $source = 'query Q($id: ID @fromContext) { user(id: $id) { id } }';
    my $first = parse($source);
    my $second = parse($source);

    $first->{definitions}[0]{variableDefinitions}[0]{directives}[0]{name}{value} = 'mutated';

    is $second->{definitions}[0]{variableDefinitions}[0]{directives}[0]{name}{value}, 'fromContext',
        'directive AST is not shared across parse results';
};

subtest 'graphql-js lazy/compact loc options fail explicitly when XS fast path is unavailable', sub {
    throws_ok {
        parse('type User { id: ID }', { lazy_location => 1 });
    } qr/require the XS fast path/, 'lazy_location dies explicitly on non-executable fallback path';

    throws_ok {
        parse('type User { id: ID }', { compact_loc => 1 });
    } qr/require the XS fast path/, 'compact_loc dies explicitly on non-executable fallback path';
};

subtest 'graphql-js loc is rebuilt from source tokens on XS path', sub {
    my $got = parse('query Q($id: ID = 1) @root { user(id: $id) { name } }');

    is_deeply [ map $got->{loc}{$_}, qw(line column) ], [1, 1], 'document loc starts at source start';
    is_deeply [ map $got->{definitions}[0]{loc}{$_}, qw(line column) ], [1, 1], 'operation loc points at operation keyword';
    is_deeply [ map $got->{definitions}[0]{name}{loc}{$_}, qw(line column) ], [1, 7], 'operation name loc is precise';
    is_deeply [ map $got->{definitions}[0]{variableDefinitions}[0]{loc}{$_}, qw(line column) ], [1, 9], 'variable definition loc points at $';
    is_deeply [ map $got->{definitions}[0]{variableDefinitions}[0]{type}{loc}{$_}, qw(line column) ], [1, 14], 'type loc points at type token';
    is_deeply [ map $got->{definitions}[0]{directives}[0]{loc}{$_}, qw(line column) ], [1, 22], 'directive loc points at @';
    is_deeply [ map $got->{definitions}[0]{selectionSet}{loc}{$_}, qw(line column) ], [1, 28], 'selection set loc points at opening brace';
    is_deeply [ map $got->{definitions}[0]{selectionSet}{selections}[0]{loc}{$_}, qw(line column) ], [1, 30], 'field loc points at field name';
    is_deeply [ map $got->{definitions}[0]{selectionSet}{selections}[0]{arguments}[0]{loc}{$_}, qw(line column) ], [1, 35], 'argument loc points at argument name';
};

subtest 'graphql-js loc stays correct on multi-line executable documents', sub {
    my $got = parse(<<'EOF');
query Q($id: ID = 1) {
  user(id: $id) {
    name
  }
}
EOF

    is_deeply [ map $got->{loc}{$_}, qw(line column) ], [1, 1], 'document loc stays at source start';
    is_deeply [ map $got->{definitions}[0]{loc}{$_}, qw(line column) ], [1, 1], 'operation loc stays at operation keyword';
    is_deeply [ map $got->{definitions}[0]{selectionSet}{loc}{$_}, qw(line column) ], [1, 22], 'operation selection set loc points at opening brace';
    is_deeply [ map $got->{definitions}[0]{selectionSet}{selections}[0]{loc}{$_}, qw(line column) ], [2, 3], 'field loc points at field name on next line';
    is_deeply [ map $got->{definitions}[0]{selectionSet}{selections}[0]{selectionSet}{loc}{$_}, qw(line column) ], [2, 17], 'nested selection set loc points at nested opening brace';
    is_deeply [ map $got->{definitions}[0]{selectionSet}{selections}[0]{selectionSet}{selections}[0]{loc}{$_}, qw(line column) ], [3, 5], 'nested field loc points at nested field name';
};

subtest 'graphql-js SDL loc covers descriptions and directive extensions', sub {
    my $described = parse(<<'EOF');
"Type doc"
type User {
  "Field doc"
  name: String
}
EOF
    my $directive_ext = parse('extend directive @tag on FIELD | FRAGMENT_SPREAD');

    is_deeply [ map $described->{definitions}[0]{loc}{$_}, qw(line column) ], [1, 1],
        'described type loc starts at description';
    is_deeply [ map $described->{definitions}[0]{description}{loc}{$_}, qw(line column) ], [1, 1],
        'type description loc is precise';
    is_deeply [ map $described->{definitions}[0]{fields}[0]{loc}{$_}, qw(line column) ], [3, 3],
        'described field loc starts at field description';
    is_deeply [ map $described->{definitions}[0]{fields}[0]{description}{loc}{$_}, qw(line column) ], [3, 3],
        'field description loc is precise';
    is_deeply [ map $described->{definitions}[0]{fields}[0]{name}{loc}{$_}, qw(line column) ], [4, 3],
        'field name loc points at field token';

    is_deeply [ map $directive_ext->{definitions}[0]{loc}{$_}, qw(line column) ], [1, 1],
        'directive extension loc starts at extend keyword';
    is_deeply [ map $directive_ext->{definitions}[0]{name}{loc}{$_}, qw(line column) ], [1, 19],
        'directive extension name loc points at directive name';
    is_deeply [ map $directive_ext->{definitions}[0]{locations}[0]{loc}{$_}, qw(line column) ], [1, 26],
        'directive extension first location loc is precise';
    is_deeply [ map $directive_ext->{definitions}[0]{locations}[1]{loc}{$_}, qw(line column) ], [1, 34],
        'directive extension second location loc is precise';
};

subtest 'graphql-js SDL loc handles directive locations with leading pipe', sub {
    my $doc = parse(<<'EOF');
directive @include2(if: Boolean!) on
  | FIELD
  | FRAGMENT_SPREAD
  | INLINE_FRAGMENT
EOF

    cmp_deeply strip_loc($doc), {
        kind => 'Document',
        definitions => [
            {
                kind => 'DirectiveDefinition',
                name => { kind => 'Name', value => 'include2' },
                arguments => [
                    {
                        kind => 'InputValueDefinition',
                        name => { kind => 'Name', value => 'if' },
                        type => {
                            kind => 'NonNullType',
                            type => {
                                kind => 'NamedType',
                                name => { kind => 'Name', value => 'Boolean' },
                            },
                        },
                        directives => [],
                    },
                ],
                repeatable => 0,
                locations => [
                    { kind => 'Name', value => 'FIELD' },
                    { kind => 'Name', value => 'FRAGMENT_SPREAD' },
                    { kind => 'Name', value => 'INLINE_FRAGMENT' },
                ],
            },
        ],
    };

    is_deeply [ map $doc->{definitions}[0]{locations}[0]{loc}{$_}, qw(line column) ], [2, 5],
        'leading-pipe directive location starts at the name token';
};

subtest 'graphql-js dialect can be selected through facade', sub {
    my $source = '{ user { id } }';
    my $direct = parse($source);
    my $through_facade = parse_with_options($source, {
        dialect => 'graphql-js',
    });

    cmp_deeply $through_facade, $direct, 'facade routes to graphql-js parser';
};

subtest 'graphql-js parser uses canonical XS path', sub {
    my $source = q(query Q($id: ID @fromContext, $limit: Int = 10 @clamp(max: 100)) { user(id: $id) { id } });
    my $through_parser = parse($source, { backend => 'xs' });
    my $through_facade = parse_with_options($source, {
        dialect => 'graphql-js',
        backend => 'xs',
    });

    cmp_deeply $through_facade, $through_parser, 'facade and parser stay on the same canonical XS path';
};

subtest 'graphql-js parser still rejects unsupported extension forms explicitly', sub {
    dies_ok { parse('extend directive @tag') } 'directive extension without locations still dies';
    like $@, qr/(?:Expected|Parse document failed)/, 'unsupported extension still fails explicitly';
};

done_testing;
