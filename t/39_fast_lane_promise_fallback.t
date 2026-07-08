use strict;
use warnings;
use Test::More;
use JSON::PP ();

use GraphQL::Houtou qw(build_native_runtime);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String $ID);

BEGIN {
  eval { require Promise::XS; 1 }
    or plan skip_all => 'Promise::XS is required for async execution tests';
}

use GraphQL::Houtou::Promise::PromiseXS qw(maybe_get_promise_xs);

my %calls;

sub new_runtime {
  %calls = ();
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        counted => {
          type => $String,
          resolve => sub { $calls{counted}++; 'counted' },
        },
        asyncUser => {
          type => GraphQL::Houtou::Type::Object->new(
            name => 'AUser', fields => { name => { type => $String } }),
          args => { id => { type => $ID } },
          resolve => sub {
            my (undef, $args) = @_;
            $calls{asyncUser}++;
            return Promise::XS::resolved({ name => "n$args->{id}" });
          },
        },
        asyncHello => {
          type => $String,
          resolve => sub { Promise::XS::resolved('async world') },
        },
        pendingForever => {
          type => $String,
          resolve => sub { Promise::XS::deferred()->promise },
        },
      },
    ),
    mutation => GraphQL::Houtou::Type::Object->new(
      name => 'Mutation',
      fields => {
        bump => {
          type => $String,
          args => { id => { type => $ID } },
          resolve => sub { $calls{bump}++; Promise::XS::resolved('bumped') },
        },
      },
    ),
  );
  return build_native_runtime($schema);
}

my $QUERY = 'query Q($id: ID) { counted asyncUser(id: $id) { name } }';

subtest 'variables + promise resolvers: correct data via async fallback' => sub {
  my $runtime = new_runtime();
  my $r = maybe_get_promise_xs(
    $runtime->execute_document($QUERY, variables => { id => 'u1' }));
  is_deeply $r, {
    data => { counted => 'counted', asyncUser => { name => 'nu1' } },
    errors => [],
  }, 'no promise objects or undefs leak into data';
  is $calls{asyncUser}, 2,
    'first request re-runs resolvers on the async lane (documented one-time cost)';
  is $calls{counted}, 2, 'sibling sync resolver re-ran once as well';
};

subtest 'later requests skip the fast lane (no re-execution)' => sub {
  my $runtime = new_runtime();
  maybe_get_promise_xs($runtime->execute_document($QUERY, variables => { id => 'u1' }));
  %calls = ();
  my $r = maybe_get_promise_xs(
    $runtime->execute_document($QUERY, variables => { id => 'u2' }));
  is $r->{data}{asyncUser}{name}, 'nu2', 'second request correct';
  is $calls{counted}, 1, 'each resolver ran exactly once';
  is $calls{asyncUser}, 1, 'promise resolver ran exactly once';
};

subtest 'scalar promise with variables returns a promise like the no-variables lane' => sub {
  my $runtime = new_runtime();
  my $result = $runtime->execute_document(
    'query Q($id: ID) { asyncHello }', variables => { id => 'x' });
  my $r = maybe_get_promise_xs($result);
  is $r->{data}{asyncHello}, 'async world', 'settled to the resolved value';
};

subtest 'mutations fail once with a clear error, then route to the async lane' => sub {
  my $runtime = new_runtime();
  my $m = 'mutation M($id: ID) { bump(id: $id) }';
  my $err = do {
    local $@;
    eval { $runtime->execute_document($m, variables => { id => '1' }) };
    $@;
  };
  like $err, qr/mutation resolver returned a Promise::XS promise/,
    'first mutation dies with the actionable error';
  like $err, qr/not re-executed/, 'explains that side effects were not re-run';
  is $calls{bump}, 1, 'mutation resolver was not re-executed';

  my $r = maybe_get_promise_xs($runtime->execute_document($m, variables => { id => '2' }));
  is $r->{data}{bump}, 'bumped', 'subsequent mutation runs on the async lane';
  is $calls{bump}, 2, 'exactly one more execution';
};

subtest 'to_json without on_stall settles pre-resolved chains' => sub {
  my $runtime = new_runtime();
  my $json = $runtime->execute_document_to_json($QUERY, variables => { id => 'u3' });
  my $r = JSON::PP::decode_json($json);
  is $r->{data}{asyncUser}{name}, 'nu3', 'JSON rendered through the async fallback';

  my $json2 = $runtime->execute_document_to_json($QUERY, variables => { id => 'u4' });
  is JSON::PP::decode_json($json2)->{data}{asyncUser}{name}, 'nu4',
    'flagged program renders JSON on the async lane directly';
};

subtest 'to_json with a genuinely pending promise points at on_stall' => sub {
  my $runtime = new_runtime();
  my $err = do {
    local $@;
    eval {
      $runtime->execute_document_to_json(
        'query Q($id: ID) { pendingForever }', variables => { id => 'x' });
    };
    $@;
  };
  like $err, qr/pass on_stall/, 'error names the missing hook';
};

subtest 'engine => native stays strict' => sub {
  my $runtime = new_runtime();
  my $err = do {
    local $@;
    eval {
      $runtime->execute_document($QUERY,
        variables => { id => 'u5' }, engine => 'native');
    };
    $@;
  };
  like $err, qr/synchronous fast lane/,
    'explicitly requested sync lane propagates the croak instead of falling back';
};

done_testing;
