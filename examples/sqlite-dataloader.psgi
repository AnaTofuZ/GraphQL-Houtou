#!/usr/bin/env plackup
# A GraphQL over HTTP endpoint backed by SQLite, batching the classic N+1
# (posts -> author) into one SQL query per level with the bundled
# DataLoader. Run with:
#
#   plackup examples/sqlite-dataloader.psgi
#   curl localhost:5000 -H 'Content-Type: application/json' \
#     -d '{"query":"{ posts { title author { name } } }"}'
#
# Open http://localhost:5000/ in a browser for GraphiQL.
use strict;
use warnings;
use DBI;

use GraphQL::Houtou::PSGI;
use GraphQL::Houtou::DataLoader;
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::List;
use GraphQL::Houtou::Type::Scalar qw($String $ID);

my $dbh = DBI->connect('dbi:SQLite:dbname=:memory:', '', '', { RaiseError => 1 });
$dbh->do('CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT)');
$dbh->do('CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT, author_id INTEGER)');
$dbh->do(q{INSERT INTO users VALUES (1, 'alice'), (2, 'bob')});
$dbh->do(q{INSERT INTO posts VALUES (1, 'first', 1), (2, 'second', 2), (3, 'third', 1)});

# One SELECT ... WHERE id IN (...) per request level, regardless of how many
# author fields the query touches.
sub batch_users_by_id {
  my ($ids) = @_;
  my $in = join ',', ('?') x @$ids;
  my %row = map { ($_->{id} => $_) } @{ $dbh->selectall_arrayref(
    "SELECT id, name FROM users WHERE id IN ($in)", { Slice => {} }, @$ids,
  ) };
  return [ map { $row{$_} } @$ids ];
}

my $User = GraphQL::Houtou::Type::Object->new(
  name => 'User',
  fields => {
    id => { type => $ID },
    name => { type => $String },
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
        type => GraphQL::Houtou::Type::List->new(of => $Post),
        resolve => sub {
          $dbh->selectall_arrayref(
            'SELECT id, title, author_id FROM posts ORDER BY id', { Slice => {} });
        },
      },
    },
  ),
);

GraphQL::Houtou::PSGI->new(
  schema => $schema,
  graphiql => 1,
  context => sub {
    # Loaders are per-request: the cache lives exactly as long as the request.
    my $users = GraphQL::Houtou::DataLoader->new(batch => \&batch_users_by_id);
    return ({ users => $users }, GraphQL::Houtou::DataLoader->on_stall_for($users));
  },
)->to_app;
