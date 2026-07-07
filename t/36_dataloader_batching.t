use strict;
use warnings;

use Test::More;

BEGIN {
  eval { require Promise::XS; 1 }
    or plan skip_all => 'Promise::XS not available';
}

use GraphQL::Houtou qw(execute build_native_runtime);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String $Int $ID);
use GraphQL::Houtou::DataLoader;

# ---------------------------------------------------------------------------
# A small "database": posts belong to users, users have teams.
# ---------------------------------------------------------------------------
my %USERS = map { $_->{id} => $_ } (
  { id => '1', name => 'alice', team_id => 't1' },
  { id => '2', name => 'bob',   team_id => 't1' },
  { id => '3', name => 'carol', team_id => 't2' },
);
my %TEAMS = (
  t1 => { id => 't1', name => 'core' },
  t2 => { id => 't2', name => 'infra' },
);
my @POSTS = (
  { id => 'p1', title => 'one',   author_id => '1' },
  { id => 'p2', title => 'two',   author_id => '2' },
  { id => 'p3', title => 'three', author_id => '1' },
  { id => 'p4', title => 'four',  author_id => '3' },
);

my @user_batches;
my @team_batches;

sub make_loaders {
  @user_batches = ();
  @team_batches = ();
  my $users = GraphQL::Houtou::DataLoader->new(batch => sub {
    my ($ids) = @_;
    push @user_batches, [ @$ids ];
    return [ map { $USERS{$_} } @$ids ];
  });
  my $teams = GraphQL::Houtou::DataLoader->new(batch => sub {
    my ($ids) = @_;
    push @team_batches, [ @$ids ];
    return [ map { $TEAMS{$_} } @$ids ];
  });
  return ($users, $teams);
}

my $Team = GraphQL::Houtou::Type::Object->new(
  name => 'Team',
  fields => {
    id => { type => $ID },
    name => { type => $String },
  },
);

my $User = GraphQL::Houtou::Type::Object->new(
  name => 'User',
  fields => {
    id => { type => $ID },
    name => { type => $String },
    team => {
      type => $Team,
      resolve => sub {
        my ($user, undef, $context) = @_;
        return $context->{teams}->load($user->{team_id});
      },
    },
  },
);

my $Post = GraphQL::Houtou::Type::Object->new(
  name => 'Post',
  fields => {
    id => { type => $ID },
    title => { type => $String },
    author => {
      type => $User,
      resolve => sub {
        my ($post, undef, $context) = @_;
        return $context->{users}->load($post->{author_id});
      },
    },
  },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'Query',
    fields => {
      posts => {
        type => $Post->non_null->list,
        resolve => sub { [ @POSTS ] },
      },
      post => {
        type => $Post,
        args => { id => { type => $ID } },
        resolve => sub {
          my (undef, $args) = @_;
          my ($post) = grep { $_->{id} eq $args->{id} } @POSTS;
          return $post;
        },
      },
      missing_load => {
        type => $String,
        resolve => sub { Promise::XS::deferred()->promise },
      },
    },
  ),
  types => [ $Post, $User, $Team ],
);

subtest 'N+1 collapses to one batch per level' => sub {
  my ($users, $teams) = make_loaders();
  my $result = execute($schema, '{ posts { title author { name team { name } } } }', undef,
    context => { users => $users, teams => $teams },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($users, $teams),
  );
  is_deeply $result->{errors}, [], 'no errors';
  is scalar @{ $result->{data}{posts} }, 4, 'all posts';
  is $result->{data}{posts}[0]{author}{name}, 'alice', 'author resolved';
  is $result->{data}{posts}[0]{author}{team}{name}, 'core', 'nested team resolved';

  is scalar @user_batches, 1, 'users fetched in exactly one batch';
  is_deeply [ sort @{ $user_batches[0] } ], [ '1', '2', '3' ],
    'user batch contains each distinct author once';
  is scalar @team_batches, 1, 'teams fetched in exactly one batch';
  is_deeply [ sort @{ $team_batches[0] } ], [ 't1', 't2' ],
    'team batch deduplicated';
};

subtest 'result is returned synchronously with variables' => sub {
  my ($users, $teams) = make_loaders();
  my $result = execute($schema, 'query Q($id: ID) { post(id: $id) { author { name } } }',
    { id => 'p4' },
    context => { users => $users, teams => $teams },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($users, $teams),
  );
  is ref($result), 'HASH', 'plain envelope, not a promise';
  is $result->{data}{post}{author}{name}, 'carol', 'variables + loader work together';
};

subtest 'per-request cache dedupes and prime seeds it' => sub {
  my ($users, $teams) = make_loaders();
  $users->prime('1', { id => '1', name => 'cached-alice', team_id => 't1' });
  my $result = execute($schema, '{ a: post(id: "p1") { author { name } } b: post(id: "p3") { author { name } } }',
    undef,
    context => { users => $users, teams => $teams },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($users, $teams),
  );
  is_deeply $result->{errors}, [], 'no errors';
  is $result->{data}{a}{author}{name}, 'cached-alice', 'primed value used';
  is $result->{data}{b}{author}{name}, 'cached-alice', 'cache dedupes same key';
  is scalar @user_batches, 0, 'no batch needed when everything was primed';
};

subtest 'per-key errors fail only that field' => sub {
  my $flaky = GraphQL::Houtou::DataLoader->new(batch => sub {
    my ($ids) = @_;
    return [ map {
      $_ eq 'bad'
        ? GraphQL::Houtou::DataLoader::Error->new("no such user: $_\n")
        : $USERS{1}
    } @$ids ];
  });
  my $s = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'FlakyQuery',
      fields => {
        good => { type => $User, resolve => sub { $_[2]->{flaky}->load('1') } },
        bad => { type => $User, resolve => sub { $_[2]->{flaky}->load('bad') } },
      },
    ),
    types => [ $User, $Team ],
  );
  my $result = execute($s, '{ good { name } bad { name } }', undef,
    context => { flaky => $flaky },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($flaky),
  );
  is $result->{data}{good}{name}, 'alice', 'good key resolved';
  is $result->{data}{bad}, undef, 'bad key nulled';
  like $result->{errors}[0]{message}, qr/no such user: bad/, 'per-key error surfaced';
};

subtest 'batch function die fails the whole batch' => sub {
  my $boom = GraphQL::Houtou::DataLoader->new(batch => sub { die "db down\n" });
  my $s = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'BoomQuery',
      fields => {
        u => { type => $User, resolve => sub { $_[2]->{boom}->load('1') } },
      },
    ),
    types => [ $User, $Team ],
  );
  my $result = execute($s, '{ u { name } }', undef,
    context => { boom => $boom },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($boom),
  );
  like $result->{errors}[0]{message}, qr/db down/, 'batch failure becomes a field error';
};

subtest 'deadlock is detected instead of hanging' => sub {
  my ($users, $teams) = make_loaders();
  eval {
    execute($schema, '{ missing_load }', undef,
      context => { users => $users, teams => $teams },
      on_stall => GraphQL::Houtou::DataLoader->on_stall_for($users, $teams),
    );
  };
  like $@, qr/stalled.*no progress/s, 'unresolvable promise reports a deadlock';
};

subtest 'max_batch_size chunks large batches' => sub {
  my @sizes;
  my $chunked = GraphQL::Houtou::DataLoader->new(
    max_batch_size => 2,
    batch => sub { my ($ids) = @_; push @sizes, scalar @$ids; return [ map { $USERS{1} } @$ids ] },
  );
  my @promises = $chunked->load_many(qw(a b c d e));
  is $chunked->dispatch, 5, 'dispatch reports all keys';
  is_deeply \@sizes, [2, 2, 1], 'batches chunked at max size';
};

subtest 'runtime execute_document accepts on_stall directly' => sub {
  my ($users, $teams) = make_loaders();
  my $runtime = build_native_runtime($schema);
  my $result = $runtime->execute_document('{ posts { author { name } } }',
    context => { users => $users, teams => $teams },
    on_stall => GraphQL::Houtou::DataLoader->on_stall_for($users, $teams),
  );
  is_deeply $result->{errors}, [], 'no errors';
  is scalar @user_batches, 1, 'single batch through the runtime API';
};

done_testing;
