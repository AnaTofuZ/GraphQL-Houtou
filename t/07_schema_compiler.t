use strict;
use warnings;

use Test::More 0.98;

use GraphQL::Houtou::Directive;
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Enum;
use GraphQL::Houtou::Type::InputObject;
use GraphQL::Houtou::Type::Interface;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($Boolean $Int $String);
use GraphQL::Houtou::Type::Union;
use GraphQL::Houtou::Schema::Compiler qw(compile_schema);
use GraphQL::Houtou::Schema::Compiler::PP ();
use GraphQL::Houtou::XS::SchemaCompiler qw(compile_schema_xs);

my $Node;
my $User;

$Node = GraphQL::Houtou::Type::Interface->new(
  name => 'Node',
  fields => {
    id => { type => $String->non_null },
  },
  resolve_type => sub { $User },
);

my $Status = GraphQL::Houtou::Type::Enum->new(
  name => 'Status',
  values => {
    ACTIVE => {},
    DISABLED => {
      deprecation_reason => 'Use ACTIVE instead',
    },
  },
);

my $Filter = GraphQL::Houtou::Type::InputObject->new(
  name => 'Filter',
  fields => {
    q => { type => $String },
    limit => { type => $Int, default_value => 20 },
    exact => { type => $Boolean, default_value => 0 },
  },
);

$User = GraphQL::Houtou::Type::Object->new(
  name => 'User',
  interfaces => [ $Node ],
  is_type_of => sub { ref($_[0]) eq 'HASH' && $_[0]{kind} && $_[0]{kind} eq 'user' },
  fields => {
    id => { type => $String->non_null },
    name => { type => $String },
    status => { type => $Status },
  },
);

my $SearchResult = GraphQL::Houtou::Type::Union->new(
  name => 'SearchResult',
  types => [ $User ],
  resolve_type => sub { $User },
);

my $auth = GraphQL::Houtou::Directive->new(
  name => 'auth',
  locations => [ qw(FIELD OBJECT) ],
  args => {
    role => { type => $String->non_null },
  },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'Query',
    fields => {
      viewer => {
        type => $User,
        directives => [
          { name => 'auth', arguments => { role => 'reader' } },
        ],
        resolve => sub { +{ kind => 'user', id => 'u1', name => 'Ana', status => 'ACTIVE' } },
      },
      search => {
        type => $SearchResult->list->non_null,
        args => {
          filter => { type => $Filter },
          ids => { type => $String->non_null->list },
        },
        resolve => sub { [] },
      },
    },
  ),
  types => [ $User, $Node, $SearchResult, $Filter, $Status ],
  directives => [ @GraphQL::Houtou::Directive::SPECIFIED_DIRECTIVES, $auth ],
);

my $compiled = compile_schema($schema);
my $compiled_pp = GraphQL::Houtou::Schema::Compiler::PP::compile_schema($schema);
my $compiled_xs = compile_schema_xs($schema);

sub _strip_runtime {
  my ($value) = @_;

  if (!ref $value) {
    return $value;
  }

  if (ref $value eq 'ARRAY') {
    return [ map _strip_runtime($_), @$value ];
  }

  if (ref $value eq 'HASH') {
    my %copy;
    for my $key (sort keys %$value) {
      next if $key =~ /\A(?:source_|resolve|subscribe|serialize|parse_value|resolve_type|is_type_of)\z/;
      $copy{$key} = _strip_runtime($value->{$key});
    }
    return \%copy;
  }

  return ref $value;
}

subtest 'facade, PP, and XS agree on normalized shape' => sub {
  is_deeply _strip_runtime($compiled), _strip_runtime($compiled_pp), 'facade matches PP';
  is_deeply _strip_runtime($compiled), _strip_runtime($compiled_xs), 'facade matches XS';
};

subtest 'Houtou wrappers stay in the Houtou namespace' => sub {
  isa_ok $schema, 'GraphQL::Houtou::Schema';
  isa_ok $schema->query, 'GraphQL::Houtou::Type::Object';
  isa_ok $schema->query->fields->{viewer}{type}, 'GraphQL::Houtou::Type::Object';
  isa_ok $schema->query->fields->{search}{type}, 'GraphQL::Houtou::Type::NonNull';
  isa_ok $schema->query->fields->{search}{type}->of, 'GraphQL::Houtou::Type::List';
  isa_ok $schema->query->fields->{search}{args}{ids}{type}->of, 'GraphQL::Houtou::Type::NonNull';
  isa_ok $schema->directives->[-1], 'GraphQL::Houtou::Directive';
  isa_ok $schema->name2type->{String}, 'GraphQL::Houtou::Type::Scalar';
  ok !$schema->query->fields->{search}{type}->isa('GraphQL::Type::NonNull'), 'non-null wrapper no longer uses upstream class';
  ok !$schema->query->fields->{search}{type}->of->isa('GraphQL::Type::List'), 'list wrapper no longer uses upstream class';
  ok !$schema->name2type->{String}->isa('GraphQL::Type::Scalar'), 'scalar no longer uses upstream class';
};

subtest 'roots are normalized' => sub {
  is_deeply $compiled->{roots}, {
    query => 'Query',
    mutation => undef,
    subscription => undef,
  };
};

subtest 'named types are compiled' => sub {
  is $compiled->{types}{Query}{kind}, 'OBJECT', 'query root kind';
  is $compiled->{types}{Node}{kind}, 'INTERFACE', 'interface kind';
  is $compiled->{types}{SearchResult}{kind}, 'UNION', 'union kind';
  is $compiled->{types}{Filter}{kind}, 'INPUT_OBJECT', 'input object kind';
  is $compiled->{types}{Status}{kind}, 'ENUM', 'enum kind';
};

subtest 'field and argument type references are normalized' => sub {
  is $compiled->{types}{Query}{fields}{viewer}{type}{kind}, 'NAMED', 'named field type stays named';
  is $compiled->{types}{Query}{fields}{viewer}{type}{name}, 'User', 'field type name is preserved';

  is $compiled->{types}{Query}{fields}{search}{type}{kind}, 'NON_NULL', 'non-null wrapper is preserved';
  is $compiled->{types}{Query}{fields}{search}{type}{of}{kind}, 'LIST', 'list wrapper is preserved';
  is $compiled->{types}{Query}{fields}{search}{type}{of}{of}{name}, 'SearchResult', 'nested named type is preserved';

  is $compiled->{types}{Query}{fields}{search}{args}{ids}{type}{kind}, 'LIST', 'argument list wrapper is preserved';
  is $compiled->{types}{Query}{fields}{search}{args}{ids}{type}{of}{kind}, 'NON_NULL', 'argument nested non-null wrapper is preserved';
  is $compiled->{types}{Query}{fields}{search}{args}{ids}{type}{of}{of}{name}, 'String', 'argument leaf type name is preserved';
};

subtest 'input fields and enum values carry metadata' => sub {
  is $compiled->{types}{Filter}{fields}{limit}{has_default_value}, 1, 'default value flag is set';
  is $compiled->{types}{Filter}{fields}{limit}{default_value}, 20, 'default value is preserved';
  is $compiled->{types}{Status}{values}{DISABLED}{is_deprecated}, 1, 'enum deprecation is preserved';
  is $compiled->{types}{Status}{values}{DISABLED}{deprecation_reason}, 'Use ACTIVE instead', 'enum deprecation reason is preserved';
};

subtest 'abstract type relationships are precomputed' => sub {
  is_deeply $compiled->{types}{User}{interfaces}, ['Node'], 'object interface names are preserved';
  is_deeply $compiled->{interface_implementations}{Node}, ['User'], 'interface implementation map is built';
  is_deeply $compiled->{possible_types}{Node}, ['User'], 'interface possible types are built';
  is_deeply $compiled->{possible_types}{SearchResult}, ['User'], 'union possible types are built';
};

subtest 'directives are normalized' => sub {
  ok exists $compiled->{directives}{auth}, 'custom directive is present';
  is_deeply $compiled->{directives}{auth}{locations}, [qw(FIELD OBJECT)], 'directive locations are preserved';
  is $compiled->{directives}{auth}{args}{role}{type}{kind}, 'NON_NULL', 'directive arg type is normalized';
  is $compiled->{types}{Query}{fields}{viewer}{directives}[0]{name}, 'auth', 'field directive instance is preserved';
  is $compiled->{types}{Query}{fields}{viewer}{directives}[0]{arguments}{role}, 'reader', 'field directive args are preserved';
};

done_testing;
