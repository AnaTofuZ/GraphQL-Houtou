package GraphQL::Houtou::Type::List;

use 5.014;
use strict;
use warnings;

use Moo;
use Role::Tiny ();
use Types::Standard qw(Object Any ArrayRef Bool HashRef);
use GraphQL::Houtou::Promise::Adapter qw(
  is_promise_value
  then_promise
);

extends 'GraphQL::Houtou::Type';

sub list {
  $_[0]->{_houtou_list} ||= __PACKAGE__->new(of => $_[0]);
}

sub non_null {
  require GraphQL::Houtou::Type::NonNull;
  $_[0]->{_houtou_non_null} ||= GraphQL::Houtou::Type::NonNull->new(of => $_[0]);
}

has of => (
  is => 'ro',
  isa => Object,
  required => 1,
  handles => [ qw(name) ],
);

sub BUILD {
my ($self) = @_;
  my $of = $self->of;
  my @roles;
  push @roles, 'GraphQL::Houtou::Role::Input'
    if $of->DOES('GraphQL::Houtou::Role::Input') || $of->DOES('GraphQL::Role::Input');
  push @roles, 'GraphQL::Houtou::Role::Output'
    if $of->DOES('GraphQL::Houtou::Role::Output') || $of->DOES('GraphQL::Role::Output');
  Role::Tiny->apply_roles_to_object($self, @roles) if @roles;
}

has to_string => (
  is => 'lazy',
  builder => sub {
    my ($self) = @_;
    '[' . $self->of->to_string . ']';
  },
);

sub is_valid {
  my ($self, $item) = @_;
  my $of = $self->of;

  return 1 if !defined $item;
  return if grep { !$of->is_valid($_) } @{ $self->uplift($item) };
  return 1;
}

sub uplift {
  my ($self, $item) = @_;
  return $item if ref($item) eq 'ARRAY' || !defined $item;
  return [ $item ];
}

sub graphql_to_perl {
  my ($self, $item) = @_;
  my $of = $self->of;
  my $i = 0;
  my @errors;
  my @values;

  return $item if !defined $item;
  $item = $self->uplift($item);
  @values = map {
    my $value = eval { $of->graphql_to_perl($_) };
    push @errors, qq{In element #$i: $@} if $@;
    $i++;
    $value;
  } @$item;
  die @errors if @errors;
  return \@values;
}

sub perl_to_graphql {
  my ($self, $item) = @_;
  my $of = $self->of;
  my $i = 0;
  my @errors;
  my @values;

  return $item if !defined $item;
  $item = $self->uplift($item);
  @values = map {
    my $value = eval { $of->perl_to_graphql($_) };
    push @errors, qq{In element #$i: $@} if $@;
    $i++;
    $value;
  } @$item;
  die @errors if @errors;
  return \@values;
}

my $HAS_XS_PROMISE_HELPERS;
my $HAS_XS_THEN_COMPLETE_VALUE;

sub _complete_value {
  my ($self, $context, $nodes, $info, $path, $result) = @_;
  my $item_type = $self->of;
  my $index = 0;
  my @completed;

  @completed = map {
    _complete_item_value(
      $context,
      $item_type,
      $nodes,
      $info,
      [ @$path, $index++ ],
      $_,
    );
  } @$result;

  return (grep { _is_promise($context, $_) } @completed)
    ? _promise_for_list($context, \@completed)
    : _merge_list(\@completed);
}

sub _complete_item_value {
  my ($context, $item_type, $nodes, $info, $path, $value) = @_;

  if (_is_promise($context, $value)) {
    if (!defined $HAS_XS_THEN_COMPLETE_VALUE) {
      $HAS_XS_THEN_COMPLETE_VALUE = eval {
        require GraphQL::Houtou::XS::Execution;
        GraphQL::Houtou::XS::Execution->can('_then_complete_value_xs');
      } ? 1 : 0;
    }

    if ($HAS_XS_THEN_COMPLETE_VALUE) {
      return GraphQL::Houtou::XS::Execution::_then_complete_value_xs(
        $context,
        $item_type,
        $nodes,
        $info,
        $path,
        $value,
      );
    }
  }

  return GraphQL::Houtou::Execution::PP::_complete_value_catching_error(
    $context,
    $item_type,
    $nodes,
    $info,
    $path,
    $value,
  );
}

sub _merge_list {
  my ($list) = @_;
  if (!_load_xs_promise_helpers()) {
    my @errors = map @{ $_->{errors} || [] }, @$list;
    my @data = map $_->{data}, @$list;
    return +{
      data => \@data,
      @errors ? (errors => \@errors) : (),
    };
  }

  return GraphQL::Houtou::XS::Execution::_merge_completed_list_xs($list);
}

sub _load_xs_promise_helpers {
  if (!defined $HAS_XS_PROMISE_HELPERS) {
    $HAS_XS_PROMISE_HELPERS = eval {
      require GraphQL::Houtou::XS::Execution;
      GraphQL::Houtou::XS::Execution->can('_promise_is_promise_xs')
        && GraphQL::Houtou::XS::Execution->can('_promise_all_xs')
        && GraphQL::Houtou::XS::Execution->can('_promise_then_xs')
        && GraphQL::Houtou::XS::Execution->can('_merge_completed_list_xs');
    } ? 1 : 0;
  }

  return $HAS_XS_PROMISE_HELPERS;
}

sub _merge_list_pp {
  my ($list) = @_;
  my @errors = map @{ $_->{errors} || [] }, @$list;
  my @data = map $_->{data}, @$list;
  return +{
    data => \@data,
    @errors ? (errors => \@errors) : (),
  };
}

sub _promise_for_list {
  my ($context, $list) = @_;
  die "Given a promise in list but no PromiseCode given\n"
    if !$context->{promise_code};

  if (_load_xs_promise_helpers()) {
    my $aggregate = GraphQL::Houtou::XS::Execution::_promise_all_xs($context->{promise_code}, $list);
    return GraphQL::Houtou::XS::Execution::_promise_then_xs(
      $context->{promise_code},
      $aggregate,
      sub {
        return GraphQL::Houtou::XS::Execution::_merge_completed_list_xs(
          GraphQL::Houtou::XS::Execution::_promise_all_values_to_arrayref(@_)
        );
      },
      undef,
    );
  }

  return then_promise($context->{promise_code}, $context->{promise_code}{all}->(@$list), sub {
    return _merge_list_pp(GraphQL::Houtou::XS::Execution::_promise_all_values_to_arrayref(@_));
  });
}

sub _is_promise {
  my ($context, $value) = @_;
  if (_load_xs_promise_helpers()) {
    return !!GraphQL::Houtou::XS::Execution::_promise_is_promise_xs($context->{promise_code}, $value);
  }
  return is_promise_value($context->{promise_code}, $value);
}

1;
