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

GetOptions(
  'count=s' => \$count,
  'width=i' => \$width,
) or die "Usage: $0 [--count Benchmark-count] [--width field-count]\n";

die "--width must be positive\n" unless $width > 0;

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

my $native = build_runner('native');
my $native_no_args = build_runner('native_no_args');

# Warm both paths before measuring compiled-program request throughput.
$native->() for 1 .. 1_000;
$native_no_args->() for 1 .. 1_000;

print "resolver ABI benchmark: $width no-argument fields\n";
cmpthese($count, {
  native => $native,
  native_no_args => $native_no_args,
});
