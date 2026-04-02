use strict;
use warnings;
use Test::More;
use Test::Deep;
use Test::Exception;

use GraphQL::Houtou qw(parse parse_with_options);
use GraphQL::Houtou::Backend::GraphQLJS::XS ();
use GraphQL::Houtou::Backend::Pegex ();
use GraphQL::Houtou::Backend::XS ();
use GraphQL::Houtou::GraphQLPerl::Parser ();
use GraphQL::Houtou::GraphQLJS::Parser ();

BEGIN {
    eval {
        require GraphQL::Houtou::XS::Parser;
        GraphQL::Houtou::XS::Parser->import('parse_xs');
        1;
    };
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

subtest 'default parse stays graphql-perl dialect but uses xs by default', sub {
    my $source = 'query Q { user { id } }';
    my $legacy = parse($source);
    my $explicit_xs = parse_with_options($source, {
        dialect => 'graphql-perl',
        backend => 'xs',
    });

    cmp_deeply $explicit_xs, $legacy, 'default graphql-perl parse matches explicit xs backend';
};

subtest 'graphql-perl namespace delegates to compatibility parser', sub {
    my $source = 'type Hello { world: String }';
    my $legacy = parse($source);
    my $namespaced = GraphQL::Houtou::GraphQLPerl::Parser::parse($source);
    my $explicit = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, {
        backend => 'xs',
    });

    cmp_deeply $namespaced, $legacy, 'namespaced parser matches legacy parse';
    cmp_deeply $explicit, $legacy, 'namespaced parse_with_options uses xs by default path';
};

subtest 'backend modules expose the implementation split explicitly', sub {
    my $source = 'type Hello { world: String }';
    my $pegex = GraphQL::Houtou::Backend::Pegex::parse($source);
    my $via_parser = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, {
        backend => 'pegex',
    });

    cmp_deeply $pegex, $via_parser, 'pegex backend module matches parser dispatcher';

    SKIP: {
        skip 'XS parser is not built', 1 unless defined &parse_xs;
        my $xs = GraphQL::Houtou::Backend::XS::parse($source);
        cmp_deeply $xs, parse_xs($source), 'xs backend module matches direct xs parser';
    }
};

subtest 'graphql-js namespace is routable', sub {
    my $source = '{ field }';
    my $namespaced = GraphQL::Houtou::GraphQLJS::Parser::parse($source);
    my $through_facade = parse_with_options($source, { dialect => 'graphql-js' });
    my $through_backend = GraphQL::Houtou::Backend::GraphQLJS::XS::parse($source);

    is $namespaced->{kind}, 'Document', 'graphql-js namespace returns a document node';
    cmp_deeply $through_facade, $namespaced, 'dialect selection routes to graphql-js namespace';
    cmp_deeply $through_backend, $namespaced, 'graphql-js xs backend exposes the canonical xs path';
};

subtest 'graphql-js parser keeps PP fallback unloaded on XS path', sub {
    unless (defined &parse_xs) {
        plan skip_all => 'XS parser is not built';
    }

    ok !exists $INC{'GraphQL/Houtou/GraphQLJS/PP.pm'},
        'graphql-js parser module does not eagerly load PP fallback';
};

subtest 'invalid dialect and backend are rejected explicitly', sub {
    dies_ok { parse_with_options('{ field }', { dialect => 'unknown' }) }
        'unknown dialect dies';
    like $@, qr/Unknown parser dialect/, 'dialect error is explicit';

    dies_ok {
        GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options('{ field }', {
            backend => 'wat',
        });
    } 'unknown backend dies';
    like $@, qr/Unknown parser backend/, 'backend error is explicit';
};

subtest 'graphql-perl xs backend can be selected explicitly', sub {
    unless (defined &parse_xs) {
        plan skip_all => 'XS parser is not built';
    }

    my $source = 'query Q($id: ID = 1) { user(id: $id) { id } }';
    my $explicit = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, {
        backend => 'xs',
    });
    my $direct = parse_xs($source);

    cmp_deeply $explicit, $direct, 'explicit xs backend matches parse_xs';
};

subtest 'graphql-perl can be derived from graphql-js xs through an adapter path', sub {
    my $source = 'query Q($id: ID = 1) @root { user(id: $id) { name } }';
    my $legacy_xs = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, {
        backend => 'xs',
    });
    my $legacy_from_graphqljs = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, {
        backend => 'graphqljs-xs',
    });

    cmp_deeply strip_location($legacy_from_graphqljs), strip_location($legacy_xs),
        'graphqljs-xs backend can reproduce legacy AST shape for a representative executable document';
};

done_testing;
