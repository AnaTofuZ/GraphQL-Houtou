package GraphQL::Houtou::GraphQLJS::Canonical;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Houtou::GraphQLJS::Locator qw(apply_loc_from_source);

our @EXPORT_OK = qw(
  parse_canonical_document
);

my $HAS_XS_PREPROCESS = eval {
  require GraphQL::Houtou::XS::Parser;
  GraphQL::Houtou::XS::Parser->import(qw(
    graphqljs_apply_executable_loc_xs
    graphqljs_build_document_xs
    graphqljs_build_directives_xs
    graphqljs_build_executable_document_xs
    graphqljs_parse_document_xs
    graphqljs_preprocess_xs
    graphqljs_patch_document_xs
    parse_directives_xs
  ));
  1;
};

sub _convert_directive_texts {
  my ($raw_directives) = @_;
  return [] if !$raw_directives || !@$raw_directives;

  return graphqljs_build_directives_xs(join ' ', @$raw_directives);
}

sub _parse_legacy_document {
  my ($source, $backend, $no_location) = @_;

  die "graphql-js parser requires XS backend support.\n"
    if !$HAS_XS_PREPROCESS;
  die "graphql-js parser only supports backend 'xs'.\n"
    if ($backend || '') ne 'xs';

  return parse_xs($source, $no_location);
}

sub _build_graphqljs_document_from_legacy {
  my ($legacy) = @_;
  my $is_executable = _is_executable_legacy_document($legacy);

  if ($is_executable) {
    my $doc = graphqljs_build_executable_document_xs($legacy);
    return ($doc, $is_executable)
      if defined $doc && ref $doc eq 'HASH';
  }

  {
    my $doc = graphqljs_build_document_xs($legacy);
    return ($doc, $is_executable)
      if defined $doc && ref $doc eq 'HASH';
  }

  die "graphql-js XS builder could not materialize a canonical document.\n";
}

sub _materialize_operation_variable_directives_xs {
  my ($meta) = @_;
  return if !@{ $meta->{operation_variable_directives} || [] };

  my @materialized;
  for my $operation (@{ $meta->{operation_variable_directives} || [] }) {
    my %converted;
    for my $name (keys %$operation) {
      $converted{$name} = _convert_directive_texts($operation->{$name});
    }
    push @materialized, \%converted;
  }
  $meta->{operation_variable_directives} = \@materialized;
  return $meta;
}

sub _preprocess_source {
  my ($source) = @_;

  die "graphql-js parser requires XS backend support.\n"
    if !$HAS_XS_PREPROCESS;

  my $meta = graphqljs_preprocess_xs($source);
  my $rewritten = delete $meta->{rewritten_source};
  delete $meta->{rewrites};
  return ($rewritten, $meta);
}

sub _is_executable_legacy_document {
  my ($legacy) = @_;
  return 0 if !$legacy || ref($legacy) ne 'ARRAY';

  for my $definition (@$legacy) {
    return 0 if ref($definition) ne 'HASH';
    my $kind = $definition->{kind} || '';
    return 0 if $kind ne 'operation' && $kind ne 'fragment';
  }

  return 1;
}

sub parse_canonical_document {
  my ($source, $options) = @_;
  $options ||= {};

  if ($HAS_XS_PREPROCESS
      && ($options->{backend} || 'xs') eq 'xs') {
    my $doc = graphqljs_parse_document_xs(
      $source,
      ($options->{no_location} || $options->{noLocation}) ? 1 : 0,
      $options->{lazy_location} ? 1 : 0,
      $options->{compact_loc} ? 1 : 0,
    );
    return $doc if defined $doc && ref $doc eq 'HASH';
    if ($options->{lazy_location} || $options->{compact_loc}) {
      die "graphql-js parser options lazy_location/compact_loc require the XS fast path for this document.\n";
    }
  }

  my ($rewritten, $meta) = _preprocess_source($source);
  my $backend = $options->{backend} || 'xs';
  my $legacy = _parse_legacy_document($rewritten, $backend, $options->{no_location} // $options->{noLocation});
  my ($doc) = _build_graphqljs_document_from_legacy($legacy);
  _materialize_operation_variable_directives_xs($meta);

  $doc = graphqljs_patch_document_xs($doc, $meta);
  unless ($options->{no_location} || $options->{noLocation} || $options->{lazy_location}) {
    my $located = graphqljs_apply_executable_loc_xs($doc, $source);
    return $located if defined $located && ref $located eq 'HASH';
    return apply_loc_from_source($doc, $source);
  }
  return $doc;
}

1;
