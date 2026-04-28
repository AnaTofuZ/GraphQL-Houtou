package GraphQL::Houtou::Runtime::BlockFrame;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();
use GraphQL::Houtou::Promise::Adapter qw(all_promise then_promise);
use Scalar::Util qw(reftype);

sub new {
  my ($class, %args) = @_;
  if ($args{perl_only}) {
    return bless {
      values => ($args{values} || {}),
      pending_names => ($args{pending_names} || []),
      pending_outcomes => ($args{pending_outcomes} || []),
    }, $class;
  }
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_new_xs(
    $class,
    ($args{values} || {}),
    ($args{pending_names} || []),
    ($args{pending_outcomes} || []),
  );
}

sub values {
  return $_[0]{values} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_values_xs($_[0]);
}

sub pending_names {
  return $_[0]{pending_names} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_pending_names_xs($_[0]);
}

sub pending_outcomes {
  return $_[0]{pending_outcomes} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_pending_outcomes_xs($_[0]);
}

sub has_pending {
  return scalar @{ $_[0]{pending_outcomes} || [] } if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_has_pending_xs($_[0]);
}

sub consume_outcome {
  if (reftype($_[0]) && reftype($_[0]) eq 'HASH') {
    $_[1]->consume_outcome($_[0]{values}, $_[2], $_[3]);
    return;
  }
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::block_frame_consume_outcome_xs($_[0], $_[1], $_[2], $_[3]);
  return;
}

sub add_pending {
  if (reftype($_[0]) && reftype($_[0]) eq 'HASH') {
    push @{ $_[0]{pending_names} }, $_[1];
    push @{ $_[0]{pending_outcomes} }, $_[2];
    return $_[2];
  }
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::block_frame_add_pending_xs($_[0], $_[1], $_[2]);
}

sub merge_resolved_pending {
  my ($self, $writer, $resolved) = @_;
  if (!(reftype($self) && reftype($self) eq 'HASH')) {
    GraphQL::Houtou::_bootstrap_xs();
    return GraphQL::Houtou::XS::VM::block_frame_merge_pending_xs($self, $writer, $resolved);
  }
  my $merged = $self->values;
  my $names = $self->pending_names;
  my @resolved = ref($resolved) eq 'ARRAY' ? @$resolved : ($resolved);

  for my $i (0 .. $#resolved) {
    next if !defined $names->[$i];
    next if !defined $resolved[$i];
    $writer->consume_outcome($merged, $names->[$i], $resolved[$i]);
  }

  return $merged;
}

sub _xs_finalize_callback {
  my ($merge) = @_;
  return sub {
    my @resolved = @_ == 1 && ref($_[0]) eq 'ARRAY' ? @{ $_[0] } : @_;
    return GraphQL::Houtou::XS::VM::block_frame_merge_pending_state_xs($merge, \@resolved);
  };
}

sub finalize {
  my ($self, $promise_code, $writer) = @_;
  if (!(reftype($self) && reftype($self) eq 'HASH')) {
    GraphQL::Houtou::_bootstrap_xs();
    return GraphQL::Houtou::XS::VM::block_frame_finalize_xs($self, $promise_code, $writer);
  }
  my $pending = $self->pending_outcomes;
  return $self->values if !@$pending;

  my $aggregate = all_promise($promise_code, @$pending);
  return then_promise($promise_code, $aggregate, sub {
    my @resolved = @_ == 1 && ref($_[0]) eq 'ARRAY' ? @{ $_[0] } : @_;
    return $self->merge_resolved_pending($writer, \@resolved);
  });
}

1;
