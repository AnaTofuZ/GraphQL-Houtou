use 5.014;
use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use Getopt::Long qw(GetOptions);

my $count = -3;
my $repeat = 5;
my @cases;
my @modes = qw(houtou_runtime_cached_perl houtou_runtime_native_bundle);

GetOptions(
  'count=s' => \$count,
  'repeat=i' => \$repeat,
  'case=s@' => \@cases,
  'mode=s@' => \@modes,
) or die usage();

@cases = qw(nested_variable_object list_of_objects abstract_with_fragment)
  if !@cases;
{
  my %seen;
  @modes = grep { !$seen{$_}++ } @modes;
}

my $script = File::Spec->catfile($Bin, 'execution-benchmark.pl');

my %samples;
for my $run (1 .. $repeat) {
  my @cmd = (
    $^X,
    '-Iblib/lib',
    '-Iblib/arch',
    $script,
    '--count=' . $count,
    (map { ('--case', $_) } @cases),
  );

  print "=== sample $run/$repeat ===\n";
  my $output = qx{@cmd};
  die "benchmark command failed\n" if $?;
  print $output;

  my $parsed = parse_benchmark_output($output, \@modes);
  for my $case (@cases) {
    for my $mode (@modes) {
      next if !exists $parsed->{$case}{$mode};
      push @{ $samples{$case}{$mode} }, $parsed->{$case}{$mode};
    }
  }
}

print "\n=== checkpoint summary ===\n";
for my $case (@cases) {
  print "\n[$case]\n";
  for my $mode (@modes) {
    my $values = $samples{$case}{$mode} || [];
    next if !@$values;
    my @sorted = sort { $a <=> $b } @$values;
    my $median = @sorted % 2
      ? $sorted[@sorted / 2]
      : ($sorted[@sorted / 2 - 1] + $sorted[@sorted / 2]) / 2;
    my $min = $sorted[0];
    my $max = $sorted[-1];
    my $mean = 0;
    $mean += $_ for @sorted;
    $mean /= @sorted;
    printf "%-24s median=%8.0f/s mean=%8.0f/s min=%8.0f/s max=%8.0f/s samples=%s\n",
      $mode,
      $median,
      $mean,
      $min,
      $max,
      join(',', @$values);
  }
}

sub parse_benchmark_output {
  my ($text, $wanted_modes) = @_;
  my %wanted = map { $_ => 1 } @$wanted_modes;
  my %parsed;
  my $current_case;

  for my $line (split /\n/, $text) {
    if ($line =~ /^===\s+(.+?)\s+===$/) {
      $current_case = $1;
      next;
    }
    next if !$current_case;
    next if $line !~ /^\S+\s+\d+\/s/;

    my ($mode, $rate) = $line =~ /^(\S+)\s+(\d+)\/s/;
    next if !$mode || !$rate;
    next if !$wanted{$mode};
    $parsed{$current_case}{$mode} = $rate;
  }

  return \%parsed;
}

sub usage {
  return <<"USAGE";
Usage: $0 [--count=-3] [--repeat=5] [--case name ...] [--mode name ...]

Runs util/execution-benchmark.pl multiple times and reports checkpoint-oriented
summary statistics (median/mean/min/max) for the selected cases and modes.
USAGE
}
