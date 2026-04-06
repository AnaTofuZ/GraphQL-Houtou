package GraphQL::Houtou::Type::Object;

use 5.014;
use strict;
use warnings;

use Moo;
use GraphQL::Houtou::Directive ();
use Types::Standard qw(ArrayRef Object CodeRef);
use GraphQL::Error;

extends 'GraphQL::Houtou::Type';
with qw(
  GraphQL::Houtou::Role::Output
  GraphQL::Houtou::Role::Composite
  GraphQL::Houtou::Role::Named
  GraphQL::Houtou::Role::FieldsOutput
  GraphQL::Houtou::Role::HashMappable
);

sub list {
  require GraphQL::Houtou::Type::List;
  $_[0]->{_houtou_list} ||= GraphQL::Houtou::Type::List->new(of => $_[0]);
}

sub non_null {
  require GraphQL::Houtou::Type::NonNull;
  $_[0]->{_houtou_non_null} ||= GraphQL::Houtou::Type::NonNull->new(of => $_[0]);
}

use constant DEBUG => $ENV{GRAPHQL_DEBUG};

has interfaces => (is => 'ro', isa => ArrayRef[Object], default => sub { [] });
has is_type_of => (is => 'ro', isa => CodeRef);

sub graphql_to_perl {
  my ($self, $item) = @_;
  my $fields = $self->fields;

  return $item if !defined $item;
  $item = $self->uplift($item);
  return $self->hashmap($item, $fields, sub {
    my ($key, $value) = @_;
    return $fields->{$key}{type}->graphql_to_perl($value // $fields->{$key}{default_value});
  });
}

sub _collect_fields {
  my ($self, $context, $selections, $fields_got, $visited_fragments) = @_;

  for my $selection (@$selections) {
    my $node = $selection;
    next if !_should_include_node($context->{variable_values}, $node);

    if ($selection->{kind} eq 'field') {
      my $use_name = $node->{alias} || $node->{name};
      my ($field_names, $nodes_defs) = @$fields_got;
      $field_names = [ @$field_names, $use_name ] if !exists $nodes_defs->{$use_name};
      $nodes_defs = {
        %$nodes_defs,
        $use_name => [ @{ $nodes_defs->{$use_name} || [] }, $node ],
      };
      $fields_got = [ $field_names, $nodes_defs ];
      next;
    }

    if ($selection->{kind} eq 'inline_fragment') {
      next if !$self->_fragment_condition_match($context, $node);
      ($fields_got, $visited_fragments) = $self->_collect_fields(
        $context,
        $node->{selections},
        $fields_got,
        $visited_fragments,
      );
      next;
    }

    if ($selection->{kind} eq 'fragment_spread') {
      my $frag_name = $node->{name};
      my $fragment;
      next if $visited_fragments->{$frag_name};
      $visited_fragments = { %$visited_fragments, $frag_name => 1 };
      $fragment = $context->{fragments}{$frag_name};
      next if !$fragment;
      next if !$self->_fragment_condition_match($context, $fragment);
      ($fields_got, $visited_fragments) = $self->_collect_fields(
        $context,
        $fragment->{selections},
        $fields_got,
        $visited_fragments,
      );
    }
  }

  return ($fields_got, $visited_fragments);
}

sub _fragment_condition_match {
  my ($self, $context, $node) = @_;
  my $condition_type;
  my $schema = $context->{schema};
  my $runtime_cache = $context->{runtime_cache} || $schema->runtime_cache || $schema->prepare_runtime;
  my $name2type = $runtime_cache->{name2type} || $schema->name2type;
  my $possible_type_map = $runtime_cache->{possible_type_map} ||= {};

  return 1 if !$node->{on};
  return 1 if $node->{on} eq $self->name;
  $condition_type = $name2type->{ $node->{on} }
    // die GraphQL::Error->new(
      message => "Unknown type for fragment condition '$node->{on}'."
    );
  return '' if !$condition_type->DOES('GraphQL::Houtou::Role::Abstract')
    && !$condition_type->DOES('GraphQL::Role::Abstract');
  return $possible_type_map->{ $condition_type->name }{ $self->name }
    if exists $possible_type_map->{ $condition_type->name };
  return $schema->is_possible_type($condition_type, $self);
}

sub _should_include_node {
  my ($variables, $node) = @_;
  my $skip = $GraphQL::Houtou::Directive::SKIP->_get_directive_values($node, $variables);
  return '' if $skip && $skip->{if};
  my $include = $GraphQL::Houtou::Directive::INCLUDE->_get_directive_values($node, $variables);
  return '' if $include && !$include->{if};
  return 1;
}

sub _complete_value {
  my ($self, $context, $nodes, $info, $path, $result) = @_;
  my $subfield_nodes = [ [], {} ];
  my $visited_fragment_names = {};

  if ($self->is_type_of) {
    my $is_type_of = $self->is_type_of->($result, $context->{context_value}, $info);
    die GraphQL::Error->new(
      message => "Expected a value of type '@{[$self->to_string]}' but received: '@{[ref($result) || $result]}'."
    ) if !$is_type_of;
  }

  for (grep { $_->{selections} } @$nodes) {
    ($subfield_nodes, $visited_fragment_names) = $self->_collect_fields(
      $context,
      $_->{selections},
      $subfield_nodes,
      $visited_fragment_names,
    );
  }

  require GraphQL::Houtou::Execution::PP;
  return GraphQL::Houtou::Execution::PP::_execute_fields($context, $self, $result, $path, $subfield_nodes);
}

has to_doc => (
  is => 'lazy',
  builder => sub {
    my ($self) = @_;
    my @fieldlines = map {
      my ($main, @description) = @$_;
      (@description, $main);
    } $self->_make_fieldtuples($self->fields);
    my $implements = join ' & ', map $_->name, @{ $self->interfaces || [] };
    $implements &&= 'implements ' . $implements . ' ';
    return join '', map "$_\n",
      $self->_description_doc_lines($self->description),
      "type @{[$self->name]} $implements\{",
      (map length() ? "  $_" : "", @fieldlines),
      "}";
  },
);

1;
