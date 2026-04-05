package GraphQL::Houtou::Type::Library;

use 5.014;
use strict;
use warnings;

use Type::Library
  -base,
  -declare => qw(
    StrNameValid
    FieldMapInput
    FieldMapOutput
    ValuesMatchTypes
    DocumentLocation
    JSONable
    ErrorResult
    FieldsGot
    Int32Signed
    ArrayRefNonEmpty
    UniqueByProperty
    ExpectObject
    ExecutionResult
    ExecutionPartialResult
    Promise
    PromiseCode
    AsyncIterator
  );
use Type::Utils -all;
use Types::TypeTiny -all;
use Types::Standard -all;
use JSON::MaybeXS;

our $VERSION = '0.01';
my $JSON = JSON::MaybeXS->new->allow_nonref;
my $InputTypeConsumer = ConsumerOf['GraphQL::Houtou::Role::Input']
  | ConsumerOf['GraphQL::Role::Input'];
my $OutputTypeConsumer = ConsumerOf['GraphQL::Houtou::Role::Output']
  | ConsumerOf['GraphQL::Role::Output'];

declare "StrNameValid", as StrMatch[ qr/^[_a-zA-Z][_a-zA-Z0-9]*$/ ];

declare "ValuesMatchTypes",
  constraint_generator => sub {
    my ($value_key, $type_key) = @_;
    declare as HashRef[Dict[
      $type_key => $InputTypeConsumer,
      slurpy Any,
    ]], where {
      !grep {
        $_->{$value_key} and !$_->{$type_key}->is_valid($_->{$value_key})
      } values %$_
    }, inline_as {
      (undef, <<EOF);
        !grep {
          \$_->{$value_key} and !\$_->{$type_key}->is_valid(\$_->{$value_key})
        } values %{$_[1]}
EOF
    };
  };

declare "FieldsGot", as Tuple[
  ArrayRef[StrNameValid],
  Map[StrNameValid, ArrayRef[HashRef]]
];

declare "FieldMapInput", as Map[
  StrNameValid,
  Dict[
    type => $InputTypeConsumer,
    default_value => Optional[Any],
    directives => Optional[ArrayRef[HashRef]],
    description => Optional[Str],
  ]
] & ValuesMatchTypes['default_value', 'type' ];

declare "FieldMapOutput", as Map[
  StrNameValid,
  Dict[
    type => $OutputTypeConsumer,
    args => Optional[FieldMapInput],
    resolve => Optional[CodeRef],
    subscribe => Optional[CodeRef],
    directives => Optional[ArrayRef[HashRef]],
    deprecation_reason => Optional[Str],
    description => Optional[Str],
  ]
];

declare "Int32Signed", as Int, where { $_ >= -2147483648 and $_ <= 2147483647 };

declare "ArrayRefNonEmpty", constraint_generator => sub {
  intersection [ ArrayRef[@_], Tuple[Any, slurpy Any] ]
};

declare "UniqueByProperty",
  constraint_generator => sub {
    die "must give one property name" unless @_ == 1;
    my ($prop) = @_;
    declare as ArrayRef[HasMethods[$prop]], where {
      my %seen;
      !grep $seen{$_->$prop}++, @$_;
    }, inline_as {
      (undef, "my %seen; !grep \$seen{\$_->$prop}++, \@{$_[1]};");
    };
  };

declare "ExpectObject",
  as Maybe[HashRef],
  message { "found not an object" };

declare "DocumentLocation",
  as Dict[
    line => Int,
    column => Int,
  ];

declare "JSONable",
  as Any,
  where { $JSON->encode($_); 1 };

declare "ErrorResult",
  as Dict[
    message => Str,
    path => Optional[ArrayRef[Str]],
    locations => Optional[ArrayRef[DocumentLocation]],
    extensions => Optional[HashRef[JSONable]],
  ];

declare "ExecutionResult",
  as Dict[
    data => Optional[JSONable],
    errors => Optional[ArrayRef[ErrorResult]],
  ];

declare "ExecutionPartialResult",
  as Dict[
    data => Optional[JSONable],
    errors => Optional[ArrayRef[InstanceOf['GraphQL::Error']]],
  ];

declare "Promise",
  as HasMethods[qw(then)];

declare "PromiseCode",
  as Dict[
    resolve => CodeLike,
    all => CodeLike,
    reject => CodeLike,
    new => Optional[CodeLike],
    then => Optional[CodeLike],
    is_promise => Optional[CodeLike],
  ];

declare "AsyncIterator",
  as InstanceOf['GraphQL::AsyncIterator'];

1;

__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou::Type::Library - Houtou-owned GraphQL Type::Tiny constraints

=head1 SYNOPSIS

    use GraphQL::Houtou::Type::Library -all;

=head1 DESCRIPTION

This module owns the GraphQL-specific Type::Tiny constraints used by
Houtou schema and execution-related APIs.

=cut
