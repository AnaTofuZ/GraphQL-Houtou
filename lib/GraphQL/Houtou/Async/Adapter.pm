package GraphQL::Houtou::Async::Adapter;

use 5.024;
use strict;
use warnings;
use Promise::XS ();
use Scalar::Util qw(blessed);
use GraphQL::Houtou ();

our $VERSION = $GraphQL::Houtou::VERSION;

sub register {
  my ($class, %spec) = @_;
  return bless \%spec, $class;
}

my %BUILTIN;
sub builtin { return $BUILTIN{$_[0]} ||= bless { _builtin => 1 }, $_[0] }
sub _spec { $_[0]->is_builtin ? undef : $_[0] }
sub is_builtin { $_[0]{_builtin} ? 1 : 0 }

sub coerce {
  my ($class, $adapter) = @_;
  return $class->builtin
    if !defined($adapter) || (!ref($adapter) && $adapter eq 'Promise::XS');
  die "async_adapter must be an adapter object; only 'Promise::XS' is built in\n"
    if !ref($adapter);
  die "async_adapter must be a GraphQL::Houtou async adapter object\n"
    if !blessed($adapter) || !$adapter->isa($class);
  return $adapter;
}

sub new_pending {
  my ($self) = @_;
  if ($self->is_builtin) {
    my $deferred = Promise::XS::deferred();
    return [
      $deferred->promise,
      sub { $deferred->resolve(@_) },
      sub { $deferred->reject(@_) },
    ];
  }
  my $pending = $self->{new_pending}->();
  die "async adapter new_pending must return [promise, resolve, reject]\n"
    if ref($pending) ne 'ARRAY' || !$self->is_promise($pending->[0])
    || ref($pending->[1]) ne 'CODE' || ref($pending->[2]) ne 'CODE';
  return $pending;
}

sub from_ticket {
  my ($self, $ticket) = @_;
  if ($self->is_builtin) {
    my $deferred = Promise::XS::deferred();
    $ticket->_subscribe_native(
      sub { $deferred->resolve($_[0]) },
      sub { $deferred->reject($_[0]) },
    );
    return $deferred->promise;
  }
  my ($promise, $resolve, $reject) = @{ $self->new_pending };
  $ticket->_subscribe_native($resolve, $reject);
  return $promise;
}

sub ticket_promise {
  my ($ticket) = @_;
  return ($ticket->[3] || __PACKAGE__->builtin)->from_ticket($ticket);
}

sub ticket_then {
  my ($ticket, @callbacks) = @_;
  my $adapter = $ticket->[3];
  if (!$adapter) {
    my $deferred = Promise::XS::deferred();
    $ticket->_subscribe_native(
      sub { $deferred->resolve($_[0]) },
      sub { $deferred->reject($_[0]) },
    );
    return $deferred->promise->then(@callbacks);
  }
  return $adapter->then($adapter->from_ticket($ticket), @callbacks);
}

sub ticket_catch {
  my ($ticket, $callback) = @_;
  my $adapter = $ticket->[3];
  if (!$adapter) {
    my $deferred = Promise::XS::deferred();
    $ticket->_subscribe_native(
      sub { $deferred->resolve($_[0]) },
      sub { $deferred->reject($_[0]) },
    );
    return $deferred->promise->catch($callback);
  }
  return GraphQL::Houtou::DataLoader::Ticket::_catch_adapter(
    $adapter, $ticket, $callback,
  );
}

sub ticket_finally {
  my ($ticket, $callback) = @_;
  my $adapter = $ticket->[3];
  if (!$adapter) {
    my $deferred = Promise::XS::deferred();
    $ticket->_subscribe_native(
      sub { $deferred->resolve($_[0]) },
      sub { $deferred->reject($_[0]) },
    );
    return $deferred->promise->finally($callback);
  }
  return GraphQL::Houtou::DataLoader::Ticket::_finally_adapter(
    $adapter, $ticket, $callback,
  );
}

# ponytail: one Perl adapter branch; move it to XS only if public chain profiles matter.
sub ticket_race {
  my $invocant = shift;
  if (ref($invocant)) {
    my $adapter = $invocant->[3];
    return Promise::XS::Promise->race(@_) if !$adapter;
    return GraphQL::Houtou::DataLoader::Ticket::_race_adapter(
      $adapter, @_,
    );
  }
  my ($ticket) = grep {
    ref($_) eq 'GraphQL::Houtou::DataLoader::Ticket'
  } @_;
  my $adapter = $ticket && $ticket->[3];
  return Promise::XS::Promise->race(@_) if !$adapter;
  return GraphQL::Houtou::DataLoader::Ticket::_race_adapter(
    $adapter, @_,
  );
}

sub ticket_all {
  my $invocant = shift;
  if (ref($invocant)) {
    my $adapter = $invocant->[3];
    return Promise::XS::Promise->all(@_) if !$adapter;
    return GraphQL::Houtou::DataLoader::Ticket::_all_adapter(
      $adapter, @_,
    );
  }
  my ($ticket) = grep {
    ref($_) eq 'GraphQL::Houtou::DataLoader::Ticket'
  } @_;
  my $adapter = $ticket && $ticket->[3];
  return Promise::XS::Promise->all(@_) if !$adapter;
  return GraphQL::Houtou::DataLoader::Ticket::_all_adapter(
    $adapter, @_,
  );
}

sub all {
  my ($self, $values) = @_;
  return $self->{all}->($values) if !$self->is_builtin;
  return Promise::XS::Promise->all(@$values);
}

sub then {
  my ($self, $promise, @callbacks) = @_;
  return $self->{then}->($promise, @callbacks) if !$self->is_builtin;
  return $promise->then(@callbacks);
}

sub is_promise {
  my ($self, $value) = @_;
  return 0 if !blessed($value);
  return $value->isa('Promise::XS::Promise') if $self->is_builtin;
  return $value->isa($self->{class});
}

1;

__END__

=head1 NAME

GraphQL::Houtou::Async::Adapter - describe an async backend for Houtou's XS VM

=head1 SYNOPSIS

In an adapter distribution:

  package GraphQL::Houtou::Async::Adapter::MyPromise;

  use parent 'GraphQL::Houtou::Async::Adapter';

  my $ADAPTER;

  sub adapter {
    return $ADAPTER ||= __PACKAGE__->register(
      name        => 'my_promise',
      class       => 'My::Promise',
      new_pending => \&new_pending,
      all         => \&all,
      then        => \&then,
    );
  }

In an application:

  use GraphQL::Houtou::Async::Adapter::MyPromise;

  my $adapter = GraphQL::Houtou::Async::Adapter::MyPromise->adapter;
  my $runtime = $schema->build_native_runtime(async_adapter => $adapter);

=head1 DESCRIPTION

This module is the public adapter boundary between the Houtou native VM
and promise implementations. Houtou only bundles its C<Promise::XS> fast path.
Adapters for other implementations should be released as independent
distributions.

Each native runtime owns its adapter callbacks. Adapter objects may be reused
across runtimes without process-global registration or adapter limits.

=head1 ADAPTER CONTRACT

=over

=item name

An optional identifier for documentation and diagnostics.

=item class

The promise class returned by resolvers and adapter callbacks. Subclasses are
also recognized.

=item new_pending

A coderef taking no arguments and returning C<[ $promise, $resolve ]>, or
C<[ $promise, $resolve, $reject ]> when the adapter is also used by DataLoader.
The latter callbacks settle C<$promise>; the VM only needs C<$resolve>.

=item all

A coderef receiving one array reference. It must accept plain values and
backend promises and return a backend promise that resolves to one array
reference in the original order.

=item then

A required coderef called as C<($promise, $on_done, $on_fail)>, where
C<$on_fail> may be omitted.

Some promise implementations require callbacks to return another promise. In
that case the adapter must wrap plain values returned by Houtou's callbacks.
For example, a Future-style adapter needs the equivalent of:

  then => sub {
    my ($future, $done, $fail) = @_;
    my @callbacks = (sub { Future->done($done->(@_)) });
    push @callbacks, sub { Future->done($fail->(@_)) } if $fail;
    my $next = $future->then(@callbacks);
    my $keep = $next;
    $future->on_ready(sub { undef $keep }) if !$next->is_ready;
    return $next;
  }

=back

=head1 WRITING AN ADAPTER IN PERL

For a promise whose C<then> method accepts ordinary callback return values, the
adapter can delegate directly to that method:

  my $adapter = GraphQL::Houtou::Async::Adapter->register(
    name  => 'promise_es6',
    class => 'Promise::ES6',
    new_pending => sub {
      my ($resolve, $reject);
      my $promise = Promise::ES6->new(sub {
        ($resolve, $reject) = @_;
      });
      return [ $promise, $resolve, $reject ];
    },
    all => sub {
      return Promise::ES6->all($_[0]);
    },
    then => sub {
      my ($promise, @callbacks) = @_;
      return $promise->then(@callbacks);
    },
  );

The adapter object should be cached by the adapter module and passed to
C<build_native_runtime> through C<async_adapter>. Only C<'Promise::XS'> has a
built-in string form.

=head1 WRITING AN ADAPTER IN XS

All three callbacks may be XSUB coderefs. A small Perl bootstrap can therefore
register native functions supplied by an external XS distribution:

  package GraphQL::Houtou::Async::Adapter::NativePromise;

  use XSLoader;
  use GraphQL::Houtou::Async::Adapter;

  XSLoader::load(__PACKAGE__, our $VERSION);

  my $ADAPTER = GraphQL::Houtou::Async::Adapter->register(
    name        => 'native_promise',
    class       => 'Native::Promise',
    new_pending => \&new_pending_xs,
    all         => \&all_xs,
    then        => \&then_xs,
  );

  sub adapter { $ADAPTER }

The XSUB signatures follow the same contract:

  SV * new_pending_xs() /* returns [promise, resolve, reject] */
  SV * all_xs(values)
      SV *values
  SV * then_xs(promise, on_done, on_fail = &PL_sv_undef)
      SV *promise
      SV *on_done
      SV *on_fail

An XS adapter may call the promise implementation's public C API directly.
For example, C<Future::XS> exposes F<future.h>. A Perl adapter for that backend
should load C<Future::XS> but use the public C<Future> class, which selects the
XS implementation while retaining C<Future>'s compatibility methods. Merely
moving Perl method calls into an XSUB does not remove their cost; use the
backend C API where the benchmark justifies the extra code.

=head1 PERFORMANCE

Adapter ownership and dispatch live in XS. The callbacks may themselves be XSUBs,
so an XS-backed implementation does not need a Perl callback body. The bundled
C<Promise::XS> backend still has a dedicated VM hot path and is the baseline
for adapter benchmarks.

=cut
