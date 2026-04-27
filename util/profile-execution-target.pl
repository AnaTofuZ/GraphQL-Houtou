use 5.014;
use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use Getopt::Long qw(GetOptions);

BEGIN {
  my $root = File::Spec->catdir($Bin, '..');
  my $upstream = File::Spec->catdir($root, '..', 'graphql-perl');

  unshift @INC,
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'blib', 'lib'),
    File::Spec->catdir($root, 'blib', 'arch'),
    File::Spec->catdir($upstream, 'lib');
}

use GraphQL::Execution qw(execute);
use GraphQL::Language::Parser qw(parse);

use GraphQL::Schema;
use GraphQL::Type::Interface;
use GraphQL::Type::Object;
use GraphQL::Type::Scalar ();
use GraphQL::Type::Union;

use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Interface ();
use GraphQL::Houtou::Type::Object ();
use GraphQL::Houtou::Type::Scalar ();
use GraphQL::Houtou::Type::Union ();

my $case_name;
my $target;
my $iterations = 300;

GetOptions(
  'case=s' => \$case_name,
  'target=s' => \$target,
  'iterations=i' => \$iterations,
) or die usage();

die usage() if !$case_name || !$target;

{
  package Local::ImmediatePromise;

  sub new {
    my ($class, %args) = @_;
    return bless {
      status => $args{status},
      values => $args{values} || [],
    }, $class;
  }

  sub resolve {
    my ($class, @values) = @_;
    return $class->new(status => 'fulfilled', values => \@values);
  }

  sub reject {
    my ($class, @values) = @_;
    return $class->new(status => 'rejected', values => \@values);
  }

  sub all {
    my ($class, @values) = @_;
    my @rows;

    for my $value (@values) {
      if (ref($value) && eval { $value->isa(__PACKAGE__) }) {
        return $class->reject(@{ $value->{values} })
          if ($value->{status} || '') eq 'rejected';
        push @rows, [ @{ $value->{values} } ];
      } else {
        push @rows, [ $value ];
      }
    }

    return $class->resolve(@rows);
  }

  sub then {
    my ($self, $on_fulfilled, $on_rejected) = @_;
    my $callback = ($self->{status} || '') eq 'rejected'
      ? $on_rejected
      : $on_fulfilled;

    return __PACKAGE__->new(
      status => $self->{status},
      values => [ @{ $self->{values} } ],
    ) if !$callback;

    my @ret = eval { $callback->(@{ $self->{values} }) };
    return __PACKAGE__->reject($@) if $@;
    return $ret[0]
      if @ret == 1 && ref($ret[0]) && eval { $ret[0]->isa(__PACKAGE__) };
    return __PACKAGE__->resolve(@ret);
  }

  sub get {
    my ($self) = @_;
    die @{ $self->{values} } if ($self->{status} || '') eq 'rejected';
    return wantarray ? @{ $self->{values} } : $self->{values}[0];
  }
}

sub promise_code {
  return {
    resolve => sub { Local::ImmediatePromise->resolve(@_) },
    reject => sub { Local::ImmediatePromise->reject(@_) },
    all => sub { Local::ImmediatePromise->all(@_) },
    new => sub { Local::ImmediatePromise->new },
    then => sub {
      my ($promise, $on_fulfilled, $on_rejected) = @_;
      return $promise->then($on_fulfilled, $on_rejected);
    },
    is_promise => sub {
      my ($value) = @_;
      return ref($value) eq 'Local::ImmediatePromise';
    },
  };
}

sub maybe_get {
  my ($value) = @_;
  return (ref($value) && eval { $value->isa('Local::ImmediatePromise') })
    ? scalar $value->get
    : $value;
}

sub build_upstream_schema {
  my ($include_async_case) = @_;

  my $User = GraphQL::Type::Object->new(
    name => 'User',
    fields => {
      id => { type => $GraphQL::Type::Scalar::ID->non_null },
      name => { type => $GraphQL::Type::Scalar::String->non_null },
    },
  );

  my $NamedEntity = GraphQL::Type::Interface->new(
    name => 'NamedEntity',
    resolve_type => sub { 'User' },
    fields => {
      name => { type => $GraphQL::Type::Scalar::String->non_null },
    },
  );

  my $SearchResult = GraphQL::Type::Union->new(
    name => 'SearchResult',
    resolve_type => sub { 'User' },
    types => [ $User ],
  );

  my %fields = (
    hello => {
      type => $GraphQL::Type::Scalar::String->non_null,
      resolve => sub { 'world' },
    },
    greet => {
      type => $GraphQL::Type::Scalar::String->non_null,
      args => {
        name => { type => $GraphQL::Type::Scalar::String->non_null },
      },
      resolve => sub {
        my ($root, $args) = @_;
        return "hello $args->{name}";
      },
    },
    user => {
      type => $User,
      args => {
        id => { type => $GraphQL::Type::Scalar::ID->non_null },
      },
      resolve => sub {
        my ($root, $args) = @_;
        return {
          id => $args->{id},
          name => "user:$args->{id}",
        };
      },
    },
    users => {
      type => $User->list->non_null,
      resolve => sub {
        return [
          { id => '21', name => 'user:21' },
          { id => '22', name => 'user:22' },
        ];
      },
    },
    searchResult => {
      type => $SearchResult,
      resolve => sub {
        return {
          id => '13',
          name => 'search:13',
        };
      },
    },
  );

  if ($include_async_case) {
    $fields{asyncHello} = {
      type => $GraphQL::Type::Scalar::String->non_null,
      resolve => sub { Local::ImmediatePromise->resolve('async-world') },
    };
    $fields{asyncList} = {
      type => $GraphQL::Type::Scalar::String->non_null->list->non_null,
      resolve => sub {
        return [
          Local::ImmediatePromise->resolve('alpha'),
          Local::ImmediatePromise->resolve('beta'),
        ];
      },
    };
  }

  my $Query = GraphQL::Type::Object->new(name => 'Query', fields => \%fields);

  return GraphQL::Schema->new(
    query => $Query,
    types => [ $User, $NamedEntity, $SearchResult ],
  );
}

sub build_houtou_schema {
  my ($include_async_case) = @_;

  my $User = GraphQL::Houtou::Type::Object->new(
    name => 'User',
    fields => {
      id => { type => $GraphQL::Houtou::Type::Scalar::ID->non_null },
      name => { type => $GraphQL::Houtou::Type::Scalar::String->non_null },
    },
  );

  my $NamedEntity = GraphQL::Houtou::Type::Interface->new(
    name => 'NamedEntity',
    resolve_type => sub { 'User' },
    fields => {
      name => { type => $GraphQL::Houtou::Type::Scalar::String->non_null },
    },
  );

  my $SearchResult = GraphQL::Houtou::Type::Union->new(
    name => 'SearchResult',
    resolve_type => sub { 'User' },
    types => [ $User ],
  );

  my %fields = (
    hello => {
      type => $GraphQL::Houtou::Type::Scalar::String->non_null,
      resolver_mode => 'native',
      resolve => sub { 'world' },
    },
    greet => {
      type => $GraphQL::Houtou::Type::Scalar::String->non_null,
      args => {
        name => { type => $GraphQL::Houtou::Type::Scalar::String->non_null },
      },
      resolver_mode => 'native',
      resolve => sub {
        my ($root, $args) = @_;
        return "hello $args->{name}";
      },
    },
    user => {
      type => $User,
      args => {
        id => { type => $GraphQL::Houtou::Type::Scalar::ID->non_null },
      },
      resolver_mode => 'native',
      resolve => sub {
        my ($root, $args) = @_;
        return {
          id => $args->{id},
          name => "user:$args->{id}",
        };
      },
    },
    users => {
      type => $User->list->non_null,
      resolver_mode => 'native',
      resolve => sub {
        return [
          { id => '21', name => 'user:21' },
          { id => '22', name => 'user:22' },
        ];
      },
    },
    searchResult => {
      type => $SearchResult,
      resolver_mode => 'native',
      resolve => sub {
        return {
          id => '13',
          name => 'search:13',
        };
      },
    },
  );

  if ($include_async_case) {
    $fields{asyncHello} = {
      type => $GraphQL::Houtou::Type::Scalar::String->non_null,
      resolver_mode => 'native',
      resolve => sub { Local::ImmediatePromise->resolve('async-world') },
    };
    $fields{asyncList} = {
      type => $GraphQL::Houtou::Type::Scalar::String->non_null->list->non_null,
      resolver_mode => 'native',
      resolve => sub {
        return [
          Local::ImmediatePromise->resolve('alpha'),
          Local::ImmediatePromise->resolve('beta'),
        ];
      },
    };
  }

  my $Query = GraphQL::Houtou::Type::Object->new(name => 'Query', fields => \%fields);

  return GraphQL::Houtou::Schema->new(
    query => $Query,
    types => [ $User, $NamedEntity, $SearchResult ],
  );
}

my %cases = (
  simple_scalar => {
    query => '{ hello greet(name: "houtou") }',
  },
  nested_variable_object => {
    query => 'query q($id: ID!) { user(id: $id) { id name } }',
    vars => { id => '42' },
    op => 'q',
  },
  list_of_objects => {
    query => '{ users { id name } }',
  },
  abstract_with_fragment => {
    query => '{ searchResult { __typename ... on User { id name } } }',
  },
  async_scalar => {
    query => '{ asyncHello }',
    promise => 1,
  },
  async_list => {
    query => '{ asyncList }',
    promise => 1,
  },
);

die "Unknown case: $case_name\n" unless exists $cases{$case_name};
my $spec = $cases{$case_name};

my %targets = map { $_ => 1 } qw(
  upstream_ast
  upstream_string
  houtou_runtime_cached_perl
  houtou_runtime_native_bundle
);
die "Unknown target: $target\n" unless $targets{$target};
die "Target $target is not available for promise cases\n"
  if $spec->{promise} && $target eq 'houtou_runtime_native_bundle';

DB::disable_profile() if DB->can('disable_profile');

my $up_schema = build_upstream_schema($spec->{promise});
my $houtou_schema = build_houtou_schema($spec->{promise});
my $query = $spec->{query};
my $vars = $spec->{vars};
my $op = $spec->{op};
my $promise = $spec->{promise} ? promise_code() : undef;
my $up_ast = parse($query);
my $runtime = $houtou_schema->build_runtime;
my $program = $runtime->compile_program($query);
my $native_runtime = !$promise ? $houtou_schema->build_native_runtime : undef;
my $native_bundle = $native_runtime
  ? $native_runtime->compile_bundle(
      $program,
      (defined($vars) ? (variables => $vars) : ()),
    )
  : undef;

my %dispatch = (
  upstream_ast => sub {
    return maybe_get(execute($up_schema, $up_ast, undef, undef, $vars, $op, undef, $promise));
  },
  upstream_string => sub {
    return maybe_get(execute($up_schema, $query, undef, undef, $vars, $op, undef, $promise));
  },
  houtou_runtime_cached_perl => sub {
    return maybe_get(
      $runtime->execute_program(
        $program,
        engine => 'perl',
        (defined($vars) ? (variables => $vars) : ()),
        ($promise ? (promise_code => $promise) : ()),
      )
    );
  },
  houtou_runtime_native_bundle => sub {
    return maybe_get($native_bundle->execute);
  },
);

my $runner = $dispatch{$target};
my $expected = $dispatch{$target}->();
die "Sanity check failed for $case_name/$target\n" if !defined $expected;

DB::enable_profile() if DB->can('enable_profile');
for (1 .. $iterations) {
  my $got = $runner->();
  require Data::Dumper;
  local $Data::Dumper::Sortkeys = 1;
  die "Result mismatch for $case_name/$target\n"
    if Data::Dumper::Dumper($got) ne Data::Dumper::Dumper($expected);
}
DB::disable_profile() if DB->can('disable_profile');

print(
  DB->can('enable_profile')
    ? "profiled case=$case_name target=$target iterations=$iterations\n"
    : "executed case=$case_name target=$target iterations=$iterations (DB profile hooks unavailable)\n"
);

sub usage {
  return "Usage: $0 --case NAME --target NAME [--iterations N]\n";
}
