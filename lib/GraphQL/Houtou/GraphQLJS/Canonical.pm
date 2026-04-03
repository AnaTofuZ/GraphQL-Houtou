package GraphQL::Houtou::GraphQLJS::Canonical;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Houtou::Adapter::GraphQLPerlToGraphQLJS qw(
  convert_document
);
use GraphQL::Houtou::GraphQLJS::Locator qw(apply_loc_from_source);
use GraphQL::Houtou::GraphQLJS::Util qw(rebase_loc);

our @EXPORT_OK = qw(
  parse_canonical_document
);

my $HAS_XS_PREPROCESS = eval {
  require GraphQL::Houtou::XS::Parser;
  GraphQL::Houtou::XS::Parser->import(qw(
    graphqljs_apply_executable_loc_xs
    graphqljs_build_directives_xs
    graphqljs_build_executable_document_xs
    graphqljs_preprocess_xs
    graphqljs_patch_document_xs
    parse_directives_xs
  ));
  1;
};

my %DIRECTIVE_CACHE;

sub _pp_package {
  require GraphQL::Houtou::GraphQLJS::PP;
  return 'GraphQL::Houtou::GraphQLJS::PP';
}

sub _preprocess_source_pp {
  my ($source) = @_;
  my $pkg = _pp_package();
  return $pkg->can('preprocess_source_fallback')->($source);
}

sub _materialize_operation_variable_directives_pp {
  my ($meta) = @_;
  my $pkg = _pp_package();
  return $pkg->can('materialize_operation_variable_directives')->($meta);
}

sub _patch_document_pp {
  my ($doc, $meta) = @_;
  my $pkg = _pp_package();
  return $pkg->can('patch_document_fallback')->($doc, $meta);
}

sub _convert_directive_texts {
  my ($raw_directives, $loc) = @_;
  return [] if !$raw_directives || !@$raw_directives;

  my $cache_key = join "\x1e", @$raw_directives;
  my $converted = $DIRECTIVE_CACHE{$cache_key};
  if (!$converted) {
    $converted = graphqljs_build_directives_xs(join ' ', @$raw_directives);
    $DIRECTIVE_CACHE{$cache_key} = $converted;
  }

  my @copy = map {
    my %directive = %$_;
    rebase_loc(\%directive, $loc);
    \%directive;
  } @$converted;

  return \@copy;
}

sub _parse_legacy_document {
  my ($source, $backend, $no_location) = @_;

  if ($backend eq 'xs') {
    require GraphQL::Houtou::Backend::XS;
    return GraphQL::Houtou::Backend::XS::parse($source, $no_location);
  }
  if ($backend eq 'pegex') {
    require GraphQL::Houtou::Backend::Pegex;
    return GraphQL::Houtou::Backend::Pegex::parse($source, $no_location);
  }

  die "Unknown parser backend '$backend'.\n";
}

sub _build_graphqljs_document_from_legacy {
  my ($legacy, $options) = @_;
  my $is_executable = _is_executable_legacy_document($legacy);
  my $use_xs_builder = $HAS_XS_PREPROCESS
    && ($options->{backend} || '') eq 'xs'
    && $is_executable;

  if ($use_xs_builder) {
    my $doc = graphqljs_build_executable_document_xs($legacy);
    return ($doc, $is_executable)
      if defined $doc && ref $doc eq 'HASH';
  }

  return (
    convert_document($legacy, {
      %$options,
      ($use_xs_builder ? (skip_location_projection => 1) : ()),
    }),
    $is_executable,
  );
}

sub _materialize_operation_variable_directives_xs {
  my ($meta) = @_;
  return if !@{ $meta->{operation_variable_directives} || [] };

  my @materialized;
  for my $operation (@{ $meta->{operation_variable_directives} || [] }) {
    my %converted;
    for my $name (keys %$operation) {
      $converted{$name} = _convert_directive_texts($operation->{$name}, undef);
    }
    push @materialized, \%converted;
  }
  $meta->{operation_variable_directives} = \@materialized;
  return $meta;
}

sub _preprocess_source {
  my ($source) = @_;

  if ($HAS_XS_PREPROCESS) {
    my $meta = graphqljs_preprocess_xs($source);
    my $rewritten = delete $meta->{rewritten_source};
    delete $meta->{rewrites};
    return ($rewritten, $meta);
  }

  return _preprocess_source_pp($source);
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

  my ($rewritten, $meta) = _preprocess_source($source);
  my $backend = $options->{backend} || ($HAS_XS_PREPROCESS ? 'xs' : 'pegex');
  my $legacy = _parse_legacy_document($rewritten, $backend, $options->{no_location} // $options->{noLocation});
  my ($doc, $is_executable) = _build_graphqljs_document_from_legacy($legacy, {
    %$options,
    backend => $backend,
  });
  if ($HAS_XS_PREPROCESS) {
    _materialize_operation_variable_directives_xs($meta);
  }
  else {
    _materialize_operation_variable_directives_pp($meta);
  }

  if ($HAS_XS_PREPROCESS) {
    $doc = graphqljs_patch_document_xs($doc, $meta);
    unless ($options->{no_location} || $options->{noLocation}) {
      my $located = graphqljs_apply_executable_loc_xs($doc, $source);
      return $located if defined $located && ref $located eq 'HASH';
      return apply_loc_from_source($doc, $source);
    }
    return $doc;
  }

  return _patch_document_pp($doc, $meta);
}

1;
