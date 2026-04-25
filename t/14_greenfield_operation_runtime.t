use strict;
use warnings;

use Test::More 0.98;

use GraphQL::Houtou::Runtime qw(compile_operation);
use GraphQL::Houtou::Schema;
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

subtest 'schema runtime can lower source into execution program' => sub {
  my $runtime = $schema->compile_runtime;
  my $program = $runtime->compile_operation('{ viewer { id name } }');

  isa_ok $program, 'GraphQL::Houtou::Runtime::ExecutionProgram';
  isa_ok $program->root_block, 'GraphQL::Houtou::Runtime::ExecutionBlock';
  is $program->operation_type, 'query', 'query operation inferred';
  is $program->root_block->type_name, 'Query', 'root block keeps root type';

  my ($viewer) = @{ $program->root_block->instructions };
  is $viewer->field_name, 'viewer', 'viewer field lowered';
  is $viewer->resolve_op, 'RESOLVE_EXPLICIT', 'explicit resolver lowered';
  is $viewer->complete_op, 'COMPLETE_OBJECT', 'object completion lowered';
  ok $viewer->child_block_name, 'child block emitted for object field';

  my $child = $program->block_by_name($viewer->child_block_name);
  isa_ok $child, 'GraphQL::Houtou::Runtime::ExecutionBlock';
  is $child->type_name, 'User', 'child block uses concrete object type';
  is_deeply [ map { $_->field_name } @{ $child->instructions } ], [ qw(id name) ], 'child field instructions lowered';
};

subtest 'top-level helper can lower operation source' => sub {
  my $runtime = $schema->compile_runtime;
  my $program = compile_operation($runtime, '{ search }');

  isa_ok $program, 'GraphQL::Houtou::Runtime::ExecutionProgram';
  my ($search) = @{ $program->root_block->instructions };
  is $search->complete_op, 'COMPLETE_LIST', 'list field lowers to list completion op';
  is $search->dispatch_family, 'LIST', 'dispatch family preserved';
};

subtest 'execution program can round-trip through struct form' => sub {
  my $program = $schema->compile_operation('{ viewer { id } }');
  my $struct = $program->to_struct;
  my ($root_block) = grep { $_->{name} eq $struct->{root_block} } @{ $struct->{blocks} };

  is $struct->{operation_type}, 'query', 'struct keeps operation type';
  is $struct->{root_block}, $program->root_block->name, 'struct keeps root block name';
  is $root_block->{instructions}[0]{complete_op}, 'COMPLETE_OBJECT', 'instruction op is serialized on root block';
};

done_testing;
