package GraphQL::Houtou::Role::FieldDeprecation;

use 5.014;
use strict;
use warnings;

use Moo::Role;
use JSON::MaybeXS;

# Shared deprecation handling for fields and enum values.

my $JSON_noutf8 = JSON::MaybeXS->new->utf8(0)->allow_nonref;

has _fields_deprecation_applied => (
  is => 'rw',
);

sub _fields_deprecation_apply {
  my ($self, $key) = @_;
  return if $self->_fields_deprecation_applied;

  $self->_fields_deprecation_applied(1);
  my $value = $self->{$key} = { %{ $self->{$key} } };
  for my $name (keys %$value) {
    if (defined $value->{$name}{deprecation_reason}) {
      $value->{$name} = { %{ $value->{$name} }, is_deprecated => 1 };
    }
  }
}

sub _from_ast_field_deprecate {
  my ($self, $key, $values) = @_;
  my $value = +{ %{ $values->{$key} } };
  my $directives = delete $value->{directives};
  return $values if !$directives || !@$directives;

  my ($deprecated) = grep { $_->{name} eq 'deprecated' } @$directives;
  return $values if !$deprecated;

  require GraphQL::Houtou::Directive;
  my $reason = $deprecated->{arguments}{reason}
    // $GraphQL::Houtou::Directive::DEPRECATED->args->{reason}{default_value};
  return +{
    %$values,
    $key => { %$value, deprecation_reason => $reason },
  };
}

sub _to_doc_field_deprecate {
  my ($self, $line, $value) = @_;
  return $line if !$value->{is_deprecated};

  require GraphQL::Houtou::Directive;
  $line .= ' @deprecated';
  $line .= '(reason: ' . $JSON_noutf8->encode($value->{deprecation_reason}) . ')'
    if $value->{deprecation_reason} ne
      $GraphQL::Houtou::Directive::DEPRECATED->args->{reason}{default_value};
  return $line;
}

1;
