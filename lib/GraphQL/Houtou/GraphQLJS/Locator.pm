package GraphQL::Houtou::GraphQLJS::Locator;

use 5.014;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
  apply_loc_from_source
);

sub _loc {
  return $_[0]{loc};
}

sub _set_loc {
  my ($node, $loc) = @_;
  return if ref($node) ne 'HASH' || !$loc;
  $node->{loc} = { %$loc };
}

sub _peek {
  my ($state, $offset) = @_;
  $offset ||= 0;
  return $state->{tokens}[ $state->{index} + $offset ];
}

sub _consume {
  my ($state) = @_;
  return $state->{tokens}[ $state->{index}++ ];
}

sub _peek_text {
  my ($state, $text) = @_;
  my $token = _peek($state);
  return $token && $token->{text} eq $text;
}

sub _peek_kind {
  my ($state, $kind) = @_;
  my $token = _peek($state);
  return $token && $token->{kind} eq $kind;
}

sub _consume_text {
  my ($state, $text) = @_;
  die "Expected token $text\n" if !_peek_text($state, $text);
  return _consume($state);
}

sub _consume_kind {
  my ($state, $kind) = @_;
  die "Expected token kind $kind\n" if !_peek_kind($state, $kind);
  return _consume($state);
}

sub _optional_description {
  my ($state, $node) = @_;
  return unless $node->{description};
  return unless _peek_kind($state, 'STRING') || _peek_kind($state, 'BLOCK_STRING');
  my $token = _consume($state);
  _set_loc($node->{description}, _loc($token));
  return _loc($token);
}

sub _name_lookup {
  my ($nodes, $extractor) = @_;
  my %lookup;
  for my $node (@{ $nodes || [] }) {
    my $name = $extractor->($node);
    push @{ $lookup{$name} }, $node;
  }
  return \%lookup;
}

sub _take_named_node {
  my ($lookup, $name) = @_;
  my $nodes = $lookup->{$name} || [];
  return shift @$nodes if @$nodes;
  return;
}

sub _locate_name_node {
  my ($state, $node) = @_;
  my $token = _consume_kind($state, 'NAME');
  _set_loc($node, _loc($token));
  return _loc($token);
}

sub _locate_type;
sub _locate_value;
sub _locate_directives;
sub _locate_selection_set;
sub _locate_selection;
sub _locate_definition;

sub _locate_type {
  my ($state, $node) = @_;

  if ($node->{kind} eq 'NamedType') {
    my $loc = _locate_name_node($state, $node->{name});
    _set_loc($node, $loc);
    return $loc;
  }

  if ($node->{kind} eq 'ListType') {
    my $token = _consume_text($state, '[');
    _set_loc($node, _loc($token));
    _locate_type($state, $node->{type});
    _consume_text($state, ']');
    return _loc($token);
  }

  if ($node->{kind} eq 'NonNullType') {
    my $loc = _locate_type($state, $node->{type});
    _consume_text($state, '!');
    _set_loc($node, $loc);
    return $loc;
  }

  die "Unsupported type node $node->{kind}\n";
}

sub _locate_value {
  my ($state, $node) = @_;

  if ($node->{kind} eq 'Variable') {
    my $dollar = _consume_text($state, '$');
    my $name_loc = _locate_name_node($state, $node->{name});
    _set_loc($node, _loc($dollar));
    return _loc($dollar);
  }

  if ($node->{kind} eq 'IntValue' || $node->{kind} eq 'FloatValue') {
    die "Expected numeric token\n" if !_peek_kind($state, 'INT') && !_peek_kind($state, 'FLOAT');
    my $token = _consume($state);
    _set_loc($node, _loc($token));
    return _loc($token);
  }

  if ($node->{kind} eq 'StringValue') {
    my $token = _consume($state);
    die "Expected string token\n" if !$token || ($token->{kind} ne 'STRING' && $token->{kind} ne 'BLOCK_STRING');
    _set_loc($node, _loc($token));
    return _loc($token);
  }

  if ($node->{kind} eq 'BooleanValue' || $node->{kind} eq 'NullValue' || $node->{kind} eq 'EnumValue') {
    my $token = _consume_kind($state, 'NAME');
    _set_loc($node, _loc($token));
    return _loc($token);
  }

  if ($node->{kind} eq 'ListValue') {
    my $token = _consume_text($state, '[');
    _set_loc($node, _loc($token));
    _locate_value($state, $_) for @{ $node->{values} || [] };
    _consume_text($state, ']');
    return _loc($token);
  }

  if ($node->{kind} eq 'ObjectValue') {
    my $token = _consume_text($state, '{');
    my $fields = _name_lookup($node->{fields}, sub { $_[0]{name}{value} });
    _set_loc($node, _loc($token));

    while (!_peek_text($state, '}')) {
      my $name = _consume_kind($state, 'NAME');
      my $field = _take_named_node($fields, $name->{text});
      die "Missing object field node for $name->{text}\n" if !$field;
      _set_loc($field, _loc($name));
      _set_loc($field->{name}, _loc($name));
      _consume_text($state, ':');
      _locate_value($state, $field->{value});
    }

    _consume_text($state, '}');
    return _loc($token);
  }

  die "Unsupported value node $node->{kind}\n";
}

sub _locate_arguments {
  my ($state, $nodes) = @_;
  return if !@$nodes;

  _consume_text($state, '(');
  my $lookup = _name_lookup($nodes, sub { $_[0]{name}{value} });

  while (!_peek_text($state, ')')) {
    my $name = _consume_kind($state, 'NAME');
    my $node = _take_named_node($lookup, $name->{text});
    die "Missing argument node for $name->{text}\n" if !$node;
    _set_loc($node, _loc($name));
    _set_loc($node->{name}, _loc($name));
    _consume_text($state, ':');
    _locate_value($state, $node->{value});
  }

  _consume_text($state, ')');
}

sub _locate_directives {
  my ($state, $nodes) = @_;
  for my $node (@{ $nodes || [] }) {
    my $at = _consume_text($state, '@');
    _consume_kind($state, 'NAME');
    my $name_token = $state->{tokens}[ $state->{index} - 1 ];
    _set_loc($node, _loc($at));
    _set_loc($node->{name}, _loc($name_token));
    _locate_arguments($state, $node->{arguments}) if @{ $node->{arguments} || [] };
  }
}

sub _locate_variable_definitions {
  my ($state, $nodes) = @_;
  return if !@$nodes;

  _consume_text($state, '(');
  my $lookup = _name_lookup($nodes, sub { $_[0]{variable}{name}{value} });

  while (!_peek_text($state, ')')) {
    my $dollar = _consume_text($state, '$');
    my $name = _consume_kind($state, 'NAME');
    my $node = _take_named_node($lookup, $name->{text});
    die "Missing variable definition node for $name->{text}\n" if !$node;
    _set_loc($node, _loc($dollar));
    _set_loc($node->{variable}, _loc($dollar));
    _set_loc($node->{variable}{name}, _loc($name));
    _consume_text($state, ':');
    _locate_type($state, $node->{type});
    if (exists $node->{defaultValue}) {
      _consume_text($state, '=');
      _locate_value($state, $node->{defaultValue});
    }
    _locate_directives($state, $node->{directives});
  }

  _consume_text($state, ')');
}

sub _locate_selection_set {
  my ($state, $node) = @_;
  my $token = _consume_text($state, '{');
  _set_loc($node, _loc($token));
  _locate_selection($state, $_) for @{ $node->{selections} || [] };
  _consume_text($state, '}');
  return _loc($token);
}

sub _locate_selection {
  my ($state, $node) = @_;

  if ($node->{kind} eq 'Field') {
    my $first = _peek($state);
    if ($node->{alias}) {
      my $alias_loc = _locate_name_node($state, $node->{alias});
      _consume_text($state, ':');
      my $name_loc = _locate_name_node($state, $node->{name});
      _set_loc($node, _loc($first));
    }
    else {
      my $name_loc = _locate_name_node($state, $node->{name});
      _set_loc($node, $name_loc);
    }

    _locate_arguments($state, $node->{arguments}) if @{ $node->{arguments} || [] };
    _locate_directives($state, $node->{directives});
    _locate_selection_set($state, $node->{selectionSet}) if $node->{selectionSet};
    return;
  }

  if ($node->{kind} eq 'FragmentSpread') {
    my $spread = _consume_text($state, '...');
    _set_loc($node, _loc($spread));
    _locate_name_node($state, $node->{name});
    _locate_directives($state, $node->{directives});
    return;
  }

  if ($node->{kind} eq 'InlineFragment') {
    my $spread = _consume_text($state, '...');
    _set_loc($node, _loc($spread));
    if ($node->{typeCondition}) {
      _consume_kind($state, 'NAME');
      _locate_type($state, $node->{typeCondition});
    }
    _locate_directives($state, $node->{directives});
    _locate_selection_set($state, $node->{selectionSet});
    return;
  }

  die "Unsupported selection node $node->{kind}\n";
}

sub _locate_input_value_definitions {
  my ($state, $nodes) = @_;
  my $lookup = _name_lookup($nodes, sub { $_[0]{name}{value} });

  while (!_peek_text($state, '}') && !_peek_text($state, ')')) {
    my $desc_loc;
    $desc_loc = _loc(_consume($state)) if _peek_kind($state, 'STRING') || _peek_kind($state, 'BLOCK_STRING');
    my $name = _consume_kind($state, 'NAME');
    my $node = _take_named_node($lookup, $name->{text});
    die "Missing input value node for $name->{text}\n" if !$node;
    _set_loc($node, $desc_loc || _loc($name));
    _set_loc($node->{description}, $desc_loc) if $node->{description} && $desc_loc;
    _set_loc($node->{name}, _loc($name));
    _consume_text($state, ':');
    _locate_type($state, $node->{type});
    if (exists $node->{defaultValue}) {
      _consume_text($state, '=');
      _locate_value($state, $node->{defaultValue});
    }
    _locate_directives($state, $node->{directives});
  }
}

sub _locate_arguments_definition {
  my ($state, $nodes) = @_;
  return if !@$nodes;
  _consume_text($state, '(');
  _locate_input_value_definitions($state, $nodes);
  _consume_text($state, ')');
}

sub _locate_field_definitions {
  my ($state, $nodes) = @_;
  return if !@$nodes;

  _consume_text($state, '{');
  my $lookup = _name_lookup($nodes, sub { $_[0]{name}{value} });

  while (!_peek_text($state, '}')) {
    my $desc_loc;
    $desc_loc = _loc(_consume($state)) if _peek_kind($state, 'STRING') || _peek_kind($state, 'BLOCK_STRING');
    my $name = _consume_kind($state, 'NAME');
    my $node = _take_named_node($lookup, $name->{text});
    die "Missing field definition node for $name->{text}\n" if !$node;
    _set_loc($node, $desc_loc || _loc($name));
    _set_loc($node->{description}, $desc_loc) if $node->{description} && $desc_loc;
    _set_loc($node->{name}, _loc($name));
    _locate_arguments_definition($state, $node->{arguments}) if @{ $node->{arguments} || [] };
    _consume_text($state, ':');
    _locate_type($state, $node->{type});
    _locate_directives($state, $node->{directives});
  }

  _consume_text($state, '}');
}

sub _locate_enum_values {
  my ($state, $nodes) = @_;
  return if !@$nodes;

  _consume_text($state, '{');
  my $lookup = _name_lookup($nodes, sub { $_[0]{name}{value} });

  while (!_peek_text($state, '}')) {
    my $desc_loc;
    $desc_loc = _loc(_consume($state)) if _peek_kind($state, 'STRING') || _peek_kind($state, 'BLOCK_STRING');
    my $name = _consume_kind($state, 'NAME');
    my $node = _take_named_node($lookup, $name->{text});
    die "Missing enum value node for $name->{text}\n" if !$node;
    _set_loc($node, $desc_loc || _loc($name));
    _set_loc($node->{description}, $desc_loc) if $node->{description} && $desc_loc;
    _set_loc($node->{name}, _loc($name));
    _locate_directives($state, $node->{directives});
  }

  _consume_text($state, '}');
}

sub _locate_operation_types {
  my ($state, $nodes) = @_;
  return if !@$nodes;

  _consume_text($state, '{');
  my $lookup = _name_lookup($nodes, sub { $_[0]{operation} });

  while (!_peek_text($state, '}')) {
    my $operation = _consume_kind($state, 'NAME');
    my $node = _take_named_node($lookup, $operation->{text});
    die "Missing operation type node for $operation->{text}\n" if !$node;
    _set_loc($node, _loc($operation));
    _consume_text($state, ':');
    _locate_type($state, $node->{type});
  }

  _consume_text($state, '}');
}

sub _locate_interfaces {
  my ($state, $nodes) = @_;
  return if !@$nodes;
  my $lookup = _name_lookup($nodes, sub { $_[0]{name}{value} });
  _consume_kind($state, 'NAME');
  _consume_text($state, '&') if _peek_text($state, '&');
  while (_peek_kind($state, 'NAME')) {
    my $name = _consume_kind($state, 'NAME');
    my $node = _take_named_node($lookup, $name->{text});
    die "Missing interface node for $name->{text}\n" if !$node;
    _set_loc($node, _loc($name));
    _set_loc($node->{name}, _loc($name));
    _consume_text($state, '&') if _peek_text($state, '&');
  }
}

sub _locate_union_types {
  my ($state, $nodes) = @_;
  return if !@$nodes;
  _consume_text($state, '=');
  _consume_text($state, '|') if _peek_text($state, '|');
  for my $node (@$nodes) {
    _locate_type($state, $node);
    _consume_text($state, '|') if _peek_text($state, '|');
  }
}

sub _locate_directive_locations {
  my ($state, $nodes) = @_;
  return if !@$nodes;
  _consume_kind($state, 'NAME');
  _consume_text($state, '|') if _peek_text($state, '|');
  for my $node (@$nodes) {
    _locate_name_node($state, $node);
    _consume_text($state, '|') if _peek_text($state, '|');
  }
}

sub _locate_definition {
  my ($state, $node) = @_;

  if ($node->{kind} eq 'OperationDefinition') {
    if (_peek_text($state, '{')) {
      my $loc = _locate_selection_set($state, $node->{selectionSet});
      _set_loc($node, $loc);
      return;
    }

    my $token = _consume_kind($state, 'NAME');
    _set_loc($node, _loc($token));
    _locate_name_node($state, $node->{name}) if $node->{name};
    _locate_variable_definitions($state, $node->{variableDefinitions});
    _locate_directives($state, $node->{directives});
    _locate_selection_set($state, $node->{selectionSet});
    return;
  }

  if ($node->{kind} eq 'FragmentDefinition') {
    my $token = _consume_kind($state, 'NAME');
    _set_loc($node, _loc($token));
    _locate_name_node($state, $node->{name});
    _consume_kind($state, 'NAME');
    _locate_type($state, $node->{typeCondition});
    _locate_directives($state, $node->{directives});
    _locate_selection_set($state, $node->{selectionSet});
    return;
  }

  my $description_loc = _optional_description($state, $node);
  my $definition_loc = $description_loc;

  if ($node->{kind} =~ /Extension\z/) {
    my $extend = _consume_kind($state, 'NAME');
    $definition_loc ||= _loc($extend);
  }

  if ($node->{kind} eq 'SchemaDefinition' || $node->{kind} eq 'SchemaExtension') {
    my $token = _consume_kind($state, 'NAME');
    $definition_loc ||= _loc($token);
    _set_loc($node, $definition_loc);
    _locate_directives($state, $node->{directives});
    _locate_operation_types($state, $node->{operationTypes});
    return;
  }

  if ($node->{kind} eq 'ScalarTypeDefinition' || $node->{kind} eq 'ScalarTypeExtension') {
    my $token = _consume_kind($state, 'NAME');
    $definition_loc ||= _loc($token);
    _locate_name_node($state, $node->{name});
    _set_loc($node, $definition_loc);
    _locate_directives($state, $node->{directives});
    return;
  }

  if ($node->{kind} eq 'ObjectTypeDefinition' || $node->{kind} eq 'ObjectTypeExtension') {
    my $token = _consume_kind($state, 'NAME');
    $definition_loc ||= _loc($token);
    _locate_name_node($state, $node->{name});
    _set_loc($node, $definition_loc);
    _locate_interfaces($state, $node->{interfaces}) if @{ $node->{interfaces} || [] };
    _locate_directives($state, $node->{directives});
    _locate_field_definitions($state, $node->{fields});
    return;
  }

  if ($node->{kind} eq 'InterfaceTypeDefinition' || $node->{kind} eq 'InterfaceTypeExtension') {
    my $token = _consume_kind($state, 'NAME');
    $definition_loc ||= _loc($token);
    _locate_name_node($state, $node->{name});
    _set_loc($node, $definition_loc);
    _locate_interfaces($state, $node->{interfaces}) if @{ $node->{interfaces} || [] };
    _locate_directives($state, $node->{directives});
    _locate_field_definitions($state, $node->{fields});
    return;
  }

  if ($node->{kind} eq 'UnionTypeDefinition' || $node->{kind} eq 'UnionTypeExtension') {
    my $token = _consume_kind($state, 'NAME');
    $definition_loc ||= _loc($token);
    _locate_name_node($state, $node->{name});
    _set_loc($node, $definition_loc);
    _locate_directives($state, $node->{directives});
    _locate_union_types($state, $node->{types}) if @{ $node->{types} || [] };
    return;
  }

  if ($node->{kind} eq 'EnumTypeDefinition' || $node->{kind} eq 'EnumTypeExtension') {
    my $token = _consume_kind($state, 'NAME');
    $definition_loc ||= _loc($token);
    _locate_name_node($state, $node->{name});
    _set_loc($node, $definition_loc);
    _locate_directives($state, $node->{directives});
    _locate_enum_values($state, $node->{values});
    return;
  }

  if ($node->{kind} eq 'InputObjectTypeDefinition' || $node->{kind} eq 'InputObjectTypeExtension') {
    my $token = _consume_kind($state, 'NAME');
    $definition_loc ||= _loc($token);
    _locate_name_node($state, $node->{name});
    _set_loc($node, $definition_loc);
    _locate_directives($state, $node->{directives});
    if (@{ $node->{fields} || [] }) {
      _consume_text($state, '{');
      _locate_input_value_definitions($state, $node->{fields});
      _consume_text($state, '}');
    }
    return;
  }

  if ($node->{kind} eq 'DirectiveDefinition' || $node->{kind} eq 'DirectiveExtension') {
    my $token = _consume_kind($state, 'NAME');
    $definition_loc ||= _loc($token);
    _consume_text($state, '@');
    _locate_name_node($state, $node->{name});
    _set_loc($node, $definition_loc);
    _locate_arguments_definition($state, $node->{arguments}) if @{ $node->{arguments} || [] };
    if ($node->{repeatable}) {
      _consume_kind($state, 'NAME');
    }
    _locate_directive_locations($state, $node->{locations});
    return;
  }

  die "Unsupported definition node $node->{kind}\n";
}

sub apply_loc_from_source {
  my ($doc, $source) = @_;
  require GraphQL::Houtou::XS::Parser;
  GraphQL::Houtou::XS::Parser->import('tokenize_xs');

  my $tokens = tokenize_xs($source);
  my $state = {
    tokens => $tokens,
    index => 0,
  };

  _set_loc($doc, { line => 1, column => 1 });
  _locate_definition($state, $_) for @{ $doc->{definitions} || [] };

  return $doc;
}

1;
