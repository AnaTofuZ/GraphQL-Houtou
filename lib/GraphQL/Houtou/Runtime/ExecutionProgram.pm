package GraphQL::Houtou::Runtime::ExecutionProgram;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    version => $args{version} || 1,
    operation_type => $args{operation_type} || 'query',
    operation_name => $args{operation_name},
    variable_defs => $args{variable_defs} || {},
    blocks => $args{blocks} || [],
    root_block => $args{root_block},
  }, $class;
}

sub version { return $_[0]{version} }
sub operation_type { return $_[0]{operation_type} }
sub operation_name { return $_[0]{operation_name} }
sub variable_defs { return $_[0]{variable_defs} }
sub blocks { return $_[0]{blocks} }
sub root_block { return $_[0]{root_block} }

sub block_by_name {
  my ($self, $name) = @_;
  return if !defined $name;
  return $self->{root_block} if $self->{root_block} && $self->{root_block}->name eq $name;
  for my $block (@{ $self->{blocks} || [] }) {
    return $block if $block->name eq $name;
  }
  return;
}

sub to_struct {
  my ($self) = @_;
  return {
    version => $self->{version},
    operation_type => $self->{operation_type},
    operation_name => $self->{operation_name},
    variable_defs => { %{ $self->{variable_defs} || {} } },
    root_block => $self->{root_block} ? $self->{root_block}->name : undef,
    blocks => [ map { $_->to_struct } @{ $self->{blocks} || [] } ],
  };
}

1;
