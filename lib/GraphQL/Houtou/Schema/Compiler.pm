package GraphQL::Houtou::Schema::Compiler;

use 5.014;
use strict;
use warnings;

use Exporter 'import';
use Scalar::Util qw(blessed refaddr);

our @EXPORT_OK = qw(
  compile_schema
);

sub compile_schema {
  my ($schema) = @_;

  die "compile_schema expects a GraphQL::Schema instance\n"
    if !blessed($schema) || !$schema->isa('GraphQL::Schema');

  my $name2type = $schema->name2type || {};
  my %compiled_types = map {
    my $type = $name2type->{$_};
    ($_ => _compile_named_type($schema, $type))
  } sort keys %$name2type;

  my %interface_implementations;
  my %possible_types;

  for my $type_name (sort keys %compiled_types) {
    my $compiled = $compiled_types{$type_name};
    if ($compiled->{kind} eq 'OBJECT') {
      for my $iface (@{ $compiled->{interfaces} || [] }) {
        push @{ $interface_implementations{$iface} ||= [] }, $type_name;
      }
    }
    if ($compiled->{kind} eq 'INTERFACE' || $compiled->{kind} eq 'UNION') {
      my @possible = map $_->name, @{ $schema->get_possible_types($name2type->{$type_name}) || [] };
      $possible_types{$type_name} = \@possible;
    }
  }

  my %compiled_directives = map {
    my $directive = $_;
    ($directive->name => _compile_directive($directive))
  } @{ $schema->directives || [] };

  return {
    roots => {
      query => $schema->query ? $schema->query->name : undef,
      mutation => $schema->mutation ? $schema->mutation->name : undef,
      subscription => $schema->subscription ? $schema->subscription->name : undef,
    },
    types => \%compiled_types,
    directives => \%compiled_directives,
    interface_implementations => \%interface_implementations,
    possible_types => \%possible_types,
    source_schema => $schema,
  };
}

sub _compile_named_type {
  my ($schema, $type) = @_;

  my $compiled = {
    kind => _named_type_kind($type),
    name => $type->name,
    class => ref($type),
    description => eval { $type->description },
    type_string => $type->to_string,
    source_type => $type,
    source_type_id => refaddr($type),
    is_input => $type->DOES('GraphQL::Role::Input') ? 1 : 0,
    is_output => $type->DOES('GraphQL::Role::Output') ? 1 : 0,
    is_abstract => $type->DOES('GraphQL::Role::Abstract') ? 1 : 0,
    is_introspection => $type->{is_introspection} ? 1 : 0,
  };

  if ($type->isa('GraphQL::Type::Object')) {
    $compiled->{interfaces} = [ map $_->name, @{ $type->interfaces || [] } ];
    $compiled->{fields} = _compile_fields($type->fields || {});
    $compiled->{is_type_of} = $type->is_type_of if $type->is_type_of;
  } elsif ($type->isa('GraphQL::Type::Interface')) {
    $compiled->{fields} = _compile_fields($type->fields || {});
    $compiled->{resolve_type} = $type->resolve_type if $type->resolve_type;
  } elsif ($type->isa('GraphQL::Type::Union')) {
    $compiled->{types} = [ map $_->name, @{ $type->get_types || [] } ];
    $compiled->{resolve_type} = $type->resolve_type if $type->resolve_type;
  } elsif ($type->isa('GraphQL::Type::InputObject')) {
    $compiled->{fields} = _compile_input_fields($type->fields || {});
  } elsif ($type->isa('GraphQL::Type::Enum')) {
    $compiled->{values} = _compile_enum_values($type->values || {});
  } elsif ($type->isa('GraphQL::Type::Scalar')) {
    $compiled->{serialize} = $type->serialize if $type->serialize;
    $compiled->{parse_value} = $type->parse_value if $type->parse_value;
  }

  return $compiled;
}

sub _compile_fields {
  my ($fields) = @_;

  my %compiled = map {
    my $field_name = $_;
    my $field = $fields->{$field_name} || {};
    ($field_name => {
      name => $field_name,
      type => _compile_type_ref($field->{type}),
      description => $field->{description},
      deprecation_reason => $field->{deprecation_reason},
      is_deprecated => $field->{is_deprecated} ? 1 : 0,
      directives => _compile_directive_instances($field->{directives}),
      args => _compile_input_fields($field->{args} || {}),
      resolve => $field->{resolve},
      subscribe => $field->{subscribe},
      source_field => $field,
    })
  } sort keys %$fields;

  return \%compiled;
}

sub _compile_input_fields {
  my ($fields) = @_;

  my %compiled = map {
    my $field_name = $_;
    my $field = $fields->{$field_name} || {};
    ($field_name => {
      name => $field_name,
      type => _compile_type_ref($field->{type}),
      description => $field->{description},
      default_value => exists $field->{default_value} ? $field->{default_value} : undef,
      has_default_value => exists $field->{default_value} ? 1 : 0,
      directives => _compile_directive_instances($field->{directives}),
      deprecation_reason => $field->{deprecation_reason},
      is_deprecated => $field->{is_deprecated} ? 1 : 0,
      source_field => $field,
    })
  } sort keys %$fields;

  return \%compiled;
}

sub _compile_enum_values {
  my ($values) = @_;

  my %compiled = map {
    my $enum_name = $_;
    my $value = $values->{$enum_name} || {};
    ($enum_name => {
      name => $enum_name,
      value => exists $value->{value} ? $value->{value} : $enum_name,
      description => $value->{description},
      deprecation_reason => $value->{deprecation_reason},
      is_deprecated => $value->{is_deprecated} ? 1 : 0,
      source_value => $value,
    })
  } sort keys %$values;

  return \%compiled;
}

sub _compile_directive {
  my ($directive) = @_;

  return {
    name => $directive->name,
    class => ref($directive),
    description => $directive->description,
    locations => [ @{ $directive->locations || [] } ],
    args => _compile_input_fields($directive->args || {}),
    source_directive => $directive,
  };
}

sub _compile_directive_instances {
  my ($directives) = @_;

  return [] if !$directives || !@$directives;

  return [
    map {
      +{
        name => $_->{name},
        arguments => $_->{arguments} ? { %{ $_->{arguments} } } : {},
        source_directive => $_,
      }
    } @$directives
  ];
}

sub _compile_type_ref {
  my ($type) = @_;

  die "cannot compile undefined GraphQL type reference\n" if !$type;

  if ($type->isa('GraphQL::Type::NonNull')) {
    return {
      kind => 'NON_NULL',
      of => _compile_type_ref($type->of),
      type_string => $type->to_string,
      source_type => $type,
      source_type_id => refaddr($type),
    };
  }

  if ($type->isa('GraphQL::Type::List')) {
    return {
      kind => 'LIST',
      of => _compile_type_ref($type->of),
      type_string => $type->to_string,
      source_type => $type,
      source_type_id => refaddr($type),
    };
  }

  return {
    kind => 'NAMED',
    name => $type->name,
    named_kind => _named_type_kind($type),
    type_string => $type->to_string,
    source_type => $type,
    source_type_id => refaddr($type),
  };
}

sub _named_type_kind {
  my ($type) = @_;

  return 'SCALAR' if $type->isa('GraphQL::Type::Scalar');
  return 'OBJECT' if $type->isa('GraphQL::Type::Object');
  return 'INTERFACE' if $type->isa('GraphQL::Type::Interface');
  return 'UNION' if $type->isa('GraphQL::Type::Union');
  return 'ENUM' if $type->isa('GraphQL::Type::Enum');
  return 'INPUT_OBJECT' if $type->isa('GraphQL::Type::InputObject');

  die "unknown GraphQL named type class @{[ref $type]}\n";
}

1;

__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou::Schema::Compiler - Compile graphql-perl schema objects into a normalized internal form

=head1 SYNOPSIS

    use GraphQL::Houtou::Schema::Compiler qw(compile_schema);

    my $compiled = compile_schema($schema);

=head1 DESCRIPTION

This module turns a C<GraphQL::Schema> object from the upstream C<GraphQL>
distribution into a normalized Perl data structure that is easier to
consume from future XS execution and validation layers.

The current implementation is intentionally conservative: it preserves the
public schema/type API while producing a pre-walked representation of roots,
types, fields, arguments, directives, and abstract type relations.

=cut
