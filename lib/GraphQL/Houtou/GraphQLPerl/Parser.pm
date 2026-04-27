package GraphQL::Houtou::GraphQLPerl::Parser;

use 5.014;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
  parse
  parse_with_options
);

my $HAS_XS_BACKEND = eval {
  require GraphQL::Houtou::XS::Parser;
  GraphQL::Houtou::XS::Parser->import(qw(parse_xs));
  1;
};

sub _has_xs_backend {
  return $HAS_XS_BACKEND;
}

sub parse {
  my ($source, $no_location) = @_;
  die "XS parser backend is required for GraphQL::Houtou::parse().\n" if !_has_xs_backend();
  return parse_xs($source, $no_location);
}

sub parse_with_options {
  my ($source, $options) = @_;
  $options ||= {};
  my $backend = $options->{backend} || 'xs';
  my $no_location = $options->{no_location};
  $no_location = $options->{noLocation} if !defined $no_location;

  if ($backend eq 'xs') {
    die "XS parser backend is required for GraphQL::Houtou::parse_with_options().\n" if !_has_xs_backend();
    return parse_xs($source, $no_location);
  }

  die "Unknown parser backend '$backend'.\n";
}

1;
