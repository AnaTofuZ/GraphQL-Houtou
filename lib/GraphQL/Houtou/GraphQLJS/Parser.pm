package GraphQL::Houtou::GraphQLJS::Parser;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Houtou::Adapter::GraphQLPerlToGraphQLJS qw(
  convert_document
  convert_legacy_directives
);
use GraphQL::Houtou::GraphQLJS::Locator qw(apply_loc_from_source);
use GraphQL::Houtou::GraphQLPerl::Parser ();

my $HAS_XS_PREPROCESS = eval {
  require GraphQL::Houtou::XS::Parser;
  GraphQL::Houtou::XS::Parser->import(qw(
    graphqljs_preprocess_xs
    graphqljs_patch_document_xs
    parse_directives_xs
  ));
  1;
};

our @EXPORT_OK = qw(
  parse
);

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

sub _rebase_loc {
  my ($node, $loc) = @_;
  if (ref $node eq 'HASH') {
    if ($loc) {
      $node->{loc} = { %$loc };
    }
    else {
      delete $node->{loc};
    }
    _rebase_loc($node->{$_}, $loc) for grep $_ ne 'loc', keys %$node;
    return $node;
  }
  if (ref $node eq 'ARRAY') {
    _rebase_loc($_, $loc) for @$node;
  }
  return $node;
}

sub _convert_directive_texts {
  my ($raw_directives, $loc) = @_;
  return [] if !$raw_directives || !@$raw_directives;

  my $cache_key = join "\x1e", @$raw_directives;
  my $converted = $DIRECTIVE_CACHE{$cache_key};
  if (!$converted) {
    my $legacy = parse_directives_xs(join ' ', @$raw_directives);
    $converted = convert_legacy_directives($legacy, undef);
    $DIRECTIVE_CACHE{$cache_key} = $converted;
  }

  my @copy = map {
    my %directive = %$_;
    _rebase_loc(\%directive, $loc);
    \%directive;
  } @$converted;

  return \@copy;
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

sub parse {
  my ($source, $options) = @_;
  $options ||= {};

  my ($rewritten, $meta) = _preprocess_source($source);
  my $legacy = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($rewritten, {
    %$options,
    backend => $options->{backend} || ($HAS_XS_PREPROCESS ? 'xs' : 'pegex'),
  });
  my $doc = convert_document($legacy, $options);
  if ($HAS_XS_PREPROCESS) {
    _materialize_operation_variable_directives_xs($meta);
  }
  else {
    _materialize_operation_variable_directives_pp($meta);
  }

  if ($HAS_XS_PREPROCESS) {
    $doc = graphqljs_patch_document_xs($doc, $meta);
    return apply_loc_from_source($doc, $source) unless $options->{no_location} || $options->{noLocation};
    return $doc;
  }

  return _patch_document_pp($doc, $meta);
}

1;
