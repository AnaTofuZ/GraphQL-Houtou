use strict;
use warnings;

use FindBin qw($Bin);
use Getopt::Long qw(GetOptions);
use lib "$Bin/../lib";

use GraphQL::Houtou qw(parse_with_options);

my $dialect = 'graphql-perl';
my $backend = 'xs';
my $file = 't/kitchen-sink.graphql';
my $iterations = 200;

GetOptions(
  'dialect=s'    => \$dialect,
  'backend=s'    => \$backend,
  'file=s'       => \$file,
  'iterations=i' => \$iterations,
) or die "Usage: $0 [--dialect graphql-perl|graphql-js] [--backend pegex|xs|canonical-xs] [--file path] [--iterations N]\n";

die "--dialect must be graphql-perl or graphql-js\n"
  unless $dialect eq 'graphql-perl' || $dialect eq 'graphql-js';

if ($dialect eq 'graphql-js') {
  die "--backend must be xs for graphql-js\n"
    unless $backend eq 'xs';
}
else {
  die "--backend must be pegex, xs, or canonical-xs for graphql-perl\n"
    unless $backend eq 'pegex' || $backend eq 'xs' || $backend eq 'canonical-xs';
}

open my $fh, '<', $file or die "Failed to open $file: $!";
my $source = do { local $/; <$fh> };

for (1 .. $iterations) {
  parse_with_options($source, {
    dialect => $dialect,
    backend => $backend,
  });
}

print "profiled dialect=$dialect backend=$backend file=$file iterations=$iterations\n";
