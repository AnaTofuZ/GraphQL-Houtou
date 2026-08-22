package GraphQL::Houtou::Async::Adapter::Future;

use 5.024;
use strict;
use warnings;

use parent 'GraphQL::Houtou::Async::Adapter';
use Scalar::Util qw(blessed);

my $ADAPTER;

sub adapter {
  return $ADAPTER if $ADAPTER;
  require Future;
  Future->VERSION(0.45);
  return $ADAPTER = __PACKAGE__->register(
    name => 'future',
    class => 'Future',
    then => sub {
      my ($future, $done, $fail) = @_;
      my $next = defined($fail)
        ? $future->then($done, $fail)
        : $future->then($done);
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
      my ($values) = @_;
      my @futures = map {
        blessed($_) && $_->isa('Future') ? $_ : Future->done($_)
      } @$values;
      return Future->needs_all(@futures)->then(sub { [@_] });
    },
  );
}

1;

__END__

=head1 NAME

GraphQL::Houtou::Async::Adapter::Future - Future backend for GraphQL::Houtou

=head1 SYNOPSIS

  my $runtime = $schema->build_native_runtime(async_adapter => 'Future');

=head1 DESCRIPTION

This optional adapter requires L<Future> 0.45 or newer. Promise::XS remains
the default backend and retains its dedicated XS hot path.

=cut
