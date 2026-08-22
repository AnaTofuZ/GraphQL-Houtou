use strict;
use warnings;

use Test::More;
use Scalar::Util qw(blessed);

BEGIN {
  eval { require Promise::ES6; Promise::ES6->VERSION(0.28); 1 }
    or plan skip_all => 'Promise::ES6 0.28 required';
}

use GraphQL::Houtou::Async::Adapter;
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

my $then_error;
my $adapter = GraphQL::Houtou::Async::Adapter->register(
  name => 'test_promise_es6',
  class => 'Promise::ES6',
  then => sub {
    die "$then_error\n" if defined $then_error;
    my ($promise, @callbacks) = @_;
    return $promise->then(@callbacks);
  },
  new_pending => sub {
    my $resolve;
    my $promise = Promise::ES6->new(sub { ($resolve) = @_ });
    return [ $promise, $resolve ];
  },
  all => sub { Promise::ES6->all($_[0]) },
);

my $resolve_pending;
my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'PromiseES6AdapterQuery',
    fields => {
      ready => {
        type => $String,
        resolve => sub { Promise::ES6->resolve('ready') },
      },
      items => {
        type => $String->list,
        resolve => sub {
          [ Promise::ES6->resolve('a'), 'b' ]
        },
      },
      pending => {
        type => $String,
        resolve => sub {
          return Promise::ES6->new(sub { ($resolve_pending) = @_ });
        },
      },
    },
  ),
);

my $runtime = $schema->build_native_runtime(async_adapter => $adapter);
my $ready_value = $runtime->execute_document('{ ready items }');
my $ready = !blessed($ready_value);
if (!$ready) {
  $ready_value->then(sub { ($ready, $ready_value) = (1, $_[0]) });
}
ok $ready, 'Promise::ES6 pre-resolved response settles synchronously';
is_deeply $ready_value, {
  data => { ready => 'ready', items => [qw(a b)] },
}, 'external-style Promise::ES6 adapter completes values';

my $result = $runtime->execute_document('{ pending }');
my ($done, $value);
$result->then(sub { ($done, $value) = (1, $_[0]) });
ok !$done, 'Promise::ES6 response remains pending';
$resolve_pending->('later');
ok $done, 'Promise::ES6 response resumes after resolution';
is_deeply $value, { data => { pending => 'later' } },
  'Promise::ES6 pending response is correct';

$then_error = 'adapter then failed';
eval {
  $runtime->_settle_result(Promise::ES6->resolve('unused'), sub { 0 });
};
my $error = $@;
like $error, qr/adapter then failed/, 'adapter then exceptions propagate';
unlike $error, qr/execution stalled/, 'adapter then exceptions are not reported as stalls';

done_testing;
