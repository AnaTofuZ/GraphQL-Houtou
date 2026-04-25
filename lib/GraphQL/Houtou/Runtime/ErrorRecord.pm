package GraphQL::Houtou::Runtime::ErrorRecord;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    message => $args{message},
    path_frame => $args{path_frame},
  }, $class;
}

sub message { return $_[0]{message} }
sub path_frame { return $_[0]{path_frame} }

sub to_error {
  my ($self) = @_;
  my $error = {
    message => $self->{message},
  };

  if (my $path_frame = $self->{path_frame}) {
    my $path = $path_frame->materialize_path;
    $error->{path} = $path if @$path;
  }

  return $error;
}

1;
