package GraphQL::Houtou::XS::Parser;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL ();
use GraphQL::Error;
use GraphQL::Language::Receiver ();
use JSON::PP ();
use XSLoader ();

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  graphqljs_apply_executable_loc_xs
  graphqljs_build_document_xs
  graphqljs_build_executable_document_xs
  graphqljs_build_directives_xs
  graphqljs_parse_executable_document_xs
  graphqlperl_build_document_xs
  graphqlperl_find_legacy_empty_object_location_xs
  graphqljs_preprocess_xs
  graphqljs_patch_document_xs
  parse_xs
  parse_directives_xs
  tokenize_xs
);

XSLoader::load('GraphQL::Houtou', $VERSION);

sub _make_bool {
  return $_[0] ? JSON::PP::true : JSON::PP::false;
}

sub _string_value {
  return GraphQL::Language::Receiver::_unescape($_[0]);
}

sub _block_string_value {
  return GraphQL::Language::Receiver::_blockstring_value($_[0]);
}

sub _format_error {
  my ($source, $position, $msg) = @_;
  my ($line, $column) = _line_column($source, $position);
  my $pretext = substr(
    $source,
    $position < 50 ? 0 : $position - 50,
    $position < 50 ? $position : 50,
  );
  my $context = substr($source, $position, 50);
  $pretext =~ s/.*\n//gs;
  $context =~ s/\n/\\n/g;
  return GraphQL::Error->new(
    locations => [ { line => $line, column => $column } ],
    message => <<EOF,
Error parsing Pegex document:
  msg:      $msg
  context:  $pretext$context
            ${\ (' ' x (length($pretext)) . '^')}
  position: $position (0 pre-lookahead)
EOF
  );
}

sub _line_column {
  my ($source, $position) = @_;
  my $line = 1;
  my $column = 1;
  my $i = 0;
  my $length = length $source;
  $position = $length if $position > $length;
  while ($i < $position) {
    my $char = substr($source, $i, 1);
    if ($char eq "\r") {
      ++$line;
      $column = 1;
      ++$i;
      ++$i if $i < $position && substr($source, $i, 1) eq "\n";
      next;
    }
    if ($char eq "\n") {
      ++$line;
      $column = 1;
      ++$i;
      next;
    }
    ++$column;
    ++$i;
  }
  return ($line, $column);
}

1;
