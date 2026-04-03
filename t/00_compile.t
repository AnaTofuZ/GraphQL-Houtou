use strict;
use Test::More 0.98;

use_ok $_ for qw(
    GraphQL::Houtou
    GraphQL::Houtou::Backend::GraphQLJS::XS
    GraphQL::Houtou::Backend::Pegex
    GraphQL::Houtou::Backend::XS
    GraphQL::Houtou::Adapter::GraphQLJSToGraphQLPerl
    GraphQL::Houtou::GraphQLPerl::FromGraphQLJS
    GraphQL::Houtou::GraphQLJS::Canonical
    GraphQL::Houtou::GraphQLJS::Locator
    GraphQL::Houtou::GraphQLPerl::Parser
    GraphQL::Houtou::GraphQLJS::Parser
    GraphQL::Houtou::GraphQLJS::Util
    GraphQL::Houtou::XS::Parser
);

done_testing;
