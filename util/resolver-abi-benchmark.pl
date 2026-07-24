use 5.014;
use strict;
use warnings;

use Benchmark qw(cmpthese);
use FindBin qw($Bin);
use File::Spec;
use Getopt::Long qw(GetOptions);

BEGIN {
  my $root = File::Spec->catdir($Bin, '..');
  unshift @INC,
    File::Spec->catdir($root, 'blib', 'lib'),
    File::Spec->catdir($root, 'blib', 'arch'),
    File::Spec->catdir($root, 'lib');
}

use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

my $count = -3;
my $width = 10;
my $scenario = 'no_args';

GetOptions(
  'count=s' => \$count,
  'width=i' => \$width,
  'scenario=s' => \$scenario,
) or die "Usage: $0 [--count Benchmark-count] [--width field-count] [--scenario no_args|static_args]\n";

die "--width must be positive\n" unless $width > 0;
die "--scenario must be no_args or static_args\n"
  unless $scenario eq 'no_args' || $scenario eq 'static_args';

sub build_runner {
  my ($resolver_mode) = @_;
  my %fields = map {
    my $value = "value$_";
    ("field$_" => {
      type => $String,
      resolver_mode => $resolver_mode,
      resolve => sub { return $value },
    })
  } 1 .. $width;

  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => \%fields,
    ),
  );
  my $runtime = $schema->build_runtime;
  my $document = '{ ' . join(q( ), map { "field$_" } 1 .. $width) . ' }';
  my $program = $runtime->compile_program($document);

  return sub { $runtime->execute_program($program) };
}

sub build_static_args_runner {
  my ($resolver_mode) = @_;
  my %fields = map {
    my $name = "field$_";
    ($name => {
      type => $String,
      resolver_mode => $resolver_mode,
      args => {
        prefix => { type => $String },
        value => { type => $String },
      },
      resolve => $resolver_mode eq 'native_positional'
        ? sub {
            my ($source, $prefix, $value) = @_;
            return "$prefix$value";
          }
        : sub {
            my ($source, $args) = @_;
            return "$args->{prefix}$args->{value}";
          },
    })
  } 1 .. $width;

  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => \%fields,
    ),
  );
  my $runtime = $schema->build_runtime;
  my $document = '{ ' . join(q( ), map {
    qq{field$_(prefix: "p", value: "$_")}
  } 1 .. $width) . ' }';
  my $program = $runtime->compile_program($document);

  return sub { $runtime->execute_program($program) };
}

my ($label, $cases);
if ($scenario eq 'static_args') {
  $label = "$width fields with two static arguments";
  $cases = {
    native => build_static_args_runner('native'),
    native_positional => build_static_args_runner('native_positional'),
  };
} else {
  $label = "$width no-argument fields";
  $cases = {
    native => build_runner('native'),
    native_no_args => build_runner('native_no_args'),
  };
}

# Warm all paths before measuring compiled-program request throughput.
for my $runner (values %$cases) {
  $runner->() for 1 .. 1_000;
}

print "resolver ABI benchmark: $label\n";
cmpthese($count, $cases);
