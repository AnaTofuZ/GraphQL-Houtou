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
            graphqljs_build_document_xs
            graphqljs_build_executable_document_xs
            graphqljs_parse_document_xs
            graphqljs_parse_executable_document_xs
            graphqlperl_build_document_xs
            graphqlperl_find_legacy_empty_object_location_xs
            parse_xs
            graphqljs_preprocess_xs
            graphqljs_patch_document_xs
            parse_directives_xs
            tokenize_xs
        ));
        1;
    } or plan skip_all => 'XS parser is not built';
}

use GraphQL::Houtou::Adapter::GraphQLJSToGraphQLPerl ();
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

subtest 'graphqljs_build_executable_document_xs matches canonical parser for executable documents', sub {
    my $source = 'query Q($id: ID = 1) @root { user(id: $id) { ...UserFields } } fragment UserFields on User { name }';
    my $legacy = parse_xs($source);
    my $built = graphqljs_build_executable_document_xs($legacy);
    my $expected = parse_canonical_document($source, {
        backend => 'xs',
        no_location => 1,
    });

    cmp_deeply $built, $expected, 'xs executable builder matches canonical parser output';
};

subtest 'graphqljs_build_executable_document_xs matches canonical parser for empty object values', sub {
    my $source = 'query Q($input: Filter = {}) { user(filter: {}) { id } }';
    my $legacy = parse_xs($source);
    my $built = graphqljs_build_executable_document_xs($legacy);
    my $expected = parse_canonical_document($source, {
        backend => 'xs',
        no_location => 1,
    });

    cmp_deeply $built, $expected, 'xs executable builder handles empty object values';
};

subtest 'graphqljs_parse_executable_document_xs matches canonical parser for executable documents', sub {
    my $source = 'query Q($id: ID = 1) @root { user(id: $id) { ...UserFields } } fragment UserFields on User { name }';
    my $built = graphqljs_parse_executable_document_xs($source);
    my $expected = parse_canonical_document($source, {
        backend => 'xs',
    });

    cmp_deeply $built, $expected, 'xs executable fast path matches canonical parser output';
};

subtest 'graphqljs_parse_executable_document_xs keeps variable definition directives inline', sub {
    my $source = 'query Q($id: ID @fromContext, $limit: Int = 10 @clamp(max: 100)) @root { user(id: $id) { id } }';
    my $built = graphqljs_parse_executable_document_xs($source);
    my $expected = parse_canonical_document($source, {
        backend => 'xs',
    });

    cmp_deeply $built, $expected, 'xs executable fast path matches canonical output with variable directives';
};

subtest 'graphqljs_parse_executable_document_xs keeps shorthand query shape stable', sub {
    my $built = graphqljs_parse_executable_document_xs('{ __typename }', 1);

    cmp_deeply $built->{definitions}[0], {
        kind => 'OperationDefinition',
        operation => 'query',
        variableDefinitions => [],
        directives => [],
        selectionSet => {
            kind => 'SelectionSet',
            selections => [
                {
                    kind => 'Field',
                    name => {
                        kind => 'Name',
                        value => '__typename',
                    },
                    arguments => [],
                    directives => [],
                },
            ],
        },
    }, 'xs executable fast path preserves empty arrays on shorthand queries';
};

subtest 'graphqljs_parse_document_xs matches canonical parser on executable fast path', sub {
    my $source = 'query Q($id: ID = 1) @root { user(id: $id) { ...UserFields } } fragment UserFields on User { name }';
    my $built = graphqljs_parse_document_xs($source);
    my $expected = parse_canonical_document($source, {
        backend => 'xs',
    });

    cmp_deeply $built, $expected, 'xs canonical entrypoint matches canonical parser for executable documents';
};

subtest 'graphqljs_parse_document_xs materializes type system documents without locations', sub {
    my $source = 'type User { id: ID! }';
    my $built = graphqljs_parse_document_xs($source, 1);
    my $expected = parse_canonical_document($source, {
        backend => 'xs',
        no_location => 1,
    });

    cmp_deeply $built, $expected, 'xs canonical entrypoint handles non-executable documents in no_location mode';
};

subtest 'graphqljs_parse_document_xs materializes type system documents with locations', sub {
    my $source = "type User {\n  id: ID!\n}";
    my $built = graphqljs_parse_document_xs($source);
    my $expected = parse_canonical_document($source, {
        backend => 'xs',
    });

    cmp_deeply $built, $expected, 'xs canonical entrypoint handles non-executable documents with locations';
};

subtest 'graphqljs_parse_document_xs can return lazy locations for executable documents', sub {
    my $source = "query Q {\n  user { id }\n}";
    my $doc = graphqljs_parse_document_xs($source, 0, 1);

    isa_ok $doc->{loc}, 'GraphQL::Houtou::XS::LazyLoc';
    is $doc->{loc}->start, 0, 'document loc stores start offset lazily';
    is_deeply $doc->{loc}->as_hash($source), { line => 1, column => 1 }, 'lazy loc materializes on demand';
    is $doc->{definitions}[0]{loc}->start, 0, 'definition loc also stores start offset';
    is $doc->{definitions}[0]{name}{loc}->start, 6, 'child loc stores original source offset';
};

subtest 'parse_canonical_document supports lazy_location option', sub {
    my $source = "query Q {\n  user { id }\n}";
    my $doc = parse_canonical_document($source, {
        backend => 'xs',
        lazy_location => 1,
    });

    isa_ok $doc->{definitions}[0]{selectionSet}{loc}, 'GraphQL::Houtou::XS::LazyLoc';
    is $doc->{definitions}[0]{selectionSet}{loc}->start, 8, 'canonical parser returns lazy loc payloads';
};

subtest 'graphqljs_parse_document_xs supports compact_loc for executable documents', sub {
    my $source = "query Q {\n  user(id: 1) { id }\n}";
    my $doc = graphqljs_parse_document_xs($source, 0, 0, 1);
    my $field = $doc->{definitions}[0]{selectionSet}{selections}[0];
    my $arg = $field->{arguments}[0];

    ok exists $field->{loc}, 'field keeps loc in compact mode';
    ok !exists $field->{name}{loc}, 'field name drops loc in compact mode';
    ok exists $arg->{loc}, 'argument keeps loc in compact mode';
    ok !exists $arg->{name}{loc}, 'argument name drops loc in compact mode';
};

subtest 'parse_canonical_document supports compact_loc option', sub {
    my $source = "query Q {\n  user(id: 1) { id }\n}";
    my $doc = parse_canonical_document($source, {
        backend => 'xs',
        compact_loc => 1,
    });

    ok exists $doc->{definitions}[0]{loc}, 'definition keeps loc';
    ok !exists $doc->{definitions}[0]{name}{loc}, 'definition name drops loc';
};

subtest 'graphqljs_build_document_xs matches canonical parser for type system documents', sub {
    my $source = <<'EOF';
"Type doc"
type User implements Node @entity {
  "Role doc"
  role(status: Status = ACTIVE): String @deprecated
}

enum Status { ACTIVE INACTIVE }

input UserFilter {
  status: Status = ACTIVE
}

directive @entity on OBJECT | INTERFACE

schema { query: Query mutation: Mutation }
EOF
    my $legacy = parse_xs($source);
    my $built = graphqljs_build_document_xs($legacy);
    my $expected = parse_canonical_document($source, {
        backend => 'xs',
        no_location => 1,
    });

    cmp_deeply $built, $expected, 'xs full-document builder matches canonical parser output';
};

subtest 'graphqlperl_build_document_xs matches Perl adapter for type system documents', sub {
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
    my $document = parse_canonical_document($source, {
        backend => 'xs',
    });
    my $built = graphqlperl_build_document_xs($document);
    my $expected = GraphQL::Houtou::Adapter::GraphQLJSToGraphQLPerl::convert_document($document);

    cmp_deeply $built, $expected, 'xs graphql-perl full-document builder matches the Perl adapter output';
};

subtest 'graphqlperl_build_document_xs matches Perl adapter for executable documents', sub {
    my $source = 'query Q($id: ID = 1, $flag: Boolean = false) @root { user(id: $id) { ...UserFields } } fragment UserFields on User { name }';
    my $document = parse_canonical_document($source, {
        backend => 'xs',
    });
    my $built = graphqlperl_build_document_xs($document);
    my $expected = GraphQL::Houtou::Adapter::GraphQLJSToGraphQLPerl::convert_document($document);

    cmp_deeply $built, $expected, 'xs graphql-perl full-document builder also matches executable output';
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

subtest 'graphqlperl_find_legacy_empty_object_location_xs detects legacy empty object errors directly', sub {
    my $loc = graphqlperl_find_legacy_empty_object_location_xs(
        'query Q($input: Filter = {}) { user(filter: {}) { id } }'
    );
    isa_ok $loc, 'HASH', 'legacy compat helper returns a location hash';
    is_deeply [ map $loc->{$_}, qw(line column) ], [1, 27],
        'helper points at the empty object closing brace';

    my $none = graphqlperl_find_legacy_empty_object_location_xs(
        'query Q($input: Filter = {a: 1}) { user(filter: {a: 1}) { id } }'
    );
    ok !defined($none), 'non-empty object value is not reported';
};

done_testing;
