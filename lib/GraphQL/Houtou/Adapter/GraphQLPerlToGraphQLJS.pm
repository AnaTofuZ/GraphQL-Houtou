package GraphQL::Houtou::Adapter::GraphQLPerlToGraphQLJS;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use Scalar::Util qw(blessed looks_like_number);

our @EXPORT_OK = qw(
  convert_legacy_directives
  convert_document
);

our $SKIP_LOCATION_PROJECTION = 0;

sub _node {
  my ($kind, $fields, $loc) = @_;
  my %node = (kind => $kind, %{$fields || {}});
  $node{loc} = { %$loc } if !$SKIP_LOCATION_PROJECTION && $loc;
  return \%node;
}

sub _name_node {
  my ($value, $loc) = @_;
  return _node('Name', { value => $value }, $loc);
}

sub _description_node {
  my ($description, $loc) = @_;
  return if !defined $description;
  # graphql-perl AST には block string だったかどうかが残らないので、
  # 現状は改行の有無を近似値として graphql-js の block flag に写す。
  return _node('StringValue', {
    value => $description,
    block => index($description, "\n") >= 0 ? 1 : 0,
  }, $loc);
}

sub _value_loc {
  my ($legacy, $fallback) = @_;
  return undef if $SKIP_LOCATION_PROJECTION;
  return $legacy->{location} if ref($legacy) eq 'HASH' && $legacy->{location};
  return $fallback;
}

sub _is_bool {
  my ($value) = @_;
  return blessed($value) && blessed($value) =~ /Boolean$/;
}

sub _convert_type {
  my ($type, $loc) = @_;
  if (!ref $type) {
    return _node('NamedType', {
      name => _name_node($type, $loc),
    }, $loc);
  }
  if (ref($type) eq 'ARRAY' && @$type == 2) {
    my ($kind, $inner) = @$type;
    if ($kind eq 'list') {
      return _node('ListType', {
        type => _convert_type($inner->{type}, $loc),
      }, $loc);
    }
    if ($kind eq 'non_null') {
      return _node('NonNullType', {
        type => _convert_type($inner->{type}, $loc),
      }, $loc);
    }
  }
  die "Cannot convert graphql-perl type representation to graphql-js AST.\n";
}

sub _convert_value {
  my ($value, $loc) = @_;

  return _node('NullValue', {}, $loc) if !defined $value;

  if (_is_bool($value)) {
    return _node('BooleanValue', { value => $value ? 1 : 0 }, $loc);
  }

  if (!ref $value) {
    if (looks_like_number($value)) {
      my $string = "$value";
      return _node($string =~ /\A-?\d+\z/ ? 'IntValue' : 'FloatValue', {
        value => $string,
      }, $loc);
    }
    return _node('StringValue', {
      value => "$value",
      block => 0,
    }, $loc);
  }

  if (ref($value) eq 'SCALAR') {
    return _node('Variable', {
      name => _name_node($$value, $loc),
    }, $loc);
  }

  if (ref($value) eq 'REF' && ref($$value) eq 'SCALAR') {
    return _node('EnumValue', {
      value => $$$value,
    }, $loc);
  }

  if (ref($value) eq 'ARRAY') {
    return _node('ListValue', {
      values => [ map _convert_value($_, $loc), @$value ],
    }, $loc);
  }

  if (ref($value) eq 'HASH') {
    return _node('ObjectValue', {
      fields => [
        map _node('ObjectField', {
          name => _name_node($_, $loc),
          value => _convert_value($value->{$_}, $loc),
        }, $loc), sort keys %$value
      ],
    }, $loc);
  }

  die "Cannot convert graphql-perl value representation to graphql-js AST.\n";
}

sub _convert_arguments {
  my ($args, $loc) = @_;
  return [] if !$args;
  return [
    map _node('Argument', {
      name => _name_node($_, $loc),
      value => _convert_value($args->{$_}, $loc),
    }, $loc), sort keys %$args
  ];
}

sub _convert_directives {
  my ($directives, $fallback_loc) = @_;
  return [] if !$directives;
  return [
    map {
      my $loc = _value_loc($_, $fallback_loc);
      _node('Directive', {
        name => _name_node($_->{name}, $loc),
        arguments => _convert_arguments($_->{arguments}, $loc),
      }, $loc)
    } @$directives
  ];
}

sub convert_legacy_directives {
  my ($directives, $fallback_loc) = @_;
  return _convert_directives($directives, $fallback_loc);
}

sub _convert_selection_set {
  my ($selections, $loc) = @_;
  return _node('SelectionSet', {
    selections => [ map _convert_selection($_, $loc), @$selections ],
  }, $loc);
}

sub _convert_selection {
  my ($selection, $fallback_loc) = @_;
  my $loc = _value_loc($selection, $fallback_loc);

  if ($selection->{kind} eq 'field') {
    return _node('Field', {
      ($selection->{alias}
        ? (alias => _name_node($selection->{alias}, $loc))
        : ()),
      name => _name_node($selection->{name}, $loc),
      arguments => _convert_arguments($selection->{arguments}, $loc),
      directives => _convert_directives($selection->{directives}, $loc),
      ($selection->{selections}
        ? (selectionSet => _convert_selection_set($selection->{selections}, $loc))
        : ()),
    }, $loc);
  }

  if ($selection->{kind} eq 'fragment_spread') {
    return _node('FragmentSpread', {
      name => _name_node($selection->{name}, $loc),
      directives => _convert_directives($selection->{directives}, $loc),
    }, $loc);
  }

  if ($selection->{kind} eq 'inline_fragment') {
    return _node('InlineFragment', {
      ($selection->{on}
        ? (typeCondition => _node('NamedType', {
          name => _name_node($selection->{on}, $loc),
        }, $loc))
        : ()),
      directives => _convert_directives($selection->{directives}, $loc),
      selectionSet => _convert_selection_set($selection->{selections}, $loc),
    }, $loc);
  }

  die "Unsupported selection kind '$selection->{kind}' for graphql-js AST conversion.\n";
}

sub _convert_variable_definitions {
  my ($variables, $loc) = @_;
  return [] if !$variables;
  return [
    map {
      my $def = $variables->{$_};
      _node('VariableDefinition', {
        variable => _node('Variable', {
          name => _name_node($_, $loc),
        }, $loc),
        type => _convert_type($def->{type}, $loc),
        (exists $def->{default_value}
          ? (defaultValue => _convert_value($def->{default_value}, $loc))
          : ()),
        directives => [],
      }, $loc)
    } sort keys %$variables
  ];
}

sub _convert_input_value_definitions {
  my ($args, $loc) = @_;
  return [] if !$args;
  return [
    map {
      my $arg = $args->{$_};
      _node('InputValueDefinition', {
        ($arg->{description}
          ? (description => _description_node($arg->{description}, $loc))
          : ()),
        name => _name_node($_, $loc),
        type => _convert_type($arg->{type}, $loc),
        (exists $arg->{default_value}
          ? (defaultValue => _convert_value($arg->{default_value}, $loc))
          : ()),
        directives => _convert_directives($arg->{directives}, $loc),
      }, $loc)
    } sort keys %$args
  ];
}

sub _convert_field_definitions {
  my ($fields, $loc) = @_;
  return [] if !$fields;
  return [
    map {
      my $field = $fields->{$_};
      _node('FieldDefinition', {
        ($field->{description}
          ? (description => _description_node($field->{description}, $loc))
          : ()),
        name => _name_node($_, $loc),
        arguments => _convert_input_value_definitions($field->{args}, $loc),
        type => _convert_type($field->{type}, $loc),
        directives => _convert_directives($field->{directives}, $loc),
      }, $loc)
    } sort keys %$fields
  ];
}

sub _convert_definition {
  my ($definition) = @_;
  my $loc = _value_loc($definition, { line => 1, column => 1 });

  if ($definition->{kind} eq 'operation') {
    return _node('OperationDefinition', {
      operation => $definition->{operationType} || 'query',
      ($definition->{name}
        ? (name => _name_node($definition->{name}, $loc))
        : ()),
      variableDefinitions => _convert_variable_definitions($definition->{variables}, $loc),
      directives => _convert_directives($definition->{directives}, $loc),
      selectionSet => _convert_selection_set($definition->{selections}, $loc),
    }, $loc);
  }

  if ($definition->{kind} eq 'fragment') {
    return _node('FragmentDefinition', {
      name => _name_node($definition->{name}, $loc),
      typeCondition => _node('NamedType', {
        name => _name_node($definition->{on}, $loc),
      }, $loc),
      directives => _convert_directives($definition->{directives}, $loc),
      selectionSet => _convert_selection_set($definition->{selections}, $loc),
    }, $loc);
  }

  if ($definition->{kind} eq 'schema') {
    return _node('SchemaDefinition', {
      directives => _convert_directives($definition->{directives}, $loc),
      operationTypes => [
        map _node('OperationTypeDefinition', {
          operation => $_,
          type => _node('NamedType', {
            name => _name_node($definition->{$_}, $loc),
          }, $loc),
        }, $loc), grep exists $definition->{$_}, qw(query mutation subscription)
      ],
    }, $loc);
  }

  if ($definition->{kind} eq 'scalar') {
    return _node('ScalarTypeDefinition', {
      ($definition->{description}
        ? (description => _description_node($definition->{description}, $loc))
        : ()),
      name => _name_node($definition->{name}, $loc),
      directives => _convert_directives($definition->{directives}, $loc),
    }, $loc);
  }

  if ($definition->{kind} eq 'type') {
    return _node('ObjectTypeDefinition', {
      ($definition->{description}
        ? (description => _description_node($definition->{description}, $loc))
        : ()),
      name => _name_node($definition->{name}, $loc),
      interfaces => [
        map _node('NamedType', { name => _name_node($_, $loc) }, $loc),
          @{ $definition->{interfaces} || [] }
      ],
      directives => _convert_directives($definition->{directives}, $loc),
      fields => _convert_field_definitions($definition->{fields}, $loc),
    }, $loc);
  }

  if ($definition->{kind} eq 'interface') {
    return _node('InterfaceTypeDefinition', {
      ($definition->{description}
        ? (description => _description_node($definition->{description}, $loc))
        : ()),
      name => _name_node($definition->{name}, $loc),
      interfaces => [],
      directives => _convert_directives($definition->{directives}, $loc),
      fields => _convert_field_definitions($definition->{fields}, $loc),
    }, $loc);
  }

  if ($definition->{kind} eq 'union') {
    return _node('UnionTypeDefinition', {
      ($definition->{description}
        ? (description => _description_node($definition->{description}, $loc))
        : ()),
      name => _name_node($definition->{name}, $loc),
      directives => _convert_directives($definition->{directives}, $loc),
      types => [
        map _node('NamedType', { name => _name_node($_, $loc) }, $loc),
          @{ $definition->{types} || [] }
      ],
    }, $loc);
  }

  if ($definition->{kind} eq 'enum') {
    return _node('EnumTypeDefinition', {
      ($definition->{description}
        ? (description => _description_node($definition->{description}, $loc))
        : ()),
      name => _name_node($definition->{name}, $loc),
      directives => _convert_directives($definition->{directives}, $loc),
      values => [
        map {
          my $value = $definition->{values}{$_};
          _node('EnumValueDefinition', {
            ($value->{description}
              ? (description => _description_node($value->{description}, $loc))
              : ()),
            name => _name_node($_, $loc),
            directives => _convert_directives($value->{directives}, $loc),
          }, $loc)
        } sort keys %{ $definition->{values} || {} }
      ],
    }, $loc);
  }

  if ($definition->{kind} eq 'input') {
    return _node('InputObjectTypeDefinition', {
      ($definition->{description}
        ? (description => _description_node($definition->{description}, $loc))
        : ()),
      name => _name_node($definition->{name}, $loc),
      directives => _convert_directives($definition->{directives}, $loc),
      fields => _convert_input_value_definitions($definition->{fields}, $loc),
    }, $loc);
  }

  if ($definition->{kind} eq 'directive') {
    return _node('DirectiveDefinition', {
      ($definition->{description}
        ? (description => _description_node($definition->{description}, $loc))
        : ()),
      name => _name_node($definition->{name}, $loc),
      arguments => _convert_input_value_definitions($definition->{args}, $loc),
      repeatable => 0,
      locations => [
        map _name_node($_, $loc), @{ $definition->{locations} || [] }
      ],
    }, $loc);
  }

  die "Unsupported graphql-perl definition kind '$definition->{kind}' for graphql-js AST conversion.\n";
}

sub convert_document {
  my ($legacy, $options) = @_;
  $options ||= {};
  local $SKIP_LOCATION_PROJECTION = $options->{no_location}
    || $options->{noLocation}
    || $options->{skip_location_projection};

  return _node('Document', {
    definitions => [ map _convert_definition($_), @$legacy ],
  }, { line => 1, column => 1 });
}

1;
