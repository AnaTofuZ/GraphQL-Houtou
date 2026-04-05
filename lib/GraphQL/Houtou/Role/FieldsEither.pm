package GraphQL::Houtou::Role::FieldsEither;

use 5.014;
use strict;
use warnings;

use Moo::Role;
use JSON::MaybeXS;

with qw(GraphQL::Houtou::Role::FieldDeprecation);

# Shared field-map helpers used by both input and output definitions.

my $JSON_noutf8 = JSON::MaybeXS->new->utf8(0)->allow_nonref;

sub _make_field_def {
  my ($self, $name2type, $field_name, $field_def) = @_;
  require GraphQL::Houtou::Schema;

  my %args;
  if ($field_def->{args}) {
    %args = (
      args => +{
        map { $self->_make_field_def($name2type, $_, $field_def->{args}{$_}) }
          keys %{ $field_def->{args} }
      },
    );
  }

  return (
    $field_name => {
      %$field_def,
      type => GraphQL::Houtou::Schema::lookup_type($field_def, $name2type),
      %args,
    }
  );
}

sub _from_ast_fields {
  my ($self, $name2type, $ast_node, $key) = @_;
  my $fields = $ast_node->{$key};
  $fields = $self->_from_ast_field_deprecate($_, $fields) for keys %$fields;

  return (
    $key => sub { +{
      map {
        my @pair = eval {
          $self->_make_field_def($name2type, $_, $fields->{$_})
        };
        die "Error in field '$_': $@" if $@;
        @pair;
      } keys %$fields
    } },
  );
}

sub _description_doc_lines {
  my ($self, $description) = @_;
  return if !$description;

  my @lines = split /\n/, $description;
  return if !@lines;
  if (@lines == 1) {
    return '"' . ($lines[0] =~ s#"#\\"#gr) . '"';
  }

  return (
    '"""',
    (map { s#"""#\\"""#gr } @lines),
    '"""',
  );
}

sub _make_fieldtuples {
  my ($self, $fields) = @_;

  return map {
    my $field = $fields->{$_};
    my @argtuples = map { $_->[0] } $self->_make_fieldtuples($field->{args} || {});
    my $type = $field->{type};
    my $line = $_;
    $line .= '(' . join(', ', @argtuples) . ')' if @argtuples;
    $line .= ': ' . $type->to_string;
    $line .= ' = ' . $JSON_noutf8->encode(
      $type->perl_to_graphql($field->{default_value})
    ) if exists $field->{default_value};
    my @directives = map {
      my $args = $_->{arguments};
      my @pairs = map { "$_: " . $JSON_noutf8->encode($args->{$_}) } keys %$args;
      '@' . $_->{name} . (@pairs ? '(' . join(', ', @pairs) . ')' : '');
    } @{ $field->{directives} || [] };
    $line .= join(' ', ('', @directives)) if @directives;
    [
      $self->_to_doc_field_deprecate($line, $field),
      $self->_description_doc_lines($field->{description}),
    ]
  } sort keys %$fields;
}

1;
