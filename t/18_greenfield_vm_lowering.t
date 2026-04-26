use strict;
use warnings;
use Test::More;

use lib 'lib';
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Interface;
use GraphQL::Houtou::Type::Scalar qw($String);

my $Node = GraphQL::Houtou::Type::Interface->new(
  name => 'VmNode',
  fields => {
    id => { type => $String },
  },
  tag_resolver => sub { $_[0]{kind} },
);

my $User = GraphQL::Houtou::Type::Object->new(
  name => 'VmUser',
  interfaces => [ $Node ],
  runtime_tag => 'user',
  fields => {
    id => { type => $String },
  },
);

my $Query = GraphQL::Houtou::Type::Object->new(
  name => 'VmQuery',
  fields => {
    viewer => {
      type => $User,
      resolve => sub { return { id => 'u1' } },
    },
    node => {
      type => $Node,
      resolve => sub { return { kind => 'user', id => 'u2' } },
    },
  },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => $Query,
  types => [ $User, $Node ],
);

subtest 'schema can lower operation into VM program' => sub {
  my $vm = $schema->compile_vm_operation('{ viewer { id } node { id } }');
  isa_ok $vm, 'GraphQL::Houtou::Runtime::VMProgram';
  isa_ok $vm->root_block, 'GraphQL::Houtou::Runtime::VMBlock';
  is $vm->operation_type, 'query', 'vm program keeps operation type';
  my ($viewer, $node) = @{ $vm->root_block->ops || [] };
  like $viewer->opcode, qr/^RESOLVE_.*:COMPLETE_OBJECT$/, 'viewer lowers to object completion opcode';
  like $node->opcode, qr/^RESOLVE_.*:COMPLETE_ABSTRACT$/, 'node lowers to abstract completion opcode';
  is $node->abstract_child_blocks->{VmUser}, 'QUERY.node.VmUser#1',
    'abstract op keeps lowered child block mapping';
  ok $viewer->resolve_handler, 'viewer op binds resolve handler';
  ok $viewer->complete_handler, 'viewer op binds complete handler';
  ok $viewer->resolve_dispatch, 'viewer op binds resolve dispatch coderef';
  ok $viewer->complete_dispatch, 'viewer op binds complete dispatch coderef';
  ok $viewer->opcode_code, 'viewer op binds numeric opcode code';
  is $viewer->resolve_code, 2, 'viewer op binds resolve family code';
  is $viewer->complete_code, 2, 'viewer op binds complete family code';
  isa_ok $vm->block_by_name('QUERY.node.VmUser#1'), 'GraphQL::Houtou::Runtime::VMBlock',
    'vm program keeps direct block map';
};

subtest 'VM program descriptor can round-trip through schema helpers' => sub {
  my $descriptor = $schema->compile_vm_operation_descriptor('{ viewer { id } }');
  my $vm = $schema->inflate_vm_operation($descriptor);
  isa_ok $vm, 'GraphQL::Houtou::Runtime::VMProgram';
  isa_ok $vm->root_block, 'GraphQL::Houtou::Runtime::VMBlock';
  is $vm->root_block->ops->[0]->field_name, 'viewer', 'inflated VM program keeps field op';
  ok $vm->root_block->ops->[0]->opcode_code, 'inflated VM op keeps numeric opcode code';
};

subtest 'schema can emit XS-friendly native VM descriptor' => sub {
  my $descriptor = $schema->compile_vm_native_descriptor('{ viewer { id } node { id } }');
  ok defined $descriptor->{root_block_index}, 'native descriptor keeps root block index';
  ok ref($descriptor->{blocks}) eq 'ARRAY' && @{$descriptor->{blocks}} >= 2,
    'native descriptor keeps indexed blocks';
  my $root = $descriptor->{blocks}[ $descriptor->{root_block_index} ];
  ok ref($root->{slots}) eq 'ARRAY' && @{$root->{slots}} >= 2,
    'native block keeps compact slot table';
  ok $root->{ops}[0]{opcode_code}, 'native op keeps opcode code';
  ok defined $root->{ops}[0]{slot_index}, 'native op keeps slot index';
  ok exists $root->{ops}[1]{abstract_child_block_indexes}{VmUser},
    'native op keeps abstract child block indexes';
};

done_testing;
