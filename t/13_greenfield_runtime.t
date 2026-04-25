use strict;
use warnings;

use Test::More 0.98;

use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Runtime qw(compile_schema inflate_schema);
use GraphQL::Houtou::Type::Interface;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);
use GraphQL::Houtou::Type::Union;

my $User;

my $Node = GraphQL::Houtou::Type::Interface->new(
  name => 'Node',
  fields => {
    id => { type => $String->non_null },
  },
  tag_resolver => sub { $_[0]{kind} },
);

$User = GraphQL::Houtou::Type::Object->new(
  name => 'User',
  interfaces => [ $Node ],
  runtime_tag => 'user',
  fields => {
    id => { type => $String->non_null },
    name => { type => $String },
  },
);

my $SearchResult = GraphQL::Houtou::Type::Union->new(
  name => 'SearchResult',
  types => [ $User ],
  tag_resolver => sub { $_[0]{kind} },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'Query',
    fields => {
      viewer => {
        type => $User,
        resolve => sub { +{ kind => 'user', id => 'u1', name => 'Ana' } },
      },
      search => {
        type => $SearchResult->list->non_null,
        resolve => sub { [] },
      },
    },
  ),
  types => [ $User, $Node, $SearchResult ],
);

subtest 'schema can compile greenfield runtime graph' => sub {
  my $compiled = $schema->compile_runtime;

  isa_ok $compiled, 'GraphQL::Houtou::Runtime::SchemaGraph';
  isa_ok $compiled->program, 'GraphQL::Houtou::Runtime::Program';
  isa_ok $compiled->root_block('query'), 'GraphQL::Houtou::Runtime::Block';
  is $compiled->root_types->{query}, 'Query', 'query root type is compiled';
};

subtest 'top-level compile helper returns same graph kind' => sub {
  my $compiled = compile_schema($schema);
  isa_ok $compiled, 'GraphQL::Houtou::Runtime::SchemaGraph';
};

subtest 'runtime graph records field families and dispatch shapes' => sub {
  my $compiled = $schema->compile_runtime_graph;
  my $block = $compiled->root_block('query');
  my %slots = map { ($_->field_name => $_) } @{ $block->slots };

  is $slots{viewer}->completion_family, 'OBJECT', 'viewer compiles to object family';
  is $slots{viewer}->resolver_shape, 'EXPLICIT', 'viewer keeps explicit resolver shape';
  is $slots{search}->completion_family, 'LIST', 'search compiles to list family';
  is $compiled->type_index->{Node}{completion_family}, 'ABSTRACT', 'interface recorded as abstract family';
  is $compiled->dispatch_index->{SearchResult}{dispatch_family}, 'TAG', 'union tag dispatch is compiled';
};

subtest 'runtime graph can round-trip through descriptor form' => sub {
  my $descriptor = $schema->compile_runtime_descriptor;
  my $inflated = inflate_schema($schema, $descriptor);

  isa_ok $inflated, 'GraphQL::Houtou::Runtime::SchemaGraph';
  is $inflated->root_block('query')->name, 'QUERY', 'inflated graph restores root block';
  is $inflated->root_block('query')->slots->[0]->can('field_name') ? 1 : 0, 1, 'inflated slot object responds to accessors';
  is_deeply $inflated->to_struct, $descriptor, 'descriptor round-trip is stable';
};

done_testing;
