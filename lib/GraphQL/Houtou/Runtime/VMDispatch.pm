package GraphQL::Houtou::Runtime::VMDispatch;

use 5.014;
use strict;
use warnings;

sub bind_program {
  my ($class, $program) = @_;
  return if !$program || $program->{dispatch_bound};

  for my $block ($program->root_block, @{ $program->blocks || [] }) {
    next if !$block;
    for my $op (@{ $block->ops || [] }) {
      $op->{resolve_dispatch} ||= _resolve_dispatch_for($op);
      $op->{complete_dispatch} ||= _complete_dispatch_for($op);
    }
  }

  $program->{dispatch_bound} = 1;
  return $program;
}

sub _resolve_dispatch_for {
  my ($op) = @_;
  return ($op->resolve_handler || '') eq 'resolve_explicit'
    ? \&GraphQL::Houtou::Runtime::VMExecutor::_resolve_explicit
    : \&GraphQL::Houtou::Runtime::VMExecutor::_resolve_default;
}

sub _complete_dispatch_for {
  my ($op) = @_;
  return ($op->complete_handler || '') eq 'complete_object'
    ? \&GraphQL::Houtou::Runtime::VMExecutor::_complete_object
    : ($op->complete_handler || '') eq 'complete_list'
      ? \&GraphQL::Houtou::Runtime::VMExecutor::_complete_list
      : ($op->complete_handler || '') eq 'complete_abstract'
        ? \&GraphQL::Houtou::Runtime::VMExecutor::_complete_abstract
        : \&GraphQL::Houtou::Runtime::VMExecutor::_complete_generic;
}

1;
