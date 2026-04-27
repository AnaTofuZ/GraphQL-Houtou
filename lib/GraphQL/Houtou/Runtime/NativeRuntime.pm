package GraphQL::Houtou::Runtime::NativeRuntime;

use 5.014;
use strict;
use warnings;

use GraphQL::Houtou::Native ();
use GraphQL::Houtou::Runtime::InputCoercion ();
use GraphQL::Houtou::Runtime::VMCompiler ();
use GraphQL::Houtou::Schema ();
use JSON::PP ();

sub new {
  my ($class, %args) = @_;
  die "runtime_schema is required\n" if !$args{runtime_schema};
  return bless {
    runtime_schema => $args{runtime_schema},
    native_runtime_struct => $args{native_runtime_struct},
    native_runtime_compact_struct => $args{native_runtime_compact_struct},
    native_runtime_handle => $args{native_runtime_handle},
  }, $class;
}

sub runtime_schema { return $_[0]{runtime_schema} }

sub native_runtime_struct {
  my ($self) = @_;
  $self->{native_runtime_struct} ||= $self->runtime_schema->to_native_exec_struct;
  return $self->{native_runtime_struct};
}

sub native_runtime_compact_struct {
  my ($self) = @_;
  $self->{native_runtime_compact_struct} ||= $self->runtime_schema->to_native_compact_struct;
  return $self->{native_runtime_compact_struct};
}

sub native_runtime_handle {
  my ($self) = @_;
  $self->{native_runtime_handle} ||= GraphQL::Houtou::Native::load_native_runtime(
    $self->native_runtime_struct,
  );
  return $self->{native_runtime_handle};
}

sub compile_program {
  my ($self, $document, %opts) = @_;
  return $self->runtime_schema->compile_program($document, %opts);
}

sub compile_bundle_for_document {
  my ($self, $document, %opts) = @_;
  my $program = $self->compile_program($document, %opts);
  return $self->compile_bundle($program, %opts);
}

sub specialize_program {
  my ($self, $program, %opts) = @_;
  my $candidate = __PACKAGE__->specialize_program_for_native(
    $self->runtime_schema,
    $program,
    %opts,
  );
  my $engine = __PACKAGE__->preferred_engine_for_program($candidate, %opts);
  die "Program cannot be specialized into the native VM path.\n" if $engine ne 'native';
  return $candidate;
}

sub specialize_program_for_native {
  my ($class, $runtime_schema, $program, %opts) = @_;
  return $program if !$program;

  my $variables = GraphQL::Houtou::Runtime::InputCoercion::prepare_variables(
    $runtime_schema,
    $program,
    $opts{variables} || {},
  );
  my $clone = GraphQL::Houtou::Runtime::VMCompiler->inflate_program(
    $runtime_schema,
    $program->to_struct,
  );

  for my $block (@{ $clone->blocks || [] }) {
    my @ops;
    for my $op (@{ $block->ops || [] }) {
      next if !_specialize_directives($op, $variables);
      _specialize_args($runtime_schema, $op, $variables);
      push @ops, $op;
    }
    $block->set_ops(\@ops);
  }

  $clone->set_variable_defs({});
  return $clone;
}

sub preferred_engine_for_program {
  my ($class, $program, %opts) = @_;
  return 'perl' if $opts{promise_code};
  return 'perl' if !$program || !$program->can('blocks');
  return 'perl' if keys %{ $program->variable_defs || {} };

  for my $block (@{ $program->blocks || [] }) {
    for my $op (@{ $block->ops || [] }) {
      return 'perl' if $op->has_directives;
      my $slot = $op->bound_slot or next;
      my $shape = $slot->resolver_shape || q();
      my $mode = $slot->resolver_mode || q();
      if ($shape ne 'DEFAULT') {
        return 'perl' if $shape ne 'EXPLICIT';
        return 'perl' if $mode ne 'NATIVE';
      }
      if ($op->has_args) {
        my $args_mode = $op->args_mode || q();
        return 'perl' if $args_mode ne 'STATIC';
      }
      my $dispatch = $slot->dispatch_family || q();
      return 'perl'
        if $dispatch ne 'GENERIC'
        && $dispatch ne 'TAG'
        && $dispatch ne 'OBJECT'
        && $dispatch ne 'LIST'
        && $dispatch ne 'ABSTRACT';
    }
  }

  return 'native';
}

sub compile_bundle {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program($program, %opts);
  return $self->load_bundle_parts($candidate);
}

sub compile_bundle_descriptor {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program($program, %opts);
  return {
    runtime => $self->native_runtime_compact_struct,
    program => $candidate->to_native_compact_struct,
  };
}

sub compile_bundle_descriptor_for_document {
  my ($self, $document, %opts) = @_;
  my $program = $self->compile_program($document, %opts);
  return $self->compact_bundle_descriptor($program);
}

sub compact_bundle_descriptor {
  my ($self, $program) = @_;
  return {
    runtime => $self->native_runtime_compact_struct,
    program => $program->to_native_compact_struct,
  };
}

sub load_bundle_parts {
  my ($self, $program) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::load_native_bundle_parts_xs(
    $self->native_runtime_compact_struct,
    $program->to_native_compact_struct,
  );
}

sub load_bundle_descriptor {
  my ($self, $descriptor) = @_;
  return GraphQL::Houtou::Native::load_native_bundle($descriptor);
}

sub inflate_bundle_descriptor {
  my ($self, $descriptor) = @_;
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_native_bundle(
    $self->runtime_schema,
    $descriptor,
  );
}

sub dump_bundle_descriptor {
  my ($self, $program, $path, %opts) = @_;
  my $descriptor = $self->compile_bundle_descriptor($program, %opts);
  open my $fh, '>', $path or die "Cannot open $path for write: $!";
  print {$fh} JSON::PP::encode_json($descriptor);
  close $fh;
  return $descriptor;
}

sub dump_bundle_descriptor_for_document {
  my ($self, $document, $path, %opts) = @_;
  my $descriptor = $self->compile_bundle_descriptor_for_document($document, %opts);
  open my $fh, '>', $path or die "Cannot open $path for write: $!";
  print {$fh} JSON::PP::encode_json($descriptor);
  close $fh;
  return $descriptor;
}

sub load_bundle_descriptor_file {
  my ($self, $path) = @_;
  open my $fh, '<', $path or die "Cannot open $path for read: $!";
  local $/;
  my $json = <$fh>;
  close $fh;
  my $descriptor = JSON::PP::decode_json($json);
  return $self->load_bundle_descriptor($descriptor);
}

sub execute_program {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program($program, %opts);
  return $self->execute_compact_program($candidate, %opts);
}

sub execute_compact_program {
  my ($self, $program, %opts) = @_;
  return GraphQL::Houtou::Native::execute_native_program(
    $self->native_runtime_handle,
    $self->native_runtime_compact_struct,
    $program->to_native_compact_struct,
    $opts{root_value},
    $opts{context},
  );
}

sub execute_bundle_descriptor {
  my ($self, $descriptor, %opts) = @_;
  my $bundle = $self->load_bundle_descriptor($descriptor);
  return $self->execute_bundle($bundle, %opts);
}

sub execute_document {
  my ($self, $document, %opts) = @_;
  my $program = $self->compile_program($document, %opts);
  return $self->execute_program($program, %opts);
}

sub execute_bundle {
  my ($self, $bundle, %opts) = @_;
  return GraphQL::Houtou::Native::execute_native_bundle(
    $self->native_runtime_handle,
    $bundle,
    $opts{root_value},
    $opts{context},
  );
}

sub _specialize_directives {
  my ($op, $variables) = @_;
  my $mode = $op->directives_mode || 'NONE';
  return 1 if $mode eq 'NONE';

  my $guards = $op->directives_payload || [];
  return 0 if !GraphQL::Houtou::Runtime::InputCoercion::evaluate_runtime_guards($guards, $variables);

  $op->set_has_directives(0);
  $op->set_directives_mode('NONE');
  $op->set_directives_payload(undef);
  return 1;
}

sub _specialize_args {
  my ($runtime_schema, $op, $variables) = @_;
  my $arg_defs = $op->arg_defs || {};
  if (!keys %$arg_defs) {
    $op->set_has_args(0);
    $op->set_args_mode('NONE');
    $op->set_args_payload(undef);
    return;
  }

  my $mode = $op->args_mode || 'NONE';
  my $payload = $op->args_payload || {};
  my $coerced = $mode eq 'DYNAMIC'
    ? GraphQL::Houtou::Runtime::InputCoercion::coerce_dynamic_args($runtime_schema, $arg_defs, $payload, $variables)
    : GraphQL::Houtou::Runtime::InputCoercion::coerce_static_args($runtime_schema, $arg_defs, $payload);

  my $has_args = keys %$coerced ? 1 : 0;
  $op->set_has_args($has_args);
  $op->set_args_mode($has_args ? 'STATIC' : 'NONE');
  $op->set_args_payload($has_args ? $coerced : undef);
}

1;
