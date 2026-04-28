package GraphQL::Houtou::Runtime::FieldFrame;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();
use Scalar::Util qw(reftype);

sub new {
  my ($class, %args) = @_;
  if ($args{perl_only}) {
    return bless {
      source => $args{source},
      path_frame => $args{path_frame},
      resolved_value => $args{resolved_value},
      outcome => $args{outcome},
    }, $class;
  }
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
  return $_[0]{source} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::field_frame_source_xs($_[0]);
}

sub path_frame {
  return $_[0]{path_frame} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::field_frame_path_frame_xs($_[0]);
}

sub resolved_value {
  return $_[0]{resolved_value} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::field_frame_resolved_value_xs($_[0]);
}

sub outcome {
  return $_[0]{outcome} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::field_frame_outcome_xs($_[0]);
}

sub set_resolved_value {
  if (reftype($_[0]) && reftype($_[0]) eq 'HASH') {
    $_[0]{resolved_value} = $_[1];
    return $_[1];
  }
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::field_frame_set_resolved_value_xs($_[0], $_[1]);
  return $_[1];
}

sub set_outcome {
  if (reftype($_[0]) && reftype($_[0]) eq 'HASH') {
    $_[0]{outcome} = $_[1];
    return $_[1];
  }
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::field_frame_set_outcome_xs($_[0], $_[1]);
  return $_[1];
}

1;
