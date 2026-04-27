package GraphQL::Houtou::Runtime::FieldFrame;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();

sub new {
  my ($class, %args) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::field_frame_new_xs(
    $class,
    $args{source},
    $args{path_frame},
    $args{resolved_value},
    $args{outcome},
  );
}

sub source {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::field_frame_source_xs($_[0]);
}

sub path_frame {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::field_frame_path_frame_xs($_[0]);
}

sub resolved_value {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::field_frame_resolved_value_xs($_[0]);
}

sub outcome {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::field_frame_outcome_xs($_[0]);
}

sub set_resolved_value {
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::field_frame_set_resolved_value_xs($_[0], $_[1]);
  return $_[1];
}

sub set_outcome {
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::field_frame_set_outcome_xs($_[0], $_[1]);
  return $_[1];
}

1;
