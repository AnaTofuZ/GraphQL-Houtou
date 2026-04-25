package GraphQL::Houtou::Runtime::Writer;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    values => $args{values} || {},
    error_records => $args{error_records} || [],
    pending => $args{pending} || [],
  }, $class;
}

sub values { return $_[0]{values} }
sub error_records { return $_[0]{error_records} }
sub pending { return $_[0]{pending} }

sub materialize_errors {
  my ($self) = @_;
  return [ map { $_->to_error } @{ $self->{error_records} || [] } ];
}

1;
