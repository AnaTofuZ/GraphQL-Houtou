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
    program => $args{program},
  }, $class;
}

sub version { return $_[0]{version} }
sub schema { return $_[0]{schema} }
sub runtime_cache { return $_[0]{runtime_cache} }
sub type_index { return $_[0]{type_index} }
sub dispatch_index { return $_[0]{dispatch_index} }
sub root_types { return $_[0]{root_types} }
sub slot_catalog { return $_[0]{slot_catalog} }
sub program { return $_[0]{program} }

sub slot_by_index {
  my ($self, $index) = @_;
  return if !defined $index;
  return $self->{slot_catalog}[$index];
}

sub root_block {
  my ($self, $name) = @_;
  return $self->{program} ? $self->{program}->root_block($name) : undef;
}

sub block_by_type_name {
  my ($self, $type_name) = @_;
  return $self->{program} ? $self->{program}->block_by_type_name($type_name) : undef;
}

sub compile_operation {
  my ($self, $document, %opts) = @_;
  require GraphQL::Houtou::Runtime::OperationCompiler;
  return GraphQL::Houtou::Runtime::OperationCompiler->compile_operation($self, $document, %opts);
}

sub compile_program {
  my ($self, $document, %opts) = @_;
  return $self->compile_operation($document, %opts);
}

sub inflate_operation {
  my ($self, $descriptor) = @_;
  require GraphQL::Houtou::Runtime::OperationCompiler;
  return GraphQL::Houtou::Runtime::OperationCompiler->inflate_operation($self, $descriptor);
}

sub inflate_program {
  my ($self, $descriptor) = @_;
  return $self->inflate_operation($descriptor);
}

sub execute_operation {
  my ($self, $program, %opts) = @_;
  require GraphQL::Houtou::Runtime;
  return GraphQL::Houtou::Runtime::execute_operation($self, $program, %opts);
}

sub execute_program {
  my ($self, $program, %opts) = @_;
  return $self->execute_operation($program, %opts);
}

sub execute_program_perl {
  my ($self, $program, %opts) = @_;
  require GraphQL::Houtou::Runtime;
  return GraphQL::Houtou::Runtime::execute_program_perl($self, $program, %opts);
}

sub lower_vm_program {
  my ($self, $program) = @_;
  require GraphQL::Houtou::Runtime::VMCompiler;
  return GraphQL::Houtou::Runtime::VMCompiler->lower_program($self, $program);
}

sub lower_program_to_vm {
  my ($self, $program) = @_;
  return $self->lower_vm_program($program);
}

sub inflate_vm_program {
  my ($self, $descriptor) = @_;
  require GraphQL::Houtou::Runtime::VMCompiler;
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_program($self, $descriptor);
}

sub inflate_vm_native_bundle {
  my ($self, $descriptor) = @_;
  require GraphQL::Houtou::Runtime::VMCompiler;
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_native_bundle($self, $descriptor);
}

sub inflate_vm_bundle {
  my ($self, $descriptor) = @_;
  return $self->inflate_vm_native_bundle($descriptor);
}

sub execute_vm_program {
  my ($self, $program, %opts) = @_;
  require GraphQL::Houtou::Runtime;
  return GraphQL::Houtou::Runtime::execute_vm_program($self, $program, %opts);
}

sub execute_vm {
  my ($self, $program, %opts) = @_;
  return $self->execute_vm_program($program, %opts);
}

sub execute_vm_native_bundle {
  my ($self, $descriptor, %opts) = @_;
  require GraphQL::Houtou::Runtime;
  return GraphQL::Houtou::Runtime::execute_vm_native_bundle($self, $descriptor, %opts);
}

sub to_struct {
  my ($self) = @_;
  return {
    version => $self->{version},
    root_types => { %{ $self->{root_types} || {} } },
    type_index => { %{ $self->{type_index} || {} } },
    dispatch_index => { %{ $self->{dispatch_index} || {} } },
    slot_catalog => [ map { $_->to_struct } @{ $self->{slot_catalog} || [] } ],
    program => $self->{program} ? $self->{program}->to_struct : undef,
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

sub to_native_exec_struct {
  my ($self) = @_;
  my $struct = $self->to_native_struct;
  $struct->{slot_catalog} = [ map { $_->to_native_exec_struct } @{ $self->{slot_catalog} || [] } ];
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

sub _dispatch_family_code {
  my ($family) = @_;
  return 2 if ($family || q()) eq 'RESOLVE_TYPE';
  return 3 if ($family || q()) eq 'TAG';
  return 4 if ($family || q()) eq 'POSSIBLE_TYPES';
  return 1;
}

1;
