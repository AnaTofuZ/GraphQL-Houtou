#!/usr/bin/env perl
# Long-running worker soak test.
#
# Simulates the request patterns a prefork web worker sees and asserts that
# resident memory stops growing once the process is warmed up. Scenarios
# cover the paths where native allocations churn per request: fresh
# variables, program cache eviction, specialized (runtime directive)
# programs, resolver/coercion error paths including escaped dies, async
# Promise::XS execution, and persisted bundles.
#
#   perl -Iblib/lib -Iblib/arch util/soak-test.pl
#   perl -Iblib/lib -Iblib/arch util/soak-test.pl --iterations 100000 \
#     --warmup 10000 --max-growth-kb 8192 --scenario varying_variables
use 5.014;
use strict;
use warnings;

use FindBin qw($Bin);
use File::Spec;
use Getopt::Long qw(GetOptions);

BEGIN {
  my $root = File::Spec->catdir($Bin, '..');
  for my $path (
    File::Spec->catdir($root, 'blib', 'lib'),
    File::Spec->catdir($root, 'blib', 'arch'),
    File::Spec->catdir($root, 'lib'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5'),
    File::Spec->catdir($root, 'local', 'lib', 'perl5', 'darwin-2level'),
  ) {
    unshift @INC, $path if -d $path;
  }
}

use GraphQL::Houtou qw(build_native_runtime compile_native_bundle);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::InputObject;
use GraphQL::Houtou::Type::Scalar qw($String $Int $ID);
use GraphQL::Houtou::Directive;

my $iterations = 20000;
my $warmup = 5000;
my $max_growth_kb = 8192;
my @requested;

GetOptions(
  'iterations=i' => \$iterations,
  'warmup=i' => \$warmup,
  'max-growth-kb=i' => \$max_growth_kb,
  'scenario=s@' => \@requested,
) or die "Usage: $0 [--iterations N] [--warmup N] [--max-growth-kb KB] [--scenario name]\n";

sub rss_kb {
  if ($^O eq 'linux') {
    open my $fh, '<', '/proc/self/status' or die "cannot read /proc/self/status: $!";
    while (my $line = <$fh>) {
      return $1 if $line =~ /^VmRSS:\s+(\d+)\s+kB/;
    }
    die "VmRSS not found in /proc/self/status\n";
  }
  my $rss = qx{ps -o rss= -p $$};
  $rss =~ s/\s+//g;
  die "cannot read RSS via ps\n" if $rss !~ /^\d+$/;
  return $rss + 0;
}

# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------

my $mask = GraphQL::Houtou::Directive->new(
  name => 'mask',
  locations => [qw(FIELD)],
  args => { enabled => { type => $Int } },
  apply_field_result => sub {
    my ($value, undef, undef, undef, undef, undef, $directive_args) = @_;
    return $directive_args->{enabled} ? '***' : $value;
  },
);

my $schema = do {
  my $User = GraphQL::Houtou::Type::Object->new(
    name => 'User',
    fields => {
      id => { type => $ID },
      name => { type => $String },
    },
  );
  GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        user => {
          type => $User,
          args => { id => { type => $ID } },
          resolve => sub { my (undef, $args) = @_; { id => $args->{id}, name => "u$args->{id}" } },
        },
        find => {
          type => $String,
          args => { by => { type => GraphQL::Houtou::Type::InputObject->new(
            name => 'LookupBy',
            is_one_of => 1,
            fields => { id => { type => $ID }, email => { type => $String } },
          ) } },
          resolve => sub { 'found' },
        },
        boom => { type => $String, resolve => sub { die "boom\n" } },
        secret => { type => $String, resolve => sub { 'classified' } },
        asyncHello => {
          type => $String,
          resolve => sub { require Promise::XS; Promise::XS::resolved('async world') },
        },
      },
    ),
    directives => [ @GraphQL::Houtou::Directive::SPECIFIED_DIRECTIVES, $mask ],
  );
};

my $runtime = build_native_runtime($schema, program_cache_max => 50);
my $bundle = compile_native_bundle($schema, '{ secret }');
require GraphQL::Houtou::Promise::PromiseXS;
GraphQL::Houtou::Promise::PromiseXS->import(qw(maybe_get_promise_xs));

my %scenarios = (
  varying_variables => sub {
    my ($i) = @_;
    my $r = $runtime->execute_document(
      'query Q($id: ID!) { user(id: $id) { id name } }',
      variables => { id => "v$i" },
    );
    die "varying_variables produced errors\n" if @{ $r->{errors} || [] };
  },
  program_cache_eviction => sub {
    my ($i) = @_;
    my $alias = 'f' . ($i % 200);
    my $r = $runtime->execute_document("{ $alias: secret }");
    die "eviction query failed\n" if @{ $r->{errors} || [] };
  },
  specialized_directives => sub {
    my ($i) = @_;
    my $r = $runtime->execute_document(
      'query Q($on: Int) { secret @mask(enabled: $on) }',
      variables => { on => $i % 2 },
    );
    die "directive query failed\n" if @{ $r->{errors} || [] };
  },
  resolver_error => sub {
    my $r = $runtime->execute_document('{ boom secret }');
    die "resolver error not captured\n" if !@{ $r->{errors} || [] };
  },
  escaped_die => sub {
    eval { $runtime->execute_document('{ find(by: { id: "1", email: "x" }) }') };
    die "escaped die did not propagate\n" if !$@;
  },
  async_promise => sub {
    my $result = maybe_get_promise_xs($runtime->execute_document('{ asyncHello }'));
    die "async result missing\n" if ($result->{data}{asyncHello} || '') ne 'async world';
  },
  persisted_bundle => sub {
    my $r = $runtime->execute_bundle($bundle);
    die "bundle execute failed\n" if @{ $r->{errors} || [] };
  },
);

my @names = @requested ? @requested : sort keys %scenarios;
for my $name (@names) {
  die "Unknown scenario: $name\n" if !$scenarios{$name};
}

sub run_mixed {
  my ($count) = @_;
  for my $i (1 .. $count) {
    my $scenario = $scenarios{ $names[ $i % @names ] };
    $scenario->($i);
  }
}

printf "soak: scenarios=%s warmup=%d iterations=%d max-growth=%dKB\n",
  join(',', @names), $warmup, $iterations, $max_growth_kb;

run_mixed($warmup);
my $baseline_kb = rss_kb();
printf "soak: rss after warmup: %d KB\n", $baseline_kb;

run_mixed($iterations);
my $final_kb = rss_kb();
my $growth_kb = $final_kb - $baseline_kb;
printf "soak: rss after %d iterations: %d KB (growth %+d KB)\n",
  $iterations, $final_kb, $growth_kb;

if ($growth_kb > $max_growth_kb) {
  die sprintf "soak FAILED: RSS grew %d KB (> %d KB) over %d iterations\n",
    $growth_kb, $max_growth_kb, $iterations;
}
say "soak PASSED";
