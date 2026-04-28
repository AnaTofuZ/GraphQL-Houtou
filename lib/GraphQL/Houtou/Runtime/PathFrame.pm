package GraphQL::Houtou::Runtime::PathFrame;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();

sub new {
  my ($class, %args) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::path_frame_new_xs($class, $args{parent}, $args{key});
}

sub parent {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::path_frame_parent_xs($_[0]);
}

sub key {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::path_frame_key_xs($_[0]);
}

sub materialize_path {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::path_frame_materialize_path_xs($_[0]);
}

1;
