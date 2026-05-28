package GraphQL::Houtou::Type::InputObject;

use 5.014;
use strict;
use warnings;

use parent 'GraphQL::Houtou::Type';
use Role::Tiny::With;
use GraphQL::Houtou::Internal::TypeSupport qw(description_doc_lines named_from_ast apply_fields_deprecation);
use GraphQL::Houtou::Type::List ();
use GraphQL::Houtou::Type::NonNull ();

with qw(
  GraphQL::Houtou::Role::Input
  GraphQL::Houtou::Role::FieldsInput
  GraphQL::Houtou::Role::HashMappable
);

sub list {
  $_[0]->{_houtou_list} ||= GraphQL::Houtou::Type::List->new(of => $_[0]);
}

sub non_null {
  $_[0]->{_houtou_non_null} ||= GraphQL::Houtou::Type::NonNull->new(of => $_[0]);
}

use constant DEBUG => $ENV{GRAPHQL_DEBUG};

sub new {
  my ($class, %args) = @_;
  my $self = $class->SUPER::new(%args);
  $self->{name} = $args{name};
  $self->{description} = $args{description};
  $self->{fields} = $args{fields};
  return bless $self, $class;
}

sub name { $_[0]->{name} }
sub description { $_[0]->{description} }
sub to_string { $_[0]->{to_string} ||= $_[0]->name }

sub fields {
  my ($self) = @_;
  my $fields = $self->{fields};
  if (ref($fields) eq 'CODE') {
    $fields = $fields->();
    $self->{fields} = $fields;
  }
  if (!$self->{_fields_deprecation_applied}) {
    $self->{fields} = apply_fields_deprecation($self->{fields});
    $self->{_fields_deprecation_applied} = 1;
  }
  return $self->{fields};
}

sub is_valid {
  my ($self, $item) = @_;
  my $fields = $self->fields;

  return 1 if !defined $item;
  return if grep { !$fields->{$_}{type}->is_valid($item->{$_} // $fields->{$_}{default_value}) } keys %$fields;
  return 1;
}

sub uplift {
  my ($self, $item) = @_;
  my $fields = $self->fields;

  return $item if !defined $item;
  die "found not an object" if ref($item) ne 'HASH';
  _assert_known_fields($item, $fields);
  my %uplifted;
  for my $key (sort keys %$fields) {
    next if !exists $item->{$key} && !exists $fields->{$key}{default_value};
    my $value = exists $item->{$key} ? $item->{$key} : $fields->{$key}{default_value};
    $uplifted{$key} = $fields->{$key}{type}->uplift($value);
  }
  return \%uplifted;
}

sub graphql_to_perl {
  my ($self, $item) = @_;
  my $fields = $self->fields;

  return $item if !defined $item;
  die "found not an object" if ref($item) ne 'HASH';
  $item = $self->uplift($item);
  my %value;
  for my $key (sort keys %$fields) {
    next if !exists $item->{$key} && !exists $fields->{$key}{default_value};
    my $raw = exists $item->{$key} ? $item->{$key} : $fields->{$key}{default_value};
    $value{$key} = $fields->{$key}{type}->graphql_to_perl($raw);
  }
  return \%value;
}

sub perl_to_graphql {
  my ($self, $item) = @_;
  my $fields = $self->fields;

  return $item if !defined $item;
  die "found not an object" if ref($item) ne 'HASH';
  $item = $self->uplift($item);
  my %value;
  for my $key (sort keys %$fields) {
    next if !exists $item->{$key} && !exists $fields->{$key}{default_value};
    my $raw = exists $item->{$key} ? $item->{$key} : $fields->{$key}{default_value};
    $value{$key} = $fields->{$key}{type}->perl_to_graphql($raw);
  }
  return \%value;
}

sub _assert_known_fields {
  my ($item, $fields) = @_;
  my @unknown = grep { !exists $fields->{$_} } sort keys %{$item || {}};
  die join '', map qq{In field "$_": Unknown field.\n}, @unknown if @unknown;
  return;
}

1;
