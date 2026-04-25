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

sub _lower_block {
  my ($block) = @_;
  return GraphQL::Houtou::Runtime::VMBlock->new(
    name => $block->name,
    type_name => $block->type_name,
    family => $block->family,
    ops => [ map { _lower_instruction($_) } @{ $block->instructions || [] } ],
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

1;
