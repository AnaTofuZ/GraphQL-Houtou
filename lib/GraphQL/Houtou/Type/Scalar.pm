package GraphQL::Houtou::Type::Scalar;

use 5.014;
use strict;
use warnings;

use Moo;
use Exporter 'import';
use GraphQL::Houtou::Type::Library -all;
use JSON::MaybeXS qw(JSON is_bool);
use Types::Standard -all;

extends 'GraphQL::Houtou::Type';
with qw(
  GraphQL::Role::Input
  GraphQL::Role::Output
  GraphQL::Role::Leaf
  GraphQL::Role::Named
  GraphQL::Role::FieldsEither
);

our @EXPORT_OK = qw($Int $Float $String $Boolean $ID);
use constant DEBUG => $ENV{GRAPHQL_DEBUG};

sub list {
  require GraphQL::Houtou::Type::List;
  $_[0]->{_houtou_list} ||= GraphQL::Houtou::Type::List->new(of => $_[0]);
}

sub non_null {
  require GraphQL::Houtou::Type::NonNull;
  $_[0]->{_houtou_non_null} ||= GraphQL::Houtou::Type::NonNull->new(of => $_[0]);
}

sub _leave_undef {
  my ($closure) = @_;
  sub { return undef if !defined $_[0]; goto &$closure; };
}

has serialize => (is => 'ro', isa => CodeRef, required => 1);
has parse_value => (is => 'ro', isa => CodeRef);

sub is_valid {
  my ($self, $item) = @_;
  return 1 if !defined $item;
  return eval { $self->serialize->($item); 1 };
}

sub graphql_to_perl {
  my ($self, $item) = @_;
  return $self->parse_value->($item);
}

sub perl_to_graphql {
  my ($self, $item) = @_;
  return $self->serialize->($item);
}

our $Int = __PACKAGE__->new(
  name => 'Int',
  description =>
    'The `Int` scalar type represents non-fractional signed whole numeric ' .
    'values. Int can represent values between -(2^31) and 2^31 - 1.',
  serialize => _leave_undef(sub { !is_Int32Signed($_[0]) and die "Not an Int.\n"; $_[0] + 0 }),
  parse_value => _leave_undef(sub { !is_Int32Signed($_[0]) and die "Not an Int.\n"; $_[0] + 0 }),
);

our $Float = __PACKAGE__->new(
  name => 'Float',
  description =>
    'The `Float` scalar type represents signed double-precision fractional ' .
    'values as specified by [IEEE 754](http://en.wikipedia.org/wiki/IEEE_floating_point).',
  serialize => _leave_undef(sub { !is_Num($_[0]) and die "Not a Float.\n"; $_[0] + 0 }),
  parse_value => _leave_undef(sub { !is_Num($_[0]) and die "Not a Float.\n"; $_[0] + 0 }),
);

our $String = __PACKAGE__->new(
  name => 'String',
  description =>
    'The `String` scalar type represents textual data, represented as UTF-8 ' .
    'character sequences. The String type is most often used by GraphQL to ' .
    'represent free-form human-readable text.',
  serialize => _leave_undef(sub { !is_Str($_[0]) and die "Not a String.\n"; $_[0] . '' }),
  parse_value => _leave_undef(sub { !is_Str($_[0]) and die "Not a String.\n"; $_[0] }),
);

our $Boolean = __PACKAGE__->new(
  name => 'Boolean',
  description => 'The `Boolean` scalar type represents `true` or `false`.',
  serialize => _leave_undef(sub {
    !is_Bool($_[0]) && !is_bool($_[0]) and die "Not a Boolean.\n";
    $_[0] ? JSON->true : JSON->false;
  }),
  parse_value => _leave_undef(sub {
    !is_Bool($_[0]) && !is_bool($_[0]) and die "Not a Boolean.\n";
    $_[0] + 0;
  }),
);

our $ID = __PACKAGE__->new(
  name => 'ID',
  description =>
    'The `ID` scalar type represents a unique identifier, often used to ' .
    'refetch an object or as key for a cache. The ID type appears in a JSON ' .
    'response as a String; however, it is not intended to be human-readable. ' .
    'When expected as an input type, any string (such as `"4"`) or integer ' .
    '(such as `4`) input value will be accepted as an ID.',
  serialize => _leave_undef(sub { Str->(@_); $_[0] . '' }),
  parse_value => _leave_undef(sub { Str->(@_); $_[0] }),
);

1;
