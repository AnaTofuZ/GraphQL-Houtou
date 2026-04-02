use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;

use GraphQL::Houtou qw(parse_with_options);
use GraphQL::Houtou::Adapter::GraphQLPerlToGraphQLJS qw(convert_document);
use GraphQL::Houtou::Backend::XS ();
use GraphQL::Houtou::GraphQLJS::Locator qw(apply_loc_from_source);
use GraphQL::Houtou::GraphQLJS::PP qw(
    materialize_operation_variable_directives
    patch_document_fallback
    preprocess_source_fallback
);
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

subtest 'graphql-js no_location strips loc recursively', sub {
    my $source = 'query Q($id: ID @fromContext) { user(id: $id) { id } }';
    my $with_loc = parse($source);
    my $without_loc = parse($source, { no_location => 1 });

    ok exists $with_loc->{loc}, 'document has loc by default';
    ok !exists $without_loc->{loc}, 'document loc can be stripped';
    ok !exists $without_loc->{definitions}[0]{loc}, 'nested loc is stripped';
    ok !exists $without_loc->{definitions}[0]{variableDefinitions}[0]{directives}[0]{loc}, 'patched directive loc is stripped too';
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

subtest 'graphql-js dialect can be selected through facade', sub {
    my $source = '{ user { id } }';
    my $direct = parse($source);
    my $through_facade = parse_with_options($source, {
        dialect => 'graphql-js',
    });

    cmp_deeply $through_facade, $direct, 'facade routes to graphql-js parser';
};

subtest 'XS and PP directive patch paths stay aligned', sub {
    my $source = q(query Q($id: ID @fromContext, $limit: Int = 10 @clamp(max: 100)) { user(id: $id) { id } });
    my $xs_doc = parse($source, { backend => 'xs' });

    my ($rewritten, $meta) = preprocess_source_fallback($source);
    my $legacy = GraphQL::Houtou::Backend::XS::parse($rewritten);
    my $pp_doc = convert_document($legacy, {});
    materialize_operation_variable_directives($meta);
    $pp_doc = patch_document_fallback($pp_doc, $meta);
    $pp_doc = apply_loc_from_source($pp_doc, $source);

    cmp_deeply $pp_doc, $xs_doc, 'PP fallback patch matches XS patch output';
};

subtest 'graphql-js parser still rejects unsupported extension forms explicitly', sub {
    dies_ok { parse('extend directive @tag on FIELD') } 'directive extension currently dies';
    like $@, qr/(?:Expected|Parse document failed)/, 'unsupported extension still fails explicitly';
};

done_testing;
