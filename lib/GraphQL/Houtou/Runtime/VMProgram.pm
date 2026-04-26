package GraphQL::Houtou::Runtime::VMProgram;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  my $root_block = $args{root_block};
  my @blocks = @{ $args{blocks} || [] };
  my %block_map = map { ($_->name => $_) } @blocks;
  $block_map{ $root_block->name } = $root_block if $root_block;
  return bless {
    version => $args{version} || 1,
    operation_type => $args{operation_type} || 'query',
    operation_name => $args{operation_name},
    blocks => \@blocks,
    root_block => $root_block,
    block_map => \%block_map,
  }, $class;
}

sub version { return $_[0]{version} }
sub operation_type { return $_[0]{operation_type} }
sub operation_name { return $_[0]{operation_name} }
sub blocks { return $_[0]{blocks} }
sub root_block { return $_[0]{root_block} }

sub block_by_name {
  my ($self, $name) = @_;
  return if !defined $name;
  return $self->{block_map}{$name};
}

sub to_struct {
  my ($self) = @_;
  return {
    version => $self->{version},
    operation_type => $self->{operation_type},
    operation_name => $self->{operation_name},
    root_block => $self->{root_block} ? $self->{root_block}->name : undef,
    blocks => [ map { $_->to_struct } @{ $self->{blocks} || [] } ],
  };
}

1;
