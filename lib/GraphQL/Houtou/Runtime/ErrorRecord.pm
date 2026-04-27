package GraphQL::Houtou::Runtime::ErrorRecord;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();

sub new {
  my ($class, %args) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::error_record_new_xs(
    $class,
    $args{message},
    $args{path_frame},
  );
}

sub message {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::error_record_message_xs($_[0]);
}

sub path_frame {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::error_record_path_frame_xs($_[0]);
}

sub to_error {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::error_record_to_error_xs($_[0]);
}

1;
