use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);

use lib 'lib';
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Runtime qw(
  load_native_bundle
  load_native_runtime
  native_bundle_summary
  native_codes
  native_runtime_summary
);
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
  my $vm = $schema->compile_operation('{ viewer { id } node { id } }');
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
  my $descriptor = $schema->compile_operation_descriptor('{ viewer { id } }');
  my $vm = $schema->inflate_operation($descriptor);
  isa_ok $vm, 'GraphQL::Houtou::Runtime::VMProgram';
  isa_ok $vm->root_block, 'GraphQL::Houtou::Runtime::VMBlock';
  is $vm->root_block->ops->[0]->field_name, 'viewer', 'inflated VM program keeps field op';
  ok $vm->root_block->ops->[0]->opcode_code, 'inflated VM op keeps numeric opcode code';
};

subtest 'schema can emit XS-friendly native VM descriptor' => sub {
  my $descriptor = $schema->compile_native_operation_descriptor('{ viewer { id } node { id } }');
  ok defined $descriptor->{root_block_index}, 'native descriptor keeps root block index';
  ok ref($descriptor->{blocks_compact}) eq 'ARRAY' && @{$descriptor->{blocks_compact}} >= 2,
    'native descriptor keeps indexed blocks';
  my $root = $descriptor->{blocks_compact}[ $descriptor->{root_block_index} ];
  ok ref($root->[3]) eq 'ARRAY' && @{$root->[3]} >= 2,
    'native block keeps compact slot table';
  ok defined $root->[3][0][3],
    'native block slot keeps schema slot index';
  ok $root->[4][0][0], 'native op keeps opcode code';
  ok defined $root->[4][0][4], 'native op keeps slot index';
  ok exists $root->[4][1][6]{VmUser},
    'native op keeps abstract child block indexes';
};

subtest 'schema can emit bundled native runtime and VM descriptor' => sub {
  my $bundle = $schema->compile_native_bundle_descriptor('{ viewer { id } node { id } }');
  my $codes = native_codes();
  ok ref($bundle->{runtime}{slot_catalog_compact}) eq 'ARRAY' && @{$bundle->{runtime}{slot_catalog_compact}} >= 2,
    'native bundle keeps runtime slot catalog';
  ok defined $bundle->{runtime}{slot_catalog_compact}[0][5],
    'native bundle keeps runtime numeric family code';
  is $bundle->{runtime}{slot_catalog_compact}[1][5], $codes->{family_abstract},
    'native runtime family code matches XS header constant';
  is $bundle->{runtime}{slot_catalog_compact}[1][7], $codes->{kind_interface},
    'native runtime slot keeps return type kind code';
  ok ref($bundle->{program}{blocks_compact}) eq 'ARRAY' && @{$bundle->{program}{blocks_compact}} >= 2,
    'native bundle keeps vm program blocks';
  is $bundle->{program}{operation_type_code}, $codes->{optype_query},
    'native bundle keeps operation type code';
  is $bundle->{program}{blocks_compact}[ $bundle->{program}{root_block_index} ][2], $codes->{family_object},
    'native bundle keeps block family code';
  ok defined $bundle->{program}{blocks_compact}[ $bundle->{program}{root_block_index} ][4][0][4],
    'native bundle op keeps slot index';
  is $bundle->{program}{blocks_compact}[ $bundle->{program}{root_block_index} ][4][0][1], $codes->{resolve_explicit},
    'native op resolve code matches XS header constant';
  is $bundle->{program}{blocks_compact}[ $bundle->{program}{root_block_index} ][4][1][3], $codes->{dispatch_tag},
    'native op dispatch family code matches XS header constant';
};

subtest 'native VM bundle descriptor can round-trip through JSON helpers' => sub {
  my ($fh, $path) = tempfile();
  close $fh;

  my $descriptor = $schema->dump_native_bundle_descriptor('{ viewer { id } node { id } }', $path);
  my $loaded = $schema->load_native_bundle_descriptor($path);

  is_deeply $loaded, $descriptor, 'native bundle survives JSON file boundary';
};

subtest 'native VM bundle can inflate back into a VM program' => sub {
  my $bundle = $schema->compile_native_bundle_descriptor('{ viewer { id } node { id } }');
  my $vm = $schema->inflate_vm_native_bundle_descriptor($bundle);
  isa_ok $vm, 'GraphQL::Houtou::Runtime::VMProgram';
  isa_ok $vm->root_block, 'GraphQL::Houtou::Runtime::VMBlock';
  is $vm->root_block->ops->[0]->field_name, 'viewer', 'inflated native bundle restores field name';
};

subtest 'XS can inflate native VM bundle descriptor into a native handle' => sub {
  my $bundle = $schema->compile_native_bundle_descriptor('{ viewer { id } node { id } }');
  my $codes = native_codes();
  my $handle = load_native_bundle($bundle);

  isa_ok $handle, 'GraphQL::Houtou::Runtime::NativeBundle';

  my $summary = native_bundle_summary($handle);
  is $summary->{runtime_slot_count}, scalar(@{ $bundle->{runtime}{slot_catalog_compact} || [] }),
    'XS native handle sees runtime slot count';
  is $summary->{block_count}, scalar(@{ $bundle->{program}{blocks_compact} || [] }),
    'XS native handle sees block count';
  is $summary->{root_block_index}, $bundle->{program}{root_block_index},
    'XS native handle keeps root block index';
  is $summary->{operation_type_code}, $codes->{optype_query},
    'XS native handle keeps operation type code';
  is $summary->{root_family_code}, $codes->{family_object},
    'XS native handle keeps root block family code';
  is_deeply $summary->{root_dispatch_family_codes}, [ $codes->{dispatch_generic}, $codes->{dispatch_tag} ],
    'XS native handle keeps root op dispatch family codes';
};

subtest 'XS can inflate runtime schema into a native runtime handle' => sub {
  my $runtime = $schema->build_runtime;
  my $handle = load_native_runtime($runtime->to_native_exec_struct);

  isa_ok $handle, 'GraphQL::Houtou::Runtime::NativeRuntime';

  my $summary = native_runtime_summary($handle);
  is $summary->{runtime_slot_count}, scalar(@{ $runtime->slot_catalog || [] }),
    'native runtime handle sees slot catalog count';
  ok $summary->{has_runtime_cache}, 'native runtime handle keeps runtime cache';
  ok $summary->{has_name2type}, 'native runtime handle keeps name2type map';
  ok $summary->{has_dispatch_index}, 'native runtime handle keeps dispatch index';
};

done_testing;
