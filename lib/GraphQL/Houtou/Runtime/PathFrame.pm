package GraphQL::Houtou::Runtime::PathFrame;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();
use Scalar::Util qw(reftype);

sub new {
  my ($class, %args) = @_;
  if ($args{perl_only}) {
    return bless {
      parent => $args{parent},
      key => $args{key},
    }, $class;
  }
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::path_frame_new_xs($class, $args{parent}, $args{key});
}

sub parent {
  return $_[0]{parent} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::path_frame_parent_xs($_[0]);
}

sub key {
  return $_[0]{key} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::path_frame_key_xs($_[0]);
}

sub materialize_path {
  if (reftype($_[0]) && reftype($_[0]) eq 'HASH') {
    my @path;
    my $cursor = $_[0];
    while ($cursor) {
      unshift @path, $cursor->{key};
      $cursor = $cursor->{parent};
    }
    return \@path;
  }
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::path_frame_materialize_path_xs($_[0]);
}

1;
