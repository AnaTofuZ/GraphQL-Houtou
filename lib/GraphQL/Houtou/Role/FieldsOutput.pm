package GraphQL::Houtou::Role::FieldsOutput;

use 5.014;
use strict;
use warnings;

use Moo::Role;
use MooX::Thunking;

use GraphQL::Houtou::Type::Library qw(FieldMapOutput);

with qw(
  GraphQL::Houtou::Role::FieldDeprecation
  GraphQL::Houtou::Role::FieldsEither
);

# Output field container role with thunking and deprecation normalization.

has fields => (
  is => 'thunked',
  isa => FieldMapOutput,
  required => 1,
);

around fields => sub {
  my ($orig, $self) = @_;
  $self->$orig;
  $self->_fields_deprecation_apply('fields');
  return $self->{fields};
};

1;
