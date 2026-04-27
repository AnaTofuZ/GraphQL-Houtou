use strict;
use warnings;
use Test::More;

use GraphQL::Houtou qw(parse parse_with_options);
use GraphQL::Houtou::GraphQLJS::Parser ();

BEGIN {
    eval {
        require GraphQL::Houtou::XS::Parser;
        GraphQL::Houtou::XS::Parser->import('parse_xs');
        1;
    };
}

sub slurp {
    my ($path) = @_;
    open my $fh, '<', $path or die "open($path): $!";
    local $/;
    return <$fh>;
}

my $kitchen = slurp('t/kitchen-sink.graphql');
my $schema_kitchen = slurp('t/schema-kitchen-sink.graphql');

subtest 'graphql-perl pegex parses kitchen-sink inputs', sub {
    my $exec = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($kitchen, {
        backend => 'pegex',
    });
    my $schema = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($schema_kitchen, {
        backend => 'pegex',
    });

    is scalar(@$exec), 6, 'executable kitchen-sink yields expected definitions';
    is $exec->[0]{kind}, 'operation', 'first executable definition is an operation';
    is scalar(@$schema), 35, 'schema kitchen-sink yields expected top-level definitions';
    is $schema->[0]{kind}, 'schema', 'first schema definition is schema';
};

subtest 'graphql-perl xs parses kitchen-sink inputs', sub {
    unless (defined &parse_xs) {
        plan skip_all => 'XS parser is not built';
    }

    my $exec = parse_xs($kitchen);
    my $schema = parse_xs($schema_kitchen);

    is scalar(@$exec), 6, 'xs executable kitchen-sink yields expected definitions';
    is $exec->[0]{kind}, 'operation', 'xs first executable definition is an operation';
    is scalar(@$schema), 35, 'xs schema kitchen-sink yields expected top-level definitions';
    is $schema->[0]{kind}, 'schema', 'xs first schema definition is schema';
};

subtest 'graphql-js parses kitchen-sink inputs', sub {
    my $exec = GraphQL::Houtou::GraphQLJS::Parser::parse($kitchen);
    my $schema = GraphQL::Houtou::GraphQLJS::Parser::parse($schema_kitchen);

    is $exec->{kind}, 'Document', 'graphql-js executable kitchen-sink returns document';
    is scalar(@{ $exec->{definitions} }), 6, 'graphql-js executable kitchen-sink yields expected definition count';
    is $exec->{definitions}[0]{kind}, 'OperationDefinition', 'graphql-js first executable definition is operation';

    is $schema->{kind}, 'Document', 'graphql-js schema kitchen-sink returns document';
    is scalar(@{ $schema->{definitions} }), 35, 'graphql-js schema kitchen-sink yields expected top-level definitions';
    is $schema->{definitions}[0]{kind}, 'SchemaDefinition', 'graphql-js first schema definition is schema';

    my @foo_defs = grep {
        ($_->{kind} eq 'ObjectTypeDefinition' || $_->{kind} eq 'ObjectTypeExtension')
            && $_->{name}
            && $_->{name}{value} eq 'Foo'
    } @{ $schema->{definitions} };
    is_deeply [ map $_->{kind}, @foo_defs ], [
        'ObjectTypeDefinition',
        'ObjectTypeExtension',
        'ObjectTypeExtension',
    ], 'graphql-js keeps base type and both Foo extensions distinct on loc path';
    ok exists $foo_defs[1]{loc}, 'first Foo extension carries loc';
};

subtest 'facade routes graphql-js kitchen-sink parsing', sub {
    my $doc = parse_with_options($kitchen, {
        dialect => 'graphql-js',
    });

    is $doc->{kind}, 'Document', 'facade graphql-js parse returns document';
    is scalar(@{ $doc->{definitions} }), 6, 'facade graphql-js parse yields expected definition count';
};

done_testing;
