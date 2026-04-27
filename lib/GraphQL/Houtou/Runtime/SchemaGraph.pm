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
  require GraphQL::Houtou::Runtime;
  return GraphQL::Houtou::Runtime::execute_program($self, $program, %opts);
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

sub _dispatch_family_code {
  my ($family) = @_;
  return 2 if ($family || q()) eq 'RESOLVE_TYPE';
  return 3 if ($family || q()) eq 'TAG';
  return 4 if ($family || q()) eq 'POSSIBLE_TYPES';
  return 1;
}

1;
