package GraphQL::Houtou::Runtime::VMCompiler;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Runtime::VMBlock ();
use GraphQL::Houtou::Runtime::VMOp ();
use GraphQL::Houtou::Runtime::VMProgram ();

sub lower_program {
  my ($class, $runtime_schema, $program) = @_;
  my @blocks = map { _lower_block($_) } @{ $program->blocks || [] };
  my %by_name = map { ($_->name => $_) } @blocks;
  my $root_block = $program->root_block ? $by_name{ $program->root_block->name } : undef;

  return GraphQL::Houtou::Runtime::VMProgram->new(
    version => 1,
    operation_type => $program->operation_type,
    operation_name => $program->operation_name,
    blocks => \@blocks,
    root_block => $root_block,
  );
}

sub inflate_program {
  my ($class, $runtime_schema, $struct) = @_;
  my @blocks = map { _inflate_block($_) } @{ $struct->{blocks} || [] };
  my %by_name = map { ($_->name => $_) } @blocks;
  my $root_block = defined $struct->{root_block} ? $by_name{ $struct->{root_block} } : undef;

  return GraphQL::Houtou::Runtime::VMProgram->new(
    version => $struct->{version} || 1,
    operation_type => $struct->{operation_type} || 'query',
    operation_name => $struct->{operation_name},
    blocks => \@blocks,
    root_block => $root_block,
  );
}

sub _lower_block {
  my ($block) = @_;
  return GraphQL::Houtou::Runtime::VMBlock->new(
    name => $block->name,
    type_name => $block->type_name,
    family => $block->family,
    ops => [ map { _lower_instruction($_) } @{ $block->instructions || [] } ],
  );
}

sub _inflate_block {
  my ($struct) = @_;
  return GraphQL::Houtou::Runtime::VMBlock->new(
    name => $struct->{name},
    type_name => $struct->{type_name},
    family => $struct->{family} || 'OBJECT',
    ops => [ map { _inflate_op($_) } @{ $struct->{ops} || [] } ],
  );
}

sub _lower_instruction {
  my ($instruction) = @_;
  return GraphQL::Houtou::Runtime::VMOp->new(
    opcode => join(
      q(:),
      ($instruction->resolve_op || 'RESOLVE_DEFAULT'),
      ($instruction->complete_op || 'COMPLETE_GENERIC'),
    ),
    field_name => $instruction->field_name,
    result_name => $instruction->result_name,
    dispatch_family => $instruction->dispatch_family,
    child_block_name => $instruction->child_block_name,
    abstract_child_blocks => $instruction->abstract_child_blocks,
    arg_defs => $instruction->arg_defs,
    args_mode => $instruction->args_mode,
    has_args => $instruction->has_args,
    directives_mode => $instruction->directives_mode,
    has_directives => $instruction->has_directives,
  );
}

sub _inflate_op {
  my ($struct) = @_;
  return GraphQL::Houtou::Runtime::VMOp->new(
    opcode => $struct->{opcode},
    field_name => $struct->{field_name},
    result_name => $struct->{result_name},
    dispatch_family => $struct->{dispatch_family},
    child_block_name => $struct->{child_block_name},
    abstract_child_blocks => $struct->{abstract_child_blocks} || {},
    arg_defs => $struct->{arg_defs} || {},
    args_mode => $struct->{args_mode} || 'NONE',
    has_args => $struct->{has_args},
    directives_mode => $struct->{directives_mode} || 'NONE',
    has_directives => $struct->{has_directives},
  );
}

1;
