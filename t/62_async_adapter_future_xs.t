use strict;
use warnings;

use Test::More;
use Scalar::Util qw(blessed);

use Future;
use Future::XS 0.15;
use GraphQL::Houtou::Async::Adapter;
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

ok(Future->isa('Future::XS'), 'Future uses the XS implementation');

my $adapter = GraphQL::Houtou::Async::Adapter->register(
  name => 'test_future_xs',
  class => 'Future',
  then => sub {
    my ($future, $done, $fail) = @_;
    my $next = $future->then(
      sub { Future->done($done->(@_)) },
      sub { Future->done($fail->(@_)) },
    );
    my $keep = $next;
    $future->on_ready(sub { undef $keep }) if !$next->is_ready;
    return $next;
  },
  new_pending => sub {
    my $future = Future->new;
    return [
      $future,
      sub { $future->done(@_) },
      sub { $future->fail(@_) },
    ];
  },
  all => sub {
    my @futures = map {
      blessed($_) && $_->isa('Future') ? $_ : Future->done($_)
    } @{ $_[0] };
    return Future->done([]) if !@futures;
    return Future->needs_all(@futures)->then(
      sub { Future->done([@_]) },
    );
  },
);

my $pending;
my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'FutureXSAdapterQuery',
    fields => {
      ready => { type => $String, resolve => sub { Future->done('ready') } },
      items => {
        type => $String->list,
        resolve => sub { [ Future->done('a'), 'b' ] },
      },
      pending => {
        type => $String,
        resolve => sub { $pending = Future->new },
      },
    },
  ),
);

my $runtime = $schema->build_native_runtime(async_adapter => $adapter);
my $ready = $runtime->execute_document('{ ready items }');
($ready) = $ready->get if blessed($ready);
is_deeply $ready, { data => { ready => 'ready', items => [qw(a b)] } },
  'external-style Future::XS adapter completes values';

my $result = $runtime->execute_document('{ pending }');
ok !$result->is_ready, 'XS-backed Future response remains pending';
$pending->done('later');
my ($settled) = $result->get;
is_deeply $settled, { data => { pending => 'later' } },
  'Future::XS response resumes after resolution';

done_testing;
