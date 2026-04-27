use strict;
use warnings;

use Test::More;

{
  package Local::RuntimePromise;

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
    my @resolved;
    for my $value (@values) {
      if (ref($value) && eval { $value->isa(__PACKAGE__) }) {
        die @{ $value->{values} } if $value->{status} eq 'rejected';
        push @resolved, $value->{values}[0];
        next;
      }
      push @resolved, $value;
    }
    return $class->resolve(\@resolved);
  }

  sub then {
    my ($self, $on_fulfilled, $on_rejected) = @_;
    my $status = $self->{status};
    my $callback = $status eq 'fulfilled' ? $on_fulfilled : $on_rejected;
    if (!$callback) {
      return __PACKAGE__->new(
        status => $status,
        values => [ @{ $self->{values} } ],
      );
    }
    my @ret = eval { $callback->(@{ $self->{values} }) };
    return __PACKAGE__->reject($@) if $@;
    return $ret[0] if @ret == 1 && ref($ret[0]) && eval { $ret[0]->isa(__PACKAGE__) };
    return __PACKAGE__->resolve(@ret);
  }

  sub get {
    my ($self) = @_;
    die @{ $self->{values} } if $self->{status} eq 'rejected';
    return wantarray ? @{ $self->{values} } : $self->{values}[0];
  }
}

use GraphQL::Houtou::Promise::Adapter qw(normalize_promise_code);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);
use GraphQL::Houtou::Type::Union;

my $promise_code = normalize_promise_code({
  resolve => sub { Local::RuntimePromise->resolve(@_) },
  reject  => sub { Local::RuntimePromise->reject(@_) },
  all     => sub { Local::RuntimePromise->all(@_) },
  then    => sub {
    my ($promise, $on_fulfilled, $on_rejected) = @_;
    return $promise->then($on_fulfilled, $on_rejected);
  },
  is_promise => sub {
    my ($value) = @_;
    return ref($value) eq 'Local::RuntimePromise';
  },
});

my $User = GraphQL::Houtou::Type::Object->new(
  name => 'RuntimePromiseUser',
  runtime_tag => 'user',
  fields => {
    id => { type => $String->non_null },
    name => { type => $String->non_null },
  },
);

my $SearchResult = GraphQL::Houtou::Type::Union->new(
  name => 'RuntimePromiseSearchResult',
  types => [ $User ],
  tag_resolver => sub { $_[0]{kind} },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => GraphQL::Houtou::Type::Object->new(
    name => 'RuntimePromiseQuery',
    fields => {
      later => {
        type => $String->non_null,
        resolve => sub { Local::RuntimePromise->resolve('world') },
      },
      later_user => {
        type => $User,
        resolve => sub {
          Local::RuntimePromise->resolve({ id => '41', name => 'async:41' });
        },
      },
      later_list => {
        type => $String->non_null->list->non_null,
        resolve => sub {
          [
            Local::RuntimePromise->resolve('alpha'),
            Local::RuntimePromise->resolve('beta'),
          ];
        },
      },
      later_search => {
        type => $SearchResult,
        resolve => sub {
          Local::RuntimePromise->resolve({
            kind => 'user',
            id => '42',
            name => 'async:42',
          });
        },
      },
    },
  ),
  types => [ $User, $SearchResult ],
);

subtest 'runtime program returns promise when promise_code is supplied' => sub {
  my $result = $schema->execute(
    '{ later later_user { id name } later_list later_search { ... on RuntimePromiseUser { id name } } }',
    promise_code => $promise_code,
  );

  isa_ok $result, 'Local::RuntimePromise';
  is_deeply $result->get, {
    data => {
      later => 'world',
      later_user => {
        id => '41',
        name => 'async:41',
      },
      later_list => [ 'alpha', 'beta' ],
      later_search => {
        id => '42',
        name => 'async:42',
      },
    },
    errors => [],
  }, 'runtime program resolves promise-backed scalar/object/list/abstract fields';
};

done_testing;
