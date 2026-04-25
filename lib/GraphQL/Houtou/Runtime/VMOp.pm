package GraphQL::Houtou::Runtime::VMOp;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    opcode => $args{opcode},
    field_name => $args{field_name},
    result_name => $args{result_name},
    dispatch_family => $args{dispatch_family},
    child_block_name => $args{child_block_name},
    abstract_child_blocks => $args{abstract_child_blocks} || {},
    arg_defs => $args{arg_defs} || {},
    args_mode => $args{args_mode} || 'NONE',
    has_args => $args{has_args} ? 1 : 0,
    directives_mode => $args{directives_mode} || 'NONE',
    has_directives => $args{has_directives} ? 1 : 0,
  }, $class;
}

sub opcode { return $_[0]{opcode} }
sub field_name { return $_[0]{field_name} }
sub result_name { return $_[0]{result_name} }
sub dispatch_family { return $_[0]{dispatch_family} }
sub child_block_name { return $_[0]{child_block_name} }
sub abstract_child_blocks { return $_[0]{abstract_child_blocks} }
sub arg_defs { return $_[0]{arg_defs} }
sub args_mode { return $_[0]{args_mode} }
sub has_args { return $_[0]{has_args} }
sub directives_mode { return $_[0]{directives_mode} }
sub has_directives { return $_[0]{has_directives} }

sub to_struct {
  my ($self) = @_;
  return {
    opcode => $self->{opcode},
    field_name => $self->{field_name},
    result_name => $self->{result_name},
    dispatch_family => $self->{dispatch_family},
    child_block_name => $self->{child_block_name},
    abstract_child_blocks => { %{ $self->{abstract_child_blocks} || {} } },
    arg_defs => { %{ $self->{arg_defs} || {} } },
    args_mode => $self->{args_mode},
    has_args => $self->{has_args},
    directives_mode => $self->{directives_mode},
    has_directives => $self->{has_directives},
  };
}

1;
