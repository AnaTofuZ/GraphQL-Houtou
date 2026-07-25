use strict;
use warnings;
use Test::More;

BEGIN {
  eval { require Promise::XS; 1 }
    or plan skip_all => 'Promise::XS is required for async execution tests';
}

# R5 regression: every request path that abandons or errors mid-flight must
# release its block/path frames. The live counters count frames handed out
# minus frames released; nonzero between requests is an orphaned frame
# (the async block-frame and fast-lane path-frame regressions).

use GraphQL::Houtou qw(execute build_native_runtime);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);
use GraphQL::Houtou::DataLoader;

GraphQL::Houtou::_bootstrap_xs();

sub live_counts { GraphQL::Houtou::XS::VM::debug_frame_live_counts_xs() }

sub assert_no_live_frames {
  my ($label) = @_;
  my $c = live_counts();
  is $c->{block_frame}, 0, "$label: no live block frames";
  is $c->{path_frame}, 0, "$label: no live path frames";
}

my $Inner = GraphQL::Houtou::Type::Object->new(
  name => 'Inner',
  fields => {
    hang => { type => $String, resolve => sub { Promise::XS::deferred()->promise } },
  },
);
my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'Query',
    fields => {
      hello => {
        type => $String,
        args => { name => { type => $String->non_null } },
        resolve => sub { 'hi ' . $_[1]{name} },
      },
      hang => { type => $String, resolve => sub { Promise::XS::deferred()->promise } },
      inner => { type => $Inner, resolve => sub { {} } },
      user => {
        type => GraphQL::Houtou::Type::Object->new(
          name => 'User', fields => { name => { type => $String } }),
        resolve => sub { my (undef, undef, $ctx) = @_; $ctx->{users}->load('u1') },
      },
    },
  ),
);

subtest 'baseline' => sub {
  assert_no_live_frames('before any request');
};

subtest 'deadlocked stall releases the pending frames' => sub {
  for my $query ('{ hang }', '{ inner { hang } }') {
    my $err = do { local $@; eval { execute($schema, $query, undef, on_stall => sub { 0 }) }; $@ };
    like $err, qr/stalled.*no progress/s, "$query reports the deadlock";
    assert_no_live_frames("deadlock $query");
  }
};

subtest 'stall without on_stall releases the pending frames' => sub {
  my $runtime = build_native_runtime($schema, async => 1);
  for my $query ('{ hang }', '{ inner { hang } }') {
    my $err = do { local $@; eval { $runtime->execute_document_to_json($query) }; $@ };
    like $err, qr/pass on_stall/, "$query points at on_stall";
    assert_no_live_frames("undriven stall $query");
  }
};

subtest 'request-time coercion failure releases the fast-lane path frames' => sub {
  my $runtime = build_native_runtime($schema);
  # A nullable variable with a default may sit in a non-null argument
  # position, and an explicit null then fails argument coercion inside the
  # fast lane - the deferred-croak path this regression guards. (A missing
  # non-null variable no longer reaches the lane: it is rejected while
  # variables are prepared, before any frame is allocated.)
  my $query = 'query Q($n: String = "x") { hello(name: $n) }';
  my $nulled = $runtime->execute_document($query, variables => { n => undef });
  like $nulled->{errors}[0]{message}, qr/given null value/, 'request error envelope';
  my $json = $runtime->execute_document_to_json($query, variables => { n => undef });
  like $json, qr/given null value/, 'request error envelope (JSON lane)';
  assert_no_live_frames('coercion failure');

  my $missing = $runtime->execute_document(
    'query Q($n: String!) { hello(name: $n) }', variables => {},
  );
  like $missing->{errors}[0]{message}, qr/was not provided/,
    'missing non-null variable is rejected at variable preparation';
  assert_no_live_frames('missing variable rejection');
};

subtest 'promise on the sync fast lane releases the path frames' => sub {
  my $sync = build_native_runtime($schema);
  for my $case (
    [ 'execute'  => sub { $sync->execute_document('{ hang }', variables => {}) } ],
    [ 'to_json'  => sub { $sync->execute_document_to_json('{ hang }', variables => {}) } ],
  ) {
    my ($name, $run) = @$case;
    my $err = do { local $@; eval { $run->() }; $@ };
    like $err, qr/async => 1/, "$name croaks with the async hint";
  }
  assert_no_live_frames('sync-lane promise croak');
};

subtest 'a completed DataLoader request stays clean' => sub {
  my $users = GraphQL::Houtou::DataLoader->new(batch => sub {
    my ($ids) = @_;
    return [ map { { name => "user-$_" } } @$ids ];
  });
  my $result = execute($schema, '{ user { name } }', undef,
    context => { users => $users },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($users),
  );
  is $result->{data}{user}{name}, 'user-u1', 'loader request resolved';
  assert_no_live_frames('completed loader request');
};

subtest 'repeated root-leaf DataLoader ticket continuations stay clean' => sub {
  # gql_runtime_vm_fast_root_continuation_ctx_t is shared by the resolve and
  # reject arms via a cv_refcnt pair, mirroring
  # gql_runtime_vm_pending_callback_ctx_t; a refcounting mistake there would
  # only show up after many suspend/resume cycles, not a single request.
  my $leaf_schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        greeting => {
          type => $String,
          args => { id => { type => $String } },
          resolve => sub {
            my (undef, $args, $ctx) = @_;
            return $ctx->{loader}->load($args->{id});
          },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($leaf_schema, async => 1);
  for my $i (1 .. 200) {
    my $loader = GraphQL::Houtou::DataLoader->new(
      batch => sub { my ($ids) = @_; return [ map { "v:$_" } @$ids ] },
    );
    my $r = $runtime->execute_document(
      'query Q($id: String) { greeting(id: $id) }',
      variables => { id => "k$i" },
      context => { loader => $loader },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );
    is $r->{data}{greeting}, "v:k$i", "iteration $i resolved" or last;
  }
  assert_no_live_frames('200 pending-ticket root-leaf continuations');
};

subtest 'repeated multi-sibling root promotions stay clean' => sub {
  # Each request here promotes to a real block_frame_t + exec_state_handle_t
  # (gql_runtime_vm_try_execute_fast_root_continuation_sv's multi-sibling
  # path); a leak in that construction or in gql_runtime_vm_block_frame_finalize_sv's
  # arm/drain handoff would only show up after many requests, not one.
  my $multi_schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        a => { type => $String, resolve => sub { 'sync-a' } },
        b => {
          type => $String,
          args => { id => { type => $String } },
          resolve => sub {
            my (undef, $args, $ctx) = @_;
            return $ctx->{loader}->load($args->{id});
          },
        },
        c => { type => $String, resolve => sub { 'sync-c' } },
      },
    ),
  );
  my $runtime = build_native_runtime($multi_schema, async => 1);
  for my $i (1 .. 200) {
    my $loader = GraphQL::Houtou::DataLoader->new(
      batch => sub { my ($ids) = @_; return [ map { "v:$_" } @$ids ] },
    );
    my $r = $runtime->execute_document(
      'query Q($id: String) { a b(id: $id) c }',
      variables => { id => "m$i" },
      context => { loader => $loader },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );
    is_deeply $r, { data => { a => 'sync-a', b => "v:m$i", c => 'sync-c' } }, "iteration $i resolved"
      or last;
  }
  assert_no_live_frames('200 multi-sibling root promotions');
};

done_testing;
