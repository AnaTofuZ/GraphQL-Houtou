package GraphQL::Houtou::Runtime::DirectiveRuntime;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use JSON::MaybeXS qw(is_bool);

our @EXPORT_OK = qw(
  has_runtime_directives
  apply_runtime_directives
  slot_needs_runtime_wrapper
  wrap_field_resolver
  materialize_runtime_directives
  materialize_program_runtime_directives
);

sub has_runtime_directives {
  my ($schema) = @_;
  return 0 if !$schema;
  for my $directive (@{ $schema->directives || [] }) {
    next if !$directive;
    next if !$directive->can('has_runtime_hook') || !$directive->has_runtime_hook;
    return 1 if $directive->has_executable_location;
  }
  return 0;
}

sub slot_needs_runtime_wrapper {
  my (%args) = @_;
  my $field = $args{field} || {};
  return 0 if ref($field) ne 'HASH';
  return @{ $field->{directives} || [] } ? 1 : 0;
}

sub wrap_field_resolver {
  my (%args) = @_;
  my $schema = $args{schema};
  my $field_name = $args{field_name};
  my $field = $args{field} || {};
  my $base_resolver = $args{resolver};
  my $is_typename = ($field_name || q()) eq '__typename' ? 1 : 0;

  my $directive_defs = $schema ? ($schema->name2directive || {}) : {};
  my $schema_directives = $field->{directives} || [];

  return sub {
    my ($source, $field_args, $context, $info, $return_type) = @_;
    my $resolver = sub {
      return _default_field_resolver($source, $field_name, $info)
        if !$base_resolver;
      return $base_resolver->($source, $field_args, $context, $info, $return_type);
    };

    return $resolver->() if !@$schema_directives && !$is_typename;

    for my $instance (reverse @$schema_directives) {
      next if !$instance || ref($instance) ne 'HASH';
      my $name = $instance->{name} || next;
      my $directive = $directive_defs->{$name} || next;
      next if !$directive->can('resolve_field');
      my $middleware = $directive->resolve_field || next;
      my $directive_args = $instance->{arguments} || {};
      my $next = $resolver;
      $resolver = sub {
        return $middleware->(
          $next,
          $source,
          $field_args,
          $context,
          $info,
          $return_type,
          $directive_args,
          $directive,
        );
      };
    }

    return $resolver->();
  };
}

sub apply_runtime_directives {
  my ($runtime_schema, $source, $field_args, $context, $info, $return_type, $resolved_value) = @_;
  my $schema = _resolve_schema($runtime_schema);
  return $resolved_value if !$schema;

  my $directive_defs = $schema->name2directive || {};
  my $runtime_directives = _runtime_directives_from_info($info);
  return $resolved_value if !@$runtime_directives;

  my $resolver = sub { $resolved_value };
  for my $instance (reverse @$runtime_directives) {
    next if !$instance || ref($instance) ne 'HASH';
    my $name = $instance->{name} || next;
    my $directive = $directive_defs->{$name} || next;
    next if !$directive->can('resolve_field');
    my $middleware = $directive->resolve_field || next;
    my $directive_args = $instance->{arguments} || {};
    my $next = $resolver;
    $resolver = sub {
      return $middleware->(
        $next,
        $source,
        $field_args,
        $context,
        $info,
        $return_type,
        $directive_args,
        $directive,
      );
    };
  }

  return $resolver->();
}

sub _runtime_directives_from_info {
  my ($info) = @_;
  return [] if !$info;

  my $runtime_directives = $info->{directives} || [];
  return $runtime_directives if @$runtime_directives;

  my $program = $info->{operation};
  my $block_index = $info->{block_index};
  my $op_index = $info->{op_index};
  return [] if !defined $block_index || !defined $op_index;

  return materialize_program_runtime_directives(
    $program,
    $block_index,
    $op_index,
    $info->{variable_values} || {},
  );
}

sub materialize_runtime_directives {
  my ($payload, $variables) = @_;
  return [] if !$payload;
  return _materialize_value($payload, $variables || {});
}

sub materialize_program_runtime_directives {
  my ($program, $block_index, $op_index, $variables) = @_;
  return [] if !defined $block_index || !defined $op_index;
  my $descriptor = _program_descriptor($program);
  return [] if !$descriptor;
  my $blocks = $descriptor->{blocks_compact} || $descriptor->{blocks} || [];
  my $block = $blocks->[$block_index] || return [];
  my $ops = ref($block) eq 'ARRAY' ? ($block->[4] || []) : ($block->{ops} || []);
  my $op = $ops->[$op_index] || return [];

  if (ref($op) eq 'ARRAY') {
    return [] if !$op->[20];
    return materialize_runtime_directives($op->[19], $variables);
  }

  return [] if !$op->{has_runtime_directives};
  return materialize_runtime_directives($op->{runtime_directives_payload}, $variables);
}

sub _default_field_resolver {
  my ($source, $field_name, $info) = @_;
  return undef if !defined $field_name;

  if ($field_name eq '__typename') {
    my $parent_type = $info ? $info->{parent_type} : undef;
    return $parent_type && $parent_type->can('name') ? $parent_type->name : undef;
  }

  if ($source && ref($source) eq 'HASH') {
    return $source->{$field_name};
  }

  return undef if !$source || !ref($source) || !$source->can($field_name);
  return $source->$field_name;
}

sub _program_descriptor {
  my ($program) = @_;
  return if !$program;
  if (ref($program) && eval { $program->isa('GraphQL::Houtou::Runtime::NativeProgram') }) {
    GraphQL::Houtou::_bootstrap_xs();
    return GraphQL::Houtou::XS::VM::native_program_descriptor_xs($program);
  }
  return $program if ref($program) eq 'HASH';
  return;
}

sub _resolve_schema {
  my ($runtime_schema) = @_;
  return if !$runtime_schema;
  return $runtime_schema if ref($runtime_schema) && eval { $runtime_schema->can('name2directive') };
  return $runtime_schema->{schema}
    if ref($runtime_schema) eq 'HASH'
    && ref($runtime_schema->{schema})
    && eval { $runtime_schema->{schema}->can('name2directive') };
  return;
}

sub _materialize_value {
  my ($value, $variables) = @_;
  my $ref = ref($value);
  return $value if !$ref;
  return $value ? 1 : 0 if is_bool($value);
  return _materialize_variable($$value, $variables) if $ref eq 'SCALAR';
  return _materialize_value($$value, $variables) if $ref eq 'REF';
  return [ map { _materialize_value($_, $variables) } @$value ] if $ref eq 'ARRAY';
  return {
    map { $_ => _materialize_value($value->{$_}, $variables) }
      keys %$value
  } if $ref eq 'HASH';
  return $value;
}

sub _materialize_variable {
  my ($name, $variables) = @_;
  return undef if !defined $name;
  return exists $variables->{$name} ? $variables->{$name} : undef;
}

1;
