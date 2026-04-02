use strict;
use warnings;

use Benchmark qw(cmpthese);
use FindBin qw($Bin);
use Getopt::Long qw(GetOptions);
use lib "$Bin/../lib";

use GraphQL::Houtou qw(parse parse_with_options);

my $file = 't/kitchen-sink.graphql';
my $count = -5;

GetOptions(
  'file=s'  => \$file,
  'count=s' => \$count,
) or die "Usage: $0 [--file path] [--count Benchmark-count]\n";

open my $fh, '<', $file or die "Failed to open $file: $!";
my $source = do { local $/; <$fh> };

sub run_graphql_perl_pegex {
  return parse_with_options($source, {
    dialect => 'graphql-perl',
    backend => 'pegex',
  });
}

sub run_graphql_perl_xs {
  return parse_with_options($source, {
    dialect => 'graphql-perl',
    backend => 'xs',
  });
}

sub run_graphql_js_xs {
  return parse_with_options($source, {
    dialect => 'graphql-js',
    backend => 'xs',
  });
}

sub run_graphql_js_pegex {
  return parse_with_options($source, {
    dialect => 'graphql-js',
    backend => 'pegex',
  });
}

sub run_graphql_js_xs_noloc {
  return parse_with_options($source, {
    dialect => 'graphql-js',
    backend => 'xs',
    no_location => 1,
  });
}

sub run_graphql_js_pegex_noloc {
  return parse_with_options($source, {
    dialect => 'graphql-js',
    backend => 'pegex',
    no_location => 1,
  });
}

run_graphql_perl_pegex();
run_graphql_perl_xs();
run_graphql_js_xs();
run_graphql_js_pegex();
run_graphql_js_xs_noloc();
run_graphql_js_pegex_noloc();

print "Benchmark target: $file\n";
print "Benchmark count: $count\n";

cmpthese($count, {
  graphql_perl_pegex => \&run_graphql_perl_pegex,
  graphql_perl_xs    => \&run_graphql_perl_xs,
  graphql_js_pegex   => \&run_graphql_js_pegex,
  graphql_js_xs      => \&run_graphql_js_xs,
  graphql_js_pegex_noloc => \&run_graphql_js_pegex_noloc,
  graphql_js_xs_noloc    => \&run_graphql_js_xs_noloc,
});
