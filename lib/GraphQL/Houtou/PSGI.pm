package GraphQL::Houtou::PSGI;

use 5.014;
use strict;
use warnings;

use JSON::MaybeXS ();
use Scalar::Util qw(blessed);

use GraphQL::Houtou ();

our $VERSION = $GraphQL::Houtou::VERSION;

my $JSON = JSON::MaybeXS->new->utf8;

sub new {
  my ($class, %args) = @_;

  my $runtime = delete $args{runtime};
  if (!$runtime) {
    my $schema = delete $args{schema}
      or die "GraphQL::Houtou::PSGI->new requires a schema or a runtime\n";
    my %runtime_opts;
    $runtime_opts{program_cache_max} = delete $args{program_cache_max}
      if exists $args{program_cache_max};
    $runtime = $schema->build_native_runtime(%runtime_opts);
  }

  my $self = bless {
    runtime => $runtime,
    graphiql => delete $args{graphiql},
    graphiql_path => delete $args{graphiql_path},
    context => delete $args{context},
    root_value => delete $args{root_value},
    on_stall => delete $args{on_stall},
    max_depth => delete $args{max_depth},
  }, $class;

  if (my @unknown = sort keys %args) {
    die "Unknown GraphQL::Houtou::PSGI options: @unknown\n";
  }
  return $self;
}

sub to_app {
  my ($self) = @_;
  return sub { $self->call($_[0]) };
}

sub call {
  my ($self, $env) = @_;
  my $method = $env->{REQUEST_METHOD} || '';

  if ($method eq 'POST') {
    return $self->_handle_post($env);
  }
  if ($method eq 'GET' && $self->{graphiql} && _accepts_html($env)) {
    return _graphiql_response($self);
  }
  return _error_response($env, 405, 'GraphQL over HTTP requests must use POST',
    [ Allow => $self->{graphiql} ? 'GET, POST' : 'POST' ]);
}

sub _handle_post {
  my ($self, $env) = @_;

  my $content_type = lc($env->{CONTENT_TYPE} || '');
  $content_type =~ s/\s*;.*//s;
  if ($content_type ne 'application/json') {
    return _error_response($env, 415, 'Content-Type must be application/json');
  }

  my $body = _read_body($env);
  my $payload = do {
    local $@;
    my $decoded = eval { $JSON->decode($body) };
    $@ ? undef : $decoded;
  };
  if (ref $payload ne 'HASH') {
    return _error_response($env, 400, 'Request body must be a JSON object');
  }

  my $query = $payload->{query};
  if (!defined $query || ref $query || $query !~ /\S/) {
    return _error_response($env, 400, 'The "query" field is required');
  }
  my $variables = $payload->{variables};
  if (defined $variables && ref $variables ne 'HASH') {
    return _error_response($env, 400, 'The "variables" field must be a JSON object');
  }
  my $operation_name = $payload->{operationName};
  if (defined $operation_name && (ref $operation_name || $operation_name !~ /\S/)) {
    return _error_response($env, 400, 'The "operationName" field must be a non-empty string');
  }

  my $document = $query;
  if (defined $operation_name) {
    my ($selected, $error) = _select_operation($query, $operation_name);
    return _error_response($env, 400, $error) if $error;
    $document = $selected;
  }

  my ($context, $on_stall) = $self->_request_context($env);

  my %exec_opts;
  $exec_opts{variables} = $variables if defined $variables;
  $exec_opts{context} = $context if defined $context;
  $exec_opts{root_value} = $self->{root_value} if defined $self->{root_value};
  $exec_opts{on_stall} = $on_stall if defined $on_stall;
  $exec_opts{max_depth} = $self->{max_depth} if defined $self->{max_depth};

  my ($json, $error) = do {
    local $@;
    my $out = eval { $self->{runtime}->execute_document_to_json($document, %exec_opts) };
    $@ ? (undef, $@) : ($out, undef);
  };
  if (defined $error) {
    # Parse and validation failures surface as exceptions before any field
    # executes; GraphQL over HTTP maps those to a 400 with an errors-only
    # envelope. (Field-level failures never die - they land in "errors"
    # inside the 200 response.)
    my $message = blessed($error) || ref($error) eq 'HASH'
      ? (eval { $error->{message} } || "$error")
      : "$error";
    $message =~ s/\s+\z//;
    return _error_response($env, 400, $message);
  }

  return [
    200,
    [ 'Content-Type' => _response_content_type($env), 'Content-Length' => length $json ],
    [ $json ],
  ];
}

sub _request_context {
  my ($self, $env) = @_;
  my $context = $self->{context};
  if (ref $context eq 'CODE') {
    # The builder runs once per request and may return the context alone or
    # a (context, on_stall) pair - the natural shape when per-request
    # DataLoaders live inside the context.
    my ($built, $on_stall) = $context->($env);
    return ($built, $on_stall // $self->{on_stall});
  }
  return ($context, $self->{on_stall});
}

# The runtime compiler executes the first operation in the document, so
# operationName selection happens here: keep the fragments and the named
# operation only, and hand the filtered AST to the runtime.
sub _select_operation {
  my ($query, $operation_name) = @_;
  my $ast = do {
    local $@;
    my $parsed = eval { GraphQL::Houtou::parse($query) };
    $@ ? undef : $parsed;
  };
  return (undef, 'GraphQL document failed to parse') if ref $ast ne 'ARRAY';

  my @operations = grep { ($_->{kind} || '') eq 'operation' } @$ast;
  my ($selected) = grep { ($_->{name} || '') eq $operation_name } @operations;
  return (undef, qq{Operation "$operation_name" was not found in the document})
    if !$selected;

  my @fragments = grep { ($_->{kind} || '') eq 'fragment' } @$ast;
  return ([ $selected, @fragments ], undef);
}

sub _read_body {
  my ($env) = @_;
  my $input = $env->{'psgi.input'} or return '';
  my $length = $env->{CONTENT_LENGTH} || 0;
  my $body = '';
  while ($length > 0) {
    my $read = $input->read($body, $length, length $body);
    last if !$read;
    $length -= $read;
  }
  return $body;
}

sub _accepts_html {
  my ($env) = @_;
  return (($env->{HTTP_ACCEPT} || '') =~ m{text/html}) ? 1 : 0;
}

sub _response_content_type {
  my ($env) = @_;
  my $accept = $env->{HTTP_ACCEPT} || '';
  return $accept =~ m{application/graphql-response\+json}
    ? 'application/graphql-response+json; charset=utf-8'
    : 'application/json; charset=utf-8';
}

sub _error_response {
  my ($env, $status, $message, $extra_headers) = @_;
  my $json = $JSON->encode({ errors => [ { message => $message } ] });
  return [
    $status,
    [
      'Content-Type' => _response_content_type($env),
      'Content-Length' => length $json,
      @{ $extra_headers || [] },
    ],
    [ $json ],
  ];
}

sub _graphiql_response {
  my ($self) = @_;
  my $endpoint = $self->{graphiql_path} // '';
  my $html = <<"HTML";
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <title>GraphiQL - GraphQL::Houtou</title>
  <style>html, body, #graphiql { height: 100%; margin: 0; }</style>
  <link rel="stylesheet" href="https://esm.sh/graphiql\@4/dist/style.css" />
</head>
<body>
  <div id="graphiql">Loading GraphiQL...</div>
  <script type="importmap">
  {
    "imports": {
      "react": "https://esm.sh/react\@19",
      "react/jsx-runtime": "https://esm.sh/react\@19/jsx-runtime",
      "react-dom": "https://esm.sh/react-dom\@19",
      "react-dom/client": "https://esm.sh/react-dom\@19/client",
      "graphiql": "https://esm.sh/graphiql\@4?standalone&external=react,react/jsx-runtime,react-dom,\@graphiql/react",
      "\@graphiql/react": "https://esm.sh/\@graphiql/react\@1?standalone&external=react,react/jsx-runtime,react-dom,graphql",
      "\@graphiql/toolkit": "https://esm.sh/\@graphiql/toolkit\@0.11?standalone&external=graphql",
      "graphql": "https://esm.sh/graphql\@16"
    }
  }
  </script>
  <script type="module">
    import React from 'react';
    import ReactDOM from 'react-dom/client';
    import { GraphiQL } from 'graphiql';
    import { createGraphiQLFetcher } from '\@graphiql/toolkit';
    const fetcher = createGraphiQLFetcher({ url: '$endpoint' || window.location.pathname });
    ReactDOM.createRoot(document.getElementById('graphiql')).render(
      React.createElement(GraphiQL, { fetcher })
    );
  </script>
</body>
</html>
HTML
  return [
    200,
    [ 'Content-Type' => 'text/html; charset=utf-8', 'Content-Length' => length $html ],
    [ $html ],
  ];
}

1;
__END__

=encoding utf-8

=head1 NAME

GraphQL::Houtou::PSGI - GraphQL over HTTP endpoint as a plain PSGI app

=head1 SYNOPSIS

  # app.psgi
  use GraphQL::Houtou::PSGI;
  use GraphQL::Houtou::DataLoader;

  GraphQL::Houtou::PSGI->new(
    schema => $schema,
    graphiql => 1,
    context => sub {
      my ($env) = @_;
      my $users = GraphQL::Houtou::DataLoader->new(batch => \&batch_users);
      my $context = { users => $users, env => $env };
      return ($context, GraphQL::Houtou::DataLoader->on_stall_for($users));
    },
  )->to_app;

=head1 DESCRIPTION

A GraphQL over HTTP endpoint built directly on the PSGI interface - no
Plack modules are required at runtime. Responses are rendered by the
direct-JSON execution lane (C<execute_document_to_json>), so the Perl
response envelope is never materialized: sync schemas take the streaming
fast lane and batching (DataLoader) schemas take the async lane with the
JSON tail.

=head1 OPTIONS

=over 4

=item schema / runtime

Either a L<GraphQL::Houtou::Schema> (a native runtime is built once at
construction) or a prebuilt L<GraphQL::Houtou::Runtime::NativeRuntime>.

=item context

A hashref passed to resolvers as-is, or a coderef called once per request
with the PSGI C<$env>. The coderef may return the context alone or a
C<($context, $on_stall)> pair - the natural shape when per-request
DataLoaders live inside the context (see SYNOPSIS).

=item on_stall

A static stall-flush hook (see L<GraphQL::Houtou/Batching resolvers>).
A per-request hook returned by the C<context> builder takes precedence.

=item graphiql

Serve the GraphiQL IDE (loaded from the esm.sh CDN) on C<GET> requests
whose C<Accept> includes C<text/html>. C<graphiql_path> overrides the
endpoint URL the IDE posts to (defaults to the page's own path).

=item root_value, max_depth, program_cache_max

Passed through to the runtime.

=back

=head1 PROTOCOL

POST with C<Content-Type: application/json> and a
C<{"query": ..., "variables": ..., "operationName": ...}> body. The
response is C<application/graphql-response+json> when the client accepts
it, C<application/json> otherwise. Requests that fail before execution
(malformed body, parse or validation errors, unknown operationName)
return 400 with an errors-only envelope; field-level errors execute to a
200 response with the C<errors> array populated, as GraphQL over HTTP
specifies. GET execution is not implemented; GET serves GraphiQL when
enabled and 405 otherwise.

Note: documents that name an C<operationName> are compiled from their
parsed AST and bypass the string-keyed program cache; single-operation
requests without C<operationName> hit the cache as usual.

=cut
