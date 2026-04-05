package GraphQL::Houtou::Role::FieldsInput;

use 5.014;
use strict;
use warnings;

use Moo::Role;
use MooX::Thunking;

use GraphQL::Houtou::Type::Library qw(FieldMapInput);

# Input field container role with thunked field materialization.

has fields => (
  is => 'thunked',
  isa => FieldMapInput,
  required => 1,
);

1;
