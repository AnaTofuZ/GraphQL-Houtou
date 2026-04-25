package GraphQL::Houtou::Runtime::ExecState;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    runtime_schema => $args{runtime_schema},
    program => $args{program},
    cursor => $args{cursor},
    frame => $args{frame},
    writer => $args{writer},
    context => $args{context},
    variables => $args{variables} || {},
    root_value => $args{root_value},
    promise_code => $args{promise_code},
  }, $class;
}

sub runtime_schema { return $_[0]{runtime_schema} }
sub program { return $_[0]{program} }
sub cursor { return $_[0]{cursor} }
sub frame { return $_[0]{frame} }
sub writer { return $_[0]{writer} }
sub context { return $_[0]{context} }
sub variables { return $_[0]{variables} }
sub root_value { return $_[0]{root_value} }
sub promise_code { return $_[0]{promise_code} }

1;
