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

subtest 'parse rejects parser options and stays minimal' => sub {
  my $error;
  eval { parse('{ viewer { id } }', 1) };
  $error = $@;
  ok !$error, 'extra positional parser flags are ignored by Perl signature truncation';
};

subtest 'parse_with_options exposes only parser-local options' => sub {
  my $ast = parse_with_options('{ viewer { id } }', {
    no_location => 1,
  });

  is ref($ast), 'ARRAY', 'graphql-perl parse returns arrayref document';
  my $compat_error;
  eval { parse_with_options('{ viewer { id } }', { noLocation => 1 }) };
  $compat_error = $@;
  like($compat_error, qr/Unknown parser option 'noLocation'/, 'camelCase parser option is retired');

  my $error;
  eval { parse_with_options('{ viewer { id } }', { dialect => 'graphql-js' }) };
  $error = $@;
  like($error, qr/Unknown parser option/, 'legacy dialect option is no longer exposed');
};

done_testing;
