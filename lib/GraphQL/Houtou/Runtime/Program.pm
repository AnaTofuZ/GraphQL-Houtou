package GraphQL::Houtou::Runtime::Program;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    variable_defs => $args{variable_defs} || {},
    blocks => $args{blocks} || [],
    root_blocks => $args{root_blocks} || {},
  }, $class;
}

sub variable_defs { return $_[0]{variable_defs} }
sub blocks { return $_[0]{blocks} }
sub root_blocks { return $_[0]{root_blocks} }

sub root_block {
  my ($self, $name) = @_;
  return $self->{root_blocks}{$name};
}

sub block_by_type_name {
  my ($self, $type_name) = @_;
  return if !defined $type_name;
  for my $block (@{ $self->{blocks} || [] }) {
    next if !defined $block->root_type_name;
    return $block if $block->root_type_name eq $type_name;
  }
  return;
}

sub to_struct {
  my ($self) = @_;
  my @blocks = map { $_->to_struct } @{ $self->{blocks} || [] };
  my %root_blocks = map {
    my $block = $self->{root_blocks}{$_};
    ($_ => ($block ? $block->name : undef));
  } keys %{ $self->{root_blocks} || {} };

  return {
    variable_defs => { %{ $self->{variable_defs} || {} } },
    blocks => \@blocks,
    root_blocks => \%root_blocks,
  };
}

1;
