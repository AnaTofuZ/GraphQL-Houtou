package GraphQL::Houtou::Runtime::VMCompiler;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Runtime::OperationCompiler ();
use GraphQL::Houtou::Runtime::Slot ();
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
    variable_defs => $program->can('variable_defs') ? ($program->variable_defs || {}) : {},
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
    variable_defs => $struct->{variable_defs} || {},
    blocks => \@blocks,
    root_block => $root_block,
  );
  _bind_vm_ops($runtime_schema, $vm_program);
  GraphQL::Houtou::Runtime::VMDispatch->bind_program($vm_program);
  return $vm_program;
}

sub inflate_native_bundle {
  my ($class, $runtime_schema, $struct) = @_;
  my $program_struct = $struct->{program} || {};
  my $block_entries = $program_struct->{blocks_compact} || $program_struct->{blocks} || [];
  my @blocks = map { _inflate_native_block($_) } @{ $block_entries };
  my $root_block = defined $program_struct->{root_block_index}
    ? $blocks[ $program_struct->{root_block_index} ]
    : undef;
  my $vm_program = GraphQL::Houtou::Runtime::VMProgram->new(
    version => $program_struct->{version} || 1,
    operation_type => $program_struct->{operation_type} || 'query',
    operation_name => $program_struct->{operation_name},
    variable_defs => $program_struct->{variable_defs} || {},
    blocks => \@blocks,
    root_block => $root_block,
  );
  _bind_native_vm_ops($runtime_schema, $vm_program, $program_struct);
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
    return_type_name => $instruction->return_type_name,
    dispatch_family => $instruction->dispatch_family,
    child_block_name => $instruction->child_block_name,
    abstract_child_blocks => $instruction->abstract_child_blocks,
    arg_defs => $instruction->arg_defs,
    args_mode => $instruction->args_mode,
    args_payload => $instruction->args_payload,
    has_args => $instruction->has_args,
    directives_mode => $instruction->directives_mode,
    directives_payload => $instruction->directives_payload,
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
    return_type_name => $struct->{return_type_name},
    dispatch_family => $struct->{dispatch_family},
    child_block_name => $struct->{child_block_name},
    abstract_child_blocks => $struct->{abstract_child_blocks} || {},
    arg_defs => $struct->{arg_defs} || {},
    args_mode => $struct->{args_mode} || 'NONE',
    args_payload => $struct->{args_payload},
    has_args => $struct->{has_args},
    directives_mode => $struct->{directives_mode} || 'NONE',
    directives_payload => $struct->{directives_payload},
    has_directives => $struct->{has_directives},
  );
}

sub _inflate_native_block {
  my ($struct) = @_;
  if (ref($struct) eq 'ARRAY') {
    my ($name, $type_name, $family_code, $slots, $ops) = @$struct;
    return GraphQL::Houtou::Runtime::VMBlock->new(
      name => $name,
      type_name => $type_name,
      family => _family_from_code($family_code),
      ops => [ map { _inflate_native_op($_) } @{ $ops || [] } ],
    );
  }
  return GraphQL::Houtou::Runtime::VMBlock->new(
    name => $struct->{name},
    type_name => $struct->{type_name},
    family => $struct->{family} || 'OBJECT',
    ops => [ map { _inflate_native_op($_) } @{ $struct->{ops} || [] } ],
  );
}

sub _inflate_native_op {
  my ($struct) = @_;
  if (ref($struct) eq 'ARRAY') {
    my ($opcode_code, $resolve_code, $complete_code, $dispatch_family_code, $slot_index, $child_block_index, $abstract_child_block_indexes, $args_mode_code, $args_payload, $has_args, $has_directives, $field_name, $result_name, $return_type_name) = @$struct;
    my $resolve_family = _resolve_family_from_code($resolve_code);
    my $complete_family = _complete_family_from_code($complete_code);
    my $op = GraphQL::Houtou::Runtime::VMOp->new(
      opcode => join(q(:), $resolve_family, $complete_family),
      opcode_code => $opcode_code || 0,
      resolve_family => $resolve_family,
      resolve_code => $resolve_code || 0,
      complete_family => $complete_family,
      complete_code => $complete_code || 0,
      field_name => $field_name,
      result_name => $result_name,
      return_type_name => $return_type_name,
      args_mode => _args_mode_from_code($args_mode_code),
      args_payload => $args_payload,
      has_args => $has_args,
      has_directives => $has_directives,
    );
    $op->set_native_slot_index($slot_index);
    $op->set_native_child_block_index($child_block_index);
    $op->set_native_abstract_child_block_indexes($abstract_child_block_indexes || {});
    return $op;
  }
  my $resolve_family = _resolve_family_from_code($struct->{resolve_code});
  my $complete_family = _complete_family_from_code($struct->{complete_code});
  my $op = GraphQL::Houtou::Runtime::VMOp->new(
    opcode => join(q(:), $resolve_family, $complete_family),
    opcode_code => $struct->{opcode_code} || 0,
    resolve_family => $resolve_family,
    resolve_code => $struct->{resolve_code} || 0,
    complete_family => $complete_family,
    complete_code => $struct->{complete_code} || 0,
    return_type_name => $struct->{return_type_name},
    args_mode => $struct->{args_mode} || 'NONE',
    has_args => $struct->{has_args},
    directives_mode => $struct->{directives_mode} || 'NONE',
    has_directives => $struct->{has_directives},
  );
  $op->set_native_slot_index($struct->{slot_index});
  $op->set_native_child_block_index($struct->{child_block_index});
  $op->set_native_abstract_child_block_indexes($struct->{abstract_child_block_indexes} || {});
  return $op;
}

sub _family_from_code {
  my ($code) = @_;
  return 'OBJECT' if ($code || 0) == 2;
  return 'LIST' if ($code || 0) == 3;
  return 'ABSTRACT' if ($code || 0) == 4;
  return 'GENERIC';
}

sub _args_mode_from_code {
  my ($code) = @_;
  return 'STATIC' if ($code || 0) == 1;
  return 'DYNAMIC' if ($code || 0) == 2;
  return 'NONE';
}

sub _bind_vm_ops {
  my ($runtime_schema, $program) = @_;
  my %blocks = map { ($_->name => $_) } @{ $program->blocks || [] };
  if (my $root = $program->root_block) {
    $blocks{ $root->name } = $root;
  }

  for my $block (@{ $program->blocks || [] }, ($program->root_block || ())) {
    next if !$block;
    my $schema_block = $runtime_schema->block_by_type_name($block->type_name);
    my %slots = $schema_block
      ? map { ($_->field_name => $_) } @{ $schema_block->slots || [] }
      : ();

    for my $op (@{ $block->ops || [] }) {
      $op->set_bound_slot($op->bound_slot || $slots{ $op->field_name });
      $op->set_bound_slot($op->bound_slot || _bind_typename_slot($runtime_schema, $block, $op));
      if (!$op->abstract_dispatch && (($op->opcode || q()) =~ /:COMPLETE_ABSTRACT$/)) {
        my $slot = $op->bound_slot;
        my $return_type = $slot ? $slot->return_type_name : undef;
        $op->set_abstract_dispatch(GraphQL::Houtou::Runtime::OperationCompiler::_bind_abstract_dispatch(
          $runtime_schema,
          $return_type,
        )) if defined $return_type;
      }
      $op->set_bound_child_block($op->child_block_name
        ? $blocks{ $op->child_block_name }
        : undef);
      $op->set_bound_abstract_child_blocks({
        map {
          my $child_name = $op->abstract_child_blocks->{$_};
          ($_ => ($child_name ? $blocks{$child_name} : undef))
        } keys %{ $op->abstract_child_blocks || {} }
      });
      $op->set_resolve_handler($op->resolve_handler || $RESOLVE_HANDLER{ $op->resolve_family || '' });
      $op->set_complete_handler($op->complete_handler || $COMPLETE_HANDLER{ $op->complete_family || '' });
    }
  }

  return $program;
}

sub _bind_native_vm_ops {
  my ($runtime_schema, $program, $program_struct) = @_;
  my @block_structs = @{ $program_struct->{blocks} || [] };
  my @blocks = @{ $program->blocks || [] };
  my @runtime_slots = @{ $runtime_schema->slot_catalog || [] };

  for my $block_index (0 .. $#blocks) {
    my $block = $blocks[$block_index] or next;
    my $block_struct = $block_structs[$block_index] || {};
    my @native_slots = @{ $block_struct->{slots} || [] };

    for my $op (@{ $block->ops || [] }) {
      my $slot_struct = defined $op->native_slot_index
        ? $native_slots[ $op->native_slot_index ]
        : undef;
      my $runtime_slot = $slot_struct && defined $slot_struct->{schema_slot_index}
        ? $runtime_slots[ $slot_struct->{schema_slot_index} ]
        : undef;

      $op->set_bound_slot($runtime_slot) if $runtime_slot;
      $op->set_field_name($slot_struct->{field_name}) if $slot_struct && defined $slot_struct->{field_name};
      $op->set_result_name($slot_struct->{result_name}) if $slot_struct && defined $slot_struct->{result_name};
      $op->set_bound_slot($op->bound_slot || _bind_typename_slot($runtime_schema, $block, $op, $slot_struct));

      if (!$op->abstract_dispatch && (($op->complete_family || q()) eq 'COMPLETE_ABSTRACT')) {
        my $return_type = $runtime_slot ? $runtime_slot->return_type_name : ($slot_struct ? $slot_struct->{return_type_name} : undef);
        $op->set_abstract_dispatch(GraphQL::Houtou::Runtime::OperationCompiler::_bind_abstract_dispatch(
          $runtime_schema,
          $return_type,
        )) if defined $return_type;
      }

      $op->set_bound_child_block(defined $op->native_child_block_index
        ? $blocks[ $op->native_child_block_index ]
        : undef);
      $op->set_bound_abstract_child_blocks({
        map {
          my $idx = $op->native_abstract_child_block_indexes->{$_};
          ($_ => (defined $idx ? $blocks[$idx] : undef))
        } keys %{ $op->native_abstract_child_block_indexes || {} }
      });
      $op->set_resolve_handler($op->resolve_handler || $RESOLVE_HANDLER{ $op->resolve_family || q() });
      $op->set_complete_handler($op->complete_handler || $COMPLETE_HANDLER{ $op->complete_family || q() });
    }
  }

  return $program;
}

sub _bind_typename_slot {
  my ($runtime_schema, $block, $op, $slot_struct) = @_;
  return undef if ($op->field_name || q()) ne '__typename';

  my $string_type = $runtime_schema->runtime_cache->{name2type}{String};
  return GraphQL::Houtou::Runtime::Slot->new(
    schema_slot_key => join(q(.), ($block->type_name || q()), '__typename'),
    field_name => '__typename',
    result_name => ($op->result_name || '__typename'),
    return_type_name => (($slot_struct && $slot_struct->{return_type_name}) || 'String'),
    resolver_shape => 'DEFAULT',
    resolver_mode => 'DEFAULT',
    completion_family => 'GENERIC',
    dispatch_family => 'GENERIC',
    arg_defs => {},
    has_args => 0,
    has_directives => (($op->has_directives || 0) ? 1 : 0),
    return_type => $string_type,
  );
}

sub _resolve_family_from_code {
  my ($code) = @_;
  return 'RESOLVE_EXPLICIT' if ($code || 0) == 2;
  return 'RESOLVE_DEFAULT';
}

sub _complete_family_from_code {
  my ($code) = @_;
  return 'COMPLETE_OBJECT' if ($code || 0) == 2;
  return 'COMPLETE_LIST' if ($code || 0) == 3;
  return 'COMPLETE_ABSTRACT' if ($code || 0) == 4;
  return 'COMPLETE_GENERIC';
}

1;
