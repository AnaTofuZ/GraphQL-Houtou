package GraphQL::Houtou::GraphQLPerl::Parser;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Houtou::GraphQLPerl::FromGraphQLJS qw(
  convert_canonical_document
  enforce_legacy_compat
);

our @EXPORT_OK = qw(
  parse
  parse_with_options
);

my $HAS_XS_BACKEND = eval {
  require GraphQL::Houtou::Backend::XS;
  1;
};

sub _has_xs_backend {
  return $HAS_XS_BACKEND;
}

sub _parse_via_pegex {
  require GraphQL::Houtou::Backend::Pegex;
  return GraphQL::Houtou::Backend::Pegex::parse(@_);
}

sub _parse_via_xs {
  my ($source, $no_location, $options) = @_;
  require GraphQL::Houtou::Backend::XS;
  my $document = GraphQL::Houtou::Backend::XS::parse($source, $no_location);
  enforce_legacy_compat($source, $options);
  return $document;
}

sub _parse_via_canonical_xs {
  my ($source, $no_location, $options) = @_;
  require GraphQL::Houtou::Backend::GraphQLJS::XS;
  my $document = GraphQL::Houtou::Backend::GraphQLJS::XS::parse($source, {
    no_location => $no_location,
  });
  return convert_canonical_document($document, $source, $options);
}

sub parse {
  my ($source, $no_location) = @_;
  return _has_xs_backend()
    ? _parse_via_xs($source, $no_location, {})
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
    return _parse_via_xs($source, $no_location, $options);
  }
  if ($backend eq 'canonical-xs' || $backend eq 'graphqljs-xs') {
    return _parse_via_canonical_xs($source, $no_location, $options);
  }

  die "Unknown parser backend '$backend'.\n";
}

1;
