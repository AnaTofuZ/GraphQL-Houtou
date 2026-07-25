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
        'query Q { pendingForever }');
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

subtest 'sync runtime: a pending DataLoader ticket also fails with an actionable error' => sub {
  require GraphQL::Houtou::DataLoader;
  my $loader = GraphQL::Houtou::DataLoader->new(
    batch => sub { my ($keys) = @_; return [ map { "v:$_" } @$keys ] },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        greeting => {
          type => $String,
          args => { id => { type => $String } },
          resolve => sub { my (undef, $args) = @_; return $loader->load($args->{id}) },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $err = do {
    local $@;
    eval {
      $runtime->execute_document(
        'query Q($id: String) { greeting(id: $id) }', variables => { id => 'p1' });
    };
    $@;
  };
  like $err, qr/synchronous fast lane/, 'error names the synchronous fast lane';
  like $err, qr/async => 1/, 'error tells you to declare async => 1';
  like $err, qr/on_stall/, 'error also offers on_stall';
};

subtest 'async runtime with strict_sync stays strict' => sub {
  my $runtime = build_native_runtime(new_schema(), async => 1);
  for my $case (
    [ execute => sub {
        $runtime->execute_document($QUERY,
          variables => { id => 'u7' }, strict_sync => 1) } ],
    [ to_json => sub {
        $runtime->execute_document_to_json($QUERY,
          variables => { id => 'u8' }, strict_sync => 1) } ],
    [ on_stall => sub {
        $runtime->execute_document($QUERY,
          variables => { id => 'u9' }, strict_sync => 1,
          on_stall => sub { 1 }) } ],
  ) {
    my ($name, $run) = @$case;
    my $err = do { local $@; eval { $run->() }; $@ };
    like $err, qr/synchronous fast lane/,
      "$name: strict_sync overrides async lane selection and croaks";
  }
};

subtest 'sync runtime: promise LIST ITEMS also croak with the hint (issue #33)' => sub {
  my $Row = GraphQL::Houtou::Type::Object->new(
    name => 'Row', fields => { name => { type => $String } });
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        rows => {
          type => $Row->list,
          resolve => sub { [ map { Promise::XS::resolved({ name => "r$_" }) } 1..2 ] },
        },
        tags => {
          type => $String->list,
          resolve => sub { [ Promise::XS::resolved('t1'), Promise::XS::resolved('t2') ] },
        },
      },
    ),
  );
  my $sync_rt = build_native_runtime($schema);
  # strict_sync pins the request to the synchronous fast lane, which
  # is also where variable-carrying requests run; a bare no-variables
  # request goes down the auto lane instead (asserted below).
  for my $case (
    [ 'object list / execute' => sub {
        $sync_rt->execute_document('{ rows { name } }', strict_sync => 1) } ],
    [ 'object list / to_json' => sub { $sync_rt->execute_document_to_json('{ rows { name } }') } ],
    [ 'scalar list / execute' => sub {
        $sync_rt->execute_document('{ tags }', strict_sync => 1) } ],
    [ 'scalar list / to_json' => sub { $sync_rt->execute_document_to_json('{ tags }') } ],
  ) {
    my ($name, $run) = @$case;
    my $err = do { local $@; eval { $run->() }; $@ };
    like $err, qr/async => 1/, "$name: croaks with the async => 1 hint";
  }

  my $auto = maybe_get_promise_xs($sync_rt->execute_document('{ rows { name } tags }'));
  is_deeply $auto->{data}, {
    rows => [ { name => 'r1' }, { name => 'r2' } ],
    tags => [ 't1', 't2' ],
  }, 'no-variables requests ride the auto lane and complete promise items';

  my $async_rt = build_native_runtime($schema, async => 1);
  my $r = maybe_get_promise_xs($async_rt->execute_document('{ rows { name } tags }'));
  is_deeply $r->{data}, {
    rows => [ { name => 'r1' }, { name => 'r2' } ],
    tags => [ 't1', 't2' ],
  }, 'async runtime completes pre-resolved promise list items';
};

subtest 'async runtime: root-leaf DataLoader ticket resumes through the fast continuation' => sub {
  require GraphQL::Houtou::DataLoader;
  # A single nullable root field with no directives and no child block is
  # exactly the shape gql_runtime_vm_try_execute_fast_root_continuation_sv
  # accepts, so these cases exercise the new Ticket-aware continuation
  # rather than the pre-existing generic async executor.
  my $one_field_query = 'query Q($id: String) { greeting(id: $id) }';

  subtest 'already-fulfilled ticket unwraps without suspending' => sub {
    my $calls = 0;
    my $loader = GraphQL::Houtou::DataLoader->new(
      batch => sub { my ($keys) = @_; return [ map { "v:$_" } @$keys ] },
    );
    $loader->prime('k1', 'primed-v1');
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          greeting => {
            type => $String,
            args => { id => { type => $String } },
            resolve => sub {
              my (undef, $args) = @_;
              $calls++;
              return $loader->load($args->{id});
            },
          },
        },
      ),
    );
    my $runtime = build_native_runtime($schema, async => 1);
    my $r = $runtime->execute_document($one_field_query, variables => { id => 'k1' });
    is_deeply $r, { data => { greeting => 'primed-v1' } }, 'ready ticket value flows through';
    is $calls, 1, 'resolver ran exactly once';
  };

  subtest 'genuinely pending ticket resumes via on_stall' => sub {
    my $calls = 0;
    my $dispatches = 0;
    my $loader = GraphQL::Houtou::DataLoader->new(
      batch => sub {
        my ($keys) = @_;
        $dispatches++;
        return [ map { "batched:$_" } @$keys ];
      },
    );
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          greeting => {
            type => $String,
            args => { id => { type => $String } },
            resolve => sub {
              my (undef, $args) = @_;
              $calls++;
              return $loader->load($args->{id});
            },
          },
        },
      ),
    );
    my $runtime = build_native_runtime($schema, async => 1);
    my $r = $runtime->execute_document(
      $one_field_query,
      variables => { id => 'k2' },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );
    is_deeply $r, { data => { greeting => 'batched:k2' } }, 'pending ticket resolves via on_stall';
    is $calls, 1, 'resolver ran exactly once';
    is $dispatches, 1, 'loader dispatched exactly once';
  };

  subtest 'rejected ticket produces a field error, not a request croak' => sub {
    my $loader = GraphQL::Houtou::DataLoader->new(
      batch => sub {
        my ($keys) = @_;
        return [ map { GraphQL::Houtou::DataLoader::Error->new("missing: $_") } @$keys ];
      },
    );
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          greeting => {
            type => $String,
            args => { id => { type => $String } },
            resolve => sub { my (undef, $args) = @_; return $loader->load($args->{id}) },
          },
        },
      ),
    );
    my $runtime = build_native_runtime($schema, async => 1);
    my $r = $runtime->execute_document(
      $one_field_query,
      variables => { id => 'bad' },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );
    is $r->{data}{greeting}, undef, 'field nulled on rejection';
    is scalar @{ $r->{errors} }, 1, 'one error record';
    is $r->{errors}[0]{message}, 'missing: bad', 'rejection reason surfaces as the error message';
    is_deeply $r->{errors}[0]{path}, [ 'greeting' ], 'error path points at the field';
  };
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

subtest 'async runtime: multiple sibling root leaves promote together' => sub {
  require GraphQL::Houtou::DataLoader;
  # Every field here is a nullable scalar leaf with no directives and no
  # child block, so a root block with more than one of them is exactly the
  # shape gql_runtime_vm_try_execute_fast_root_continuation_sv's multi-
  # sibling path (lazy block_frame_t promotion) accepts, rather than
  # falling back to the generic async executor.

  subtest 'one pending sibling among synchronous ones' => sub {
    my $calls = { a => 0, b => 0, c => 0 };
    my $dispatches = 0;
    my $loader = GraphQL::Houtou::DataLoader->new(batch => sub {
      $dispatches++;
      return [ map { "loaded:$_" } @{ $_[0] } ];
    });
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          a => { type => $String, resolve => sub { $calls->{a}++; 'sync-a' } },
          b => {
            type => $String,
            args => { id => { type => $String } },
            resolve => sub { my (undef, $args) = @_; $calls->{b}++; return $loader->load($args->{id}) },
          },
          c => { type => $String, resolve => sub { $calls->{c}++; 'sync-c' } },
        },
      ),
    );
    my $runtime = build_native_runtime($schema, async => 1);
    my $r = $runtime->execute_document(
      'query Q($id: String) { a b(id: $id) c }',
      variables => { id => 'k1' },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );
    is_deeply $r, { data => { a => 'sync-a', b => 'loaded:k1', c => 'sync-c' } },
      'sync siblings and the pending one all resolve';
    is $calls->{$_}, 1, "resolver $_ ran exactly once" for qw(a b c);
    is $dispatches, 1, 'one batch dispatch';
  };

  subtest 'two siblings pending on the same batch settle together' => sub {
    my $dispatches = 0;
    my $loader = GraphQL::Houtou::DataLoader->new(batch => sub {
      $dispatches++;
      return [ map { "v:$_" } @{ $_[0] } ];
    });
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          f1 => { type => $String, resolve => sub { 'sync1' } },
          f2 => {
            type => $String, args => { id => { type => $String } },
            resolve => sub { my (undef, $a) = @_; return $loader->load($a->{id}) },
          },
          f3 => { type => $String, resolve => sub { 'sync3' } },
          f4 => {
            type => $String, args => { id => { type => $String } },
            resolve => sub { my (undef, $a) = @_; return $loader->load($a->{id}) },
          },
          f5 => { type => $String, resolve => sub { 'sync5' } },
        },
      ),
    );
    my $runtime = build_native_runtime($schema, async => 1);
    my $r = $runtime->execute_document(
      'query Q($x: String, $y: String) { f1 f2(id: $x) f3 f4(id: $y) f5 }',
      variables => { x => 'x1', y => 'y1' },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );
    is_deeply $r, {
      data => { f1 => 'sync1', f2 => 'v:x1', f3 => 'sync3', f4 => 'v:y1', f5 => 'sync5' },
    }, 'both pending siblings and every sync sibling resolve';
    is $dispatches, 1, 'one batch dispatch settles both pending siblings';
  };

  subtest 'a rejected sibling nulls only its own field' => sub {
    my $loader = GraphQL::Houtou::DataLoader->new(batch => sub {
      return [ map { GraphQL::Houtou::DataLoader::Error->new("bad: $_") } @{ $_[0] } ];
    });
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          ok => { type => $String, resolve => sub { 'still-ok' } },
          bad => {
            type => $String, args => { id => { type => $String } },
            resolve => sub { my (undef, $a) = @_; return $loader->load($a->{id}) },
          },
        },
      ),
    );
    my $runtime = build_native_runtime($schema, async => 1);
    my $r = $runtime->execute_document(
      'query Q($id: String) { ok bad(id: $id) }',
      variables => { id => 'z1' },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );
    is $r->{data}{ok}, 'still-ok', 'sibling of a rejected field still resolves';
    is $r->{data}{bad}, undef, 'rejected field is null';
    is scalar @{ $r->{errors} }, 1, 'one error record';
    is $r->{errors}[0]{message}, 'bad: z1', 'rejection reason surfaces as the error message';
    is_deeply $r->{errors}[0]{path}, [ 'bad' ], 'error path points at the rejected field';
  };

  subtest 'pre-resolved Promise::XS mixed with a pending Ticket sibling' => sub {
    my $loader = GraphQL::Houtou::DataLoader->new(batch => sub {
      return [ map { "tk:$_" } @{ $_[0] } ];
    });
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          sync_f => { type => $String, resolve => sub { 'plain' } },
          promise_f => { type => $String, resolve => sub { Promise::XS::resolved('pre-resolved') } },
          ticket_f => {
            type => $String, args => { id => { type => $String } },
            resolve => sub { my (undef, $a) = @_; return $loader->load($a->{id}) },
          },
        },
      ),
    );
    my $runtime = build_native_runtime($schema, async => 1);
    my $r = $runtime->execute_document(
      'query Q($id: String) { sync_f promise_f ticket_f(id: $id) }',
      variables => { id => 't1' },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );
    is_deeply $r, {
      data => { sync_f => 'plain', promise_f => 'pre-resolved', ticket_f => 'tk:t1' },
    }, 'a promise settling synchronously during arm and a genuinely pending ticket both resolve';
  };

  subtest 'a non-null sibling forces the whole block back to the generic executor' => sub {
    my $loader = GraphQL::Houtou::DataLoader->new(batch => sub {
      return [ map { "v:$_" } @{ $_[0] } ];
    });
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          strict => { type => $String->non_null, resolve => sub { 'must-have' } },
          loose => {
            type => $String, args => { id => { type => $String } },
            resolve => sub { my (undef, $a) = @_; return $loader->load($a->{id}) },
          },
        },
      ),
    );
    my $runtime = build_native_runtime($schema, async => 1);
    my $r = $runtime->execute_document(
      'query Q($id: String) { strict loose(id: $id) }',
      variables => { id => 'nn1' },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );
    is_deeply $r, { data => { strict => 'must-have', loose => 'v:nn1' } },
      'still correct via the generic executor fallback';
  };

  subtest 'a runtime-directive sibling forces fallback' => sub {
    my $loader = GraphQL::Houtou::DataLoader->new(batch => sub {
      return [ map { "v:$_" } @{ $_[0] } ];
    });
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          plain => { type => $String, resolve => sub { 'plain-val' } },
          loaded => {
            type => $String, args => { id => { type => $String } },
            resolve => sub { my (undef, $a) = @_; return $loader->load($a->{id}) },
          },
        },
      ),
    );
    my $runtime = build_native_runtime($schema, async => 1);
    my $r = $runtime->execute_document(
      'query Q($id: String, $skipIt: Boolean!) { plain @skip(if: $skipIt) loaded(id: $id) }',
      variables => { id => 'd1', skipIt => 1 },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );
    ok !exists($r->{data}{plain}), 'skipped field is absent';
    is $r->{data}{loaded}, 'v:d1', 'the pending sibling still resolves via the fallback';
  };

  subtest 'a statically-pruned sibling forces fallback (bundle/native_program op_index parity)' => sub {
    my $loader = GraphQL::Houtou::DataLoader->new(batch => sub {
      return [ map { "v:$_" } @{ $_[0] } ];
    });
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          plain => { type => $String, resolve => sub { die "must not run: statically skipped" } },
          other => { type => $String, resolve => sub { 'other-val' } },
          loaded => {
            type => $String, args => { id => { type => $String } },
            resolve => sub { my (undef, $a) = @_; return $loader->load($a->{id}) },
          },
        },
      ),
    );
    my $runtime = build_native_runtime($schema, async => 1);
    # A literal (not variable) @skip condition is statically evaluated at
    # bundle-prep time, deleting the op outright - this is the shape the
    # bundle/native_program op_count parity guard exists for.
    my $r = $runtime->execute_document(
      'query Q($id: String) { plain @skip(if: true) other loaded(id: $id) }',
      variables => { id => 's1' },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
    );
    ok !exists($r->{data}{plain}), 'statically skipped field is absent';
    is $r->{data}{other}, 'other-val', 'the field after the pruned one still resolves correctly';
    is $r->{data}{loaded}, 'v:s1', 'the pending sibling still resolves correctly';
  };

  subtest 'many independent requests settle in one shared batch dispatch' => sub {
    my $n = 50;
    my $dispatches = 0;
    my $loader = GraphQL::Houtou::DataLoader->new(
      cache => 0,
      batch => sub { $dispatches++; return [ map { "b:$_" } @{ $_[0] } ] },
    );
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'Query',
        fields => {
          s1 => { type => $String, resolve => sub { 'sync' } },
          p1 => {
            type => $String, args => { id => { type => $String } },
            resolve => sub { my (undef, $a) = @_; return $loader->load($a->{id}) },
          },
        },
      ),
    );
    my $runtime = build_native_runtime($schema, async => 1);
    my @pending;
    for my $i (1 .. $n) {
      # No on_stall: returns the still-pending Promise::XS directly instead
      # of auto-driving it, so all n requests' loads queue on the same
      # loader before anything dispatches.
      push @pending, [ $i, $runtime->execute_document(
        'query Q($id: String) { s1 p1(id: $id) }', variables => { id => "k$i" }) ];
    }
    is $loader->pending_count, $n, "all $n loads queued before dispatch";
    my $dispatched = $loader->dispatch;
    is $dispatches, 1, 'exactly one batch dispatch';
    is $dispatched, $n, "dispatch settled all $n tickets";
    my $ok = 0;
    for my $pair (@pending) {
      my ($i, $r) = @$pair;
      my $settled = maybe_get_promise_xs($r);
      $ok++ if $settled->{data}{s1} eq 'sync' && $settled->{data}{p1} eq "b:k$i";
    }
    is $ok, $n, 'every request settled with the correct value';
  };
};

done_testing;
