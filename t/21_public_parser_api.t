use strict;
use warnings;

use Test::More 0.98;

use GraphQL::Houtou qw(parse parse_with_options);

my $HAS_XS_PARSER = eval {
  require GraphQL::Houtou::XS::Parser;
  1;
};

subtest 'top-level parse returns legacy AST shape' => sub {
  my $ast = parse('{ viewer { id } }');

  is ref($ast), 'ARRAY', 'document is an arrayref';
  is $ast->[0]{kind}, 'operation', 'legacy parse returns operation node';
  is ref($ast->[0]{selections}), 'ARRAY', 'operation has selections';
  is $ast->[0]{selections}[0]{name}, 'viewer', 'legacy field name is preserved';
};

subtest 'graphql-js dialect remains available from top-level API' => sub {
  plan skip_all => 'graphql-js facade requires XS parser support'
    if !$HAS_XS_PARSER;

  my $ast = parse_with_options('{ viewer { id } }', {
    dialect => 'graphql-js',
    no_location => 1,
  });

  is ref($ast), 'HASH', 'graphql-js parse returns hashref document';
  is $ast->{kind}, 'Document', 'graphql-js document kind';
  is ref($ast->{definitions}), 'ARRAY', 'graphql-js document has definitions';
};

done_testing;
