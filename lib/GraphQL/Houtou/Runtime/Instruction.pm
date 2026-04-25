package GraphQL::Houtou::Runtime::Instruction;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    field_name => $args{field_name},
    result_name => $args{result_name},
    return_type_name => $args{return_type_name},
    resolve_op => $args{resolve_op},
    complete_op => $args{complete_op},
    dispatch_family => $args{dispatch_family},
    has_args => $args{has_args} ? 1 : 0,
    has_directives => $args{has_directives} ? 1 : 0,
    child_block_name => $args{child_block_name},
  }, $class;
}

sub field_name { return $_[0]{field_name} }
sub result_name { return $_[0]{result_name} }
sub return_type_name { return $_[0]{return_type_name} }
sub resolve_op { return $_[0]{resolve_op} }
sub complete_op { return $_[0]{complete_op} }
sub dispatch_family { return $_[0]{dispatch_family} }
sub has_args { return $_[0]{has_args} }
sub has_directives { return $_[0]{has_directives} }
sub child_block_name { return $_[0]{child_block_name} }

sub to_struct {
  my ($self) = @_;
  return {
    field_name => $self->{field_name},
    result_name => $self->{result_name},
    return_type_name => $self->{return_type_name},
    resolve_op => $self->{resolve_op},
    complete_op => $self->{complete_op},
    dispatch_family => $self->{dispatch_family},
    has_args => $self->{has_args},
    has_directives => $self->{has_directives},
    child_block_name => $self->{child_block_name},
  };
}

1;
