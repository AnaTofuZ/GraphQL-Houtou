package GraphQL::Houtou::GraphQLPerl::FromGraphQLJS;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Error;
use GraphQL::Houtou::Adapter::GraphQLJSToGraphQLPerl qw(convert_document);

our @EXPORT_OK = qw(
  convert_canonical_document
  enforce_legacy_compat
);

my $HAS_XS_EXECUTABLE_BUILDER = eval {
  require GraphQL::Houtou::XS::Parser;
  GraphQL::Houtou::XS::Parser->import(qw(
    graphqlperl_build_document_xs
    graphqlperl_build_executable_document_xs
  ));
  1;
};

sub _is_executable_document {
  my ($document) = @_;
  return 0 if ref($document) ne 'HASH' || ($document->{kind} || '') ne 'Document';

  for my $definition (@{ $document->{definitions} || [] }) {
    return 0 if ref($definition) ne 'HASH';
    my $kind = $definition->{kind} || '';
    return 0 if $kind ne 'OperationDefinition' && $kind ne 'FragmentDefinition';
  }

  return 1;
}

sub _enforce_legacy_empty_object_rule {
  my ($source) = @_;
  return if index($source, '{}') < 0;

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

sub enforce_legacy_compat {
  my ($source, $options) = @_;
  $options ||= {};
  _enforce_legacy_empty_object_rule($source) if !$options->{skip_legacy_compat};
  return;
}

sub convert_canonical_document {
  my ($document, $source, $options) = @_;
  $options ||= {};

  my $legacy;
  if ($HAS_XS_EXECUTABLE_BUILDER) {
    $legacy = graphqlperl_build_document_xs($document);
  }
  if (!$legacy && $HAS_XS_EXECUTABLE_BUILDER && _is_executable_document($document)) {
    $legacy = graphqlperl_build_executable_document_xs($document);
  }
  $legacy ||= convert_document($document);
  enforce_legacy_compat($source, $options);
  return $legacy;
}

1;
