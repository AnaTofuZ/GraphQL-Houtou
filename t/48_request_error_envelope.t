use strict;
use warnings;
use Test::More 0.98;

# execute_document's error taxonomy (P0-4): request errors - syntax,
# validation, input coercion - return an errors-only envelope (no "data"
# key) instead of raising exceptions, while configuration and internal
# errors keep propagating as exceptions. Field errors are unaffected: they
# stay inside a response with data.

use JSON::PP ();

use GraphQL::Houtou qw(build_native_runtime);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'Query',
    fields => {
      hello => {
        type => $String,
        args => { name => { type => $String->non_null } },
        resolve => sub { 'hi ' . $_[1]{name} },
      },
      boom => { type => $String, resolve => sub { die "kaboom\n" } },
    },
  ),
);

sub runtime { build_native_runtime($schema, program_cache_max => 100, @_) }

subtest 'syntax errors return an envelope with a clean message' => sub {
  my $result = runtime()->execute_document('{ hello( }');
  ok !exists $result->{data}, 'no data key';
  like $result->{errors}[0]{message}, qr/\ASyntax Error: /,
    'Pegex internals are reformatted';
  unlike $result->{errors}[0]{message}, qr/Pegex|position:/,
    'parser internals do not leak';
  ok $result->{errors}[0]{locations}[0]{line}, 'locations preserved';
};

subtest 'variable coercion failures are request errors' => sub {
  my $runtime = runtime();
  my $query = 'query Q($n: String!) { hello(name: $n) }';

  my $missing = $runtime->execute_document($query, variables => {});
  ok !exists $missing->{data}, 'no data key for a null non-null variable';
  like $missing->{errors}[0]{message}, qr/String! given null value/, 'message kept';

  my $wrong = $runtime->execute_document($query, variables => { n => [1] });
  like $wrong->{errors}[0]{message}, qr/Not a String/, 'wrong shape rejected';

  my $ok = $runtime->execute_document($query, variables => { n => 'Ana' });
  is $ok->{data}{hello}, 'hi Ana', 'the same cached document still executes';
};

subtest 'resolver failures stay field errors inside a data response' => sub {
  my $result = runtime()->execute_document('{ boom }');
  ok exists $result->{data}, 'data key present';
  is $result->{data}{boom}, undef, 'failed field is null';
  is_deeply $result->{errors}[0]{path}, ['boom'], 'field error carries a path';
};

subtest 'configuration errors keep raising exceptions' => sub {
  eval { require Promise::XS; 1 } or plan skip_all => 'Promise::XS not available';
  my $async_schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        later => { type => $String, resolve => sub { Promise::XS::resolved('x') } },
      },
    ),
  );
  my $sync_runtime = build_native_runtime($async_schema);
  eval { $sync_runtime->execute_document_to_json('{ later }') };
  like $@, qr/async => 1/, 'async misconfiguration is an exception, not an envelope';
};

subtest 'the JSON lane mirrors the envelope taxonomy' => sub {
  my $runtime = runtime();
  my $json = JSON::PP->new->utf8;

  my $syntax = $json->decode($runtime->execute_document_to_json('{ hello( }'));
  ok !exists $syntax->{data}, 'syntax error: no data key';
  like $syntax->{errors}[0]{message}, qr/\ASyntax Error: /, 'syntax error message';

  my $coercion = $json->decode($runtime->execute_document_to_json(
    'query Q($n: String!) { hello(name: $n) }', variables => {},
  ));
  ok !exists $coercion->{data}, 'coercion error: no data key';
  like $coercion->{errors}[0]{message}, qr/String! given null value/, 'coercion message';

  my $field = $json->decode($runtime->execute_document_to_json('{ boom }'));
  ok exists $field->{data}, 'field error keeps data';
};

done_testing;
