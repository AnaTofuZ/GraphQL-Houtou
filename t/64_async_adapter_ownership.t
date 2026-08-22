use strict;
use warnings;
use Test::More;

use GraphQL::Houtou::Async::Adapter;
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

{
  package Local::Promise;
  sub resolved { bless { value => $_[1] }, $_[0] }
  sub pending { bless {}, $_[0] }
  sub value { $_[0]{value} }
}

my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'AdapterOwnershipQuery',
    fields => { value => { type => $String } },
  ),
);

my (@runtimes, @called);
for my $index (0 .. 16) {
  my $adapter = GraphQL::Houtou::Async::Adapter->register(
    name => 'same_name_is_only_metadata',
    class => 'Local::Promise',
    new_pending => sub { die 'not used' },
    all => sub { die 'not used' },
    then => sub {
      my ($promise, $done) = @_;
      $called[$index]++;
      return Local::Promise->resolved($done->($promise->value));
    },
  );
  my $runtime = $schema->build_native_runtime(async_adapter => $adapter);
  my $chain = GraphQL::Houtou::XS::VM::runtime_then_async_xs(
    $runtime->_native_runtime_handle,
    Local::Promise->resolved($index),
    sub { $_[0] + 1 },
  );
  is $chain->value, $index + 1, "runtime $index owns the correct adapter";
  push @runtimes, $runtime;
}

is_deeply \@called, [ (1) x 17 ],
  'same-name adapters have independent callbacks and no global limit';

my $invalid = GraphQL::Houtou::Async::Adapter->register(
  class => 'Local::Promise',
  new_pending => sub { die 'not used' },
  all => sub { die 'not used' },
);
eval {
  $schema->build_native_runtime(async_adapter => $invalid)->_native_runtime_handle;
};
like $@, qr/requires class, new_pending, all, and then/,
  'then is required and invalid runtime construction is cleaned up';

my $pending_schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'InvalidPendingFactoryQuery',
    fields => {
      value => {
        type => $String,
        resolve => sub { Local::Promise->pending },
      },
    },
  ),
);
for my $case (
  [ 'promise', sub { [ 'not a promise', sub {} ] } ],
  [ 'resolve callback', sub { [ Local::Promise->resolved(undef), 'not code' ] } ],
) {
  my $adapter = GraphQL::Houtou::Async::Adapter->register(
    class => 'Local::Promise',
    new_pending => $case->[1],
    all => sub { die 'not used' },
    then => sub {
      my ($promise, $done) = @_;
      return Local::Promise->pending if !exists $promise->{value};
      return Local::Promise->resolved($done->($promise->value));
    },
  );
  eval {
    $pending_schema->build_native_runtime(async_adapter => $adapter)
      ->execute_document('{ value }');
  };
  like $@, qr/must return \[promise, resolve coderef\]/,
    "new_pending validates its $case->[0]";
}
is_deeply GraphQL::Houtou::XS::VM::debug_frame_live_counts_xs(), {
  block_frame => 0,
  path_frame => 0,
  lazy_info => 0,
}, 'invalid pending factories release execution frames';

my $builtin = $schema->build_native_runtime(async => 1);
my $plain = GraphQL::Houtou::XS::VM::runtime_then_async_xs(
  $builtin->_native_runtime_handle,
  'plain value',
  sub { uc $_[0] },
);
is $plain, 'PLAIN VALUE', 'Promise::XS dispatch does not treat scalars as promises';

done_testing;
