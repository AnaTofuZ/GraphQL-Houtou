package GraphQL::Houtou::GraphQLPerl::Parser;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Error;

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

sub _enforce_legacy_empty_object_rule {
  my ($source) = @_;
  return if !$HAS_XS_BACKEND;

  require GraphQL::Houtou::XS::Parser;
  my $tokens = GraphQL::Houtou::XS::Parser::tokenize_xs($source);
  for my $index (0 .. @$tokens - 3) {
    next if $tokens->[$index]{kind} ne 'COLON' && $tokens->[$index]{kind} ne 'EQUALS';
    next if $tokens->[$index + 1]{kind} ne 'LBRACE';
    next if $tokens->[$index + 2]{kind} ne 'RBRACE';
    die GraphQL::Error->new(
      message => 'Expected name',
      locations => [{ %{ $tokens->[$index + 2]{loc} } }],
    );
  }
}

sub _parse_via_xs {
  my ($source, $no_location, $options) = @_;
  require GraphQL::Houtou::Backend::XS;
  my $document = GraphQL::Houtou::Backend::XS::parse($source, $no_location);
  _enforce_legacy_empty_object_rule($source) if !$options->{skip_legacy_compat};
  return $document;
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

  die "Unknown parser backend '$backend'.\n";
}

1;
