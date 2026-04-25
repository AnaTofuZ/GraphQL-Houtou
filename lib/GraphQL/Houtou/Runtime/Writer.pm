package GraphQL::Houtou::Runtime::Writer;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    values => $args{values} || {},
    errors => $args{errors} || [],
    pending => $args{pending} || [],
  }, $class;
}

sub values { return $_[0]{values} }
sub errors { return $_[0]{errors} }
sub pending { return $_[0]{pending} }

1;
