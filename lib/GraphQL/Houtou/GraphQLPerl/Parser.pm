package GraphQL::Houtou::GraphQLPerl::Parser;

use 5.014;
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
  parse
  parse_with_options
);

sub _has_xs_backend {
  return eval {
    require GraphQL::Houtou::Backend::XS;
    1;
  };
}

sub _parse_via_pegex {
  require GraphQL::Houtou::Backend::Pegex;
  return GraphQL::Houtou::Backend::Pegex::parse(@_);
}

sub _parse_via_xs {
  require GraphQL::Houtou::Backend::XS;
  return GraphQL::Houtou::Backend::XS::parse(@_);
}

sub parse {
  my ($source, $no_location) = @_;
  return _has_xs_backend()
    ? _parse_via_xs($source, $no_location)
    : _parse_via_pegex($source, $no_location);
}

sub parse_with_options {
  my ($source, $options) = @_;
  $options ||= {};
  my $backend = $options->{backend} || (_has_xs_backend() ? 'xs' : 'pegex');
  my $no_location = $options->{no_location};
  $no_location = $options->{noLocation} if !defined $no_location;

  if ($backend eq 'pegex') {
    return _parse_via_pegex($source, $no_location);
  }
  if ($backend eq 'xs') {
    return _parse_via_xs($source, $no_location);
  }

  die "Unknown parser backend '$backend'.\n";
}

1;
