package GraphQL::Houtou::Runtime::VMOp;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    opcode => $args{opcode},
    opcode_code => $args{opcode_code} || 0,
    resolve_family => $args{resolve_family},
    resolve_code => $args{resolve_code} || 0,
    complete_family => $args{complete_family},
    complete_code => $args{complete_code} || 0,
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
    bound_slot => $args{bound_slot},
    bound_child_block => $args{bound_child_block},
    bound_abstract_child_blocks => $args{bound_abstract_child_blocks} || {},
    abstract_dispatch => $args{abstract_dispatch},
    resolve_handler => $args{resolve_handler},
    complete_handler => $args{complete_handler},
    resolve_dispatch => $args{resolve_dispatch},
    complete_dispatch => $args{complete_dispatch},
    run_dispatch => $args{run_dispatch},
  }, $class;
}

sub opcode { return $_[0]{opcode} }
sub opcode_code { return $_[0]{opcode_code} }
sub resolve_family { return $_[0]{resolve_family} }
sub resolve_code { return $_[0]{resolve_code} }
sub complete_family { return $_[0]{complete_family} }
sub complete_code { return $_[0]{complete_code} }
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
sub bound_slot { return $_[0]{bound_slot} }
sub bound_child_block { return $_[0]{bound_child_block} }
sub bound_abstract_child_blocks { return $_[0]{bound_abstract_child_blocks} }
sub abstract_dispatch { return $_[0]{abstract_dispatch} }
sub resolve_handler { return $_[0]{resolve_handler} }
sub complete_handler { return $_[0]{complete_handler} }
sub resolve_dispatch { return $_[0]{resolve_dispatch} }
sub complete_dispatch { return $_[0]{complete_dispatch} }
sub run_dispatch { return $_[0]{run_dispatch} }

sub to_struct {
  my ($self) = @_;
  return {
    opcode => $self->{opcode},
    opcode_code => $self->{opcode_code},
    resolve_family => $self->{resolve_family},
    resolve_code => $self->{resolve_code},
    complete_family => $self->{complete_family},
    complete_code => $self->{complete_code},
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
