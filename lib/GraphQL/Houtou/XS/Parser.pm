package GraphQL::Houtou::XS::Parser;

use 5.014;
use strict;
use warnings;
use GraphQL ();
use GraphQL::Error;
use GraphQL::Houtou ();
use GraphQL::Language::Receiver ();
use JSON::PP ();

our $VERSION = '0.01';

BEGIN {
  GraphQL::Houtou::_bootstrap_xs();
}

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

sub _new_lazy_array_ref {
  my ($class, $state, $ptr) = @_;
  my @items;
  tie @items, $class, $state, $ptr;
  return \@items;
}

sub _new_lazy_array_tie {
  my ($class, $state, $ptr, $kind) = @_;
  # NOTE: these keys are part of the XS fast-path contract in gqljs_fetch_array().
  # If you rename them, update the XS reader and the contract test together.
  return bless {
    state => $state,
    ptr => $ptr,
    kind => $kind,
    data => undef,
  }, $class;
}

package GraphQL::Houtou::XS::LazyLoc;

use 5.014;
use strict;
use warnings;

sub start {
  return $_[0][0];
}

sub as_hash {
  my ($self, $source) = @_;
  my ($line, $column) = GraphQL::Houtou::XS::Parser::_line_column($source, $self->[0]);
  return {
    line => $line,
    column => $column,
  };
}

sub line {
  my ($self, $source) = @_;
  my ($line) = GraphQL::Houtou::XS::Parser::_line_column($source, $self->[0]);
  return $line;
}

sub column {
  my ($self, $source) = @_;
  my (undef, $column) = GraphQL::Houtou::XS::Parser::_line_column($source, $self->[0]);
  return $column;
}

package GraphQL::Houtou::XS::LazyArray::Arguments;

use 5.014;
use strict;
use warnings;

sub _new {
  my ($state, $ptr) = @_;
  return GraphQL::Houtou::XS::Parser::_new_lazy_array_ref(__PACKAGE__, $state, $ptr);
}

sub TIEARRAY {
  my ($class, $state, $ptr) = @_;
  return GraphQL::Houtou::XS::Parser::_new_lazy_array_tie($class, $state, $ptr, 1);
}

sub _materialize {
  my ($self) = @_;
  return $self->{data} if $self->{data};
  $self->{data} = GraphQL::Houtou::XS::Parser::_graphqljs_materialize_arguments_xs(
    $self->{state},
    $self->{ptr},
  );
  return $self->{data};
}

sub FETCHSIZE {
  my ($self) = @_;
  return scalar @{ $self->_materialize };
}

sub STORESIZE {
  my ($self, $count) = @_;
  $#{ $self->_materialize } = $count - 1;
  return;
}

sub FETCH {
  my ($self, $index) = @_;
  return $self->_materialize->[$index];
}

sub STORE {
  my ($self, $index, $value) = @_;
  $self->_materialize->[$index] = $value;
  return $value;
}

sub CLEAR {
  my ($self) = @_;
  @{ $self->_materialize } = ();
  return;
}

sub PUSH {
  my ($self, @values) = @_;
  return push @{ $self->_materialize }, @values;
}

sub POP {
  my ($self) = @_;
  return pop @{ $self->_materialize };
}

sub SHIFT {
  my ($self) = @_;
  return shift @{ $self->_materialize };
}

sub UNSHIFT {
  my ($self, @values) = @_;
  return unshift @{ $self->_materialize }, @values;
}

sub EXISTS {
  my ($self, $index) = @_;
  return exists $self->_materialize->[$index];
}

sub DELETE {
  my ($self, $index) = @_;
  return delete $self->_materialize->[$index];
}

sub SPLICE {
  my $self = shift;
  return splice @{ $self->_materialize }, @_;
}

package GraphQL::Houtou::XS::LazyArray::Directives;

use 5.014;
use strict;
use warnings;

sub _new {
  my ($state, $ptr) = @_;
  return GraphQL::Houtou::XS::Parser::_new_lazy_array_ref(__PACKAGE__, $state, $ptr);
}

sub TIEARRAY {
  my ($class, $state, $ptr) = @_;
  return GraphQL::Houtou::XS::Parser::_new_lazy_array_tie($class, $state, $ptr, 2);
}

sub _materialize {
  my ($self) = @_;
  return $self->{data} if $self->{data};
  $self->{data} = GraphQL::Houtou::XS::Parser::_graphqljs_materialize_directives_xs(
    $self->{state},
    $self->{ptr},
  );
  return $self->{data};
}

sub FETCHSIZE {
  my ($self) = @_;
  return scalar @{ $self->_materialize };
}

sub STORESIZE {
  my ($self, $count) = @_;
  $#{ $self->_materialize } = $count - 1;
  return;
}

sub FETCH {
  my ($self, $index) = @_;
  return $self->_materialize->[$index];
}

sub STORE {
  my ($self, $index, $value) = @_;
  $self->_materialize->[$index] = $value;
  return $value;
}

sub CLEAR {
  my ($self) = @_;
  @{ $self->_materialize } = ();
  return;
}

sub PUSH {
  my ($self, @values) = @_;
  return push @{ $self->_materialize }, @values;
}

sub POP {
  my ($self) = @_;
  return pop @{ $self->_materialize };
}

sub SHIFT {
  my ($self) = @_;
  return shift @{ $self->_materialize };
}

sub UNSHIFT {
  my ($self, @values) = @_;
  return unshift @{ $self->_materialize }, @values;
}

sub EXISTS {
  my ($self, $index) = @_;
  return exists $self->_materialize->[$index];
}

sub DELETE {
  my ($self, $index) = @_;
  return delete $self->_materialize->[$index];
}

sub SPLICE {
  my $self = shift;
  return splice @{ $self->_materialize }, @_;
}

package GraphQL::Houtou::XS::LazyArray::VariableDefinitions;

use 5.014;
use strict;
use warnings;

sub _new {
  my ($state, $ptr) = @_;
  return GraphQL::Houtou::XS::Parser::_new_lazy_array_ref(__PACKAGE__, $state, $ptr);
}

sub TIEARRAY {
  my ($class, $state, $ptr) = @_;
  return GraphQL::Houtou::XS::Parser::_new_lazy_array_tie($class, $state, $ptr, 3);
}

sub _materialize {
  my ($self) = @_;
  return $self->{data} if $self->{data};
  $self->{data} = GraphQL::Houtou::XS::Parser::_graphqljs_materialize_variable_definitions_xs(
    $self->{state},
    $self->{ptr},
  );
  return $self->{data};
}

sub FETCHSIZE {
  my ($self) = @_;
  return scalar @{ $self->_materialize };
}

sub STORESIZE {
  my ($self, $count) = @_;
  $#{ $self->_materialize } = $count - 1;
  return;
}

sub FETCH {
  my ($self, $index) = @_;
  return $self->_materialize->[$index];
}

sub STORE {
  my ($self, $index, $value) = @_;
  $self->_materialize->[$index] = $value;
  return $value;
}

sub CLEAR {
  my ($self) = @_;
  @{ $self->_materialize } = ();
  return;
}

sub PUSH {
  my ($self, @values) = @_;
  return push @{ $self->_materialize }, @values;
}

sub POP {
  my ($self) = @_;
  return pop @{ $self->_materialize };
}

sub SHIFT {
  my ($self) = @_;
  return shift @{ $self->_materialize };
}

sub UNSHIFT {
  my ($self, @values) = @_;
  return unshift @{ $self->_materialize }, @values;
}

sub EXISTS {
  my ($self, $index) = @_;
  return exists $self->_materialize->[$index];
}

sub DELETE {
  my ($self, $index) = @_;
  return delete $self->_materialize->[$index];
}

sub SPLICE {
  my $self = shift;
  return splice @{ $self->_materialize }, @_;
}

package GraphQL::Houtou::XS::LazyArray::ObjectFields;

use 5.014;
use strict;
use warnings;

sub _new {
  my ($state, $ptr) = @_;
  return GraphQL::Houtou::XS::Parser::_new_lazy_array_ref(__PACKAGE__, $state, $ptr);
}

sub TIEARRAY {
  my ($class, $state, $ptr) = @_;
  return GraphQL::Houtou::XS::Parser::_new_lazy_array_tie($class, $state, $ptr, 4);
}

sub _materialize {
  my ($self) = @_;
  return $self->{data} if $self->{data};
  $self->{data} = GraphQL::Houtou::XS::Parser::_graphqljs_materialize_object_fields_xs(
    $self->{state},
    $self->{ptr},
  );
  return $self->{data};
}

sub FETCHSIZE {
  my ($self) = @_;
  return scalar @{ $self->_materialize };
}

sub STORESIZE {
  my ($self, $count) = @_;
  $#{ $self->_materialize } = $count - 1;
  return;
}

sub FETCH {
  my ($self, $index) = @_;
  return $self->_materialize->[$index];
}

sub STORE {
  my ($self, $index, $value) = @_;
  $self->_materialize->[$index] = $value;
  return $value;
}

sub CLEAR {
  my ($self) = @_;
  @{ $self->_materialize } = ();
  return;
}

sub PUSH {
  my ($self, @values) = @_;
  return push @{ $self->_materialize }, @values;
}

sub POP {
  my ($self) = @_;
  return pop @{ $self->_materialize };
}

sub SHIFT {
  my ($self) = @_;
  return shift @{ $self->_materialize };
}

sub UNSHIFT {
  my ($self, @values) = @_;
  return unshift @{ $self->_materialize }, @values;
}

sub EXISTS {
  my ($self, $index) = @_;
  return exists $self->_materialize->[$index];
}

sub DELETE {
  my ($self, $index) = @_;
  return delete $self->_materialize->[$index];
}

sub SPLICE {
  my $self = shift;
  return splice @{ $self->_materialize }, @_;
}

1;
