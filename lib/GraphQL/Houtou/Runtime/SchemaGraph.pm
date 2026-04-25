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
    program => $args{program},
  }, $class;
}

sub version { return $_[0]{version} }
sub schema { return $_[0]{schema} }
sub runtime_cache { return $_[0]{runtime_cache} }
sub type_index { return $_[0]{type_index} }
sub dispatch_index { return $_[0]{dispatch_index} }
sub root_types { return $_[0]{root_types} }
sub program { return $_[0]{program} }

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

sub inflate_operation {
  my ($self, $descriptor) = @_;
  require GraphQL::Houtou::Runtime::OperationCompiler;
  return GraphQL::Houtou::Runtime::OperationCompiler->inflate_operation($self, $descriptor);
}

sub execute_operation {
  my ($self, $program, %opts) = @_;
  require GraphQL::Houtou::Runtime::Executor;
  return GraphQL::Houtou::Runtime::Executor->execute_operation($self, $program, %opts);
}

sub to_struct {
  my ($self) = @_;
  return {
    version => $self->{version},
    root_types => { %{ $self->{root_types} || {} } },
    type_index => { %{ $self->{type_index} || {} } },
    dispatch_index => { %{ $self->{dispatch_index} || {} } },
    program => $self->{program} ? $self->{program}->to_struct : undef,
  };
}

1;
