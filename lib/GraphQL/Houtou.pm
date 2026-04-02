package GraphQL::Houtou;

use 5.014;
use strict;
use warnings;
use Exporter 'import';
use GraphQL::Houtou::GraphQLJS::Parser ();
use GraphQL::Houtou::GraphQLPerl::Parser ();

our $VERSION = '0.01';
our @EXPORT_OK = qw(
  parse
  parse_with_options
);

sub parse {
  return GraphQL::Houtou::GraphQLPerl::Parser::parse(@_);
}

sub parse_with_options {
  my ($source, $options) = @_;
  $options ||= {};
  my $dialect = $options->{dialect} || 'graphql-perl';

  if ($dialect eq 'graphql-perl') {
    return GraphQL::Houtou::GraphQLPerl::Parser::parse_with_options($source, $options);
  }
  if ($dialect eq 'graphql-js') {
    return GraphQL::Houtou::GraphQLJS::Parser::parse($source, $options);
  }

  die "Unknown parser dialect '$dialect'.\n";
}

1;
__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou - Alternative GraphQL parser toolkit for Perl

=head1 SYNOPSIS

    use GraphQL::Houtou qw(parse parse_with_options);

    my $legacy_ast = parse('{ user { id } }');

    my $js_ast = parse_with_options('{ user { id } }', {
      dialect => 'graphql-js',
      backend => 'xs',
    });

=head1 DESCRIPTION

GraphQL::Houtou provides parser implementations and AST dialect adapters
that can be used alongside the upstream C<GraphQL> distribution.

=head1 LICENSE

Copyright (C) anatofuz.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

anatofuz E<lt>anatofuz@gmail.comE<gt>

=cut
