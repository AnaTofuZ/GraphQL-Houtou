package GraphQL::Houtou::Runtime::Writer;

use 5.014;
use strict;
use warnings;

use constant {
  VALUES_SLOT => 0,
  ERROR_RECORDS_SLOT => 1,
  PENDING_SLOT => 2,
};

sub new {
  my ($class, %args) = @_;
  return bless [
    $args{values} || {},
    $args{error_records} || [],
    $args{pending} || [],
  ], $class;
}

sub values { return $_[0][VALUES_SLOT] }
sub error_records { return $_[0][ERROR_RECORDS_SLOT] }
sub pending { return $_[0][PENDING_SLOT] }

sub consume_outcome {
  my ($self, $data, $result_name, $outcome) = @_;
  return if !$outcome;
  my $kind = $outcome->kind || '';
  if ($kind eq 'SCALAR') {
    $data->{$result_name} = $outcome->scalar_value;
  }
  elsif ($kind eq 'OBJECT') {
    $data->{$result_name} = $outcome->object_value;
  }
  elsif ($kind eq 'LIST') {
    $data->{$result_name} = $outcome->list_value;
  }
  else {
    $data->{$result_name} = undef;
  }
  push @{ $self->[ERROR_RECORDS_SLOT] }, @{ $outcome->error_records || [] }
    if @{ $outcome->error_records || [] };
  return;
}

sub materialize_errors {
  my ($self) = @_;
  return [ map { $_->to_error } @{ $self->[ERROR_RECORDS_SLOT] || [] } ];
}

1;
