package GraphQL::Houtou::Runtime::VMBlock;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    name => $args{name},
    type_name => $args{type_name},
    family => $args{family} || 'OBJECT',
    ops => $args{ops} || [],
  }, $class;
}

sub name { return $_[0]{name} }
sub type_name { return $_[0]{type_name} }
sub family { return $_[0]{family} }
sub ops { return $_[0]{ops} }

sub to_struct {
  my ($self) = @_;
  return {
    name => $self->{name},
    type_name => $self->{type_name},
    family => $self->{family},
    ops => [ map { $_->to_struct } @{ $self->{ops} || [] } ],
  };
}

sub to_native_struct {
  my ($self, $block_index) = @_;
  my @slot_table;
  my %slot_index;
  for my $op (@{ $self->{ops} || [] }) {
    my $slot = $op->bound_slot or next;
    my $id = refaddr($slot);
    next if exists $slot_index{$id};
    $slot_index{$id} = scalar @slot_table;
    push @slot_table, {
      field_name => $slot->field_name,
      result_name => $slot->result_name,
      return_type_name => $slot->return_type_name,
      resolver_shape => $slot->resolver_shape,
      completion_family => $slot->completion_family,
      dispatch_family => $slot->dispatch_family,
      has_args => $slot->has_args,
      has_directives => $slot->has_directives,
    };
  }
  return {
    name => $self->{name},
    type_name => $self->{type_name},
    family => $self->{family},
    slots => \@slot_table,
    ops => [ map { $_->to_native_struct($block_index, \%slot_index) } @{ $self->{ops} || [] } ],
  };
}

1;
use Scalar::Util qw(refaddr);
