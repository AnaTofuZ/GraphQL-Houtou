use strict;
use warnings;

use Test::More 0.98;

use GraphQL::Houtou qw(parse parse_with_options);

subtest 'top-level parse returns legacy AST shape' => sub {
  my $ast = parse('{ viewer { id } }');

  is ref($ast), 'ARRAY', 'document is an arrayref';
  is $ast->[0]{kind}, 'operation', 'legacy parse returns operation node';
  is ref($ast->[0]{selections}), 'ARRAY', 'operation has selections';
  is $ast->[0]{selections}[0]{name}, 'viewer', 'legacy field name is preserved';
};

subtest 'parse_with_options keeps graphql-perl dialect only' => sub {
  my $ast = parse_with_options('{ viewer { id } }', {
    dialect => 'graphql-perl',
    backend => 'xs',
  });

  is ref($ast), 'ARRAY', 'graphql-perl parse returns arrayref document';
  my $error;
  eval { parse_with_options('{ viewer { id } }', { dialect => 'graphql-js' }) };
  $error = $@;
  like($error, qr/Unknown parser dialect/, 'graphql-js dialect is no longer exposed');
};

done_testing;
