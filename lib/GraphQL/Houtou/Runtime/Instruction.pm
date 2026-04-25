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
    arg_defs => $args{arg_defs} || {},
    has_args => $args{has_args} ? 1 : 0,
    args_mode => $args{args_mode} || 'NONE',
    args_payload => $args{args_payload},
    has_directives => $args{has_directives} ? 1 : 0,
    directives_mode => $args{directives_mode} || 'NONE',
    directives_payload => $args{directives_payload},
    child_block_name => $args{child_block_name},
    abstract_child_blocks => $args{abstract_child_blocks} || {},
    bound_slot => $args{bound_slot},
  }, $class;
}

sub field_name { return $_[0]{field_name} }
sub result_name { return $_[0]{result_name} }
sub return_type_name { return $_[0]{return_type_name} }
sub resolve_op { return $_[0]{resolve_op} }
sub complete_op { return $_[0]{complete_op} }
sub dispatch_family { return $_[0]{dispatch_family} }
sub arg_defs { return $_[0]{arg_defs} }
sub has_args { return $_[0]{has_args} }
sub args_mode { return $_[0]{args_mode} }
sub args_payload { return $_[0]{args_payload} }
sub has_directives { return $_[0]{has_directives} }
sub directives_mode { return $_[0]{directives_mode} }
sub directives_payload { return $_[0]{directives_payload} }
sub child_block_name { return $_[0]{child_block_name} }
sub abstract_child_blocks { return $_[0]{abstract_child_blocks} }
sub bound_slot { return $_[0]{bound_slot} }

sub to_struct {
  my ($self) = @_;
  return {
    field_name => $self->{field_name},
    result_name => $self->{result_name},
    return_type_name => $self->{return_type_name},
    resolve_op => $self->{resolve_op},
    complete_op => $self->{complete_op},
    dispatch_family => $self->{dispatch_family},
    arg_defs => _clone_value($self->{arg_defs}),
    has_args => $self->{has_args},
    args_mode => $self->{args_mode},
    args_payload => _clone_value($self->{args_payload}),
    has_directives => $self->{has_directives},
    directives_mode => $self->{directives_mode},
    directives_payload => _clone_value($self->{directives_payload}),
    child_block_name => $self->{child_block_name},
    abstract_child_blocks => { %{ $self->{abstract_child_blocks} || {} } },
  };
}

sub _clone_value {
  my ($value) = @_;
  my $ref = ref($value);
  return $value if !$ref;
  return [ map { _clone_value($_) } @$value ] if $ref eq 'ARRAY';
  return { map { $_ => _clone_value($value->{$_}) } keys %$value } if $ref eq 'HASH';
  return $value;
}

1;
