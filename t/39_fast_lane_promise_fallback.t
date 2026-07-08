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

sub new_schema {
  %calls = ();
  return GraphQL::Houtou::Schema->new(
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
}

my $QUERY = 'query Q($id: ID) { counted asyncUser(id: $id) { name } }';

subtest 'async runtime: variables + promise resolvers execute once, correctly' => sub {
  my $runtime = build_native_runtime(new_schema(), async => 1);
  my $r = maybe_get_promise_xs(
    $runtime->execute_document($QUERY, variables => { id => 'u1' }));
  is_deeply $r, {
    data => { counted => 'counted', asyncUser => { name => 'nu1' } },
    errors => [],
  }, 'no promise objects or undefs leak into data';
  is $calls{counted}, 1, 'sync resolver ran exactly once';
  is $calls{asyncUser}, 1, 'promise resolver ran exactly once';
};

subtest 'async runtime: mutations run once on the async lane' => sub {
  my $runtime = build_native_runtime(new_schema(), async => 1);
  my $r = maybe_get_promise_xs($runtime->execute_document(
    'mutation M($id: ID) { bump(id: $id) }', variables => { id => '1' }));
  is $r->{data}{bump}, 'bumped', 'mutation resolved';
  is $calls{bump}, 1, 'mutation resolver ran exactly once';
};

subtest 'async runtime: to_json settles pre-resolved chains to JSON' => sub {
  my $runtime = build_native_runtime(new_schema(), async => 1);
  my $json = $runtime->execute_document_to_json($QUERY, variables => { id => 'u3' });
  is JSON::PP::decode_json($json)->{data}{asyncUser}{name}, 'nu3',
    'JSON via the async lane without on_stall';
};

subtest 'async runtime: a genuine stall points at on_stall' => sub {
  my $runtime = build_native_runtime(new_schema(), async => 1);
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

subtest 'sync runtime: promise on the fast lane fails with an actionable error' => sub {
  my $runtime = build_native_runtime(new_schema());
  for my $case (
    [ execute => sub { $runtime->execute_document($QUERY, variables => { id => 'u5' }) } ],
    [ to_json => sub { $runtime->execute_document_to_json($QUERY, variables => { id => 'u6' }) } ],
  ) {
    my ($name, $run) = @$case;
    my $err = do { local $@; eval { $run->() }; $@ };
    like $err, qr/async => 1/, "$name: error tells you to declare async => 1";
    like $err, qr/on_stall/, "$name: error also offers on_stall";
  }
};

subtest 'async runtime with engine => native stays strict' => sub {
  my $runtime = build_native_runtime(new_schema(), async => 1);
  my $err = do {
    local $@;
    eval {
      $runtime->execute_document($QUERY,
        variables => { id => 'u7' }, engine => 'native');
    };
    $@;
  };
  like $err, qr/synchronous fast lane/,
    'explicit sync engine request overrides the async default and croaks';
};

subtest 'async runtime still honors on_stall batching' => sub {
  require GraphQL::Houtou::DataLoader;
  my $schema = new_schema();
  my $runtime = build_native_runtime($schema, async => 1);
  my @batches;
  my $users = GraphQL::Houtou::DataLoader->new(batch => sub {
    push @batches, [ @{ $_[0] } ];
    return [ map { { name => "loaded-$_" } } @{ $_[0] } ];
  });
  # asyncUser resolves through Promise::XS directly here; the loader-backed
  # request exercises the async runtime + on_stall combination.
  my $schema2 = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        user => {
          type => GraphQL::Houtou::Type::Object->new(
            name => 'LUser', fields => { name => { type => $String } }),
          args => { id => { type => $ID } },
          resolve => sub { my (undef,$a,$c)=@_; $c->{users}->load($a->{id}) },
        },
      },
    ),
  );
  my $rt2 = build_native_runtime($schema2, async => 1);
  my $r = $rt2->execute_document(
    'query Q($id: ID) { a: user(id: $id) { name } b: user(id: "y") { name } }',
    variables => { id => 'x' },
    context => { users => $users },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($users),
  );
  is_deeply $r->{data}, {
    a => { name => 'loaded-x' }, b => { name => 'loaded-y' },
  }, 'batched request resolves synchronously via on_stall';
  is scalar @batches, 1, 'one batch per level';
};

done_testing;
