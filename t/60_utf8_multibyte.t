use strict;
use warnings;
use Test::More 0.98;

# Robustness pass after finding a real bug: a string literal argument
# containing raw (non-escaped) multibyte characters directly in the query
# text - e.g. { greet(name: "田中さん") } - silently lost its UTF8 flag.
# Root cause: gql_runtime_vm_native_dynamic_value_t (the compiled, cached
# representation of a query's STATIC argument literals, reused across
# requests without re-parsing) had no scalar_pv_is_utf8 field, unlike
# gql_runtime_vm_native_value_t (fixed earlier for the async/Promise
# round-trip path - see t/49's "promise-settled string leaves keep their
# UTF-8 flag"). This file covers that fix and other multibyte-adjacent
# corners across Query, Mutation, and schema description strings that had
# not been exercised before.

use JSON::MaybeXS ();

use GraphQL::Houtou qw(build_native_runtime print_schema);
use GraphQL::Houtou::Schema;
use GraphQL::Houtou::Type::Enum;
use GraphQL::Houtou::Type::InputObject;
use GraphQL::Houtou::Type::List;
use GraphQL::Houtou::Type::Object;
use GraphQL::Houtou::Type::Scalar qw($String);

my $ja  = "\x{65e5}\x{672c}\x{8a9e}";              # "日本語"
my $tanaka = "\x{7530}\x{4e2d}\x{3055}\x{3093}";   # "田中さん"
my $suzuki = "\x{9234}\x{6728}";                   # "鈴木"

subtest 'Query: literal multibyte string argument keeps its UTF8 flag' => sub {
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        greet => {
          type => $String,
          args => { name => { type => $String } },
          resolve => sub { my (undef, $a) = @_; return "hello, $a->{name}" },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $result = $runtime->execute_document(qq{ { greet(name: "$tanaka") } });
  is $result->{data}{greet}, "hello, $tanaka", 'content round-trips correctly';
  ok utf8::is_utf8($result->{data}{greet}), 'UTF8 flag is set on the response value';
};

subtest 'Query: multibyte argument via variables (already a different code path)' => sub {
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        greet => {
          type => $String,
          args => { name => { type => $String } },
          resolve => sub { my (undef, $a) = @_; return "hello, $a->{name}" },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $result = $runtime->execute_document(
    'query Q($n: String) { greet(name: $n) }',
    variables => { n => $tanaka },
  );
  is $result->{data}{greet}, "hello, $tanaka", 'content round-trips correctly';
  ok utf8::is_utf8($result->{data}{greet}), 'UTF8 flag is set on the response value';
};

subtest 'Mutation: literal multibyte string argument keeps its UTF8 flag' => sub {
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => { noop => { type => $String, resolve => sub { 'ok' } } },
    ),
    mutation => GraphQL::Houtou::Type::Object->new(
      name => 'Mutation',
      fields => {
        echo => {
          type => $String,
          args => { msg => { type => $String } },
          resolve => sub { my (undef, $a) = @_; return $a->{msg} },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $result = $runtime->execute_document(qq{ mutation { echo(msg: "$ja") } });
  is $result->{data}{echo}, $ja, 'content round-trips correctly';
  ok utf8::is_utf8($result->{data}{echo}), 'UTF8 flag is set on the response value';
};

subtest 'Mutation: multibyte argument via variables' => sub {
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => { noop => { type => $String, resolve => sub { 'ok' } } },
    ),
    mutation => GraphQL::Houtou::Type::Object->new(
      name => 'Mutation',
      fields => {
        echo => {
          type => $String,
          args => { msg => { type => $String } },
          resolve => sub { my (undef, $a) = @_; return $a->{msg} },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $result = $runtime->execute_document(
    'mutation M($m: String) { echo(msg: $m) }',
    variables => { m => $ja },
  );
  is $result->{data}{echo}, $ja, 'content round-trips correctly';
  ok utf8::is_utf8($result->{data}{echo}), 'UTF8 flag is set on the response value';
};

subtest 'literal multibyte items inside a list argument' => sub {
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        join_names => {
          type => $String,
          args => { names => { type => GraphQL::Houtou::Type::List->new(of => $String) } },
          resolve => sub { my (undef, $a) = @_; return join(',', @{ $a->{names} }) },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $result = $runtime->execute_document(qq{ { join_names(names: ["$tanaka", "$suzuki"]) } });
  is $result->{data}{join_names}, "$tanaka,$suzuki", 'content round-trips correctly';
  ok utf8::is_utf8($result->{data}{join_names}), 'UTF8 flag is set on the response value';
};

subtest 'literal multibyte field inside an input object argument' => sub {
  my $Input = GraphQL::Houtou::Type::InputObject->new(
    name => 'PersonInput',
    fields => { name => { type => $String } },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        greet => {
          type => $String,
          args => { person => { type => $Input } },
          resolve => sub { my (undef, $a) = @_; return "hello, $a->{person}{name}" },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $result = $runtime->execute_document(qq{ { greet(person: { name: "$tanaka" }) } });
  is $result->{data}{greet}, "hello, $tanaka", 'content round-trips correctly';
  ok utf8::is_utf8($result->{data}{greet}), 'UTF8 flag is set on the response value';
};

subtest 'a multibyte default_value on a field argument' => sub {
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        greet => {
          type => $String,
          args => { name => { type => $String, default_value => $tanaka } },
          resolve => sub { my (undef, $a) = @_; return "hello, $a->{name}" },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $result = $runtime->execute_document('{ greet }');
  is $result->{data}{greet}, "hello, $tanaka", 'default value content is correct';
  ok utf8::is_utf8($result->{data}{greet}), 'UTF8 flag is set on the response value';
};

subtest 'a literal string mixing a \\u escape and raw multibyte characters' => sub {
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        echo => {
          type => $String,
          args => { msg => { type => $String } },
          resolve => sub { my (undef, $a) = @_; return $a->{msg} },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  # 日 decodes to the same codepoint as the first character of $ja;
  # the rest of the literal is raw (unescaped) multibyte text.
  my $result = $runtime->execute_document(qq{ { echo(msg: "\\u65e5$suzuki") } });
  is $result->{data}{echo}, "\x{65e5}$suzuki", 'escaped and raw multibyte content both decode correctly';
  ok utf8::is_utf8($result->{data}{echo}), 'UTF8 flag is set on the response value';
};

subtest 'the same compiled program executed twice with different literal args does not cross-contaminate' => sub {
  # gql_runtime_vm_native_args_payload_materialize_cached_sv caches a
  # materialized SV per compiled native_program (payload->static_args_sv),
  # reused across every execute_document call against the same schema -
  # exactly the caching layer the UTF8 bug lived in. Running the identical
  # query text twice (letting the specialized-program cache kick in) with
  # different variables/context guards against a stale or shared bad value.
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        greet => {
          type => $String,
          args => { name => { type => $String } },
          resolve => sub { my (undef, $a) = @_; return "hello, $a->{name}" },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  for my $i (1 .. 2) {
    my $result = $runtime->execute_document(qq{ { greet(name: "$tanaka") } });
    is $result->{data}{greet}, "hello, $tanaka", "iteration $i: content is correct";
    ok utf8::is_utf8($result->{data}{greet}), "iteration $i: UTF8 flag is set";
  }
};

subtest 'JSON output preserves multibyte literal arguments correctly' => sub {
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => {
        greet => {
          type => $String,
          args => { name => { type => $String } },
          resolve => sub { my (undef, $a) = @_; return "hello, $a->{name}" },
        },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $bytes = $runtime->execute_document_to_json(qq{ { greet(name: "$tanaka") } });
  ok !utf8::is_utf8($bytes), 'JSON output is octets, not a character string';
  my $decoded = JSON::MaybeXS->new->utf8->decode($bytes);
  is $decoded->{data}{greet}, "hello, $tanaka", 'decoded JSON content is correct';
};

subtest 'multibyte type and field descriptions round-trip through introspection' => sub {
  my $desc_type = "\x{3053}\x{308c}\x{306f}\x{8aac}\x{660e}\x{3067}\x{3059}"; # "これは説明です"
  my $desc_field = "\x{540d}\x{524d}\x{3092}\x{8fd4}\x{3059}";               # "名前を返す"
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      description => $desc_type,
      fields => {
        greet => { type => $String, description => $desc_field, resolve => sub { 'hi' } },
      },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $result = $runtime->execute_document(
    '{ __type(name: "Query") { description fields { name description } } }'
  );
  is $result->{data}{__type}{description}, $desc_type, 'type description content is correct';
  ok utf8::is_utf8($result->{data}{__type}{description}), 'type description keeps its UTF8 flag';
  is $result->{data}{__type}{fields}[0]{description}, $desc_field, 'field description content is correct';
  ok utf8::is_utf8($result->{data}{__type}{fields}[0]{description}), 'field description keeps its UTF8 flag';
};

subtest 'multibyte descriptions round-trip through print_schema (SDL)' => sub {
  my $desc = "\x{578b}\x{306e}\x{8aac}\x{660e}"; # "型の説明"
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      description => $desc,
      fields => {
        greet => { type => $String, resolve => sub { 'hi' } },
      },
    ),
  );
  my $sdl = print_schema($schema);
  ok utf8::is_utf8($sdl), 'SDL output keeps its UTF8 flag';
  like $sdl, qr/\Q$desc\E/, 'SDL output contains the description text unchanged';
};

subtest 'multibyte enum value description round-trips through introspection' => sub {
  my $desc = "\x{5e78}\x{305b}\x{306a}\x{72b6}\x{6001}"; # "幸せな状態"
  my $Mood = GraphQL::Houtou::Type::Enum->new(
    name => 'Mood',
    values => {
      HAPPY => { description => $desc },
    },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => { mood => { type => $Mood, resolve => sub { 'HAPPY' } } },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $result = $runtime->execute_document(
    '{ __type(name: "Mood") { enumValues { name description } } }'
  );
  is $result->{data}{__type}{enumValues}[0]{description}, $desc, 'enum value description content is correct';
  ok utf8::is_utf8($result->{data}{__type}{enumValues}[0]{description}),
    'enum value description keeps its UTF8 flag';
};

subtest 'a multibyte custom scalar validation error message is not garbled' => sub {
  my $desc = "\x{7121}\x{52b9}\x{306a}\x{5024}\x{3067}\x{3059}"; # "無効な値です"
  my $Strict = GraphQL::Houtou::Type::Scalar->new(
    name => 'Strict',
    serialize => sub { die "$desc\n" },
    parse_value => sub { $_[0] },
  );
  my $schema = GraphQL::Houtou::Schema->new(
    query => GraphQL::Houtou::Type::Object->new(
      name => 'Query',
      fields => { bad => { type => $Strict, resolve => sub { 'x' } } },
    ),
  );
  my $runtime = build_native_runtime($schema);
  my $result = $runtime->execute_document('{ bad }');
  is $result->{data}{bad}, undef, 'the field is null';
  like $result->{errors}[0]{message}, qr/\Q$desc\E/, 'the error message content is correct';
  ok utf8::is_utf8($result->{errors}[0]{message}), 'the error message keeps its UTF8 flag';
};

done_testing;
