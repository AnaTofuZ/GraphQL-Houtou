use 5.014;
use strict;
use warnings;

use Test::More;

use GraphQL::Houtou::DataLoader;
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::List;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

sub loader_for {
  my ($prefix, $seen) = @_;
  return GraphQL::Houtou::DataLoader->new(
    batch => sub {
      my ($keys) = @_;
      push @$seen, [ @$keys ];
      return [ map { "$prefix:$_" } @$keys ];
    },
  );
}

subtest 'fixed loader uses a source key without a resolver closure' => sub {
  my @seen;
  my $loader = loader_for('user', \@seen);
  my $Row = GraphQL::Houtou::Type::Object->new(
    name => 'FixedLoaderRow',
    fields => {
      user => {
        type => $String,
        loader => {
          context_key => 'users',
          key => { source_key => 'user_id' },
        },
      },
    },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'FixedLoaderQuery',
      fields => {
        rows => {
          type => GraphQL::Houtou::Type::List->new(of => $Row),
          resolve => sub {
            return [
              { user_id => '1' },
              { user_id => '2' },
              { user_id => '1' },
            ];
          },
        },
      },
    ),
    types => [ $Row ],
  );
  my $runtime = $schema->build_native_runtime(async => 1);
  my $result = $runtime->execute_document(
    '{ rows { user } }',
    context => { users => $loader },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
  );

  is_deeply $result->{data}{rows}, [
    { user => 'user:1' },
    { user => 'user:2' },
    { user => 'user:1' },
  ], 'fixed loader results preserve item positions';
  is_deeply \@seen, [ [qw(1 2)] ], 'duplicate keys are batched once';
};

subtest 'router partitions items by source route key' => sub {
  my (@primary_seen, @archive_seen);
  my $primary = loader_for('primary', \@primary_seen);
  my $archive = loader_for('archive', \@archive_seen);
  my $Row = GraphQL::Houtou::Type::Object->new(
    name => 'RoutedLoaderRow',
    fields => {
      user => {
        type => $String,
        loader => {
          router => {
            context_key => 'user_loaders',
            route_key => { source_key => 'store' },
          },
          key => { source_key => 'user_id' },
        },
      },
    },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'RoutedLoaderQuery',
      fields => {
        rows => {
          type => GraphQL::Houtou::Type::List->new(of => $Row),
          resolve => sub {
            return [
              { store => 'primary', user_id => '1' },
              { store => 'archive', user_id => '2' },
              { store => 'primary', user_id => '3' },
            ];
          },
        },
      },
    ),
    types => [ $Row ],
  );
  my $runtime = $schema->build_native_runtime(async => 1);
  my $result = $runtime->execute_document(
    '{ rows { user } }',
    context => {
      user_loaders => {
        primary => $primary,
        archive => $archive,
      },
    },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for(
      $primary, $archive,
    ),
  );

  is_deeply $result->{data}{rows}, [
    { user => 'primary:1' },
    { user => 'archive:2' },
    { user => 'primary:3' },
  ], 'router returns values from the selected loader';
  is_deeply \@primary_seen, [ [qw(1 3)] ], 'primary items share one batch';
  is_deeply \@archive_seen, [ [qw(2)] ], 'archive items use a separate batch';
};

subtest 'argument key is supported' => sub {
  my @seen;
  my $loader = loader_for('arg', \@seen);
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'ArgumentLoaderQuery',
      fields => {
        user => {
          type => $String,
          args => { id => { type => $String } },
          loader => {
            context_key => 'users',
            key => { argument => 'id' },
          },
        },
      },
    ),
  );
  my $runtime = $schema->build_native_runtime(async => 1);
  my $result = $runtime->execute_document(
    '{ user(id: "9") }',
    context => { users => $loader },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
  );

  is $result->{data}{user}, 'arg:9', 'argument is used as the loader key';
  is_deeply \@seen, [ [qw(9)] ], 'argument key reaches the batch callback';
};

subtest 'native loader path preserves custom cache keys' => sub {
  my @seen;
  my $loader = GraphQL::Houtou::DataLoader->new(
    cache_key => sub { lc $_[0] },
    batch => sub {
      my ($keys) = @_;
      push @seen, [ @$keys ];
      return [ map { "cached:$_" } @$keys ];
    },
  );
  my $Row = GraphQL::Houtou::Type::Object->new(
    name => 'CacheKeyLoaderRow',
    fields => {
      value => {
        type => $String,
        loader => {
          context_key => 'values',
          key => { source_key => 'id' },
        },
      },
    },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'CacheKeyLoaderQuery',
      fields => {
        rows => {
          type => GraphQL::Houtou::Type::List->new(of => $Row),
          resolve => sub { [ { id => 'A' }, { id => 'a' } ] },
        },
      },
    ),
    types => [ $Row ],
  );
  my $runtime = $schema->build_native_runtime(async => 1);
  my $result = $runtime->execute_document(
    '{ rows { value } }',
    context => { values => $loader },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($loader),
  );

  is_deeply $result->{data}{rows}, [
    { value => 'cached:A' },
    { value => 'cached:A' },
  ], 'custom cache key shares the first ticket';
  is_deeply \@seen, [ ['A'] ], 'equivalent keys occupy one batch slot';
};

subtest 'DataLoader subclasses retain overridden load semantics' => sub {
  {
    package Local::DeclarativeLoaderSubclass;
    our @ISA = ('GraphQL::Houtou::DataLoader');
    sub load {
      my ($self, $key) = @_;
      $self->{override_calls}++;
      return GraphQL::Houtou::DataLoader::Ticket->resolved("override:$key");
    }
  }

  my $loader = Local::DeclarativeLoaderSubclass->new(
    batch => sub { die "overridden load must bypass batch\n" },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'SubclassLoaderQuery',
      fields => {
        value => {
          type => $String,
          args => { id => { type => $String } },
          loader => {
            context_key => 'values',
            key => { argument => 'id' },
          },
        },
      },
    ),
  );
  my $runtime = $schema->build_native_runtime(async => 1);
  my $result = $runtime->execute_document(
    '{ value(id: "7") }',
    context => { values => $loader },
  );

  is $result->{data}{value}, 'override:7', 'subclass load method is honored';
  is $loader->{override_calls}, 1, 'override is called exactly once';
};

subtest 'invalid declarations fail while building the runtime graph' => sub {
  my @invalid = (
    [
      { key => { source_key => 'id' } },
      qr/exactly one of context_key or router/,
    ],
    [
      {
        context_key => 'users',
        router => {
          context_key => 'routes',
          route_key => { source_key => 'kind' },
        },
        key => { source_key => 'id' },
      },
      qr/exactly one of context_key or router/,
    ],
    [
      { context_key => 'users', key => {} },
      qr/requires exactly one of source_key or argument/,
    ],
  );

  for my $case (@invalid) {
    my ($loader, $pattern) = @$case;
    my $schema = GraphQL::Houtou::Schema->new(
      query => GraphQL::Houtou::Type::Object->new(
        name => 'InvalidLoaderQuery',
        fields => {
          value => {
            type => $String,
            loader => $loader,
          },
        },
      ),
    );
    my $ok = eval { $schema->build_native_runtime; 1 };
    ok !$ok, 'invalid loader declaration is rejected';
    like $@, $pattern, 'validation reports the declaration error';
  }
};

done_testing;
