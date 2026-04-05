use strict;
use warnings;
use Test::More;

{
  package Local::Test::ChainPromise;

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

  sub chain {
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

use GraphQL::Houtou::Execution qw(execute);
use GraphQL::Houtou::Promise::Adapter qw(normalize_promise_code);
use GraphQL::Houtou qw(
  clear_default_promise_code
  get_default_promise_code
  set_default_promise_code
);
use GraphQL::Houtou::XS::Execution qw(execute_xs);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String $ID);

my $User = GraphQL::Houtou::Type::Object->new(
  name => 'PromiseUser',
  fields => {
    id => { type => $ID->non_null },
    name => { type => $String->non_null },
  },
);

my $Query = GraphQL::Houtou::Type::Object->new(
  name => 'PromiseQuery',
  fields => {
    later => {
      type => $String->non_null,
      resolve => sub {
        return Local::Test::ChainPromise->resolve('world');
      },
    },
    later_user => {
      type => $User,
      resolve => sub {
        return Local::Test::ChainPromise->resolve({
          id => '41',
          name => 'async:41',
        });
      },
    },
    later_list => {
      type => $String->non_null->list->non_null,
      resolve => sub {
        return [
          Local::Test::ChainPromise->resolve('alpha'),
          Local::Test::ChainPromise->resolve('beta'),
        ];
      },
    },
  },
);

my $schema = GraphQL::Houtou::Schema->new(
  query => $Query,
  types => [ $User ],
);

subtest 'normalize_promise_code installs default hooks for thenable promises' => sub {
  my $promise_code = normalize_promise_code({
    resolve => sub { Local::Test::ChainPromise->resolve(@_) },
    reject => sub { Local::Test::ChainPromise->reject(@_) },
    all => sub { Local::Test::ChainPromise->all(@_) },
    then => sub {
      my ($promise, $on_fulfilled, $on_rejected) = @_;
      return $promise->chain($on_fulfilled, $on_rejected);
    },
    is_promise => sub {
      my ($value) = @_;
      return ref($value) eq 'Local::Test::ChainPromise';
    },
  });

  ok $promise_code->{_houtou_promise_adapter}, 'promise code is normalized';
  ok $promise_code->{is_promise}->(Local::Test::ChainPromise->resolve('x')), 'custom promise detector works';
};

subtest 'execute returns a promise when promise_code is supplied' => sub {
  my $promise_code = normalize_promise_code({
    resolve => sub { Local::Test::ChainPromise->resolve(@_) },
    reject => sub { Local::Test::ChainPromise->reject(@_) },
    all => sub { Local::Test::ChainPromise->all(@_) },
    then => sub {
      my ($promise, $on_fulfilled, $on_rejected) = @_;
      return $promise->chain($on_fulfilled, $on_rejected);
    },
    is_promise => sub {
      my ($value) = @_;
      return ref($value) eq 'Local::Test::ChainPromise';
    },
  });

  my $result = execute(
    $schema,
    '{ later later_user { id name } later_list }',
    undef,
    undef,
    undef,
    undef,
    undef,
    $promise_code,
  );

  isa_ok $result, 'Local::Test::ChainPromise';
  is_deeply $result->get, {
    data => {
      later => 'world',
      later_user => {
        id => '41',
        name => 'async:41',
      },
      later_list => [ 'alpha', 'beta' ],
    },
  }, 'promise-backed execution resolves to the final response';
};

subtest 'global default promise code is used when request override is absent' => sub {
  my $promise_code = set_default_promise_code({
    resolve => sub { Local::Test::ChainPromise->resolve(@_) },
    reject => sub { Local::Test::ChainPromise->reject(@_) },
    all => sub { Local::Test::ChainPromise->all(@_) },
    then => sub {
      my ($promise, $on_fulfilled, $on_rejected) = @_;
      return $promise->chain($on_fulfilled, $on_rejected);
    },
    is_promise => sub {
      my ($value) = @_;
      return ref($value) eq 'Local::Test::ChainPromise';
    },
  });

  ok get_default_promise_code(), 'default promise code is installed';

  my $result = execute(
    $schema,
    '{ later later_list }',
  );

  isa_ok $result, 'Local::Test::ChainPromise';
  is_deeply $result->get, {
    data => {
      later => 'world',
      later_list => [ 'alpha', 'beta' ],
    },
  }, 'global default promise code drives execution';

  is get_default_promise_code(), $promise_code, 'installed adapter is the normalized default';
  clear_default_promise_code();
  ok !get_default_promise_code(), 'default promise code can be cleared';
};

subtest 'XS execute_xs also normalizes and uses global default promise code' => sub {
  set_default_promise_code({
    resolve => sub { Local::Test::ChainPromise->resolve(@_) },
    reject => sub { Local::Test::ChainPromise->reject(@_) },
    all => sub { Local::Test::ChainPromise->all(@_) },
    then => sub {
      my ($promise, $on_fulfilled, $on_rejected) = @_;
      return $promise->chain($on_fulfilled, $on_rejected);
    },
    is_promise => sub {
      my ($value) = @_;
      return ref($value) eq 'Local::Test::ChainPromise';
    },
  });

  my $result = execute_xs(
    $schema,
    '{ later }',
  );

  isa_ok $result, 'Local::Test::ChainPromise';
  is_deeply $result->get, {
    data => {
      later => 'world',
    },
  }, 'XS execution path uses normalized global default promise code';

  clear_default_promise_code();
};

done_testing;
