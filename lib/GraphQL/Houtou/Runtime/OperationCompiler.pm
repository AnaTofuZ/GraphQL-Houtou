package GraphQL::Houtou::Runtime::OperationCompiler;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::GraphQLPerl::Parser ();
use GraphQL::Houtou::Runtime::ExecutionProgram ();
use GraphQL::Houtou::Runtime::ExecutionBlock ();
use GraphQL::Houtou::Runtime::Instruction ();
use GraphQL::Houtou::Runtime::Slot ();

sub compile_operation {
  my ($class, $runtime_schema, $document, %opts) = @_;
  my $ast = ref($document) ? $document : GraphQL::Houtou::GraphQLPerl::Parser::parse($document);
  my ($operation) = grep { ($_->{kind} || '') eq 'operation' } @{ $ast || [] };
  die "No operation found for runtime compiler.\n" if !$operation;
  my %fragments = map { (($_->{name} || '') => $_) }
    grep { ($_->{kind} || '') eq 'fragment' } @{ $ast || [] };

  my $operation_type = $operation->{operation} || 'query';
  my $schema_block = $runtime_schema->program->root_block($operation_type)
    or die "No root block for operation type '$operation_type'.\n";

  my %state = (
    runtime_schema => $runtime_schema,
    block_index => 0,
    blocks => [],
    fragments => \%fragments,
  );

  my $root_block = _lower_selection_block(
    \%state,
    $schema_block->root_type_name,
    $schema_block,
    $operation->{selections} || [],
    uc($operation_type),
  );

  my $program = GraphQL::Houtou::Runtime::ExecutionProgram->new(
    operation_type => $operation_type,
    operation_name => $operation->{name},
    variable_defs => _lower_variable_defs($operation->{variables}),
    blocks => $state{blocks},
    root_block => $root_block,
  );

  _bind_instruction_blocks($program);
  return $program;
}

sub inflate_operation {
  my ($class, $runtime_schema, $struct) = @_;
  my @blocks = map { _inflate_execution_block($_) } @{ $struct->{blocks} || [] };
  my %by_name = map { ($_->name => $_) } @blocks;
  my $root_block = defined $struct->{root_block} ? $by_name{ $struct->{root_block} } : undef;
  _bind_instructions_to_schema_slots($runtime_schema, \@blocks);
  my $program = GraphQL::Houtou::Runtime::ExecutionProgram->new(
    version => $struct->{version} || 1,
    operation_type => $struct->{operation_type} || 'query',
    operation_name => $struct->{operation_name},
    variable_defs => _clone_argument_value($struct->{variable_defs} || {}),
    blocks => \@blocks,
    root_block => $root_block,
  );
  _bind_instruction_blocks($program);
  return $program;
}

sub _lower_selection_block {
  my ($state, $type_name, $schema_block, $selections, $base_name) = @_;
  my %schema_slots = map { ($_->field_name => $_) } @{ $schema_block->slots || [] };
  my @instructions;
  my $field_selections = _normalize_selections($state, $selections, $type_name);

  for my $selection (@{ $field_selections || [] }) {
    next if !$selection || ($selection->{kind} || '') ne 'field';
    my $field_name = $selection->{name};
    if (($field_name || q()) eq '__typename') {
      push @instructions, _build_typename_instruction($state, $type_name, $selection);
      next;
    }
    my $slot = $schema_slots{$field_name} or next;
    my $child_block;
    my $abstract_child_blocks;
    my ($args_mode, $args_payload) = _lower_arguments($selection->{arguments});
    my ($directives_mode, $directives_payload) = _lower_directives($selection->{_runtime_guards});

    if ($selection->{selections} && @{ $selection->{selections} }) {
      my $child_type_name = $slot->return_type_name;
      if (($slot->completion_family || '') eq 'ABSTRACT') {
        $abstract_child_blocks = _lower_abstract_child_blocks(
          $state,
          $child_type_name,
          $selection->{selections},
          $base_name . q(.) . $field_name,
        );
      }
      elsif (my $child_schema_block = $state->{runtime_schema}->program->block_by_type_name($child_type_name)) {
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
      arg_defs => $slot->arg_defs,
      has_args => $slot->has_args,
      args_mode => $args_mode,
      args_payload => $args_payload,
      has_directives => (($directives_mode || 'NONE') ne 'NONE') ? 1 : 0,
      directives_mode => $directives_mode,
      directives_payload => $directives_payload,
      child_block_name => $child_block ? $child_block->name : undef,
      abstract_child_blocks => $abstract_child_blocks,
      bound_slot => $slot,
      abstract_dispatch => (($slot->completion_family || '') eq 'ABSTRACT')
        ? _bind_abstract_dispatch($state->{runtime_schema}, $slot->return_type_name)
        : undef,
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

sub _inflate_execution_block {
  my ($struct) = @_;
  return GraphQL::Houtou::Runtime::ExecutionBlock->new(
    name => $struct->{name},
    type_name => $struct->{type_name},
    family => $struct->{family} || 'OBJECT',
    instructions => [ map { _inflate_instruction($_) } @{ $struct->{instructions} || [] } ],
  );
}

sub _inflate_instruction {
  my ($struct) = @_;
  return GraphQL::Houtou::Runtime::Instruction->new(
    field_name => $struct->{field_name},
    result_name => $struct->{result_name},
    return_type_name => $struct->{return_type_name},
    resolve_op => $struct->{resolve_op},
    complete_op => $struct->{complete_op},
    dispatch_family => $struct->{dispatch_family},
    arg_defs => _clone_argument_value($struct->{arg_defs} || {}),
    has_args => $struct->{has_args},
    args_mode => $struct->{args_mode} || 'NONE',
    args_payload => _clone_argument_value($struct->{args_payload}),
    has_directives => $struct->{has_directives},
    directives_mode => $struct->{directives_mode} || 'NONE',
    directives_payload => _clone_argument_value($struct->{directives_payload}),
    child_block_name => $struct->{child_block_name},
    abstract_child_blocks => _clone_argument_value($struct->{abstract_child_blocks} || {}),
  );
}

sub _bind_instructions_to_schema_slots {
  my ($runtime_schema, $blocks) = @_;

  for my $block (@{ $blocks || [] }) {
    my $schema_block = $runtime_schema->program->block_by_type_name($block->type_name) or next;
    my %slots = map { ($_->field_name => $_) } @{ $schema_block->slots || [] };
    for my $instruction (@{ $block->instructions || [] }) {
      $instruction->{bound_slot} = $slots{ $instruction->field_name };
      $instruction->{abstract_dispatch} = _bind_abstract_dispatch(
        $runtime_schema,
        $instruction->return_type_name,
      ) if ($instruction->complete_op || '') eq 'COMPLETE_ABSTRACT';
    }
  }

  return $blocks;
}

sub _bind_instruction_blocks {
  my ($program) = @_;
  my %by_name = map { ($_->name => $_) } @{ $program->blocks || [] };
  if (my $root = $program->root_block) {
    $by_name{ $root->name } = $root;
  }

  for my $block (@{ $program->blocks || [] }, ($program->root_block || ())) {
    next if !$block;
    for my $instruction (@{ $block->instructions || [] }) {
      $instruction->{bound_child_block} = $instruction->child_block_name
        ? $by_name{ $instruction->child_block_name }
        : undef;
      $instruction->{bound_abstract_child_blocks} = {
        map {
          my $child_name = $instruction->abstract_child_blocks->{$_};
          ($_ => ($child_name ? $by_name{$child_name} : undef))
        } keys %{ $instruction->abstract_child_blocks || {} }
      };
    }
  }

  return $program;
}

sub _bind_abstract_dispatch {
  my ($runtime_schema, $abstract_name) = @_;
  return undef if !defined $abstract_name;
  my $cache = $runtime_schema->runtime_cache || {};
  my $abstract_type = ($cache->{name2type} || {})->{$abstract_name} or return undef;
  my $tag_resolver = ($cache->{tag_resolver_map} || {})->{$abstract_name};
  my $resolve_type = ($cache->{resolve_type_map} || {})->{$abstract_name};
  my $possible_types = ($cache->{possible_types} || {})->{$abstract_name} || [];
  return {
    abstract_name => $abstract_name,
    abstract_type => $abstract_type,
    dispatch_family => $tag_resolver
      ? 'TAG'
      : $resolve_type
        ? 'RESOLVE_TYPE'
        : 'POSSIBLE_TYPES',
    tag_resolver => $tag_resolver,
    tag_map => ($cache->{runtime_tag_map} || {})->{$abstract_name} || {},
    resolve_type => $resolve_type,
    possible_types => $possible_types,
    is_type_of_map => $cache->{is_type_of_map} || {},
    name2type => $cache->{name2type} || {},
  };
}

sub _lower_abstract_child_blocks {
  my ($state, $abstract_type_name, $selections, $base_name) = @_;
  my $possible_types = $state->{runtime_schema}->runtime_cache->{possible_types}{$abstract_type_name} || [];
  my %blocks;

  for my $type (@$possible_types) {
    next if !$type || !$type->isa('GraphQL::Houtou::Type::Object');
    my $schema_block = $state->{runtime_schema}->program->block_by_type_name($type->name) or next;
    my $block = _lower_selection_block(
      $state,
      $type->name,
      $schema_block,
      $selections,
      $base_name . q(.) . $type->name,
    );
    $blocks{ $type->name } = $block->name if $block;
  }

  return \%blocks;
}

sub _normalize_selections {
  my ($state, $selections, $type_name, $visited, $inherited_guards) = @_;
  $visited ||= {};
  $inherited_guards ||= [];
  my @normalized;

  for my $selection (@{ $selections || [] }) {
    next if !$selection;
    my $kind = $selection->{kind} || '';
    my ($allowed, $dynamic_guards) = _partition_runtime_guards($selection->{directives});
    next if !$allowed;
    my $combined_guards = [ @$inherited_guards, @$dynamic_guards ];
    if ($kind eq 'field') {
      my %copy = %$selection;
      $copy{_runtime_guards} = $combined_guards if @$combined_guards;
      push @normalized, \%copy;
      next;
    }
    if ($kind eq 'inline_fragment') {
      my $on = $selection->{on};
      next if defined($on) && defined($type_name) && $on ne $type_name;
      push @normalized, @{ _normalize_selections($state, $selection->{selections} || [], $type_name, $visited, $combined_guards) };
      next;
    }
    if ($kind eq 'fragment_spread') {
      my $name = $selection->{name} || '';
      next if !$name || $visited->{$name};
      my $fragment = $state->{fragments}{$name} or next;
      my $on = $fragment->{on};
      next if defined($on) && defined($type_name) && $on ne $type_name;
      local $visited->{$name} = 1;
      push @normalized, @{ _normalize_selections($state, $fragment->{selections} || [], $type_name, $visited, $combined_guards) };
      next;
    }
  }

  return \@normalized;
}

sub _build_typename_instruction {
  my ($state, $type_name, $selection) = @_;
  my ($directives_mode, $directives_payload) = _lower_directives($selection->{_runtime_guards});
  my $result_name = ($selection->{alias} || '__typename');
  my $slot = _lookup_typename_slot($state->{runtime_schema}, $type_name, $result_name, $directives_mode);
  return GraphQL::Houtou::Runtime::Instruction->new(
    field_name => '__typename',
    result_name => $result_name,
    return_type_name => 'String',
    resolve_op => 'RESOLVE_DEFAULT',
    complete_op => 'COMPLETE_GENERIC',
    dispatch_family => 'DEFAULT',
    arg_defs => {},
    has_args => 0,
    args_mode => 'NONE',
    args_payload => undef,
    has_directives => (($directives_mode || 'NONE') ne 'NONE') ? 1 : 0,
    directives_mode => $directives_mode,
    directives_payload => $directives_payload,
    bound_slot => $slot,
  );
}

sub _lookup_typename_slot {
  my ($runtime_schema, $type_name, $result_name, $directives_mode) = @_;
  my $schema_block = $runtime_schema->program->block_by_type_name($type_name);
  if ($schema_block) {
    for my $slot (@{ $schema_block->slots || [] }) {
      next if ($slot->field_name || q()) ne '__typename';
      return GraphQL::Houtou::Runtime::Slot->new(
        schema_slot_key => $slot->schema_slot_key,
        schema_slot_index => $slot->schema_slot_index,
        field_name => '__typename',
        result_name => $result_name,
        return_type_name => $slot->return_type_name,
        resolver_shape => $slot->resolver_shape,
        resolver_mode => $slot->resolver_mode,
        completion_family => $slot->completion_family,
        dispatch_family => $slot->dispatch_family,
        arg_defs => {},
        has_args => 0,
        has_directives => (($directives_mode || 'NONE') ne 'NONE') ? 1 : 0,
        resolve => $slot->resolve,
        return_type => $slot->return_type,
      );
    }
  }

  my $string_type = $runtime_schema->runtime_cache->{name2type}{String};
  return GraphQL::Houtou::Runtime::Slot->new(
    schema_slot_key => join(q(.), ($type_name || q()), '__typename'),
    field_name => '__typename',
    result_name => $result_name,
    return_type_name => 'String',
    resolver_shape => 'DEFAULT',
    resolver_mode => 'DEFAULT',
    completion_family => 'GENERIC',
    dispatch_family => 'GENERIC',
    arg_defs => {},
    has_args => 0,
    has_directives => (($directives_mode || 'NONE') ne 'NONE') ? 1 : 0,
    return_type => $string_type,
  );
}

sub _resolve_op_for_slot {
  my ($slot) = @_;
  return 'RESOLVE_EXPLICIT' if ($slot->resolver_shape || '') eq 'EXPLICIT';
  return 'RESOLVE_DEFAULT';
}

sub _lower_variable_defs {
  my ($variables) = @_;
  return {} if !$variables || !keys %$variables;
  my %defs;
  for my $name (sort keys %$variables) {
    my $def = $variables->{$name} || {};
    $defs{$name} = {
      type => { type => _clone_argument_value($def->{type}) },
      has_default => exists $def->{default_value} ? 1 : 0,
      default_value => exists $def->{default_value}
        ? _materialize_static_value($def->{default_value})
        : undef,
    };
  }
  return \%defs;
}

sub _lower_directives {
  my ($directives) = @_;
  return ('NONE', undef) if !$directives || !@$directives;
  return ('STATIC', _materialize_static_value($directives))
    if !_contains_variable_refs($directives);
  return ('DYNAMIC', _clone_argument_value($directives));
}

sub _partition_runtime_guards {
  my ($directives) = @_;
  return (1, []) if !$directives || !@$directives;
  my @dynamic;
  for my $directive (@$directives) {
    next if !$directive;
    my $name = $directive->{name} || '';
    next if $name ne 'include' && $name ne 'skip';
    my $arguments = $directive->{arguments} || {};
    my $if_value = $arguments->{if};
    if (!_contains_variable_refs($if_value)) {
      my $bool = _directive_truthy(_materialize_static_value($if_value));
      return (0, []) if $name eq 'skip' && $bool;
      return (0, []) if $name eq 'include' && !$bool;
      next;
    }
    push @dynamic, {
      name => $name,
      arguments => _clone_argument_value($arguments),
    };
  }
  return (1, \@dynamic);
}

sub _directive_truthy {
  my ($value) = @_;
  return $value ? 1 : 0;
}

sub _lower_arguments {
  my ($arguments) = @_;
  return ('NONE', undef) if !$arguments || !keys %$arguments;
  return ('STATIC', _materialize_static_value($arguments))
    if !_contains_variable_refs($arguments);
  return ('DYNAMIC', _clone_argument_value($arguments));
}

sub _contains_variable_refs {
  my ($value) = @_;
  my $ref = ref($value);
  return 0 if !$ref;
  return 1 if $ref eq 'SCALAR';
  return _contains_variable_refs($$value) if $ref eq 'REF';
  if ($ref eq 'ARRAY') {
    for my $item (@$value) {
      return 1 if _contains_variable_refs($item);
    }
    return 0;
  }
  if ($ref eq 'HASH') {
    for my $key (keys %$value) {
      return 1 if _contains_variable_refs($value->{$key});
    }
    return 0;
  }
  return 0;
}

sub _materialize_static_value {
  my ($value) = @_;
  my $ref = ref($value);
  return $value if !$ref;
  return $$$value if $ref eq 'REF';
  return [ map { _materialize_static_value($_) } @$value ] if $ref eq 'ARRAY';
  return { map { $_ => _materialize_static_value($value->{$_}) } keys %$value } if $ref eq 'HASH';
  die "Unsupported static argument value ref '$ref' in runtime compiler.\n"
    if $ref eq 'SCALAR';
  return $value;
}

sub _clone_argument_value {
  my ($value) = @_;
  my $ref = ref($value);
  return $value if !$ref;
  return $value if $ref eq 'REF' || $ref eq 'SCALAR';
  return [ map { _clone_argument_value($_) } @$value ] if $ref eq 'ARRAY';
  return { map { $_ => _clone_argument_value($value->{$_}) } keys %$value } if $ref eq 'HASH';
  return $value;
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
