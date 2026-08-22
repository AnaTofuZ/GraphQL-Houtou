use strict;
use warnings;

use Test::More;
use Scalar::Util qw(blessed);

use GraphQL::Houtou::Async::Adapter;
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

sub exercise_adapter {
  my ($name, $adapter, $resolved, $pending_factory) = @_;
  my $pending;
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => "${name}Query",
      fields => {
        ready => { type => $String, resolve => sub { $resolved->('ready') } },
        items => {
          type => $String->list,
          resolve => sub { [ $resolved->('a'), $resolved->('b') ] },
        },
        pending => {
          type => $String,
          resolve => sub { ($pending, my $promise) = $pending_factory->(); $promise },
        },
      },
    ),
  );
  my $runtime = $schema->build_native_runtime(async_adapter => $adapter);

  my $ready = $runtime->execute_document('{ ready items }');
  if (blessed($ready)) {
    my ($done, $value);
    $ready->then(sub { ($done, $value) = (1, $_[0]) }, sub { die $_[0] });
    ok $done, "$name pre-resolved response settles synchronously";
    $ready = $value;
  }
  is_deeply $ready, { data => { ready => 'ready', items => [qw(a b)] } },
    "$name adapter completes scalar and list values";

  my $result = $runtime->execute_document('{ pending }');
  my ($done, $value);
  $result->then(sub { ($done, $value) = (1, $_[0]) }, sub { die $_[0] });
  ok !$done, "$name response remains pending";
  $pending->('later');
  ok $done, "$name response resumes after resolution";
  is_deeply $value, { data => { pending => 'later' } },
    "$name pending response is correct";
}

subtest Promises => sub {
  plan skip_all => 'Promises is not installed' if !eval { require Promises; 1 };
  my $adapter = GraphQL::Houtou::Async::Adapter->register(
    name => 'promises_pp',
    class => 'Promises::Promise',
    new_pending => sub {
      my $deferred = Promises::deferred();
      return [ $deferred->promise, sub { $deferred->resolve(@_) }, sub { $deferred->reject(@_) } ];
    },
    all => sub {
      return Promises::collect(@{ $_[0] })->then(sub {
        [ map { @$_ == 1 ? $_->[0] : [@$_] } @_ ]
      });
    },
  );
  exercise_adapter(
    'Promises', $adapter,
    sub {
      my $deferred = Promises::deferred();
      $deferred->resolve(@_);
      return $deferred->promise;
    },
    sub {
      my $deferred = Promises::deferred();
      return (sub { $deferred->resolve(@_) }, $deferred->promise);
    },
  );
};

subtest 'Promise::ES6' => sub {
  plan skip_all => 'Promise::ES6 is not installed' if !eval { require Promise::ES6; 1 };
  my $adapter = GraphQL::Houtou::Async::Adapter->register(
    name => 'promise_es6_pp',
    class => 'Promise::ES6',
    new_pending => sub {
      my ($resolve, $reject);
      my $promise = Promise::ES6->new(sub { ($resolve, $reject) = @_ });
      return [ $promise, $resolve, $reject ];
    },
    all => sub { Promise::ES6->all($_[0]) },
  );
  exercise_adapter(
    'PromiseES6', $adapter,
    sub { Promise::ES6->resolve($_[0]) },
    sub {
      my ($resolve, $reject);
      my $promise = Promise::ES6->new(sub { ($resolve, $reject) = @_ });
      return ($resolve, $promise);
    },
  );
};

done_testing;
