package GraphQL::Houtou::Runtime::Outcome;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    kind => $args{kind} || 'NONE',
    value => $args{value},
    errors => $args{errors} || [],
    completed => $args{completed},
  }, $class;
}

sub kind { return $_[0]{kind} }
sub value { return $_[0]{value} }
sub errors { return $_[0]{errors} }
sub completed { return $_[0]{completed} }

1;
