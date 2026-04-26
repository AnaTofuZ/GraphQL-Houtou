use strict;
use warnings;
use Test::More;

use lib 'lib';
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::XS::GreenfieldVM qw(
  execute_native_bundle_xs
  load_native_bundle_xs
  load_native_runtime_xs
);
use GraphQL::Houtou::Type::Interface;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

my $Node = GraphQL::Houtou::Type::Interface->new(
  name => 'VmExecNode',
  fields => {
    id => { type => $String },
  },
  tag_resolver => sub { $_[0]{kind} },
);

my $User = GraphQL::Houtou::Type::Object->new(
  name => 'VmExecUser',
  interfaces => [ $Node ],
  runtime_tag => 'user',
  fields => {
    id => { type => $String },
    name => { type => $String },
  },
);

my $Query = GraphQL::Houtou::Type::Object->new(
  name => 'VmExecQuery',
  fields => {
    viewer => {
      type => $User,
      resolve => sub { return { id => 'u1', name => 'Alice' } },
    },
    users => {
      type => GraphQL::Houtou::Type::List->new(of => $User),
      resolve => sub { return [ { id => 'u1', name => 'Alice' }, { id => 'u2', name => 'Bob' } ] },
    },
    node => {
      type => $Node,
      resolve => sub { return { kind => 'user', id => 'u3', name => 'Carol' } },
    },
  },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => $Query,
  types => [ $User, $Node ],
);

subtest 'schema can execute VM-lowered program' => sub {
  my $program = $schema->compile_vm_operation('{ viewer { id name } users { id } node { id } }');
  my $result = $schema->compile_runtime->execute_vm_program($program);
  is_deeply $result, {
    data => {
      viewer => { id => 'u1', name => 'Alice' },
      users => [
        { id => 'u1' },
        { id => 'u2' },
      ],
      node => { id => 'u3' },
    },
    errors => [],
  }, 'VM executor runs object/list/abstract fields';
};

subtest 'schema helper can compile and execute VM in one call' => sub {
  my $result = $schema->execute_vm_runtime('{ viewer { id } }');
  is_deeply $result, {
    data => { viewer => { id => 'u1' } },
    errors => [],
  }, 'schema helper executes VM runtime';
};

subtest 'VM descriptor can round-trip and still execute' => sub {
  my $descriptor = $schema->compile_vm_operation_descriptor('{ node { id } }');
  my $program = $schema->inflate_vm_operation($descriptor);
  my $result = $schema->compile_runtime->execute_vm_program($program);
  is_deeply $result, {
    data => { node => { id => 'u3' } },
    errors => [],
  }, 'inflated VM program executes abstract child blocks';
};

subtest 'native VM bundle descriptor can execute through schema helper' => sub {
  my $bundle = $schema->compile_vm_native_bundle_descriptor('{ node { id } }');
  my $result = $schema->execute_vm_native_bundle_descriptor($bundle);
  is_deeply $result, {
    data => { node => { id => 'u3' } },
    errors => [],
  }, 'native VM bundle executes through runtime slot catalog binding';
};

subtest 'schema helper can compile and execute native VM bundle in one call' => sub {
  my $result = $schema->execute_vm_native_runtime('{ viewer { id } }');
  is_deeply $result, {
    data => { viewer => { id => 'u1' } },
    errors => [],
  }, 'schema helper executes native VM bundle runtime';
};

subtest 'XS native bundle handle can execute directly' => sub {
  my $runtime = $schema->compile_runtime;
  my $native_runtime = load_native_runtime_xs($runtime);
  my $bundle = load_native_bundle_xs(
    $schema->compile_vm_native_bundle_descriptor('{ viewer { id name } node { id } }')
  );
  my $result = execute_native_bundle_xs($native_runtime, $bundle);
  is_deeply $result, {
    data => {
      viewer => { id => 'u1', name => 'Alice' },
      node => { id => 'u3' },
    },
    errors => [],
  }, 'direct XS native bundle execution works';
};

done_testing;
