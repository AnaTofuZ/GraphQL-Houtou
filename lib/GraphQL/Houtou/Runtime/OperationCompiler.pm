package GraphQL::Houtou::Runtime::OperationCompiler;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou qw(parse);
use GraphQL::Houtou::Runtime::ExecutionProgram ();
use GraphQL::Houtou::Runtime::ExecutionBlock ();
use GraphQL::Houtou::Runtime::Instruction ();

sub compile_operation {
  my ($class, $runtime_schema, $document, %opts) = @_;
  my $ast = ref($document) ? $document : parse($document);
  my ($operation) = grep { ($_->{kind} || '') eq 'operation' } @{ $ast || [] };
  die "No operation found for greenfield runtime.\n" if !$operation;

  my $operation_type = $operation->{operation} || 'query';
  my $schema_block = $runtime_schema->program->root_block($operation_type)
    or die "No root block for operation type '$operation_type'.\n";

  my %state = (
    runtime_schema => $runtime_schema,
    block_index => 0,
    blocks => [],
  );

  my $root_block = _lower_selection_block(
    \%state,
    $schema_block->root_type_name,
    $schema_block,
    $operation->{selections} || [],
    uc($operation_type),
  );

  return GraphQL::Houtou::Runtime::ExecutionProgram->new(
    operation_type => $operation_type,
    operation_name => $operation->{name},
    blocks => $state{blocks},
    root_block => $root_block,
  );
}

sub _lower_selection_block {
  my ($state, $type_name, $schema_block, $selections, $base_name) = @_;
  my %schema_slots = map { ($_->field_name => $_) } @{ $schema_block->slots || [] };
  my @instructions;

  for my $selection (@{ $selections || [] }) {
    next if !$selection || ($selection->{kind} || '') ne 'field';
    my $field_name = $selection->{name};
    my $slot = $schema_slots{$field_name} or next;
    my $child_block;

    if ($selection->{selections} && @{ $selection->{selections} }) {
      my $child_type_name = $slot->return_type_name;
      my $child_schema_block = $state->{runtime_schema}->program->block_by_type_name($child_type_name);
      if ($child_schema_block) {
        $child_block = _lower_selection_block(
          $state,
          $child_type_name,
          $child_schema_block,
          $selection->{selections},
          $base_name . q(.) . $field_name,
        );
      }
    }

    push @instructions, GraphQL::Houtou::Runtime::Instruction->new(
      field_name => $field_name,
      result_name => ($selection->{alias} || $field_name),
      return_type_name => $slot->return_type_name,
      resolve_op => _resolve_op_for_slot($slot),
      complete_op => _complete_op_for_slot($slot),
      dispatch_family => $slot->dispatch_family,
      has_args => $slot->has_args,
      has_directives => $slot->has_directives,
      child_block_name => $child_block ? $child_block->name : undef,
    );
  }

  my $block = GraphQL::Houtou::Runtime::ExecutionBlock->new(
    name => _next_block_name($state, $base_name),
    type_name => $type_name,
    family => 'OBJECT',
    instructions => \@instructions,
  );
  push @{ $state->{blocks} }, $block;
  return $block;
}

sub _next_block_name {
  my ($state, $base_name) = @_;
  my $name = sprintf('%s#%d', $base_name, $state->{block_index}++);
  return $name;
}

sub _resolve_op_for_slot {
  my ($slot) = @_;
  return 'RESOLVE_EXPLICIT' if ($slot->resolver_shape || '') eq 'EXPLICIT';
  return 'RESOLVE_DEFAULT';
}

sub _complete_op_for_slot {
  my ($slot) = @_;
  my $family = $slot->completion_family || 'GENERIC';
  return 'COMPLETE_OBJECT' if $family eq 'OBJECT';
  return 'COMPLETE_LIST' if $family eq 'LIST';
  return 'COMPLETE_ABSTRACT' if $family eq 'ABSTRACT';
  return 'COMPLETE_GENERIC';
}

1;
