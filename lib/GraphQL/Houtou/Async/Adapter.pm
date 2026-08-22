package GraphQL::Houtou::Async::Adapter;

use 5.024;
use strict;
use warnings;

sub register {
  my ($class, %spec) = @_;
  require GraphQL::Houtou;
  GraphQL::Houtou::_bootstrap_xs();
  my $code = GraphQL::Houtou::XS::VM::register_async_adapter_xs(\%spec);
  return bless \$code, $class;
}

sub builtin { bless \(my $code = $_[1]), $_[0] }
sub backend_code { ${ $_[0] } }

1;

__END__

=head1 NAME

GraphQL::Houtou::Async::Adapter - register an async backend with Houtou's XS VM

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
      then        => \&then, # optional
    );
  }

In an application:

  use GraphQL::Houtou::Async::Adapter::MyPromise;

  my $adapter = GraphQL::Houtou::Async::Adapter::MyPromise->adapter;
  my $runtime = $schema->build_native_runtime(async_adapter => $adapter);

=head1 DESCRIPTION

This module is the public registration boundary between the Houtou native VM
and promise implementations. Houtou only bundles its C<Promise::XS> fast path.
Adapters for other implementations should be released as independent
distributions.

Registration is process-global and idempotent by C<name>. Registering the same
name and class again returns the existing adapter code. Reusing a name for a
different class is an error.

=head1 ADAPTER CONTRACT

=over

=item name

A non-empty, NUL-free identifier unique to the adapter distribution.

=item class

The promise class returned by resolvers and adapter callbacks. Subclasses are
also recognized.

=item new_pending

A coderef taking no arguments and returning
C<[ $promise, $resolve, $reject ]>. The latter two values are coderefs that
settle C<$promise>.

=item all

A coderef receiving one array reference. It must accept plain values and
backend promises and return a backend promise that resolves to one array
reference in the original order.

=item then

An optional coderef called as
C<($promise, $on_done, $on_fail)>, where C<$on_fail> may be omitted. If it is
not supplied at registration time, C<< $promise->then >> is cached directly.

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
adapter can consist only of the two required factories:

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

  SV * new_pending_xs()
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

Registration and dispatch live in XS. The callbacks may themselves be XSUBs,
so an XS-backed implementation does not need a Perl callback body. The bundled
C<Promise::XS> backend still has a dedicated VM hot path and is the baseline
for adapter benchmarks.

=cut
