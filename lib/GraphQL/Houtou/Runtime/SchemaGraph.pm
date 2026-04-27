package GraphQL::Houtou::Runtime::SchemaGraph;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    version => $args{version} || 1,
    schema => $args{schema},
    runtime_cache => $args{runtime_cache} || {},
    type_index => $args{type_index} || {},
    dispatch_index => $args{dispatch_index} || {},
    root_types => $args{root_types} || {},
    slot_catalog => $args{slot_catalog} || [],
    blocks => $args{blocks} || [],
    root_blocks => $args{root_blocks} || {},
  }, $class;
}

sub version { return $_[0]{version} }
sub schema { return $_[0]{schema} }
sub runtime_cache { return $_[0]{runtime_cache} }
sub type_index { return $_[0]{type_index} }
sub dispatch_index { return $_[0]{dispatch_index} }
sub root_types { return $_[0]{root_types} }
sub slot_catalog { return $_[0]{slot_catalog} }
sub blocks { return $_[0]{blocks} }
sub root_blocks { return $_[0]{root_blocks} }

sub slot_by_index {
  my ($self, $index) = @_;
  return if !defined $index;
  return $self->{slot_catalog}[$index];
}

sub root_block {
  my ($self, $name) = @_;
  return $self->{root_blocks}{$name};
}

sub block_by_type_name {
  my ($self, $type_name) = @_;
  return if !defined $type_name;
  for my $block (@{ $self->{blocks} || [] }) {
    next if !defined $block->root_type_name;
    return $block if $block->root_type_name eq $type_name;
  }
  return;
}

sub compile_program {
  my ($self, $document, %opts) = @_;
  require GraphQL::Houtou::Runtime::OperationCompiler;
  return GraphQL::Houtou::Runtime::OperationCompiler->compile_operation($self, $document, %opts);
}

sub inflate_program {
  my ($self, $descriptor) = @_;
  require GraphQL::Houtou::Runtime::VMCompiler;
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_program($self, $descriptor);
}

sub execute_program {
  my ($self, $program, %opts) = @_;
  require GraphQL::Houtou::Runtime::NativeRuntime;
  require GraphQL::Houtou::Runtime::VMCompiler;
  require GraphQL::Houtou::Runtime::VMExecutor;
  my $vm_program = $program->isa('GraphQL::Houtou::Runtime::VMProgram')
    ? $program
    : GraphQL::Houtou::Runtime::VMCompiler->lower_program($self, $program);
  my $candidate_program = $vm_program;
  $opts{engine} = delete $opts{vm_engine}
    if !defined $opts{engine} && exists $opts{vm_engine};
  if (!defined $opts{engine} || $opts{engine} eq 'native') {
    $candidate_program = GraphQL::Houtou::Runtime::NativeRuntime->specialize_program_for_native(
      $self,
      $vm_program,
      %opts,
    );
  }
  my $engine = _preferred_engine_for_program($candidate_program, %opts);
  $engine = $opts{engine} if defined $opts{engine};
  die "Requested native engine for a program that cannot be specialized into the native VM path.\n"
    if $engine eq 'native'
    && _preferred_engine_for_program($candidate_program, %opts) ne 'native';
  return GraphQL::Houtou::Runtime::VMExecutor->execute_program($self, $vm_program, %opts)
    if $engine eq 'perl';
  my $native_runtime = GraphQL::Houtou::Runtime::NativeRuntime->new(
    runtime_schema => $self,
  );
  return $native_runtime->execute_compact_program($candidate_program, %opts);
}

sub build_native_runtime {
  my ($self) = @_;
  require GraphQL::Houtou::Runtime::NativeRuntime;
  return GraphQL::Houtou::Runtime::NativeRuntime->new(
    runtime_schema => $self,
  );
}

sub to_struct {
  my ($self) = @_;
  return {
    version => $self->{version},
    root_types => { %{ $self->{root_types} || {} } },
    type_index => { %{ $self->{type_index} || {} } },
    dispatch_index => { %{ $self->{dispatch_index} || {} } },
    slot_catalog => [ map { $_->to_struct } @{ $self->{slot_catalog} || [] } ],
    blocks => [ map { $_->to_struct } @{ $self->{blocks} || [] } ],
    root_blocks => {
      map {
        my $block = $self->{root_blocks}{$_};
        ($_ => ($block ? $block->name : undef));
      } keys %{ $self->{root_blocks} || {} }
    },
  };
}

sub to_native_struct {
  my ($self) = @_;
  return {
    version => $self->{version},
    root_types => { %{ $self->{root_types} || {} } },
    type_index => {
      map {
        my $entry = $self->{type_index}{$_} || {};
        ($_ => {
          %$entry,
          kind_code => _type_kind_code($entry->{kind}),
          completion_family_code => _family_code($entry->{completion_family}),
        });
      } keys %{ $self->{type_index} || {} }
    },
    dispatch_index => {
      map {
        my $entry = $self->{dispatch_index}{$_} || {};
        ($_ => {
          %$entry,
          dispatch_family_code => _dispatch_family_code($entry->{dispatch_family}),
        });
      } keys %{ $self->{dispatch_index} || {} }
    },
    slot_catalog => [ map { $_->to_native_struct } @{ $self->{slot_catalog} || [] } ],
  };
}

sub to_native_compact_struct {
  my ($self) = @_;
  return {
    version => $self->{version},
    root_types => { %{ $self->{root_types} || {} } },
    type_index => {
      map {
        my $entry = $self->{type_index}{$_} || {};
        ($_ => {
          %$entry,
          kind_code => _type_kind_code($entry->{kind}),
          completion_family_code => _family_code($entry->{completion_family}),
        });
      } keys %{ $self->{type_index} || {} }
    },
    dispatch_index => {
      map {
        my $entry = $self->{dispatch_index}{$_} || {};
        ($_ => {
          %$entry,
          dispatch_family_code => _dispatch_family_code($entry->{dispatch_family}),
        });
      } keys %{ $self->{dispatch_index} || {} }
    },
    slot_catalog_compact => [ map { $_->to_native_compact_struct } @{ $self->{slot_catalog} || [] } ],
  };
}

sub to_native_exec_struct {
  my ($self) = @_;
  my $struct = $self->to_native_compact_struct;
  $struct->{slot_catalog_exec} = [ map { $_->to_native_exec_struct } @{ $self->{slot_catalog} || [] } ];
  $struct->{runtime_cache} = $self->{runtime_cache};
  return $struct;
}

sub _type_kind_code {
  my ($kind) = @_;
  return 1 if ($kind || q()) eq 'SCALAR';
  return 2 if ($kind || q()) eq 'OBJECT';
  return 3 if ($kind || q()) eq 'LIST';
  return 4 if ($kind || q()) eq 'INTERFACE';
  return 5 if ($kind || q()) eq 'UNION';
  return 6 if ($kind || q()) eq 'ENUM';
  return 7 if ($kind || q()) eq 'INPUT_OBJECT';
  return 8 if ($kind || q()) eq 'NON_NULL';
  return 0;
}

sub _family_code {
  my ($family) = @_;
  return 2 if ($family || q()) eq 'OBJECT';
  return 3 if ($family || q()) eq 'LIST';
  return 4 if ($family || q()) eq 'ABSTRACT';
  return 1;
}

sub _preferred_engine_for_program {
  my ($program, %opts) = @_;
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

sub _dispatch_family_code {
  my ($family) = @_;
  return 2 if ($family || q()) eq 'RESOLVE_TYPE';
  return 3 if ($family || q()) eq 'TAG';
  return 4 if ($family || q()) eq 'POSSIBLE_TYPES';
  return 1;
}

1;
