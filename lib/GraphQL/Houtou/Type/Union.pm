package GraphQL::Houtou::Type::Union;

use 5.014;
use strict;
use warnings;

use parent 'GraphQL::Houtou::Type';
use Role::Tiny::With;
use GraphQL::Houtou::Type::List ();
use GraphQL::Houtou::Type::NonNull ();

with qw(
  GraphQL::Houtou::Role::Output
  GraphQL::Houtou::Role::Composite
  GraphQL::Houtou::Role::Abstract
  GraphQL::Houtou::Role::Named
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
  die "GraphQL::Houtou::Type::Union requires name" if !defined $args{name};
  die "GraphQL::Houtou::Type::Union requires types" if !exists $args{types};
  my $types = $args{types};
  die "GraphQL::Houtou::Type::Union requires a non-empty types array"
    if ref($types) ne 'ARRAY' || !@$types;
  my %seen;
  for my $type (@$types) {
    die "GraphQL::Houtou::Type::Union requires object types" if !ref($type);
    die "Duplicate union member " . $type->name if $seen{$type->name}++;
  }
  my $self = $class->SUPER::new(%args);
  $self->{name} = $args{name};
  $self->{description} = $args{description};
  $self->{types} = $types;
  $self->{resolve_type} = $args{resolve_type};
  $self->{tag_resolver} = $args{tag_resolver};
  $self->{tag_map} = $args{tag_map};
  $self->{_types_validated} = 0;
  return $self;
}

sub name { return $_[0]->{name} }
sub description { return $_[0]->{description} }
sub to_string { return $_[0]->{to_string} ||= $_[0]->name }
sub types { return $_[0]->{types} }
sub resolve_type { return $_[0]->{resolve_type} }
sub tag_resolver { return $_[0]->{tag_resolver} }
sub tag_map { return $_[0]->{tag_map} }
sub _types_validated {
  my ($self, @set) = @_;
  $self->{_types_validated} = $set[0] if @set;
  return $self->{_types_validated};
}

sub get_types {
  my ($self) = @_;
  my @types = @{ $self->types };
  return \@types if $self->_types_validated;

  $self->_types_validated(1);
  if (!$self->resolve_type && !$self->tag_resolver) {
    my @bad = map $_->name, grep !$_->is_type_of, @types;
    die $self->name . " no resolve_type and no is_type_of for @bad" if @bad;
  }
  return \@types;
}

sub to_doc {
  my ($self) = @_;
  return $self->{to_doc} if exists $self->{to_doc};
  return $self->{to_doc} = join '', map "$_\n",
    ($self->description ? (map "# $_", split /\n/, $self->description) : ()),
    "union @{[$self->name]} = " . join(' | ', map $_->name, @{ $self->{types} });
}

1;
