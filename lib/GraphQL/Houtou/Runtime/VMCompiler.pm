package GraphQL::Houtou::Runtime::VMCompiler;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Runtime::OperationCompiler ();
use GraphQL::Houtou::Runtime::VMBlock ();
use GraphQL::Houtou::Runtime::VMDispatch ();
use GraphQL::Houtou::Runtime::VMOp ();
use GraphQL::Houtou::Runtime::VMProgram ();

my %RESOLVE_HANDLER = (
  RESOLVE_DEFAULT => 'resolve_default',
  RESOLVE_EXPLICIT => 'resolve_explicit',
);

my %RESOLVE_CODE = (
  RESOLVE_DEFAULT => 1,
  RESOLVE_EXPLICIT => 2,
);

my %COMPLETE_HANDLER = (
  COMPLETE_GENERIC => 'complete_generic',
  COMPLETE_OBJECT => 'complete_object',
  COMPLETE_LIST => 'complete_list',
  COMPLETE_ABSTRACT => 'complete_abstract',
);

my %COMPLETE_CODE = (
  COMPLETE_GENERIC => 1,
  COMPLETE_OBJECT => 2,
  COMPLETE_LIST => 3,
  COMPLETE_ABSTRACT => 4,
);

sub lower_program {
  my ($class, $runtime_schema, $program) = @_;
  my @blocks = map { _lower_block($_) } @{ $program->blocks || [] };
  my %by_name = map { ($_->name => $_) } @blocks;
  my $root_block = $program->root_block ? $by_name{ $program->root_block->name } : undef;
  my $vm_program = GraphQL::Houtou::Runtime::VMProgram->new(
    version => 1,
    operation_type => $program->operation_type,
    operation_name => $program->operation_name,
    blocks => \@blocks,
    root_block => $root_block,
  );
  _bind_vm_ops($runtime_schema, $vm_program);
  GraphQL::Houtou::Runtime::VMDispatch->bind_program($vm_program);
  return $vm_program;
}

sub inflate_program {
  my ($class, $runtime_schema, $struct) = @_;
  my @blocks = map { _inflate_block($_) } @{ $struct->{blocks} || [] };
  my %by_name = map { ($_->name => $_) } @blocks;
  my $root_block = defined $struct->{root_block} ? $by_name{ $struct->{root_block} } : undef;
  my $vm_program = GraphQL::Houtou::Runtime::VMProgram->new(
    version => $struct->{version} || 1,
    operation_type => $struct->{operation_type} || 'query',
    operation_name => $struct->{operation_name},
    blocks => \@blocks,
    root_block => $root_block,
  );
  _bind_vm_ops($runtime_schema, $vm_program);
  GraphQL::Houtou::Runtime::VMDispatch->bind_program($vm_program);
  return $vm_program;
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
  my $resolve_family = $instruction->resolve_op || 'RESOLVE_DEFAULT';
  my $complete_family = $instruction->complete_op || 'COMPLETE_GENERIC';
  return GraphQL::Houtou::Runtime::VMOp->new(
    opcode => join(q(:), $resolve_family, $complete_family),
    opcode_code => (($RESOLVE_CODE{$resolve_family} || 0) * 16) + ($COMPLETE_CODE{$complete_family} || 0),
    resolve_family => $resolve_family,
    resolve_code => $RESOLVE_CODE{$resolve_family} || 0,
    complete_family => $complete_family,
    complete_code => $COMPLETE_CODE{$complete_family} || 0,
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
    bound_slot => $instruction->bound_slot,
    abstract_dispatch => $instruction->abstract_dispatch,
  );
}

sub _inflate_op {
  my ($struct) = @_;
  return GraphQL::Houtou::Runtime::VMOp->new(
    opcode => $struct->{opcode},
    opcode_code => $struct->{opcode_code} || 0,
    resolve_family => $struct->{resolve_family},
    resolve_code => $struct->{resolve_code} || 0,
    complete_family => $struct->{complete_family},
    complete_code => $struct->{complete_code} || 0,
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

sub _bind_vm_ops {
  my ($runtime_schema, $program) = @_;
  my %blocks = map { ($_->name => $_) } @{ $program->blocks || [] };
  if (my $root = $program->root_block) {
    $blocks{ $root->name } = $root;
  }

  for my $block (@{ $program->blocks || [] }, ($program->root_block || ())) {
    next if !$block;
    my $schema_block = $runtime_schema->program->block_by_type_name($block->type_name);
    my %slots = $schema_block
      ? map { ($_->field_name => $_) } @{ $schema_block->slots || [] }
      : ();

    for my $op (@{ $block->ops || [] }) {
      $op->{bound_slot} ||= $slots{ $op->field_name };
      if (!$op->{abstract_dispatch} && (($op->opcode || q()) =~ /:COMPLETE_ABSTRACT$/)) {
        my $slot = $op->{bound_slot};
        my $return_type = $slot ? $slot->return_type_name : undef;
        $op->{abstract_dispatch} = GraphQL::Houtou::Runtime::OperationCompiler::_bind_abstract_dispatch(
          $runtime_schema,
          $return_type,
        ) if defined $return_type;
      }
      $op->{bound_child_block} = $op->child_block_name
        ? $blocks{ $op->child_block_name }
        : undef;
      $op->{bound_abstract_child_blocks} = {
        map {
          my $child_name = $op->abstract_child_blocks->{$_};
          ($_ => ($child_name ? $blocks{$child_name} : undef))
        } keys %{ $op->abstract_child_blocks || {} }
      };
      $op->{resolve_handler} ||= $RESOLVE_HANDLER{ $op->resolve_family || '' };
      $op->{complete_handler} ||= $COMPLETE_HANDLER{ $op->complete_family || '' };
    }
  }

  return $program;
}

1;
