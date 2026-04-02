package GraphQL::Houtou::Adapter::GraphQLJSToGraphQLPerl;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use JSON::PP ();

our @EXPORT_OK = qw(
  convert_document
);

sub _location {
  my ($node) = @_;
  return if ref($node) ne 'HASH';
  return $node->{loc} ? { %{ $node->{loc} } } : undef;
}

sub _store_location {
  my ($hash, $node) = @_;
  my $location = _location($node);
  $hash->{location} = $location if $location;
  return $hash;
}

sub _convert_name_node {
  my ($node) = @_;
  return if !$node;
  return $node->{value};
}

sub _convert_type {
  my ($node) = @_;
  return if !$node;

  if ($node->{kind} eq 'NamedType') {
    return _convert_name_node($node->{name});
  }
  if ($node->{kind} eq 'ListType') {
    return ['list', { type => _convert_type($node->{type}) }];
  }
  if ($node->{kind} eq 'NonNullType') {
    return ['non_null', { type => _convert_type($node->{type}) }];
  }

  die "Unsupported graphql-js type node '$node->{kind}'.\n";
}

sub _convert_value {
  my ($node) = @_;
  return if !$node;

  if ($node->{kind} eq 'Variable') {
    my $name = _convert_name_node($node->{name});
    return \$name;
  }
  if ($node->{kind} eq 'IntValue' || $node->{kind} eq 'FloatValue') {
    return 0 + $node->{value};
  }
  if ($node->{kind} eq 'StringValue') {
    return $node->{value};
  }
  if ($node->{kind} eq 'BooleanValue') {
    return $node->{value} ? JSON::PP::true : JSON::PP::false;
  }
  if ($node->{kind} eq 'NullValue') {
    return undef;
  }
  if ($node->{kind} eq 'EnumValue') {
    my $value = $node->{value};
    my $inner = \$value;
    return \$inner;
  }
  if ($node->{kind} eq 'ListValue') {
    return [ map _convert_value($_), @{ $node->{values} || [] } ];
  }
  if ($node->{kind} eq 'ObjectValue') {
    my %fields = map {
      ($_->{name}{value} => _convert_value($_->{value}))
    } @{ $node->{fields} || [] };
    return \%fields;
  }

  die "Unsupported graphql-js value node '$node->{kind}'.\n";
}

sub _convert_arguments {
  my ($nodes) = @_;
  return undef if !$nodes || !@$nodes;

  my %arguments = map {
    ($_->{name}{value} => _convert_value($_->{value}))
  } @$nodes;
  return \%arguments;
}

sub _convert_directives {
  my ($nodes) = @_;
  return [] if !$nodes || !@$nodes;

  return [
    map {
      my %directive = (
        name => _convert_name_node($_->{name}),
      );
      my $arguments = _convert_arguments($_->{arguments});
      $directive{arguments} = $arguments if $arguments;
      _store_location(\%directive, $_);
      \%directive;
    } @$nodes
  ];
}

sub _convert_selection {
  my ($node) = @_;

  if ($node->{kind} eq 'Field') {
    my %field = (
      kind => 'field',
      name => _convert_name_node($node->{name}),
    );
    $field{alias} = _convert_name_node($node->{alias}) if $node->{alias};
    my $arguments = _convert_arguments($node->{arguments});
    $field{arguments} = $arguments if $arguments;
    my $directives = _convert_directives($node->{directives});
    $field{directives} = $directives if $directives && @$directives;
    $field{selections} = [ map _convert_selection($_), @{ $node->{selectionSet}{selections} || [] } ]
      if $node->{selectionSet};
    _store_location(\%field, $node);
    return \%field;
  }

  if ($node->{kind} eq 'FragmentSpread') {
    my %fragment = (
      kind => 'fragment_spread',
      name => _convert_name_node($node->{name}),
    );
    my $directives = _convert_directives($node->{directives});
    $fragment{directives} = $directives if $directives && @$directives;
    _store_location(\%fragment, $node);
    return \%fragment;
  }

  if ($node->{kind} eq 'InlineFragment') {
    my %fragment = (
      kind => 'inline_fragment',
      selections => [ map _convert_selection($_), @{ $node->{selectionSet}{selections} || [] } ],
    );
    my $directives = _convert_directives($node->{directives});
    $fragment{directives} = $directives if $directives && @$directives;
    $fragment{on} = _convert_name_node($node->{typeCondition}{name}) if $node->{typeCondition};
    _store_location(\%fragment, $node);
    return \%fragment;
  }

  die "Unsupported graphql-js selection node '$node->{kind}'.\n";
}

sub _convert_variable_definitions {
  my ($nodes) = @_;
  return undef if !$nodes || !@$nodes;

  my %variables = map {
      my %definition = (
        type => _convert_type($_->{type}),
      );
      my $directives = _convert_directives($_->{directives});
      $definition{directives} = $directives if $directives && @$directives;
      $definition{default_value} = _convert_value($_->{defaultValue})
        if exists $_->{defaultValue};
    ($_->{variable}{name}{value} => \%definition);
  } @$nodes;

  return \%variables;
}

sub _convert_input_value_definitions {
  my ($nodes) = @_;
  return undef if !$nodes || !@$nodes;

  my %fields = map {
      my %field = (
        type => _convert_type($_->{type}),
      );
      my $directives = _convert_directives($_->{directives});
      $field{directives} = $directives if $directives && @$directives;
      $field{description} = $_->{description}{value} if $_->{description};
    $field{default_value} = _convert_value($_->{defaultValue})
      if exists $_->{defaultValue};
    _store_location(\%field, $_);
    ($_->{name}{value} => \%field);
  } @$nodes;

  return \%fields;
}

sub _convert_field_definitions {
  my ($nodes) = @_;
  return undef if !$nodes || !@$nodes;

  my %fields = map {
      my %field = (
        type => _convert_type($_->{type}),
      );
      my $directives = _convert_directives($_->{directives});
      $field{directives} = $directives if $directives && @$directives;
      $field{description} = $_->{description}{value} if $_->{description};
    my $arguments = _convert_input_value_definitions($_->{arguments});
    $field{args} = $arguments if $arguments;
    _store_location(\%field, $_);
    ($_->{name}{value} => \%field);
  } @$nodes;

  return \%fields;
}

sub _convert_definition {
  my ($node) = @_;

  if ($node->{kind} eq 'OperationDefinition') {
    my %operation = (
      kind => 'operation',
      operationType => $node->{operation},
      selections => [ map _convert_selection($_), @{ $node->{selectionSet}{selections} || [] } ],
    );
    my $directives = _convert_directives($node->{directives});
    $operation{directives} = $directives if $directives && @$directives;
    $operation{name} = _convert_name_node($node->{name}) if $node->{name};
    my $variables = _convert_variable_definitions($node->{variableDefinitions});
    $operation{variables} = $variables if $variables;
    _store_location(\%operation, $node);
    return \%operation;
  }

  if ($node->{kind} eq 'FragmentDefinition') {
    my %fragment = (
      kind => 'fragment',
      name => _convert_name_node($node->{name}),
      on => _convert_name_node($node->{typeCondition}{name}),
      selections => [ map _convert_selection($_), @{ $node->{selectionSet}{selections} || [] } ],
    );
    my $directives = _convert_directives($node->{directives});
    $fragment{directives} = $directives if $directives && @$directives;
    _store_location(\%fragment, $node);
    return \%fragment;
  }

  if ($node->{kind} eq 'SchemaDefinition' || $node->{kind} eq 'SchemaExtension') {
    my %schema = (
      kind => 'schema',
      map +($_->{operation} => _convert_name_node($_->{type}{name})), @{ $node->{operationTypes} || [] }
    );
    my $directives = _convert_directives($node->{directives});
    $schema{directives} = $directives if $directives && @$directives;
    _store_location(\%schema, $node);
    return \%schema;
  }

  if ($node->{kind} eq 'ScalarTypeDefinition' || $node->{kind} eq 'ScalarTypeExtension') {
    my %definition = (
      kind => 'scalar',
      name => _convert_name_node($node->{name}),
    );
    my $directives = _convert_directives($node->{directives});
    $definition{directives} = $directives if $directives && @$directives;
    $definition{description} = $node->{description}{value} if $node->{description};
    _store_location(\%definition, $node);
    return \%definition;
  }

  if ($node->{kind} eq 'ObjectTypeDefinition' || $node->{kind} eq 'ObjectTypeExtension') {
    my %definition = (
      kind => 'type',
      name => _convert_name_node($node->{name}),
      interfaces => [ map _convert_name_node($_->{name}), @{ $node->{interfaces} || [] } ],
    );
    my $directives = _convert_directives($node->{directives});
    $definition{directives} = $directives if $directives && @$directives;
    $definition{description} = $node->{description}{value} if $node->{description};
    my $fields = _convert_field_definitions($node->{fields});
    $definition{fields} = $fields if $fields;
    _store_location(\%definition, $node);
    return \%definition;
  }

  if ($node->{kind} eq 'InterfaceTypeDefinition' || $node->{kind} eq 'InterfaceTypeExtension') {
    my %definition = (
      kind => 'interface',
      name => _convert_name_node($node->{name}),
      interfaces => [ map _convert_name_node($_->{name}), @{ $node->{interfaces} || [] } ],
    );
    my $directives = _convert_directives($node->{directives});
    $definition{directives} = $directives if $directives && @$directives;
    $definition{description} = $node->{description}{value} if $node->{description};
    my $fields = _convert_field_definitions($node->{fields});
    $definition{fields} = $fields if $fields;
    _store_location(\%definition, $node);
    return \%definition;
  }

  if ($node->{kind} eq 'UnionTypeDefinition' || $node->{kind} eq 'UnionTypeExtension') {
    my %definition = (
      kind => 'union',
      name => _convert_name_node($node->{name}),
      types => [ map _convert_name_node($_->{name}), @{ $node->{types} || [] } ],
    );
    my $directives = _convert_directives($node->{directives});
    $definition{directives} = $directives if $directives && @$directives;
    $definition{description} = $node->{description}{value} if $node->{description};
    _store_location(\%definition, $node);
    return \%definition;
  }

  if ($node->{kind} eq 'EnumTypeDefinition' || $node->{kind} eq 'EnumTypeExtension') {
    my %definition = (
      kind => 'enum',
      name => _convert_name_node($node->{name}),
      values => {
        map {
          my %value = (
          );
          my $directives = _convert_directives($_->{directives});
          $value{directives} = $directives if $directives && @$directives;
          $value{description} = $_->{description}{value} if $_->{description};
          _store_location(\%value, $_);
          ($_->{name}{value} => \%value);
        } @{ $node->{values} || [] }
      },
    );
    my $directives = _convert_directives($node->{directives});
    $definition{directives} = $directives if $directives && @$directives;
    $definition{description} = $node->{description}{value} if $node->{description};
    _store_location(\%definition, $node);
    return \%definition;
  }

  if ($node->{kind} eq 'InputObjectTypeDefinition' || $node->{kind} eq 'InputObjectTypeExtension') {
    my %definition = (
      kind => 'input',
      name => _convert_name_node($node->{name}),
    );
    my $directives = _convert_directives($node->{directives});
    $definition{directives} = $directives if $directives && @$directives;
    $definition{description} = $node->{description}{value} if $node->{description};
    my $fields = _convert_input_value_definitions($node->{fields});
    $definition{fields} = $fields if $fields;
    _store_location(\%definition, $node);
    return \%definition;
  }

  if ($node->{kind} eq 'DirectiveDefinition' || $node->{kind} eq 'DirectiveExtension') {
    my %definition = (
      kind => 'directive',
      name => _convert_name_node($node->{name}),
      locations => [ map _convert_name_node($_), @{ $node->{locations} || [] } ],
    );
    my $args = _convert_input_value_definitions($node->{arguments});
    $definition{args} = $args if $args;
    $definition{description} = $node->{description}{value} if $node->{description};
    _store_location(\%definition, $node);
    return \%definition;
  }

  die "Unsupported graphql-js definition node '$node->{kind}'.\n";
}

sub convert_document {
  my ($document) = @_;
  die "Expected graphql-js Document node.\n"
    if ref($document) ne 'HASH' || ($document->{kind} || '') ne 'Document';

  return [
    map _convert_definition($_), @{ $document->{definitions} || [] }
  ];
}

1;
