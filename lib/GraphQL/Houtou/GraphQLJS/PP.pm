package GraphQL::Houtou::GraphQLJS::PP;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Houtou::Adapter::GraphQLPerlToGraphQLJS qw(
  convert_document
);
use GraphQL::Houtou::GraphQLPerl::Parser ();

our @EXPORT_OK = qw(
  materialize_operation_variable_directives
  patch_document_fallback
  preprocess_source_fallback
);

my %DIRECTIVE_CACHE;

sub _skip_ignored {
  my ($source, $pos_ref) = @_;
  my $length = length $source;

  while ($$pos_ref < $length) {
    my $char = substr($source, $$pos_ref, 1);
    if ($char =~ /[\x20\x09\x0a\x0d,]/ || $char eq "\x{FEFF}") {
      $$pos_ref++;
      next;
    }
    if ($char eq '#') {
      $$pos_ref++ while $$pos_ref < $length && substr($source, $$pos_ref, 1) !~ /[\x0a\x0d]/;
      next;
    }
    last;
  }
}

sub _skip_quoted_string {
  my ($source, $pos_ref) = @_;
  my $length = length $source;

  if (substr($source, $$pos_ref, 3) eq '"""') {
    $$pos_ref += 3;
    while ($$pos_ref < $length) {
      if (substr($source, $$pos_ref, 3) eq '"""') {
        $$pos_ref += 3;
        last;
      }
      $$pos_ref++;
    }
    return;
  }

  $$pos_ref++;
  while ($$pos_ref < $length) {
    my $char = substr($source, $$pos_ref, 1);
    if ($char eq '\\') {
      $$pos_ref += 2;
      next;
    }
    $$pos_ref++;
    last if $char eq '"';
  }
}

sub _read_name {
  my ($source, $pos_ref) = @_;
  my $length = length $source;
  return if $$pos_ref >= $length;

  my $start = $$pos_ref;
  my $first = substr($source, $$pos_ref, 1);
  return if $first !~ /[_A-Za-z]/;

  $$pos_ref++;
  while ($$pos_ref < $length && substr($source, $$pos_ref, 1) =~ /[_0-9A-Za-z]/) {
    $$pos_ref++;
  }

  return substr($source, $start, $$pos_ref - $start);
}

sub _skip_delimited {
  my ($source, $pos_ref, $open, $close) = @_;
  my $length = length $source;

  return if substr($source, $$pos_ref, 1) ne $open;

  $$pos_ref++;
  while ($$pos_ref < $length) {
    my $char = substr($source, $$pos_ref, 1);
    if ($char eq '#') {
      $$pos_ref++ while $$pos_ref < $length && substr($source, $$pos_ref, 1) !~ /[\x0a\x0d]/;
      next;
    }
    if ($char eq '"') {
      _skip_quoted_string($source, $pos_ref);
      next;
    }
    if ($char eq $open) {
      _skip_delimited($source, $pos_ref, $open, $close);
      next;
    }
    if ($char eq '(') {
      _skip_delimited($source, $pos_ref, '(', ')');
      next if $open ne '(';
    }
    if ($char eq '[') {
      _skip_delimited($source, $pos_ref, '[', ']');
      next if $open ne '[';
    }
    if ($char eq '{') {
      _skip_delimited($source, $pos_ref, '{', '}');
      next if $open ne '{';
    }
    $$pos_ref++;
    last if $char eq $close;
  }
}

sub _skip_directive {
  my ($source, $pos_ref) = @_;
  my $start = $$pos_ref;

  $$pos_ref++;
  _read_name($source, $pos_ref);
  _skip_ignored($source, $pos_ref);
  if (substr($source, $$pos_ref, 1) eq '(') {
    _skip_delimited($source, $pos_ref, '(', ')');
  }

  return substr($source, $start, $$pos_ref - $start);
}

sub _scan_variable_definition_directives {
  my ($block) = @_;
  my @removals;
  my %variables;
  my $pos = 1;
  my $length = length $block;

  while ($pos < $length - 1) {
    _skip_ignored($block, \$pos);
    last if $pos >= $length - 1 || substr($block, $pos, 1) eq ')';

    if (substr($block, $pos, 1) eq '$') {
      $pos++;
      my $name = _read_name($block, \$pos);
      my @directives;

      while ($pos < $length - 1) {
        my $char = substr($block, $pos, 1);
        if ($char eq '#') {
          $pos++ while $pos < $length && substr($block, $pos, 1) !~ /[\x0a\x0d]/;
          next;
        }
        if ($char eq '"') {
          _skip_quoted_string($block, \$pos);
          next;
        }
        if ($char eq '[') {
          _skip_delimited($block, \$pos, '[', ']');
          next;
        }
        if ($char eq '{') {
          _skip_delimited($block, \$pos, '{', '}');
          next;
        }
        if ($char eq '@') {
          my $start = $pos;
          my $raw = _skip_directive($block, \$pos);
          push @removals, [$start, $pos];
          push @directives, $raw;
          next;
        }
        last if $char eq '$' || $char eq ')' || $char eq ',';
        $pos++;
      }

      $variables{$name} = \@directives if $name && @directives;
      next;
    }

    $pos++;
  }

  my $rewritten = '';
  my $cursor = 0;
  for my $span (@removals) {
    $rewritten .= substr($block, $cursor, $span->[0] - $cursor);
    $cursor = $span->[1];
  }
  $rewritten .= substr($block, $cursor);

  return ($rewritten, \%variables);
}

sub _strip_variable_definition_directives {
  my ($source) = @_;
  my @operations;
  my $rewritten = '';
  my $cursor = 0;
  my $pos = 0;
  my $length = length $source;
  my $depth = 0;

  while ($pos < $length) {
    my $char = substr($source, $pos, 1);

    if ($char eq '#') {
      $pos++ while $pos < $length && substr($source, $pos, 1) !~ /[\x0a\x0d]/;
      next;
    }
    if ($char eq '"') {
      _skip_quoted_string($source, \$pos);
      next;
    }
    if ($char eq '{') {
      $depth++;
      $pos++;
      next;
    }
    if ($char eq '}') {
      $depth-- if $depth > 0;
      $pos++;
      next;
    }
    if ($depth == 0 && $char =~ /[_A-Za-z]/) {
      my $word = _read_name($source, \$pos);
      if ($word =~ /\A(?:query|mutation|subscription)\z/) {
        _skip_ignored($source, \$pos);
        _read_name($source, \$pos) if substr($source, $pos, 1) =~ /[_A-Za-z]/;
        _skip_ignored($source, \$pos);

        if (substr($source, $pos, 1) eq '(') {
          my $start = $pos;
          _skip_delimited($source, \$pos, '(', ')');
          my $block = substr($source, $start, $pos - $start);
          my ($rewritten_block, $variables) = _scan_variable_definition_directives($block);
          $rewritten .= substr($source, $cursor, $start - $cursor) . $rewritten_block;
          $cursor = $pos;
          push @operations, $variables;
          next;
        }
      }
      next;
    }

    $pos++;
  }

  $rewritten .= substr($source, $cursor);
  return ($rewritten, \@operations);
}

sub _scan_extensions {
  my ($source) = @_;
  my @extensions;
  my $pos = 0;
  my $length = length $source;
  my $depth = 0;

  while ($pos < $length) {
    my $char = substr($source, $pos, 1);

    if ($char eq '#') {
      $pos++ while $pos < $length && substr($source, $pos, 1) !~ /[\x0a\x0d]/;
      next;
    }
    if ($char eq '"') {
      _skip_quoted_string($source, \$pos);
      next;
    }
    if ($char eq '{') {
      $depth++;
      $pos++;
      next;
    }
    if ($char eq '}') {
      $depth-- if $depth > 0;
      $pos++;
      next;
    }
    if ($char =~ /[_A-Za-z]/) {
      my $word = _read_name($source, \$pos);
      if ($depth == 0) {
        if ($word eq 'extend') {
          _skip_ignored($source, \$pos);
          my $kind = _read_name($source, \$pos);
          if (defined $kind && $kind =~ /\A(?:schema|scalar|type|interface|union|enum|input)\z/) {
            my %extension = (kind => $kind);
            if ($kind ne 'schema') {
              _skip_ignored($source, \$pos);
              $extension{name} = _read_name($source, \$pos);
            }
            push @extensions, \%extension;
          }
          next;
        }
      }
      next;
    }

    $pos++;
  }

  return \@extensions;
}

sub preprocess_source_fallback {
  my ($source) = @_;
  my ($rewritten, $operation_variable_directives) = _strip_variable_definition_directives($source);
  my %meta = (
    extensions => _scan_extensions($source),
    interface_implements => {},
    operation_variable_directives => $operation_variable_directives,
    repeatable_directives => {},
  );

  while ($source =~ /^\s*interface\s+([_A-Za-z][_0-9A-Za-z]*)\s+implements\b/mg) {
    $meta{interface_implements}{$1} = 1;
  }
  $rewritten =~ s/^(\s*)interface(?=\s+[_A-Za-z][_0-9A-Za-z]*\s+implements\b)/${1}type/mg;
  while ($source =~ /^\s*extend\s+interface\s+([_A-Za-z][_0-9A-Za-z]*)\s+implements\b/mg) {
    $meta{interface_implements}{$1} = 1;
  }
  $rewritten =~ s/^(\s*extend\s+)interface(?=\s+[_A-Za-z][_0-9A-Za-z]*\s+implements\b)/${1}type/mg;

  while ($source =~ /directive\s*\@([_A-Za-z][_0-9A-Za-z]*)[^{]*?\brepeatable\b/sg) {
    $meta{repeatable_directives}{$1} = 1;
  }
  $rewritten =~ s/\brepeatable\b//g;

  return ($rewritten, \%meta);
}

sub _definition_source_kind {
  my ($definition) = @_;

  return 'schema'    if $definition->{kind} eq 'SchemaDefinition';
  return 'scalar'    if $definition->{kind} eq 'ScalarTypeDefinition';
  return 'type'      if $definition->{kind} eq 'ObjectTypeDefinition';
  return 'interface' if $definition->{kind} eq 'InterfaceTypeDefinition';
  return 'union'     if $definition->{kind} eq 'UnionTypeDefinition';
  return 'enum'      if $definition->{kind} eq 'EnumTypeDefinition';
  return 'input'     if $definition->{kind} eq 'InputObjectTypeDefinition';

  return;
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

sub _convert_directive_texts_fallback {
  my ($raw_directives, $loc) = @_;
  return [] if !$raw_directives || !@$raw_directives;

  my $cache_key = join "\x1e", @$raw_directives;
  my $converted = $DIRECTIVE_CACHE{$cache_key};
  if (!$converted) {
    my $synthetic = 'type __HOUTOU__ ' . join(' ', @$raw_directives) . ' { field: Int }';
    my $legacy = GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($synthetic, {
      backend => 'pegex',
    });
    my $doc = convert_document($legacy, {});
    $converted = $doc->{definitions}[0]{directives} || [];
    $DIRECTIVE_CACHE{$cache_key} = $converted;
  }

  my @copy = map {
    my %directive = %$_;
    _rebase_loc(\%directive, $loc);
    \%directive;
  } @$converted;

  return \@copy;
}

sub materialize_operation_variable_directives {
  my ($meta) = @_;
  return if !@{ $meta->{operation_variable_directives} || [] };

  my @materialized;
  for my $operation (@{ $meta->{operation_variable_directives} || [] }) {
    my %converted;
    for my $name (keys %$operation) {
      $converted{$name} = _convert_directive_texts_fallback($operation->{$name}, undef);
    }
    push @materialized, \%converted;
  }
  $meta->{operation_variable_directives} = \@materialized;
  return $meta;
}

sub patch_document_fallback {
  my ($doc, $meta) = @_;
  my %extension_kind = (
    schema => 'SchemaExtension',
    scalar => 'ScalarTypeExtension',
    type => 'ObjectTypeExtension',
    interface => 'InterfaceTypeExtension',
    union => 'UnionTypeExtension',
    enum => 'EnumTypeExtension',
    input => 'InputObjectTypeExtension',
  );

  for my $definition (@{ $doc->{definitions} || [] }) {
    if ($definition->{kind} eq 'ObjectTypeDefinition'
        && $meta->{interface_implements}{$definition->{name}{value}}) {
      $definition->{kind} = 'InterfaceTypeDefinition';
    }

    my $source_kind = _definition_source_kind($definition);
    if ($source_kind && @{ $meta->{extensions} || [] }) {
      my $next_extension = $meta->{extensions}[0];
      my $name = $definition->{name} ? $definition->{name}{value} : undef;
      if ($next_extension->{kind} eq $source_kind
          && (($next_extension->{name} // '') eq ($name // ''))) {
        shift @{ $meta->{extensions} };
        $definition->{kind} = $extension_kind{$source_kind}
          or die "Unknown extension kind '$source_kind'.\n";
      }
    }

    if ($definition->{kind} eq 'DirectiveDefinition'
        && $meta->{repeatable_directives}{$definition->{name}{value}}) {
      $definition->{repeatable} = 1;
    }

    if ($definition->{kind} eq 'OperationDefinition'
        && @{ $meta->{operation_variable_directives} || [] }) {
      my $operation_meta = shift @{ $meta->{operation_variable_directives} };
      for my $variable_definition (@{ $definition->{variableDefinitions} || [] }) {
        my $name = $variable_definition->{variable}{name}{value};
        next if !$operation_meta->{$name};
        $variable_definition->{directives} = _convert_directive_texts_fallback(
          $operation_meta->{$name},
          $variable_definition->{loc},
        );
      }
    }
  }
  return $doc;
}

1;
