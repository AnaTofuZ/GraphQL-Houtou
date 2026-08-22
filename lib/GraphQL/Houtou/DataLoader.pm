package GraphQL::Houtou::DataLoader;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou ();
use GraphQL::Houtou::Async::Adapter ();
use Scalar::Util qw(blessed);

our $VERSION = '0.08';

GraphQL::Houtou::_bootstrap_xs();

# Reference batching loader for GraphQL::Houtou, following the semantics of
# Facebook's dataloader. It is written strictly against the public batching
# contract (execute's on_stall hook): loads queue a key and return an
# XS-backed await ticket; dispatch() sends every queued key to the batch
# function in one call and settles the tickets.

sub new {
  my ($class, %args) = @_;
  my $batch = $args{batch};
  die "GraphQL::Houtou::DataLoader requires a 'batch' function\n"
    if ref($batch) ne 'CODE';
  my $async_adapter = exists $args{async_adapter}
    ? GraphQL::Houtou::Async::Adapter->coerce($args{async_adapter})
    : undef;
  return bless {
    batch => $batch,
    max_batch_size => $args{max_batch_size} || 0,
    cache => exists $args{cache} ? ($args{cache} ? 1 : 0) : 1,
    cache_key => ref($args{cache_key}) eq 'CODE' ? $args{cache_key} : undef,
    _batch_plan => $args{batch_plan} ? 1 : 0,
    ($async_adapter ? (_async_adapter => $async_adapter) : ()),
    _promises => {},
    _queue => [],
  }, $class;
}

sub load {
  my ($self, $key) = @_;
  die "GraphQL::Houtou::DataLoader::load requires a defined key\n" if !defined $key;
  my $cache_key = $self->{cache}
    ? ($self->{cache_key} ? $self->{cache_key}->($key) : $key)
    : undef;
  if ($self->{cache} && exists $self->{_promises}{$cache_key}) {
    return $self->{_promises}{$cache_key};
  }
  return $self->_enqueue_load_miss($key, $cache_key, $self->{cache});
}

# dataloader-js semantics: takes an arrayref of keys, returns one promise
# that resolves with an arrayref of values in key order. Per-key failures
# do not reject the promise; the failed slots hold
# GraphQL::Houtou::DataLoader::Error objects instead.
sub load_many {
  my ($self, @args) = @_;
  if (@args != 1 || ref($args[0]) ne 'ARRAY') {
    warnings::warnif(deprecated =>
      'GraphQL::Houtou::DataLoader::load_many(LIST) is deprecated; '
      . 'pass an arrayref of keys to get a single promise');
    return map { $self->load($_) } @args;
  }
  my $keys = $args[0];
  return GraphQL::Houtou::DataLoader::Ticket->resolved(
    [], $self->{_async_adapter},
  ) if !@$keys;

  my @results;
  my $remaining = @$keys;
  my $ticket = GraphQL::Houtou::DataLoader::Ticket->new(
    $self->{_async_adapter},
  );
  for my $i (0 .. $#$keys) {
    my $slot = $i;
    $self->load($keys->[$slot])->_subscribe(
      sub {
        $results[$slot] = $_[0];
        $ticket->_resolve(\@results) if !--$remaining;
        return;
      },
      sub {
        my ($reason) = @_;
        $results[$slot] =
          blessed($reason) && $reason->isa('GraphQL::Houtou::DataLoader::Error')
          ? $reason
          : GraphQL::Houtou::DataLoader::Error->new($reason);
        $ticket->_resolve(\@results) if !--$remaining;
        return;
      },
    );
  }
  return $ticket;
}

sub prime {
  my ($self, $key, $value) = @_;
  my $cache_key = $self->{cache_key} ? $self->{cache_key}->($key) : $key;
  return $self if !$self->{cache} || exists $self->{_promises}{$cache_key};
  $self->{_promises}{$cache_key} =
    GraphQL::Houtou::DataLoader::Ticket->resolved(
      $value, $self->{_async_adapter},
    );
  return $self;
}

sub clear {
  my ($self, $key) = @_;
  my $cache_key = $self->{cache_key} ? $self->{cache_key}->($key) : $key;
  delete $self->{_promises}{$cache_key};
  return $self;
}

sub clear_all {
  my ($self) = @_;
  $self->{_promises} = {};
  return $self;
}

sub pending_count { return scalar @{ $_[0]{_queue} } }

# Send every queued key to the batch function and settle the promises.
# Returns the number of keys dispatched (the on_stall progress signal).
# Settling promises runs GraphQL continuations synchronously, which may
# queue new loads; those land in a fresh queue for the next dispatch.
sub dispatch {
  my ($self) = @_;
  my $queue = $self->{_queue};
  return 0 if !@$queue;
  $self->{_queue} = [];
  return $self->_dispatch_queue($queue);
}

# Build an on_stall callback that keeps dispatching a set of loaders until
# a full pass makes no progress. Loaders may feed each other: settling one
# loader's promises can queue loads on another within the same stall.
sub on_stall_for {
  my ($class, @loaders) = @_;
  return sub {
    my $total = 0;
    my $round;
    do {
      $round = 0;
      $round += $_->dispatch for @loaders;
      $total += $round;
    } while ($round);
    return $total;
  };
}

package GraphQL::Houtou::DataLoader::Error;

sub new {
  my ($class, $message) = @_;
  return bless { message => $message }, $class;
}

sub message { return $_[0]{message} }

package GraphQL::Houtou::DataLoader::Ticket;

sub _new_pending {
  my ($adapter) = @_;
  return @{ $adapter->new_pending };
}

sub _as_promise {
  my ($self) = @_;
  return GraphQL::Houtou::Async::Adapter::ticket_promise($self);
}

*then = \&GraphQL::Houtou::Async::Adapter::ticket_then;

sub _catch_adapter {
  my ($adapter, $self, $callback) = @_;
  return $adapter->then($self->_as_promise, sub { $_[0] }, $callback);
}

*catch = \&GraphQL::Houtou::Async::Adapter::ticket_catch;

sub _after {
  my ($adapter, $callback, $done, $reject) = @_;
  my $result;
  eval { $result = $callback->(); 1 } or return $reject->($@);
  return $adapter->then($result, sub { $done->() }, $reject)
    if $adapter->is_promise($result);
  return $done->();
}

sub _finally_adapter {
  my ($adapter, $self, $callback) = @_;
  my ($promise, $resolve, $reject) = _new_pending($adapter);
  $self->_subscribe_native(
    sub {
      my $value = $_[0];
      _after($adapter, $callback, sub { $resolve->($value) }, $reject);
    },
    sub {
      my $reason = $_[0];
      _after($adapter, $callback, sub { $reject->($reason) }, $reject);
    },
  );
  return $promise;
}

*finally = \&GraphQL::Houtou::Async::Adapter::ticket_finally;

sub _adapt_values {
  return [ map {
    Scalar::Util::blessed($_)
      && $_->isa('GraphQL::Houtou::DataLoader::Ticket')
      ? $_->_as_promise : $_
  } @_ ];
}

sub _all_adapter {
  my ($adapter, @values) = @_;
  return $adapter->all(_adapt_values(@values));
}

*all = \&GraphQL::Houtou::Async::Adapter::ticket_all;

sub _race_adapter {
  my ($adapter, @values) = @_;
  my ($promise, $resolve, $reject) = _new_pending($adapter);
  my $settled = 0;
  for (@{ _adapt_values(@values) }) {
    if (!$adapter->is_promise($_)) {
      $resolve->($_) if !$settled++;
      next;
    }
    $adapter->then(
      $_,
      sub { $resolve->(@_) if !$settled++; return },
      sub { $reject->(@_) if !$settled++; return },
    );
  }
  return $promise;
}

*race = \&GraphQL::Houtou::Async::Adapter::ticket_race;

package GraphQL::Houtou::DataLoader;

1;
__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou::DataLoader - batching loader for GraphQL::Houtou resolvers

=head1 SYNOPSIS

  use GraphQL::Houtou qw(execute);
  use GraphQL::Houtou::DataLoader;

  # per request
  my $users = GraphQL::Houtou::DataLoader->new(batch => sub {
    my ($ids) = @_;
    my %row = map { $_->{id} => $_ } $db->select_users_in(@$ids);
    return [ map { $row{$_} } @$ids ];   # one entry per key, key order
  });

  # resolvers return promises from the loader
  #   resolve => sub { my ($src) = @_; $users->load($src->{user_id}) }

  my $result = execute($schema, $query, $variables,
    context => { users => $users },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($users),
  );

=head1 DESCRIPTION

Solves the N+1 problem for SQL-backed resolvers. Every C<load> during one
execution phase queues its key and returns a promise; when execution stalls
(all remaining fields are waiting on promises), the C<on_stall> hook
dispatches the queued keys to the batch function in a single call and
settles the promises, which resumes execution. A query touching N users
issues one batched lookup per nesting level instead of N individual ones.

C<execute> with C<on_stall> drives the request to completion and returns
the finished response synchronously - callers never handle promises.

=head1 MULTIPLE LOADERS

Real schemas use several loaders per request, and one loader is usually
shared by every field that resolves the same kind of record. Both shapes
need no special wiring: put every loader in the context and register them
all with C<on_stall_for>:

  my $users   = GraphQL::Houtou::DataLoader->new(batch => \&batch_users);
  my $entries = GraphQL::Houtou::DataLoader->new(batch => \&batch_entries);

  # Blog.author and Entry.author share $users; Blog also uses $entries.
  #   Blog:  author      => sub { $_[2]->{users}->load($_[0]{author_id}) }
  #          latestEntry => sub { $_[2]->{entries}->load($_[0]{latest_entry_id}) }
  #   Entry: author      => sub { $_[2]->{users}->load($_[0]{author_id}) }

  my $result = execute($schema, $query, $variables,
    context  => { users => $users, entries => $entries },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($users, $entries),
  );

Sharing one loader across types means the per-request cache dedupes keys
globally: a user already fetched for C<Blog.author> is not fetched again
for C<Entry.author>. Loaders may also feed each other - settling one
loader's promises can queue loads on another, and a single stall keeps
dispatching until a full pass makes no progress - so each dependency
level still costs one batched query per loader.

=head1 THE BATCH FUNCTION

Receives an arrayref of unique keys and must return an arrayref of the
same length, in key order. An entry may be a
C<GraphQL::Houtou::DataLoader::Error> object to fail only that key; a die
inside the batch function fails every key in the batch.

=head1 METHODS

C<load($key)>, C<load_many(\@keys)>, C<prime($key, $value)>, C<clear($key)>,
C<clear_all>, C<pending_count>, C<dispatch>.

C<batch_plan =E<gt> 1> enables Houtou's executor-owned fast path for the
narrow cacheless declarative object-list shape documented in
L<GraphQL::Houtou/Declarative loader fields>. Other shapes fall back to the
normal ticket-backed path.

C<load_many> follows dataloader-js C<loadMany>: it takes an arrayref of
keys and returns a single thenable that resolves with an arrayref of values
in key order. It never rejects on per-key failures - failed slots hold
C<GraphQL::Houtou::DataLoader::Error> objects (check with C<blessed> +
C<isa>, read the reason with C<< ->message >>). Calling it with a flat key
list is deprecated (it returns one promise per key and warns in the
C<deprecated> category).

C<load> and C<load_many> return XS-backed tickets. They retain the
Promise::XS chaining methods C<then>, C<catch>, C<finally>, C<all>, and
C<race> for application code. The executor uses C<AWAIT_IS_READY> and
C<AWAIT_GET> to consume already-settled cache entries without creating a
Promise::XS continuation; pending tickets notify the executor directly
from XS. Calling C<AWAIT_GET> before readiness throws, and calling it on a
rejected ticket throws the rejection reason.

Instances cache per key (create one loader per request unless you want
cross-request caching). Pass C<< cache => 0 >> to disable, C<cache_key>
to derive cache keys from structured keys, C<max_batch_size> to chunk
large batches. Pass the runtime's C<async_adapter> to make C<then>, C<catch>,
C<finally>, C<all>, and C<race> return that adapter's promise type.

=head1 THE on_stall CONTRACT

This loader is one implementation of the generic batching contract: the
C<on_stall> callback passed to C<execute> is invoked whenever execution
cannot proceed because promises are pending, and must return the number of
units it dispatched. Returning 0 while promises remain pending is reported
as a deadlock. Anything that can resolve promises - a hand-written batcher,
an ORM-specific loader - can implement the same contract;
C<< GraphQL::Houtou::DataLoader->on_stall_for(@loaders) >> builds the
callback for one or more of these loaders.

=cut
