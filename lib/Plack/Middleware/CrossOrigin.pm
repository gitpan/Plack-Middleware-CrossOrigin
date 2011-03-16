use strict;
use warnings;
package Plack::Middleware::CrossOrigin;
BEGIN {
  $Plack::Middleware::CrossOrigin::VERSION = '0.005';
}
# ABSTRACT: Adds headers to allow Cross-Origin Resource Sharing
use parent qw(Plack::Middleware);

use Plack::Util;
use Plack::Util::Accessor qw(
    origins
    headers
    methods
    max_age
    expose_headers
    credentials
);

my @simple_headers = qw(
    Accept
    Accept-Language
    Content-Language
    Last-Event-ID
);
my @simple_response_headers = (@simple_headers, qw(
    Cache-Control
    Content-Language
    Content-Type
    Expires
    Last-Modified
    Pragma
));

sub prepare_app {
    my ($self) = @_;

    $self->methods( [qw(
        CANCELUPLOAD
        CHECKIN
        CHECKOUT
        COPY
        DELETE
        GET
        GETLIB
        HEAD
        LOCK
        MKCOL
        MOVE
        OPTIONS
        POST
        PROPFIND
        PROPPATCH
        PUT
        REPORT
        UNCHECKOUT
        UNLOCK
        UPDATE
        VERSION-CONTROL
    )] )
        unless defined $self->methods;

    $self->headers( [qw(
        Cache-Control
        Depth
        If-Modified-Since
        User-Agent
        X-File-Name
        X-File-Size
        X-Requested-With
        X-Prototype-Version
    )])
        unless defined $self->headers;
}

sub _origins {
    my $self = shift;
    return ref $self->origins ? @{ $self->origins } : $self->origins || ();
}

sub _methods {
    my $self = shift;
    return ref $self->methods ? @{ $self->methods } : $self->methods || ();
}

sub _headers {
    my $self = shift;
    return ref $self->headers ? @{ $self->headers } : $self->headers || ();
}

sub _expose_headers {
    my $self = shift;
    return ref $self->expose_headers ? @{ $self->expose_headers } : $self->expose_headers || ();
}

sub call {
    my ($self, $env) = @_;
    if ($env->{HTTP_ORIGIN}) {
        my @origins = split / /, $env->{HTTP_ORIGIN};
        my $request_method = $env->{HTTP_ACCESS_CONTROL_REQUEST_METHOD};
        my $request_headers = $env->{HTTP_ACCESS_CONTROL_REQUEST_HEADERS};
        my @request_headers = $request_headers ? (split /,\s*/, $request_headers) : ();

        my $preflight = $env->{REQUEST_METHOD} eq 'OPTIONS' && $request_method;

        my %allowed_origins = map { $_ => 1 } $self->_origins;
        my @allowed_methods = $self->_methods;
        my %allowed_methods = map { $_ => 1 } @allowed_methods;
        my @allowed_headers = $self->_headers;
        my %allowed_headers = map { lc $_ => 1 } @allowed_headers;
        my @expose_headers = $self->_expose_headers;
        my %expose_headers = map { $_ => 1 } @expose_headers;

        my @headers;

        if (! $allowed_origins{'*'} ) {
            for my $origin (@origins) {
                return _return_403()
                    unless $allowed_origins{$origin};
            }
        }

        if ($preflight) {
            unless ( $allowed_methods{'*'} || $allowed_methods{$request_method} ) {
                return _return_403();
            }
            if (! $allowed_headers{'*'} ) {
                for my $header (@request_headers) {
                    return _return_403()
                        unless $allowed_headers{lc $header};
                }
            }
        }
        if ($self->credentials) {
            push @headers, 'Access-Control-Allow-Origin' => $env->{HTTP_ORIGIN};
            push @headers, 'Access-Control-Allow-Credentials' => 'true';
        }
        else {
            if ($allowed_origins{'*'}) {
                push @headers, 'Access-Control-Allow-Origin' => '*';
            }
            else {
                push @headers, 'Access-Control-Allow-Origin' => $env->{HTTP_ORIGIN};
            }
        }
        my $res;
        if ($preflight) {
            if (defined $self->max_age) {
                push @headers, 'Access-Control-Max-Age' => $self->max_age;
            }

            if ($allowed_methods{'*'}) {
                push @headers, 'Access-Control-Allow-Methods' => $request_method;
            }
            else {
                push @headers, 'Access-Control-Allow-Methods' => $_
                    for @allowed_methods;
            }

            if ( $allowed_headers{'*'} ) {
                push @headers, 'Access-Control-Allow-Headers' => $_
                    for @request_headers;
            }
            else {
                push @headers, 'Access-Control-Allow-Headers' => $_
                    for @allowed_headers;
            }
            $res = [200, [ 'Content-Type' => 'text/plain' ], [] ];
        }
        else {
            $res = $self->app->($env);
        }

        return $self->response_cb($res, sub {
            my $res = shift;

            if ($expose_headers{'*'}) {
                my %headers = @{ $res->[1] };
                delete $headers{$_}
                    for @simple_response_headers;
                push @headers, 'Access-Control-Expose-Headers' => $_
                    for keys %headers;
            }
            else {
                push @headers, 'Access-Control-Expose-Headers' => $_
                    for @expose_headers;
            }

            push @{$res->[1]}, @headers;
        });
    }
    # for preflighted GET requests, WebKit doesn't include Origin
    # with the actual request.  Has been fixed in trunk, but released
    # versions of Safari and Chrome still have the issue.
    elsif ($env->{REQUEST_METHOD} eq 'GET' && $env->{HTTP_USER_AGENT} && $env->{HTTP_USER_AGENT} =~ /AppleWebKit/) {
        my $origin_header;
        # transforming the referrer into the origin is the best we can do
        my ( $origin ) = ( $env->{HTTP_REFERER} =~ m{\A ( \w+://[^/]+ )}msx );
        my %allowed_origins = map { $_ => 1 } $self->_origins;
        if ( $allowed_origins{'*'} ) {
            $origin_header = '*';
        }
        elsif ($origin && $allowed_origins{$origin} ) {
            $origin_header = $origin;
        }
        if ($origin_header) {
            return $self->response_cb($self->app->($env), sub {
                my $res = shift;
                push @{$res->[1]}, 'Access-Control-Allow-Origin' => $origin_header;
            });
        }
    }
    return $self->app->($env);
}

sub _return_403 {
    my $self = shift;
    return [403, ['Content-Type' => 'text/plain', 'Content-Length' => 9], ['forbidden']];
}

1;



__END__
=pod

=head1 NAME

Plack::Middleware::CrossOrigin - Adds headers to allow Cross-Origin Resource Sharing

=head1 VERSION

version 0.005

=head1 SYNOPSIS

    # Allow any WebDAV or standard HTTP request from any location.
    builder {
        enable 'CrossOrigin', origins => '*';
        $app;
    };
    
    # Allow GET and POST requests from any location, cache results for 30 days.
    builder {
        enable 'CrossOrigin',
            origins => '*', methods => ['GET', 'POST'], max_age => 60*60*24*30;
        $app;
    };

=head1 DESCRIPTION

Adds Cross Origin Request Sharing headers used by modern browsers
to allow XMLHttpRequests across domains.

=head1 CONFIGURATION

=over 8

=item origins

A list of allowed origins.  Origins should be formatted as a URL scheme and
host. (C<http://www.example.com>)  '*' can be specified to allow
access from any location.  Must be specified for this middleware to have any effect.

=item headers

A list of allowed headers.  '*' can be specified to allow any
headers.  Includes a set of headers by default to simplify working with WebDAV and AJAX frameworks:

=over 4

=item *

C<Cache-Control>

=item *

C<Depth>

=item *

C<If-Modified-Since>

=item *

C<User-Agent>

=item *

C<X-File-Name>

=item *

C<X-File-Size>

=item *

C<X-Prototype-Version>

=item *

C<X-Requested-With>

=back

=item methods

A list of allowed methods.  '*' can be specified to allow any methods.
Defaults to all of the standard HTTP and WebDAV methods.

=item max_age

The max length in seconds to cache the response data for.  If not
specified, the web browser will decide how long to use.

=item expose_headers

A list of allowed headers to expose to the client. '*' can be
specified to allow the browser to see all of the response headers.

=item credentials

Whether the resource will be allowed with user credentials supplied.

=back

=head1 SEE ALSO

=over 4

=item *

L<W3C Spec for Cross-Origin Resource Sharing|http://www.w3.org/TR/cors/>

=item *

L<Mozilla Developer Center - HTTP Access Control|https://developer.mozilla.org/En/HTTP_access_control>

=item *

L<Mozilla Developer Center - Server-Side Access Control|https://developer.mozilla.org/En/Server-Side_Access_Control>

=item *

L<Cross browser examples of using CORS requests|http://www.nczonline.net/blog/2010/05/25/cross-domain-ajax-with-cross-origin-resource-sharing/>

=back

=head1 AUTHOR

Graham Knop <haarg@haarg.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2010 by Graham Knop.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
