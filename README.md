# NAME

GraphQL::Houtou - Alternative GraphQL parser distribution for Perl

# SYNOPSIS

    use GraphQL::Houtou qw(parse parse_with_options);

    my $legacy_ast = parse('{ user { id } }');

    my $graphql_js_ast = parse_with_options('{ user { id } }', {
        dialect => 'graphql-js',
        backend => 'xs',
    });

# DESCRIPTION

GraphQL::Houtou is a separate distribution that extracts parser-related work
from a local `graphql-perl` fork into its own CPAN-friendly module.

The current project layout includes:

- `GraphQL::Houtou`
  - top-level facade
- `GraphQL::Houtou::GraphQLPerl::Parser`
  - graphql-perl compatible AST parser
- `GraphQL::Houtou::GraphQLJS::Parser`
  - graphql-js style AST parser
- `GraphQL::Houtou::XS::Parser`
  - XS backend and helper entry points

For now, this distribution still depends on the upstream `GraphQL` module for:

- legacy Pegex parsing
- `GraphQL::Error`
- string / block string helper behavior

# LICENSE

Copyright (C) anatofuz.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

anatofuz <anatofuz@gmail.com>
