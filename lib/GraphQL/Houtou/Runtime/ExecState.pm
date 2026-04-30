package GraphQL::Houtou::Runtime::ExecState;

use 5.014;
use strict;
use warnings;
use GraphQL::Houtou ();

use GraphQL::Houtou::Promise::Adapter qw(is_promise_value normalize_promise_code then_promise);
use GraphQL::Houtou::Runtime::BlockFrame ();
use GraphQL::Houtou::Runtime::ErrorRecord ();
use GraphQL::Houtou::Runtime::InputCoercion ();
use GraphQL::Houtou::Runtime::LazyInfo ();
use Scalar::Util qw(reftype);

use constant {
  RESOLVE_DEFAULT_CODE  => 1,
  RESOLVE_EXPLICIT_CODE => 2,
  COMPLETE_GENERIC_CODE => 1,
  COMPLETE_OBJECT_CODE  => 2,
  COMPLETE_LIST_CODE    => 3,
  COMPLETE_ABSTRACT_CODE => 4,
};

sub new {
  my ($class, %args) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_new_xs(
    $class,
    $args{runtime_schema},
    $args{program},
    $args{cursor},
    $args{writer},
    $args{context},
    ($args{variables} || {}),
    $args{root_value},
    $args{promise_code},
    ($args{empty_args} || {}),
  );
}

sub build_for_program {
  my ($class, $runtime_schema, $program, %opts) = @_;
  my $promise_code = normalize_promise_code($opts{promise_code});
  return $class->new(
    runtime_schema => $runtime_schema,
    program => $program,
    cursor => GraphQL::Houtou::XS::VM::cursor_new_xs(
      'GraphQL::Houtou::Runtime::Cursor',
      undef,
      $program->to_native_program_handle,
      (defined $program->root_block_index ? $program->root_block_index : -1),
      0,
      0,
      undef,
      undef,
    ),
    writer => GraphQL::Houtou::XS::VM::writer_new_xs('GraphQL::Houtou::Runtime::Writer'),
    context => $opts{context},
    variables => GraphQL::Houtou::Runtime::InputCoercion::prepare_variables(
      $runtime_schema,
      $program,
      $opts{variables} || {},
    ),
    root_value => $opts{root_value},
    promise_code => $promise_code,
    empty_args => {},
  );
}

sub run_program {
  my ($class, $runtime_schema, $program, %opts) = @_;
  my $state = $class->build_for_program($runtime_schema, $program, %opts);
  if (!$state->promise_code) {
    GraphQL::Houtou::_bootstrap_xs();
    return GraphQL::Houtou::XS::VM::exec_state_run_program_xs($state, $opts{root_value});
  }
  my $data = $state->execute_block($program->root_block_index, $opts{root_value});
  return $state->finalize_response($data);
}

sub runtime_schema {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_runtime_schema_xs($_[0]);
}

sub program {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_program_xs($_[0]);
}

sub cursor {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_cursor_xs($_[0]);
}

sub current_block { return undef }
sub current_op { return undef }
sub current_slot { return undef }

sub current_result_name {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_current_result_name_xs($_[0]);
}

sub current_field_name {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_current_field_name_xs($_[0]);
}

sub current_return_type {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_current_return_type_xs($_[0]);
}

sub current_parent_type {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_current_parent_type_xs($_[0]);
}

sub current_path {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_current_path_xs($_[0], $_[1]);
}

sub frame {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_frame_xs($_[0]);
}

sub frame_stack {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_frame_stack_xs($_[0]);
}

sub field_frame {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_field_frame_xs($_[0]);
}

sub writer {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_writer_xs($_[0]);
}

sub context {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_context_xs($_[0]);
}

sub variables {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_variables_xs($_[0]);
}

sub root_value {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_root_value_xs($_[0]);
}

sub promise_code {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_promise_code_xs($_[0]);
}

sub empty_args {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_empty_args_xs($_[0]);
}

sub push_frame {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_push_frame_xs($_[0], $_[1]);
}

sub pop_frame {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_pop_frame_xs($_[0]);
}

sub current_frame { return $_[0]->frame }

sub enter_field {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_enter_field_xs($_[0], $_[1], $_[2]);
}

sub leave_field {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_leave_field_xs($_[0]);
}

sub current_field_frame { return $_[0]->field_frame }
sub current_path_frame { return $_[0]->field_frame ? $_[0]->field_frame->path_frame : undef }

sub advance_current_op {
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_advance_current_op_xs($_[0]);
}

sub enter_current_field {
  my ($self, $source, $base_path) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_enter_current_field_xs(
    $self,
    $source,
    $base_path,
  );
}

sub consume_current_field_outcome {
  my ($self, $outcome) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::exec_state_consume_current_result_xs($self, $outcome);
  return $self->field_frame;
}

sub enter_block {
  my ($self, $block) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  my $snapshot = GraphQL::Houtou::XS::VM::exec_state_enter_block_index_xs($self, $block);
  return ($snapshot, $self->current_frame);
}

sub leave_block {
  my ($self, $snapshot, $result) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  GraphQL::Houtou::XS::VM::exec_state_leave_block_xs($self, $snapshot);
  return $result;
}

sub finalize_current_block {
  my ($self, $snapshot) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_finalize_current_block_xs($self, $snapshot);
}

sub run_current_field_via {
  my ($self, $resolve_cb, $complete_cb) = @_;
  my $field = $self->current_field_frame;
  my $source = GraphQL::Houtou::XS::VM::field_frame_source_xs($field);
  my $path_frame = GraphQL::Houtou::XS::VM::field_frame_path_frame_xs($field);
  my ($ok, $value) = $self->_capture_eval(sub {
    return $resolve_cb->($self, $source, $path_frame);
  });
  return $self->_error_outcome($value, $path_frame) if !$ok;
  GraphQL::Houtou::XS::VM::field_frame_set_resolved_value_xs($field, $value);

  if ($self->promise_code && is_promise_value($self->promise_code, $value)) {
    return GraphQL::Houtou::Promise::Adapter::then_promise($self->promise_code, $value, sub {
      my ($resolved_value) = @_;
      my ($complete_ok, $outcome) = $self->_capture_eval(sub {
        return $complete_cb->($self, $resolved_value, $path_frame);
      });
      return $complete_ok ? $outcome : $self->_error_outcome($outcome, $path_frame);
    }, sub {
      return $self->_error_outcome($_[0], $path_frame);
    });
  }

  my ($complete_ok, $outcome) = $self->_capture_eval(sub {
    return $complete_cb->($self, $value, $path_frame);
  });
  return $complete_ok ? $outcome : $self->_error_outcome($outcome, $path_frame);
}

sub execute_current_op {
  my ($self) = @_;
  if (!$self->promise_code) {
    GraphQL::Houtou::_bootstrap_xs();
    return GraphQL::Houtou::XS::VM::exec_state_execute_current_op_xs($self);
  }
  return $self->run_current_field_via(
    sub {
      my ($state, $source, $path_frame) = @_;
      return $state->_resolve_via_code($source, $path_frame);
    },
    sub {
      my ($state, $value, $path_frame) = @_;
      return $state->_complete_via_code($value, $path_frame);
    },
  );
}

sub run_default_generic { return $_[0]->run_current_field_via(\&resolve_default,  \&complete_generic) }
sub run_default_object  { return $_[0]->run_current_field_via(\&resolve_default,  \&complete_object) }
sub run_default_list    { return $_[0]->run_current_field_via(\&resolve_default,  \&complete_list) }
sub run_default_abstract { return $_[0]->run_current_field_via(\&resolve_default,  \&complete_abstract) }
sub run_explicit_generic { return $_[0]->run_current_field_via(\&resolve_explicit, \&complete_generic) }
sub run_explicit_object { return $_[0]->run_current_field_via(\&resolve_explicit, \&complete_object) }
sub run_explicit_list   { return $_[0]->run_current_field_via(\&resolve_explicit, \&complete_list) }
sub run_explicit_abstract { return $_[0]->run_current_field_via(\&resolve_explicit, \&complete_abstract) }

sub resolve_field_value {
  my ($self, $source, $path_frame) = @_;
  return $self->_resolve_via_code($source, $path_frame);
}

sub resolve_default {
  my ($self, $source, $path_frame) = @_;
  my $field_name = $self->current_field_name;
  my $return_type = $self->current_return_type;
  my $args = $self->resolve_args_for_current_field;
  my $resolver;

  GraphQL::Houtou::_bootstrap_xs();
  my $parent_type = $self->current_parent_type;
  return $parent_type ? $parent_type->name : undef
    if ($field_name || q()) eq '__typename';
  $resolver = GraphQL::Houtou::XS::VM::exec_state_current_resolver_xs($self);

  if ($resolver) {
    my $info = $self->build_lazy_info_for_current_field($path_frame);
    return $resolver->($source, $args, $self->context, $info, $return_type);
  }

  return $source->{ $field_name } if ref($source) eq 'HASH' && defined $field_name;
  return;
}

sub resolve_explicit {
  my ($self, $source, $path_frame) = @_;
  return $self->resolve_default($source, $path_frame);
}

sub complete_resolved_value {
  my ($self, $value, $path_frame) = @_;
  return $self->_complete_via_code($value, $path_frame);
}

sub complete_generic {
  my ($self, $value, $path_frame) = @_;
  return $self->scalar_outcome($value);
}

sub complete_object {
  my ($self, $value, $path_frame) = @_;
  return $self->complete_object_value($value, $path_frame);
}

sub complete_list {
  my ($self, $value, $path_frame) = @_;
  return $self->complete_list_value($value, $path_frame);
}

sub complete_abstract {
  my ($self, $value, $path_frame) = @_;
  return $self->complete_abstract_value($value, $path_frame);
}

sub execute_child_block {
  my ($self, $block_index, $source, $path_frame) = @_;
  return $self->execute_block($block_index, $source, $path_frame);
}

sub current_child_block {
  my ($self) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_current_child_block_xs($self);
}

sub current_abstract_child_block {
  my ($self, $runtime_type_name) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_current_abstract_child_block_xs($self, $runtime_type_name);
}

sub build_lazy_info_for_current_field {
  my ($self, $path_frame) = @_;
  my $field_name = $self->current_field_name;
  my $return_type = $self->current_return_type;
  my $parent_type = $self->current_parent_type;
  my $path = $self->current_path($path_frame);
  return GraphQL::Houtou::Runtime::LazyInfo->new(
    state => $self,
    runtime_schema => $self->runtime_schema,
    block => undef,
    instruction => undef,
    path_frame => $path_frame,
    field_name => $field_name,
    return_type => $return_type,
    parent_type => $parent_type,
    path => $path,
    variable_values => $self->variables,
    root_value => $self->root_value,
    context_value => $self->context,
    operation => $self->program,
  );
}

sub resolve_args_for_current_field {
  my ($self) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_resolve_args_for_current_field_xs($self);
}

sub object_outcome_from_child_block {
  my ($self, $block_index, $value, $path_frame) = @_;
  my $child_value = $self->execute_child_block($block_index, $value, $path_frame);
  if ($self->promise_code && is_promise_value($self->promise_code, $child_value)) {
    return then_promise($self->promise_code, $child_value, sub {
      return GraphQL::Houtou::XS::VM::outcome_object_xs(
        $_[0],
        undef,
      );
    });
  }
  return GraphQL::Houtou::XS::VM::outcome_object_xs(
    $child_value,
    undef,
  );
}

sub scalar_outcome {
  my ($self, $value, $error_record) = @_;
  return GraphQL::Houtou::XS::VM::outcome_scalar_xs(
    $value,
    ($error_record ? [ $error_record ] : []),
  );
}

sub complete_object_value {
  my ($self, $value, $path_frame) = @_;
  return $self->scalar_outcome(undef) if !defined $value;
  my $child = $self->current_child_block;
  return $self->scalar_outcome($value) if !$child;
  return $self->object_outcome_from_child_block($child, $value, $path_frame);
}

sub complete_list_value {
  my ($self, $value, $path_frame) = @_;
  return $self->scalar_outcome(undef) if !defined $value;
  return $self->scalar_outcome($value) if ref($value) ne 'ARRAY';

  my $child = $self->current_child_block;
    my @items;
  for my $i (0 .. $#$value) {
    my $item_path = GraphQL::Houtou::XS::VM::path_frame_new_xs(
      'GraphQL::Houtou::Runtime::PathFrame',
      $path_frame,
      $i,
    );
    push @items, $child ? $self->execute_block($child, $value->[$i], $item_path) : $value->[$i];
  }

  if ($self->promise_code && grep { is_promise_value($self->promise_code, $_) } @items) {
    my $aggregate = GraphQL::Houtou::Promise::Adapter::all_promise($self->promise_code, @items);
    return then_promise($self->promise_code, $aggregate, sub {
      my @resolved = _promise_all_values_to_array(@_);
      return GraphQL::Houtou::XS::VM::outcome_list_xs(
        \@resolved,
        undef,
      );
    });
  }

  return GraphQL::Houtou::XS::VM::outcome_list_xs(
    \@items,
    undef,
  );
}

sub complete_abstract_value {
  my ($self, $value, $path_frame) = @_;
  return $self->scalar_outcome(undef) if !defined $value;

  my ($runtime_type, $error_record) = $self->resolve_runtime_type_for_current_field($value, $path_frame);
  return $self->scalar_outcome(undef, $error_record) if $error_record;
  return $self->scalar_outcome($value) if !$runtime_type;

  my $child = $self->current_abstract_child_block($runtime_type->name);
  return $self->scalar_outcome($value) if !$child;

  return $self->object_outcome_from_child_block($child, $value, $path_frame);
}

sub resolve_runtime_type_for_current_field {
  my ($self, $value, $path_frame, %args) = @_;
  my $cache = $self->runtime_schema->runtime_cache;
  my $abstract_type = $self->current_return_type;
  return if !$abstract_type;
  my $abstract_name = $abstract_type->name;
  my $has_callbacks =
       $cache->{tag_resolver_map}{$abstract_name}
    || $cache->{resolve_type_map}{$abstract_name}
    || @{ $cache->{possible_types}{$abstract_name} || [] };
  my $info = $args{info};
  if (!$info && $has_callbacks) {
    my $field_name = $self->current_field_name;
    my $return_type = $self->current_return_type;
    my $parent_type = $self->current_parent_type;
    my $path = $self->current_path($path_frame);
    if ($args{info_builder}) {
      $info = $args{info_builder}->();
    }
    $info ||= GraphQL::Houtou::Runtime::LazyInfo->new(
      state => $self,
      runtime_schema => $self->runtime_schema,
      block => undef,
      instruction => undef,
      path_frame => $path_frame,
      field_name => $field_name,
      return_type => $return_type,
      parent_type => $parent_type,
      path => $path,
      variable_values => $self->variables,
      root_value => $self->root_value,
      context_value => $self->context,
      operation => $self->program,
    );
  }

  my ($runtime_type, $error) = GraphQL::Houtou::XS::VM::resolve_runtime_type_for_abstract_xs(
    $cache,
    $abstract_name,
    $value,
    $self->context,
    $info,
    $abstract_type,
  );
  return (undef, $self->_error_record($error, $path_frame)) if defined $error;
  return (undef, undef) if !defined $runtime_type;
  return ($runtime_type, undef);
}

sub execute_block {
  my ($self, $block_index, $source, $base_path) = @_;
  if (!$self->promise_code) {
    GraphQL::Houtou::_bootstrap_xs();
    return GraphQL::Houtou::XS::VM::exec_state_execute_block_index_xs(
      $self,
      $block_index,
      $source,
      $base_path,
    );
  }
  return $self->_execute_block_perl($block_index, $source, $base_path);
}

sub _execute_block_perl {
  my ($self, $block_index, $source, $base_path) = @_;
  my ($snapshot) = $self->enter_block($block_index);
  while (1) {
    last if !$self->advance_current_op;
    next if !$self->should_execute_current_op;
    $self->enter_current_field($source, $base_path);
    my $outcome = $self->_run_via_code;
    $self->consume_current_field_outcome($outcome);
  }
  return $self->finalize_current_block($snapshot);
}

sub _resolve_via_code {
  my ($self, $source, $path_frame) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  my $code = GraphQL::Houtou::XS::VM::exec_state_current_resolve_code_xs($self);
  return GraphQL::Houtou::XS::VM::exec_state_resolve_current_value_xs(
    $self,
    $source,
    $path_frame,
  ) if !$code;
  return $self->resolve_explicit($source, $path_frame)
    if $code == RESOLVE_EXPLICIT_CODE;
  return $self->resolve_default($source, $path_frame);
}

sub _complete_via_code {
  my ($self, $value, $path_frame) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  my $code = GraphQL::Houtou::XS::VM::exec_state_current_complete_code_xs($self);
  return $self->complete_object($value, $path_frame)
    if $code == COMPLETE_OBJECT_CODE;
  return $self->complete_list($value, $path_frame)
    if $code == COMPLETE_LIST_CODE;
  return $self->complete_abstract($value, $path_frame)
    if $code == COMPLETE_ABSTRACT_CODE;
  return $self->complete_generic($value, $path_frame);
}

sub _run_via_code {
  my ($self) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  my $opcode = GraphQL::Houtou::XS::VM::exec_state_current_opcode_code_xs($self);

  return $self->run_default_generic if $opcode == ((RESOLVE_DEFAULT_CODE * 16) + COMPLETE_GENERIC_CODE);
  return $self->run_default_object  if $opcode == ((RESOLVE_DEFAULT_CODE * 16) + COMPLETE_OBJECT_CODE);
  return $self->run_default_list    if $opcode == ((RESOLVE_DEFAULT_CODE * 16) + COMPLETE_LIST_CODE);
  return $self->run_default_abstract if $opcode == ((RESOLVE_DEFAULT_CODE * 16) + COMPLETE_ABSTRACT_CODE);
  return $self->run_explicit_generic if $opcode == ((RESOLVE_EXPLICIT_CODE * 16) + COMPLETE_GENERIC_CODE);
  return $self->run_explicit_object if $opcode == ((RESOLVE_EXPLICIT_CODE * 16) + COMPLETE_OBJECT_CODE);
  return $self->run_explicit_list   if $opcode == ((RESOLVE_EXPLICIT_CODE * 16) + COMPLETE_LIST_CODE);
  return $self->run_explicit_abstract if $opcode == ((RESOLVE_EXPLICIT_CODE * 16) + COMPLETE_ABSTRACT_CODE);

  return $self->execute_current_op;
}

sub finalize_response {
  my ($self, $data) = @_;
  if (!$self->promise_code) {
    GraphQL::Houtou::_bootstrap_xs();
    return GraphQL::Houtou::XS::VM::exec_state_run_program_xs($self, $self->root_value)
      if !defined $data;
  return {
    data => $data,
    errors => GraphQL::Houtou::XS::VM::writer_materialize_errors_xs($self->writer),
  };
}
if ($self->promise_code && is_promise_value($self->promise_code, $data)) {
  return then_promise($self->promise_code, $data, sub {
    return {
      data => $_[0],
      errors => GraphQL::Houtou::XS::VM::writer_materialize_errors_xs($self->writer),
    };
  });
}
return {
  data => $data,
  errors => GraphQL::Houtou::XS::VM::writer_materialize_errors_xs($self->writer),
};
}

sub should_execute_current_op {
  my ($self) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::exec_state_should_execute_current_op_xs($self) ? 1 : 0;
}

sub _capture_eval {
  my ($self, $cb) = @_;
  my $ok = eval { 1 };
  my $result;
  $ok = eval {
    $result = $cb->();
    1;
  };
  return (0, $@) if !$ok;
  return (1, $result);
}

sub _error_record {
  my ($self, $error, $path_frame) = @_;
  chomp $error if defined $error;
  return GraphQL::Houtou::Runtime::ErrorRecord->new(
    message => "$error",
    path_frame => $path_frame,
  );
}

sub _error_outcome {
  my ($self, $error, $path_frame) = @_;
  return GraphQL::Houtou::XS::VM::outcome_scalar_xs(
    undef,
    [ $self->_error_record($error, $path_frame) ],
  );
}

sub _promise_all_values_to_array {
  return @{ $_[0] } if @_ == 1 && ref($_[0]) eq 'ARRAY';
  return @_;
}

1;
