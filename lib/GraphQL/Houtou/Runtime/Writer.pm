package GraphQL::Houtou::Runtime::Writer;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();
use Scalar::Util qw(reftype);

sub new {
  my ($class, %args) = @_;
  if ($args{perl_only}) {
    return bless {
      error_records => [],
    }, $class;
  }
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::writer_new_xs($class);
}

sub error_records {
  return $_[0]{error_records} if reftype($_[0]) && reftype($_[0]) eq 'HASH';
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::writer_error_records_xs($_[0]);
}

sub consume_outcome {
  my ($self, $data, $result_name, $outcome) = @_;
  return if !$outcome;
  if (reftype($self) && reftype($self) eq 'HASH') {
    $data->{$result_name} = $outcome->value;
    push @{ $self->{error_records} }, @{ $outcome->error_records || [] };
    return;
  }
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::consume_outcome_xs(
    $self,
    $data,
    $result_name,
    $outcome,
  );
  return;
}

sub materialize_errors {
  if (reftype($_[0]) && reftype($_[0]) eq 'HASH') {
    return [
      map {
        +{
          message => $_->message,
          (($_->path_frame && @{ $_->path_frame->materialize_path || [] })
            ? (path => $_->path_frame->materialize_path)
            : ()),
        }
      } @{ $_[0]{error_records} || [] }
    ];
  }
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::writer_materialize_errors_xs($_[0]);
}

1;
