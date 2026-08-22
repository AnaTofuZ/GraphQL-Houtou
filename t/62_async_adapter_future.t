use strict;
use warnings;

use Test::More;
use Scalar::Util qw(blessed);

BEGIN {
  eval { require Future; Future->VERSION(0.45); 1 }
    or plan skip_all => 'Future 0.45 is not installed';
}

use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

my $pending;
my $Child = GraphQL::Houtou::Type::Object->new(
  name => 'FutureAdapterChild',
  fields => {
    nested => { type => $String, resolve => sub { Future->done($_[0]{nested}) } },
  },
);
my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'FutureAdapterQuery',
    fields => {
      ready => {
        type => $String,
        resolve => sub { Future->done('ready') },
      },
      items => {
        type => $String->list,
        resolve => sub { [ Future->done('a'), Future->done('b') ] },
      },
      pending => {
        type => $String,
        resolve => sub { $pending = Future->new },
      },
      child => {
        type => $Child,
        resolve => sub { Future->done({ nested => 'inside' }) },
      },
    },
  ),
);

my $runtime = $schema->build_native_runtime(async_adapter => 'Future');
my $ready = $runtime->execute_document('{ ready items child { nested } }');
($ready) = $ready->get if blessed($ready) && $ready->isa('Future');
is_deeply $ready, {
  data => { ready => 'ready', items => [qw(a b)], child => { nested => 'inside' } },
},
  'Future adapter completes pre-resolved fields and lists';

my $result = $runtime->execute_document('{ pending }');
isa_ok $result, 'Future';
ok !$result->is_ready, 'pending Future stays pending';
$pending->done('later');
my ($settled) = $result->get;
is_deeply $settled, { data => { pending => 'later' } },
  'pending Future resumes native execution';

my $driven = $runtime->execute_document(
  '{ pending }',
  on_stall => sub { $pending->done('driven'); 1 },
);
is_deeply $driven, { data => { pending => 'driven' } },
  'on_stall drives a Future response through XS';

done_testing;
