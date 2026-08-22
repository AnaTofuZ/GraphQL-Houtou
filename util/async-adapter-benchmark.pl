use 5.024;
use strict;
use warnings;

use Benchmark qw(cmpthese);
use FindBin qw($Bin);
use Getopt::Long qw(GetOptions);

use lib "$Bin/../lib", "$Bin/../blib/lib", "$Bin/../blib/arch";
use GraphQL::Houtou::Async::Adapter;
use GraphQL::Houtou::Promise::PromiseXS ();
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

my $count = -3;
GetOptions('count=s' => \$count) or die "Usage: $0 [--count Benchmark-count]\n";

sub runtime_for {
  my ($resolve, $adapter) = @_;
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'AsyncAdapterBenchmarkQuery',
      fields => { value => { type => $String, resolve => $resolve } },
    ),
  );
  return $schema->build_native_runtime(
    defined($adapter) ? (async_adapter => $adapter) : (),
  );
}

my %cases;
my $sync = runtime_for(sub { 'ok' });
$cases{sync} = sub { $sync->execute_document('{ value }') };

require Promise::XS;
my $promise_xs = runtime_for(sub { Promise::XS::resolved('ok') }, 'Promise::XS');
$cases{promise_xs} = sub { $promise_xs->execute_document('{ value }') };

if (eval { require Future; Future->VERSION(0.45); 1 }) {
  require GraphQL::Houtou::Async::Adapter::Future;
  my $future = runtime_for(
    sub { Future->done('ok') },
    GraphQL::Houtou::Async::Adapter::Future->adapter,
  );
  $cases{future_pp} = sub { $future->execute_document('{ value }') };
}

if (eval { require Promises; 1 }) {
  my $adapter = GraphQL::Houtou::Async::Adapter->register(
    name => 'benchmark_promises',
    class => 'Promises::Promise',
    new_pending => sub {
      my $d = Promises::deferred();
      [ $d->promise, sub { $d->resolve(@_) }, sub { $d->reject(@_) } ]
    },
    all => sub {
      Promises::collect(@{ $_[0] })->then(sub {
        [ map { @$_ == 1 ? $_->[0] : [@$_] } @_ ]
      })
    },
  );
  my $runtime = runtime_for(sub {
    my $d = Promises::deferred();
    $d->resolve('ok');
    return $d->promise;
  }, $adapter);
  $cases{promises_pp} = sub { $runtime->execute_document('{ value }') };
}

if (eval { require Promise::ES6; 1 }) {
  my $adapter = GraphQL::Houtou::Async::Adapter->register(
    name => 'benchmark_promise_es6',
    class => 'Promise::ES6',
    new_pending => sub {
      my ($resolve, $reject);
      my $promise = Promise::ES6->new(sub { ($resolve, $reject) = @_ });
      [ $promise, $resolve, $reject ]
    },
    all => sub { Promise::ES6->all($_[0]) },
  );
  my $runtime = runtime_for(sub { Promise::ES6->resolve('ok') }, $adapter);
  $cases{promise_es6_pp} = sub { $runtime->execute_document('{ value }') };
}

$_->() for values %cases;
print "Pre-resolved scalar through GraphQL::Houtou async adapters\n";
cmpthese($count, \%cases);
