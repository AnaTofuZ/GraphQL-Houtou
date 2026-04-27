package GraphQL::Houtou::Promise::Adapter;

use 5.014;
use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
  set_default_promise_code
  get_default_promise_code
  clear_default_promise_code
  normalize_promise_code
  all_promise
  merge_hash_result
  resolve_promise
  reject_promise
  is_promise_value
  then_promise
);

my $DEFAULT_PROMISE_CODE;

sub set_default_promise_code {
  my ($promise_code) = @_;
  $DEFAULT_PROMISE_CODE = _normalize_promise_code($promise_code);
  return $DEFAULT_PROMISE_CODE;
}

sub get_default_promise_code {
  return $DEFAULT_PROMISE_CODE;
}

sub clear_default_promise_code {
  undef $DEFAULT_PROMISE_CODE;
  return;
}

sub normalize_promise_code {
  my ($promise_code) = @_;
  return _normalize_promise_code($promise_code || $DEFAULT_PROMISE_CODE);
}

sub _normalize_promise_code {
  my ($promise_code) = @_;
  return undef if !$promise_code;
  return $promise_code
    if ref($promise_code) eq 'HASH' && $promise_code->{_houtou_promise_adapter};
  die "promise_code must be a hash reference\n" if ref($promise_code) ne 'HASH';

  my $adapter = {
    %$promise_code,
    _houtou_promise_adapter => 1,
  };

  $adapter->{is_promise} ||= sub {
    my ($value) = @_;
    return !!($value && ref($value) && eval { $value->can('then') });
  };

  $adapter->{then} ||= sub {
    my ($promise, $on_fulfilled, $on_rejected) = @_;
    return defined $on_rejected
      ? $promise->then($on_fulfilled, $on_rejected)
      : $promise->then($on_fulfilled);
  };

  return $adapter;
}

sub all_promise {
  my ($promise_code, @values) = @_;
  die "all_promise requires promise_code\n"
    if !$promise_code || ref($promise_code) ne 'HASH' || !$promise_code->{all};

  return $promise_code->{all}->(@values);
}

sub merge_hash_result {
  my ($keys, $values, $errors) = @_;

  my @all_errors = (@$errors, map @{ $_->{errors} || [] }, @$values);
  my %name2data;

  for (my $i = @$values - 1; $i >= 0; $i--) {
    $name2data{$keys->[$i]} = $values->[$i]{data};
  }

  return {
    %name2data ? (data => \%name2data) : (),
    @all_errors ? (errors => \@all_errors) : (),
  };
}

sub resolve_promise {
  my ($promise_code, $value) = @_;
  die "resolve_promise requires promise_code\n"
    if !$promise_code || ref($promise_code) ne 'HASH' || !$promise_code->{resolve};

  return $promise_code->{resolve}->($value);
}

sub reject_promise {
  my ($promise_code, $value) = @_;
  die "reject_promise requires promise_code\n"
    if !$promise_code || ref($promise_code) ne 'HASH' || !$promise_code->{reject};

  return $promise_code->{reject}->($value);
}

sub is_promise_value {
  my ($promise_code, $value) = @_;
  return 0 if !$value || !ref($value);
  return !!$promise_code->{is_promise}->($value)
    if $promise_code && ref($promise_code) eq 'HASH' && $promise_code->{is_promise};
  return !!eval { $value->can('then') };
}

sub then_promise {
  my ($promise_code, $promise, $on_fulfilled, $on_rejected) = @_;
  die "then_promise requires a promise value\n" if !$promise || !ref($promise);

  if ($promise_code && ref($promise_code) eq 'HASH' && $promise_code->{then}) {
    return $promise_code->{then}->($promise, $on_fulfilled, $on_rejected);
  }

  return defined $on_rejected
    ? $promise->then($on_fulfilled, $on_rejected)
    : $promise->then($on_fulfilled);
}

1;

__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou::Promise::Adapter - PromiseCode normalization helpers

=head1 SYNOPSIS

    use GraphQL::Houtou::Promise::Adapter qw(normalize_promise_code);

    my $promise_code = normalize_promise_code({
      resolve => sub { ... },
      reject => sub { ... },
      all => sub { ... },
      then => sub { my ($promise, $ok, $ng) = @_; ... }, # optional
      is_promise => sub { my ($value) = @_; ... },        # optional
    });

=head1 DESCRIPTION

This module keeps the upstream C<promise_code> style API and adds two
optional hooks, C<then> and C<is_promise>, so callers can adapt promise
libraries with differing dispatch conventions without Houtou hardcoding
library-specific adapters.

The C<all> hook is expected to resolve to the collected fulfilled values.
Houtou accepts either a single array reference of resolved values or a
multi-value fulfillment. For GraphQL execution, each collected element is
expected to represent one field/list item result; wrapper implementations
should avoid adding extra container layers unless they intentionally model
multi-value fulfillment.

=cut
