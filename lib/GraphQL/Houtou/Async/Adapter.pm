package GraphQL::Houtou::Async::Adapter;

use 5.024;
use strict;
use warnings;

sub register {
  my ($class, %spec) = @_;
  require GraphQL::Houtou;
  GraphQL::Houtou::_bootstrap_xs();
  my $code = GraphQL::Houtou::XS::VM::register_async_adapter_xs(\%spec);
  return bless \$code, $class;
}

sub builtin { bless \(my $code = $_[1]), $_[0] }
sub backend_code { ${ $_[0] } }

1;

__END__

=head1 NAME

GraphQL::Houtou::Async::Adapter - register an async backend with Houtou's XS VM

=head1 SYNOPSIS

  my $adapter = GraphQL::Houtou::Async::Adapter->register(
    name        => 'my_future',
    class       => 'My::Future',
    new_pending => \&new_pending,
    all         => \&all,
    then        => \&then, # optional; otherwise Class->then is cached
  );

  my $runtime = $schema->build_native_runtime(async_adapter => $adapter);

=head1 DESCRIPTION

C<new_pending> returns C<[ $promise, $resolve, $reject ]>. C<all> accepts an
array reference and returns a promise resolving to an array reference. C<then>
has the signature C<($promise, $on_done, $on_fail)> and must normalize callback
return values according to the backend's chaining rules.

Registration and dispatch live in XS. The callbacks may themselves be XSUBs,
so an XS-backed implementation can register XSUB coderefs at module load time
without adding a Perl call to Houtou's execution hot path.

=cut
