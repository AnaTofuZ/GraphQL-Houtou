use strict;
use Test::More 0.98;

use_ok $_ for qw(
    GraphQL::Houtou
    GraphQL::Houtou::Backend::Pegex
    GraphQL::Houtou::Backend::XS
    GraphQL::Houtou::GraphQLPerl::Parser
    GraphQL::Houtou::GraphQLJS::Parser
    GraphQL::Houtou::XS::Parser
);

done_testing;
