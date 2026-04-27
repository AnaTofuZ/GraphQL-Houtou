package GraphQL::Houtou::Runtime::VMProgram;

use 5.014;
use strict;
use warnings;

use constant {
  VERSION_SLOT        => 0,
  OPERATION_TYPE_SLOT => 1,
  OPERATION_NAME_SLOT => 2,
  VARIABLE_DEFS_SLOT  => 3,
  BLOCKS_SLOT         => 4,
  ROOT_BLOCK_SLOT     => 5,
  BLOCK_MAP_SLOT      => 6,
  DISPATCH_BOUND_SLOT => 7,
};

sub new {
  my ($class, %args) = @_;
  my $root_block = $args{root_block};
  my @blocks = @{ $args{blocks} || [] };
  my %block_map = map { defined $_->name ? ($_->name => $_) : () } @blocks;
  $block_map{ $root_block->name } = $root_block if $root_block && defined $root_block->name;
  return bless [
    $args{version} || 1,
    $args{operation_type} || 'query',
    $args{operation_name},
    $args{variable_defs} || {},
    \@blocks,
    $root_block,
    \%block_map,
    0,
  ], $class;
}

sub version { return $_[0][VERSION_SLOT] }
sub operation_type { return $_[0][OPERATION_TYPE_SLOT] }
sub operation_name { return $_[0][OPERATION_NAME_SLOT] }
sub variable_defs { return $_[0][VARIABLE_DEFS_SLOT] }
sub blocks { return $_[0][BLOCKS_SLOT] }
sub root_block { return $_[0][ROOT_BLOCK_SLOT] }
sub dispatch_bound { return $_[0][DISPATCH_BOUND_SLOT] }
sub set_variable_defs { $_[0][VARIABLE_DEFS_SLOT] = $_[1] || {}; return $_[0][VARIABLE_DEFS_SLOT] }
sub set_dispatch_bound { $_[0][DISPATCH_BOUND_SLOT] = $_[1] ? 1 : 0; return $_[0][DISPATCH_BOUND_SLOT] }

sub block_by_name {
  my ($self, $name) = @_;
  return if !defined $name;
  return $self->[BLOCK_MAP_SLOT]{$name};
}

sub to_struct {
  my ($self) = @_;
  return {
    version => $self->version,
    operation_type => $self->operation_type,
    operation_name => $self->operation_name,
    variable_defs => { %{ $self->variable_defs || {} } },
    root_block => $self->root_block ? $self->root_block->name : undef,
    blocks => [ map { $_->to_struct } @{ $self->blocks || [] } ],
  };
}

sub to_native_struct {
  my ($self) = @_;
  my @blocks = @{ $self->blocks || [] };
  my %block_index = map { ($blocks[$_]->name => $_) } 0 .. $#blocks;
  return {
    version => $self->version,
    operation_type => $self->operation_type,
    operation_type_code => _operation_type_code($self->operation_type),
    operation_name => $self->operation_name,
    variable_defs => { %{ $self->variable_defs || {} } },
    root_block_index => $self->root_block ? $block_index{ $self->root_block->name } : undef,
    blocks => [ map { $_->to_native_struct(\%block_index) } @blocks ],
  };
}

sub to_native_compact_struct {
  my ($self) = @_;
  my @blocks = @{ $self->blocks || [] };
  my %block_index = map { ($blocks[$_]->name => $_) } 0 .. $#blocks;
  return {
    version => $self->version,
    operation_type_code => _operation_type_code($self->operation_type),
    operation_name => $self->operation_name,
    variable_defs => { %{ $self->variable_defs || {} } },
    root_block_index => $self->root_block ? $block_index{ $self->root_block->name } : undef,
    blocks_compact => [ map { $_->to_native_compact_struct(\%block_index) } @blocks ],
  };
}

sub _operation_type_code {
  my ($type) = @_;
  return 2 if ($type || q()) eq 'mutation';
  return 3 if ($type || q()) eq 'subscription';
  return 1;
}

1;
