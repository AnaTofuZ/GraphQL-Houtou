package GraphQL::Houtou::Runtime::NativeRuntime;

use 5.014;
use strict;
use warnings;

use Scalar::Util qw(blessed refaddr);

use GraphQL::Houtou::Runtime::InputCoercion ();
use GraphQL::Houtou::Runtime::DirectiveRuntime ();
use GraphQL::Houtou::Runtime::VMCompiler ();
use GraphQL::Houtou::Schema ();
use JSON::MaybeXS qw(decode_json encode_json is_bool);

use GraphQL::Houtou::Validation::DepthLimit ();

use constant DEFAULT_MAX_DEPTH => GraphQL::Houtou::Validation::DepthLimit::DEFAULT_MAX_DEPTH();

sub new {
  my ($class, %args) = @_;
  die "runtime_schema is required\n" if !$args{runtime_schema};
  my $cache_max = exists $args{program_cache_max} ? $args{program_cache_max} : 1000;
  my $max_depth = exists $args{max_depth} ? $args{max_depth} : DEFAULT_MAX_DEPTH;
  return bless {
    runtime_schema => $args{runtime_schema},
    native_runtime_struct => $args{native_runtime_struct},
    native_runtime_compact_struct => $args{native_runtime_compact_struct},
    native_runtime_handle => $args{native_runtime_handle},
    _program_cache => {},
    _program_cache_order => [],
    _program_cache_max => $cache_max,
    _specialized_program_cache => {},
    _specialized_program_cache_order => [],
    _specialized_program_cache_max => $cache_max,
    _max_depth => $max_depth,
  }, $class;
}

sub runtime_schema { return $_[0]{runtime_schema} }

sub _native_runtime_struct {
  my ($self) = @_;
  $self->{native_runtime_struct} ||= $self->runtime_schema->to_native_exec_struct;
  return $self->{native_runtime_struct};
}

sub _native_runtime_compact_struct {
  my ($self) = @_;
  $self->{native_runtime_compact_struct} ||= $self->runtime_schema->to_native_compact_struct;
  return $self->{native_runtime_compact_struct};
}

sub _native_runtime_handle {
  my ($self) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  $self->{native_runtime_handle} ||= GraphQL::Houtou::XS::VM::load_native_runtime_xs(
    $self->_native_runtime_struct,
  );
  return $self->{native_runtime_handle};
}

sub compile_program {
  my ($self, $document, %opts) = @_;
  if (!ref($document) && $self->{_program_cache_max}) {
    my $cached = $self->{_program_cache}{$document};
    return $cached if $cached;
    my $program = $self->runtime_schema->compile_program($document, %opts);
    $self->_store_program_cache($document, $program);
    return $program;
  }
  return $self->runtime_schema->compile_program($document, %opts);
}

sub _store_program_cache {
  my ($self, $key, $program) = @_;
  my $cache = $self->{_program_cache};
  my $order = $self->{_program_cache_order};
  if (scalar(@$order) >= $self->{_program_cache_max}) {
    my $evicted = shift @$order;
    delete $cache->{$evicted};
  }
  $cache->{$key} = $program;
  push @$order, $key;
}

sub program_cache_size { scalar keys %{ $_[0]{_program_cache} } }

sub clear_program_cache {
  my ($self) = @_;
  $self->{_program_cache} = {};
  $self->{_program_cache_order} = [];
  $self->{_specialized_program_cache} = {};
  $self->{_specialized_program_cache_order} = [];
}

sub compile_bundle_for_document {
  my ($self, $document, %opts) = @_;
  my $descriptor = $self->compile_bundle_descriptor_for_document($document, %opts);
  return $self->load_bundle_descriptor($descriptor);
}

sub specialize_program {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program_for_native(
    $program,
    %opts,
  );
  my $engine = __PACKAGE__->preferred_engine_for_program($candidate, %opts);
  die "Program cannot be specialized into the native VM path.\n" if $engine ne 'native';
  return $candidate;
}

sub specialize_program_for_native {
  my ($self, $program, %opts) = @_;
  return $program if !$program;

  my $native_program = _require_native_program($program);
  my $variables = GraphQL::Houtou::Runtime::InputCoercion::prepare_variables(
    $self->runtime_schema,
    $native_program,
    $opts{variables} || {},
  );
  GraphQL::Houtou::_bootstrap_xs();
  return $self->_specialize_program_descriptor(
    $native_program,
    $variables,
  );
}

sub _specialize_program_descriptor {
  my ($self, $native_program, $variables) = @_;
  my $specialized = GraphQL::Houtou::XS::VM::specialize_native_program_xs(
    $self->_native_runtime_handle,
    $native_program,
    $variables,
  );
  my $descriptor = ref($specialized) && eval { $specialized->isa('GraphQL::Houtou::Runtime::NativeProgram') }
    ? GraphQL::Houtou::XS::VM::native_program_descriptor_xs($specialized)
    : $specialized;
  _specialize_runtime_directives_payloads($descriptor, $variables);
  return GraphQL::Houtou::XS::VM::load_native_program_xs($descriptor);
}

sub preferred_engine_for_program {
  my ($class, $program, %opts) = @_;
  return 'perl' if !$program;
  my $struct = _require_native_program($program);
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::program_native_eligible_xs(
    $struct,
    0,
  ) ? 'native' : 'perl';
}

sub compile_bundle {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program($program, %opts);
  return $self->_load_bundle_parts(_require_native_program($candidate));
}

sub compile_bundle_descriptor {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program($program, %opts);
  GraphQL::Houtou::_bootstrap_xs();
  return {
    runtime => $self->_native_runtime_compact_struct,
    program => GraphQL::Houtou::XS::VM::native_program_descriptor_xs($candidate),
  };
}

sub compile_program_descriptor {
  my ($self, $program, %opts) = @_;
  my $candidate = $self->specialize_program($program, %opts);
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::native_program_descriptor_xs($candidate);
}

sub compile_program_descriptor_for_document {
  my ($self, $document, %opts) = @_;
  my $program = $self->compile_program($document, %opts);
  return $self->compile_program_descriptor($program, %opts);
}

sub compile_bundle_descriptor_for_document {
  my ($self, $document, %opts) = @_;
  my $program = $self->compile_program($document, %opts);
  return $self->compile_bundle_descriptor($program, %opts);
}

sub _load_bundle_parts {
  my ($self, $program) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::load_native_bundle_from_handles_xs(
    $self->_native_runtime_handle,
    $program,
  );
}

sub _require_native_program {
  my ($program) = @_;
  return $program
    if ref($program) && eval { $program->isa('GraphQL::Houtou::Runtime::NativeProgram') };
  die "Active runtime paths expect a GraphQL::Houtou::Runtime::NativeProgram.\n";
}

sub load_bundle_descriptor {
  my ($self, $descriptor) = @_;
  GraphQL::Houtou::_bootstrap_xs();
  return GraphQL::Houtou::XS::VM::load_native_bundle_xs($descriptor);
}

sub inflate_bundle_descriptor {
  my ($self, $descriptor) = @_;
  return GraphQL::Houtou::Runtime::VMCompiler->inflate_native_bundle(
    $self->runtime_schema,
    $descriptor,
  );
}

sub dump_bundle_descriptor {
  my ($self, $program, $path, %opts) = @_;
  my $descriptor = $self->compile_bundle_descriptor($program, %opts);
  open my $fh, '>', $path or die "Cannot open $path for write: $!";
  print {$fh} encode_json($descriptor);
  close $fh;
  return $descriptor;
}

sub dump_bundle_descriptor_for_document {
  my ($self, $document, $path, %opts) = @_;
  my $descriptor = $self->compile_bundle_descriptor_for_document($document, %opts);
  open my $fh, '>', $path or die "Cannot open $path for write: $!";
  print {$fh} encode_json($descriptor);
  close $fh;
  return $descriptor;
}

sub load_bundle_descriptor_file {
  my ($self, $path) = @_;
  open my $fh, '<', $path or die "Cannot open $path for read: $!";
  local $/;
  my $json = <$fh>;
  close $fh;
  my $descriptor = decode_json($json);
  return $self->load_bundle_descriptor($descriptor);
}

sub execute_program {
  my ($self, $program, %opts) = @_;
  my $native_program = _require_native_program($program);
  my $runtime_handle = $self->_native_runtime_handle;
  my $on_stall = delete $opts{on_stall};
  my $has_root_value = exists $opts{root_value};
  my $has_context_value = exists $opts{context};
  my $has_variables = exists $opts{variables};
  my $root_value = $has_root_value ? $opts{root_value} : undef;
  my $context_value = $has_context_value ? $opts{context} : undef;
  my $variables = $has_variables ? $opts{variables} : undef;
  my $engine = exists $opts{engine} ? $opts{engine} : undef;

  die "promise_code is no longer supported; Promise::XS is detected automatically.\n"
    if exists $opts{promise_code};

  die "engine => 'perl' is no longer supported for sync runtime execution.\n"
    if defined $engine && $engine eq 'perl';

  if (!defined $engine && exists $opts{vm_engine}) {
    $engine = delete $opts{vm_engine};
  }
  if ($on_stall && !defined $engine) {
    require GraphQL::Houtou::Promise::PromiseXS;
    # Batching resolvers return promises, so the request must run on the
    # async-capable lane regardless of variables, and the returned promise
    # is driven to completion here: Promise::XS resolutions run their
    # callbacks synchronously, so each flush advances the XS scheduler
    # until the next stall.
    my $result = GraphQL::Houtou::XS::VM::execute_native_program_auto_xs(
      $runtime_handle,
      $native_program,
      $root_value,
      $context_value,
      $variables,
    );
    return _settle_result($result, $on_stall);
  }
  if ((defined $engine && $engine eq 'native') || (!defined $engine && $has_variables)) {
    # Promise-returning resolvers cannot run on the sync fast lane. Once a
    # program has revealed one (see the sentinel catch below) it starts on
    # the async lane up front, exactly like the no-variables path.
    if (!defined $engine
        && GraphQL::Houtou::XS::VM::native_program_prefers_async_lane_xs($native_program)) {
      require GraphQL::Houtou::Promise::PromiseXS;
      return GraphQL::Houtou::XS::VM::execute_native_program_auto_xs(
        $runtime_handle,
        $native_program,
        $root_value,
        $context_value,
        $variables,
      );
    }
    my $prepared_variables = GraphQL::Houtou::Runtime::InputCoercion::prepare_variables(
      $self->runtime_schema,
      $native_program,
      $variables || {},
    );
    # Programs without runtime directives or variable-dependent directive
    # guards are variable-invariant: the fast lanes evaluate dynamic
    # arguments against the prepared variables at request time, so no
    # per-request clone/specialize (or variables-keyed cache) is needed.
    my $effective_program = $native_program;
    if (GraphQL::Houtou::XS::VM::native_program_needs_variable_specialization_xs($native_program)) {
      $effective_program = $self->_cached_specialized_program(
        $native_program,
        $prepared_variables,
      );
    }
    my $result = eval {
      $self->execute_compact_program($effective_program, %opts, variables => $prepared_variables);
    };
    if (my $err = $@) {
      die $err if defined $engine
        || $err !~ /returned a Promise::XS promise in the synchronous fast lane/;
      return $self->_fast_lane_promise_fallback($native_program, sub {
        GraphQL::Houtou::XS::VM::execute_native_program_auto_xs(
          $runtime_handle,
          $native_program,
          $root_value,
          $context_value,
          $variables,
        );
      });
    }
    return $result;
  }
  if (!$has_root_value && !$has_context_value && !$has_variables) {
    return GraphQL::Houtou::XS::VM::execute_native_program_auto_simple_xs(
      $runtime_handle,
      $native_program,
    );
  }
  return GraphQL::Houtou::XS::VM::execute_native_program_auto_xs(
    $runtime_handle,
    $native_program,
    $root_value,
    $context_value,
    $variables,
  );
}

# A resolver returned a promise on the sync fast lane. Remember that on the
# program so subsequent requests start on the async lane, then re-execute
# there - but only for queries, which the GraphQL spec defines as free of
# side effects. A mutation may already have applied part of its effects, so
# re-running it is not safe; it fails once with a clear error and later
# requests for the same operation route to the async lane automatically.
sub _fast_lane_promise_fallback {
  my ($self, $native_program, $retry) = @_;
  GraphQL::Houtou::XS::VM::native_program_mark_prefers_async_lane_xs($native_program);
  require GraphQL::Houtou::Promise::PromiseXS;
  if (GraphQL::Houtou::XS::VM::native_program_operation_type_xs($native_program) != 1) {
    die "a mutation resolver returned a Promise::XS promise on the synchronous lane;"
      . " the mutation was not re-executed (its side effects may be partially applied)."
      . " Pass on_stall to start mutations on the async lane; subsequent requests for"
      . " this operation will route there automatically.\n";
  }
  return $retry->();
}

sub execute_compact_program {
  my ($self, $program, %opts) = @_;
  my $native_program = _require_native_program($program);
  return GraphQL::Houtou::XS::VM::execute_native_program_handle_xs(
    $self->_native_runtime_handle,
    $native_program,
    $opts{root_value},
    $opts{context},
    $opts{variables},
  );
}

# Drive a possibly-pending async result to completion using the caller's
# on_stall callback. This is the core batching contract: execution runs
# until every field either completed or is waiting on a promise ("stall"),
# then on_stall is invoked and must make progress (return a true dispatch
# count) by resolving promises - typically by flushing data loaders. Each
# resolution runs its continuations synchronously, advancing the scheduler
# to the next stall. No progress while promises remain pending is reported
# as a deadlock.
sub _settle_result {
  my ($result, $on_stall) = @_;
  return $result
    if !(blessed($result) && $result->isa('Promise::XS::Promise'));

  my ($settled, $value) = (0, undef);
  $result->then(
    sub { ($settled, $value) = (1, $_[0]) },
    sub { ($settled, $value) = (-1, $_[0]) },
  );
  while (!$settled) {
    my $progressed = $on_stall->();
    if (!$settled && !$progressed) {
      die "GraphQL execution stalled: promises are pending but on_stall made no progress"
        . " (a resolver returned a promise that no registered loader will resolve)\n";
    }
  }
  if ($settled < 0) {
    die $value if ref $value || ($value // '') ne '';
    die "GraphQL execution failed with an unknown async rejection\n";
  }
  return $value;
}

sub execute_bundle_descriptor {
  my ($self, $descriptor, %opts) = @_;
  my $bundle = $self->load_bundle_descriptor($descriptor);
  return $self->execute_bundle($bundle, %opts);
}

sub execute_document {
  my ($self, $document, %opts) = @_;
  my $max_depth = exists $opts{max_depth} ? delete $opts{max_depth} : $self->{_max_depth};

  if (defined $max_depth) {
    my $is_string = !ref($document);
    my $already_cached = $is_string
      && $self->{_program_cache_max}
      && $self->{_program_cache}{$document};
    if (!$already_cached) {
      my $ast = $is_string ? GraphQL::Houtou::parse($document) : $document;
      my @errors = GraphQL::Houtou::Validation::DepthLimit::check_query_depth(
        $ast, max_depth => $max_depth,
      );
      return { data => undef, errors => \@errors } if @errors;
    }
  }

  my $program = $self->compile_program($document, %opts);
  return $self->execute_program($program, %opts);
}

sub execute_bundle {
  my ($self, $bundle, %opts) = @_;
  return GraphQL::Houtou::XS::VM::execute_native_bundle_xs(
    $self->_native_runtime_handle,
    $bundle,
    $opts{root_value},
    $opts{context},
    $opts{variables},
  );
}

# Direct-JSON siblings of the sync native lane: the response is rendered as
# UTF-8 JSON bytes in XS without materializing the Perl envelope. Without
# on_stall the lane is sync-only and resolvers returning Promise::XS
# promises croak; with on_stall the request runs on the async lane and the
# response frame serializes its native value tree straight to JSON when it
# resolves (see execute_program_to_json).

sub execute_bundle_to_json {
  my ($self, $bundle, %opts) = @_;
  return GraphQL::Houtou::XS::VM::execute_native_bundle_to_json_xs(
    $self->_native_runtime_handle,
    $bundle,
    $opts{root_value},
    $opts{context},
    $opts{variables},
  );
}

sub execute_program_to_json {
  my ($self, $program, %opts) = @_;
  my $native_program = _require_native_program($program);
  my $on_stall = delete $opts{on_stall};
  if ($on_stall) {
    # Batching resolvers return promises, so run on the async lane; the
    # response frame renders JSON directly from its native value tree at
    # resolve time (query field order preserved). The auto lane prepares
    # program variables itself.
    require GraphQL::Houtou::Promise::PromiseXS;
    my $result = GraphQL::Houtou::XS::VM::execute_native_program_auto_to_json_xs(
      $self->_native_runtime_handle,
      $native_program,
      $opts{root_value},
      $opts{context},
      $opts{variables},
    );
    return _settle_result($result, $on_stall);
  }
  if (GraphQL::Houtou::XS::VM::native_program_prefers_async_lane_xs($native_program)) {
    return $self->_auto_json_or_die($native_program, %opts);
  }
  my $prepared_variables = GraphQL::Houtou::Runtime::InputCoercion::prepare_variables(
    $self->runtime_schema,
    $native_program,
    $opts{variables} || {},
  );
  my $effective_program = $native_program;
  if (GraphQL::Houtou::XS::VM::native_program_needs_variable_specialization_xs($native_program)) {
    $effective_program = $self->_cached_specialized_program(
      $native_program,
      $prepared_variables,
    );
  }
  my $json = eval {
    GraphQL::Houtou::XS::VM::execute_native_program_to_json_xs(
      $self->_native_runtime_handle,
      $effective_program,
      $opts{root_value},
      $opts{context},
      $prepared_variables,
    );
  };
  if (my $err = $@) {
    die $err if $err !~ /returned a Promise::XS promise in the synchronous fast lane/;
    return $self->_fast_lane_promise_fallback($native_program, sub {
      $self->_auto_json_or_die($native_program, %opts);
    });
  }
  return $json;
}

# Async JSON lane without an on_stall hook: promises that resolve during
# execution (pre-resolved chains) complete synchronously and yield JSON; a
# genuine stall has nothing to flush it, so fail with a pointer to on_stall
# rather than handing a promise to a caller that expected bytes.
sub _auto_json_or_die {
  my ($self, $native_program, %opts) = @_;
  require GraphQL::Houtou::Promise::PromiseXS;
  my $result = GraphQL::Houtou::XS::VM::execute_native_program_auto_to_json_xs(
    $self->_native_runtime_handle,
    $native_program,
    $opts{root_value},
    $opts{context},
    $opts{variables},
  );
  if (blessed($result) && $result->isa('Promise::XS::Promise')) {
    # Pre-resolved promise chains settle during execution, so the response
    # promise may already hold the JSON; only a genuine stall is an error.
    my $settled = eval {
      GraphQL::Houtou::Promise::PromiseXS::maybe_get_promise_xs($result);
    };
    if (my $err = $@) {
      # A rejected response promise carries a real request error; only the
      # still-pending case earns the on_stall hint.
      die $err if $err !~ /did not resolve synchronously/;
      die "resolvers returned pending promises; pass on_stall (see GraphQL::Houtou::DataLoader)"
        . " so execute_document_to_json can drive them to completion\n";
    }
    return $settled;
  }
  return $result;
}

sub execute_document_to_json {
  my ($self, $document, %opts) = @_;
  my $max_depth = exists $opts{max_depth} ? delete $opts{max_depth} : $self->{_max_depth};

  if (defined $max_depth) {
    my $is_string = !ref($document);
    my $already_cached = $is_string
      && $self->{_program_cache_max}
      && $self->{_program_cache}{$document};
    if (!$already_cached) {
      my $ast = $is_string ? GraphQL::Houtou::parse($document) : $document;
      my @errors = GraphQL::Houtou::Validation::DepthLimit::check_query_depth(
        $ast, max_depth => $max_depth,
      );
      if (@errors) {
        require JSON::MaybeXS;
        return JSON::MaybeXS->new->utf8->encode({ data => undef, errors => \@errors });
      }
    }
  }

  my $program = $self->compile_program($document, %opts);
  return $self->execute_program_to_json($program, %opts);
}

sub _cached_specialized_program {
  my ($self, $native_program, $variables) = @_;
  return $native_program if !$variables || !keys %$variables;

  my $variables_key = _specialized_variables_cache_key($variables);
  if (length($variables_key) > 2048) {
    # Unbounded variable payloads would otherwise become unbounded cache
    # keys; specialize without caching instead.
    return $self->_specialize_program_descriptor($native_program, $variables);
  }
  my $key = join q(|), refaddr($native_program), $variables_key;

  if (my $cached = $self->{_specialized_program_cache}{$key}) {
    return $cached;
  }

  my $specialized = $self->_specialize_program_descriptor($native_program, $variables);
  my $cache = $self->{_specialized_program_cache};
  my $order = $self->{_specialized_program_cache_order};
  if (scalar(@$order) >= $self->{_specialized_program_cache_max}) {
    my $evicted = shift @$order;
    delete $cache->{$evicted};
  }
  $cache->{$key} = $specialized;
  push @$order, $key;
  return $specialized;
}

sub _specialized_variables_cache_key {
  my ($value) = @_;
  my $ref = ref($value);
  return 'u' if !defined $value;
  return $value ? 'b1' : 'b0' if is_bool($value);
  return 's:' . $value if !$ref;
  if ($ref eq 'ARRAY') {
    return 'a:[' . join(',', map { _specialized_variables_cache_key($_) } @$value) . ']';
  }
  if ($ref eq 'HASH') {
    return 'h:{' . join(',', map {
      my $k = $_;
      $k . '=>' . _specialized_variables_cache_key($value->{$k})
    } sort keys %$value) . '}';
  }
  return $ref . ':' . "$value";
}

sub _specialize_runtime_directives_payloads {
  my ($descriptor, $variables) = @_;
  return $descriptor if !$descriptor;

  if (ref($descriptor) eq 'HASH') {
    my $blocks = $descriptor->{blocks_compact} || $descriptor->{blocks} || [];
    for my $block (@$blocks) {
      my $ops = ref($block) eq 'ARRAY' ? ($block->[4] || []) : ($block->{ops} || []);
      for my $op (@$ops) {
        _specialize_runtime_directives_op($op, $variables);
      }
    }
  }

  return $descriptor;
}

sub _specialize_runtime_directives_op {
  my ($op, $variables) = @_;
  return if !$op;

  if (ref($op) eq 'ARRAY') {
    my $mode_code = $op->[18] || 0;
    return if !$mode_code || !$op->[20];
    my $payload = GraphQL::Houtou::Runtime::DirectiveRuntime::materialize_runtime_directives(
      $op->[19],
      $variables,
    );
    $op->[18] = 1;
    $op->[19] = $payload;
    $op->[20] = @$payload ? 1 : 0;
    return;
  }

  return if ref($op) ne 'HASH';
  my $mode_code = $op->{runtime_directives_mode_code} || 0;
  return if !$mode_code || !$op->{has_runtime_directives};

  my $payload = GraphQL::Houtou::Runtime::DirectiveRuntime::materialize_runtime_directives(
    $op->{runtime_directives_payload},
    $variables,
  );
  $op->{runtime_directives_mode_code} = 1;
  $op->{runtime_directives_payload} = $payload;
  $op->{has_runtime_directives} = @$payload ? 1 : 0;
}

1;
