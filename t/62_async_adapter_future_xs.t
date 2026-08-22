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

my $then = sub {
  my ($future, $done, $fail) = @_;
  my @callbacks = (sub { Future->done($done->(@_)) });
  push @callbacks, sub { Future->done($fail->(@_)) } if $fail;
  my $next = $future->then(@callbacks);
  my $keep = $next;
  $future->on_ready(sub { undef $keep }) if !$next->is_ready;
  return $next;
};

my $adapter = GraphQL::Houtou::Async::Adapter->register(
  name => 'test_future_xs',
  class => 'Future',
  then => $then,
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

my $rejected = $then->(Future->fail('original failure'), sub { Future->done(@_) });
is(($rejected->failure)[0], 'original failure',
  'Future adapter preserves rejection when on_fail is omitted');

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

my @warnings;
my $json;
{
  local $SIG{__WARN__} = sub { push @warnings, @_ };
  $json = $runtime->execute_document_to_json(
    '{ pending }',
    on_stall => sub { $pending->done('driven'); 1 },
  );
}
is $json, '{"data":{"pending":"driven"}}',
  'on_stall drives a Future JSON response through the adapter';
is_deeply \@warnings, [], 'Future JSON settlement emits no warnings';

done_testing;
