package GraphQL::Houtou::Runtime::Program;

use 5.014;
use strict;
use warnings;

sub new {
  my ($class, %args) = @_;
  return bless {
    blocks => $args{blocks} || [],
    root_blocks => $args{root_blocks} || {},
  }, $class;
}

sub blocks { return $_[0]{blocks} }
sub root_blocks { return $_[0]{root_blocks} }

sub root_block {
  my ($self, $name) = @_;
  return $self->{root_blocks}{$name};
}

sub to_struct {
  my ($self) = @_;
  my @blocks = map { $_->to_struct } @{ $self->{blocks} || [] };
  my %root_blocks = map {
    my $block = $self->{root_blocks}{$_};
    ($_ => ($block ? $block->name : undef));
  } keys %{ $self->{root_blocks} || {} };

  return {
    blocks => \@blocks,
    root_blocks => \%root_blocks,
  };
}

1;
