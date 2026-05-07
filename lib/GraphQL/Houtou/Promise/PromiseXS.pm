package GraphQL::Houtou::Promise::PromiseXS;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use GraphQL::Houtou::Promise::Adapter qw(normalize_promise_code);

our @EXPORT_OK = qw(
  is_promise_xs_value
  maybe_get_promise_xs
  promise_xs_code
);

my $PROMISE_XS_CODE;

sub _load_promise_xs {
  require Promise::XS;
  return 1;
}

sub is_promise_xs_value {
  my ($value) = @_;
  return !!($value && ref($value) && eval { $value->isa('Promise::XS::Promise') });
}

sub promise_xs_code {
  _load_promise_xs();
  return $PROMISE_XS_CODE ||= normalize_promise_code({
    _houtou_promise_backend => 'promise_xs',
    resolve => sub { Promise::XS::resolved(@_) },
    reject  => sub { Promise::XS::rejected(@_) },
    all     => \&_all_promise_xs,
    then    => \&_then_promise_xs,
    is_promise => \&is_promise_xs_value,
  });
}

sub _all_promise_xs {
  my @values = @_;
  my $all_promise = Promise::XS::all(@values);
  return $all_promise->then(sub {
    my @rows = @_;
    my @flattened = map {
      ref($_) eq 'ARRAY' && @{$_} == 1 ? $_->[0] : $_
    } @rows;
    return \@flattened;
  });
}

sub _then_promise_xs {
  my ($promise, $on_fulfilled, $on_rejected) = @_;
  my $called = 0;
  my @sync_ret;

  my $wrapped_fulfilled = sub {
    $called = 1;
    @sync_ret = $on_fulfilled ? $on_fulfilled->(@_) : @_;
    return @sync_ret;
  };

  my $wrapped_rejected = sub {
    $called = 1;
    @sync_ret = $on_rejected ? $on_rejected->(@_) : @_;
    return @sync_ret;
  };

  my $next = defined $on_rejected
    ? $promise->then($wrapped_fulfilled, $wrapped_rejected)
    : $promise->then($wrapped_fulfilled);

  return $sync_ret[0] if $called && @sync_ret == 1;
  return $next;
}

sub maybe_get_promise_xs {
  my ($value) = @_;
  return $value if !is_promise_xs_value($value);

  my $done = 0;
  my @fulfilled;
  my @rejected;

  $value->then(
    sub {
      $done = 1;
      @fulfilled = @_;
      return;
    },
    sub {
      $done = 1;
      @rejected = @_;
      return;
    },
  );

  die "Promise::XS promise did not resolve synchronously\n" if !$done;
  die @rejected if @rejected;
  return wantarray ? @fulfilled : $fulfilled[0];
}

1;
