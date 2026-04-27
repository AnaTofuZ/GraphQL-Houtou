package GraphQL::Houtou::Runtime::NativeBundle;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  die "runtime is required\n" if !$args{runtime};
  die "descriptor is required\n" if !$args{descriptor};
  die "native_bundle_handle is required\n" if !$args{native_bundle_handle};
  return bless {
    runtime => $args{runtime},
    program => $args{program},
    descriptor => $args{descriptor},
    native_bundle_handle => $args{native_bundle_handle},
  }, $class;
}

sub runtime { return $_[0]{runtime} }
sub program { return $_[0]{program} }
sub descriptor { return $_[0]{descriptor} }
sub native_bundle_handle { return $_[0]{native_bundle_handle} }

sub execute {
  my ($self, %opts) = @_;
  return $self->runtime->execute_bundle($self, %opts);
}

1;
