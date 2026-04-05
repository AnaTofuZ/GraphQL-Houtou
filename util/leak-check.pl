#!/usr/bin/env perl
use 5.014;
use strict;
use warnings;

use Cwd qw(abs_path getcwd);
use File::Basename qw(dirname);
use File::Path qw(make_path remove_tree);
use File::Spec;
use File::Temp qw(tempdir);
use Getopt::Long qw(GetOptions);
my @requested_cases;
my $build_dir;
my $keep_build_dir = 0;
my $help = 0;
my $backend = (($^O // '') eq 'darwin') ? 'leaks' : 'asan';

GetOptions(
  'case=s@' => \@requested_cases,
  'build-dir=s' => \$build_dir,
  'keep-build-dir!' => \$keep_build_dir,
  'backend=s' => \$backend,
  'help' => \$help,
) or usage(1);

usage(0) if $help;

my $repo_root = abs_path(File::Spec->catdir(dirname(abs_path($0)), File::Spec->updir));
my %cases = (
  parser_graphqljs => {
    description => 'graphql-js parser and compatibility surface',
    command => [ qw(perl -Iblib/lib -Iblib/arch t/03_parser_graphqljs.t) ],
  },
  xs_smoke => {
    description => 'XS parser and graphql-js smoke coverage',
    command => [ qw(perl -Iblib/lib -Iblib/arch t/04_xs_smoke.t) ],
  },
  execution => {
    description => 'sync execution and abstract completion coverage',
    command => [ qw(perl -Iblib/lib -Iblib/arch t/11_execution.t) ],
  },
  promise => {
    description => 'promise execution and merge coverage',
    command => [ qw(perl -Iblib/lib -Iblib/arch t/12_promise.t) ],
  },
);

my @case_names = @requested_cases ? @requested_cases : qw(parser_graphqljs xs_smoke execution promise);
for my $name (@case_names) {
  die "Unknown leak-check case: $name\n" unless exists $cases{$name};
}
die "Unknown backend: $backend\n" unless $backend eq 'asan' || $backend eq 'leaks';

$build_dir ||= tempdir('houtou-leak-check-XXXXXX', TMPDIR => 1, CLEANUP => !$keep_build_dir);
$build_dir = abs_path($build_dir);

stage_repo($repo_root, $build_dir);
build_copy($build_dir, $backend);

my @failures;
for my $name (@case_names) {
  my $result = run_case($build_dir, $name, $cases{$name});
  push @failures, $result if !$result->{ok};
}

say "";
say "Leak check summary:";
for my $name (@case_names) {
  my ($failure) = grep { $_->{name} eq $name } @failures;
  if ($failure) {
    say "  FAIL $name";
  } else {
    say "  PASS $name";
  }
}

say "Build directory kept at: $build_dir" if $keep_build_dir;

if (@failures) {
  say "";
  for my $failure (@failures) {
    say "Case $failure->{name} failed:";
    say $failure->{reason};
    say "Log: $failure->{log}";
    say "";
  }
  exit 1;
}

exit 0;

sub build_copy {
  my ($dir, $selected_backend) = @_;
  my @configure = qw(perl Build.PL);
  if ($selected_backend eq 'asan') {
    push @configure,
      q(--extra_compiler_flags=-O1 -g -fno-omit-frame-pointer -fsanitize=address),
      q(--extra_linker_flags=-fsanitize=address);
  }

  run_command(
    dir => $dir,
    name => 'configure',
    log => File::Spec->catfile($dir, 'leak-check.configure.log'),
    command => \@configure,
    env => {},
    fail_pattern => undef,
  );

  run_command(
    dir => $dir,
    name => 'build',
    log => File::Spec->catfile($dir, 'leak-check.build.log'),
    command => [qw(./Build build)],
    env => {},
    fail_pattern => undef,
  );
}

sub run_case {
  my ($dir, $name, $case) = @_;
  my $log = File::Spec->catfile($dir, "leak-check.$name.log");
  my %env = ( PERL_DESTRUCT_LEVEL => 2 );
  my $command = $case->{command};
  my $fail_pattern;

  if ($backend eq 'asan') {
    $env{ASAN_OPTIONS} = 'detect_leaks=1:abort_on_error=0:halt_on_error=0:fast_unwind_on_malloc=0';
    $fail_pattern = qr/LeakSanitizer|ERROR: AddressSanitizer|SUMMARY: AddressSanitizer/;
  } else {
    $command = [ 'leaks', '--atExit', '--', @$command ];
    $fail_pattern = qr/Process .*: (?!0 leaks for 0 total leaked bytes\.)\d+ leaks for \d+ total leaked bytes\./m;
  }

  my $result = eval {
    run_command(
      dir => $dir,
      name => $name,
      log => $log,
      command => $command,
      env => \%env,
      fail_pattern => $fail_pattern,
    );
  };

  if ($@) {
    chomp(my $reason = $@);
    return {
      name => $name,
      ok => 0,
      reason => $reason,
      log => $log,
    };
  }

  return {
    name => $name,
    ok => 1,
    log => $log,
  };
}

sub stage_repo {
  my ($src, $dst) = @_;
  remove_tree($dst);
  mkdir $dst or die "mkdir $dst: $!";

  my @command = (
    qw(rsync -a --delete),
    '--exclude', '.git',
    '--exclude', 'blib',
    '--exclude', '_build',
    '--exclude', 'Build',
    '--exclude', 'Build.bat',
    '--exclude', 'MYMETA.json',
    '--exclude', 'MYMETA.yml',
    '--exclude', '*.o',
    '--exclude', '*.bs',
    '--exclude', '*.bundle',
    '--exclude', '*.so',
    "$src/",
    "$dst/",
  );

  run_command(
    dir => getcwd(),
    name => 'stage',
    log => File::Spec->catfile(dirname($dst), 'leak-check.stage.log'),
    command => \@command,
    env => {},
    fail_pattern => undef,
  );
}

sub run_command {
  my (%args) = @_;
  my $dir = $args{dir};
  my $name = $args{name};
  my $log = $args{log};
  my $command = $args{command};
  my $env = $args{env} || {};
  my $fail_pattern = $args{fail_pattern};

  say "";
  say "==> $name";
  say "    @{ $command }";

  make_path(dirname($log));
  {
    open my $seed_fh, '>', $log or die "open $log: $!";
    close $seed_fh;
  }

  my $pid = fork();
  die "fork failed: $!" unless defined $pid;

  if ($pid == 0) {
    chdir $dir or die "chdir $dir: $!";
    open STDOUT, '>', $log or die "open $log: $!";
    open STDERR, '>&', \*STDOUT or die "dup STDERR: $!";
    local %ENV = (%ENV, %$env);
    exec @$command or die "exec @$command failed: $!";
  }

  waitpid($pid, 0);
  my $exit = $? >> 8;

  open my $log_fh, '<', $log or die "open $log: $!";
  local $/;
  my $combined = <$log_fh>;
  close $log_fh;
  print $combined if defined $combined;

  die "command failed ($name), exit=$exit\n" if $exit != 0;

  if ($fail_pattern && $combined =~ $fail_pattern) {
    die "memory checker reported issues for $name\n";
  }

  return 1;
}

sub usage {
  my ($exit) = @_;
  print <<"USAGE";
Usage: $0 [--case NAME] [--backend leaks|asan] [--build-dir DIR] [--keep-build-dir]

Builds a temporary repo copy and runs representative XS workloads under a
memory leak checker. The default backend is 'leaks' on macOS and 'asan'
elsewhere.

Available cases:
  parser_graphqljs
  xs_smoke
  execution
  promise
USAGE
  exit $exit;
}
