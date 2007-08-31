package SVN::TracWiki;

use warnings;
use strict;
use Carp;
use Module::Pluggable require => 1;
use SVN::TracWiki::ConfigLoader;
use Path::Class;
use RPC::XML;
use RPC::XML::Client;
use File::Extract;
use UNIVERSAL::can;
use File::MMagic;

$RPC::XML::ENCODING = 'UTF-8';

use version;our $VERSION = qv('0.0.1');

my $context;
sub context { $context }
sub set_context {
    my ($class, $c) = @_;
    $context = $c;
}

sub bootstrap {
    my ( $class, $opts ) = @_;
    my $self = $class->new($opts);
    $self->run;
}

sub new {
    my ( $class, $opts ) = @_;

    my $self = bless $opts, $class;
    $self->{mime_types} = [];

    my $config_loader = SVN::TracWiki::ConfigLoader->new;
    $self->{config} = $config_loader->load($opts->{config}, $self);
    __PACKAGE__->set_context($self);
}

sub run {
    my $self = shift;


    my $e = File::Extract->new;
    $self->{extractor} = $e;
    $e->magic->addFileExts('xls', 'application/excel');

    $self->load_plugins;

    my @files = $self->get_files;

    my $temp_dir = $self->{config}->{svn}->{temp_dir};
    for my $file ( @files ) {
        my $path = File::Spec->catfile( $temp_dir, $file );
        my $r = $self->{extractor}->extract($path);
        next unless $r;

        my $text = $r->text;
        next unless $text;

        Encode::_utf8_off($text) if Encode::is_utf8($text);
        next if $r->mime_type eq 'text/plain' or $r->mime_type eq 'text/html';

        $text = "{{{\n$text\n}}}" if $self->{format_of}->{$r->mime_type} eq 'text';
        $text = "source:$file\n\n$text";
        $self->publish_to_wiki($file, $text);
    }

    $self->clean_files;
}

sub load_plugins {
    my $self = shift;

    my $e = $self->{extractor};

    my @plugins;
    for my $class ( $self->plugins ) {
        my ( $name ) = ( $class =~ /SVN::TracWiki::Plugin::Extract::(.+)/ );
        next unless $name;

        my $ext_ref   = $class->ext;
        my $mime_type = $class->mime_type;

        $ext_ref = [ $ext_ref ] if ref $ext_ref ne 'ARRAY';
        map { $e->magic->addFileExts( $_, $mime_type ) } @$ext_ref;

        $self->{format_of}->{$mime_type} = $class->can('format');

        $e->register_processor($class);

        $class->mk_classdata('conf');
        $class->conf( $self->{config}->{plugins}->{$name} );
    }
}

sub get_files {
    my $self = shift;

    my $svnlook  = $self->{config}->{svn}->{svnlook} || '/usr/bin/svnlook';
    my $repos    = $self->{repos};
    my $rev      = $self->{rev};
    my $temp_dir = $self->{config}->{svn}->{temp_dir} || '/var/tmp/svn';

    my $files = `$svnlook changed $repos`;

    my @files;
    for ( split "\n", $files ) {
        next unless $_ =~ /^(:?U|A)/;
        next if $_ =~ m!/$!;
        my ( $file ) = ( $_ =~ /\s([^\s]+)$/ );
        my $output_path = file( File::Spec->catfile( $temp_dir, $file ) );
        $output_path->parent->mkpath;
        $output_path->cleanup;
        system "$svnlook cat $repos $file > $output_path";
        push @files, $file;
    }

    return @files;
}

sub clean_files {
    my $self = shift;
    my $dir = dir( $self->{config}->{svn}->{temp_dir} );
    $dir->recurse(
        callback => sub {
            my $file = shift;
            return unless -f $file;
            $file->remove;
        },
    );
}

sub publish_to_wiki {
    my ( $self, $page, $text ) = @_;

    if ( $self->{config}->{trac}->{xmlrpc_endpoint} ) {
        $self->send_via_xmlrpc($page, $text);
    }else{
        $self->send_via_basic_auth($page, $text);
    }
}

sub send_via_xmlrpc {
    my ($self, $page, $text) = @_;

    my $conf = $self->{config}->{trac};
    my $ua = RPC::XML::Client->new($conf->{xmlrpc_endpoint});
    $ua->credentials($conf->{realm}, $conf->{username}, $conf->{password});

     my $res = $ua->send_request(
         'wiki.putPage',
         RPC::XML::string->new($page),
         RPC::XML::string->new($text),
         RPC::XML::struct->new,
     );

     if ( ref $res eq 'RPC::XML::fault' ) {
         warn $res->string;
     }
    elsif ( !ref $res ) {
        warn $res;
    }
}

sub send_via_basic_auth {
    my ($self, $page, $text) = @_;

    my $conf = $self->{config}->{trac};

    my $ua = LWP::UserAgent->new;
    $ua->cookie_jar( {} );

    my $req = HTTP::Request->new( GET => $conf->{trac_url} . "/login/" );
    $req->authorization_basic( $conf->{username}, $conf->{password} );

    my $res = $ua->request( $req );

    # are we logged in ?
    if ( !$res->is_success ) {
        die ( "Can't login on this trac, check your login" );
    }
    my $cookie = $res->request->headers->{ cookie };
    $cookie =~ /trac_form_token=(.*);/;
    my $form_token = $1;

    my $page_rev = 0;
    my $page_url = $conf->{trac_url} . "/wiki/" . $page;

    $req = HTTP::Request->new( GET => $page_url );
    $res = $ua->request( $req );

    if ( $res->is_success ) {
        if ( $res->content
             =~ /<input type="hidden" name="version" value="(\d+?)" \/>/ )
        {
            $page_rev = $1;
        }
    }

    $req = HTTP::Request->new( POST => $page_url );
    $req->content_type( 'application/x-www-form-urlencoded' );
    $req->content(   "__FORM_TOKEN="
                   . $form_token
                   . "&action=edit&version="
                   . $page_rev
                   . "&text="
                   . $text
                   . "&save=Submit+changes" );
    $res = $ua->request( $req );
}

BEGIN {
    no warnings 'redefine';

    *File::Extract::new = sub {
        my $class = shift;
        my %args  = @_;

        my $encoding  = $args{output_encoding} || 'utf8';
        my @encodings = $args{encodings} ?
            (ref($args{encodings}) eq 'ARRAY' ? @{$args{encodings}} : $args{encodings}) : ();
        my $self  = bless {
            filters         => $args{filters},
            processors      => $args{processors},
            magic           => File::MMagic->new,
            encodings       => \@encodings,
            output_encoding => $encoding
        }, $class;
        return $self;
    };

    *File::MMagic::checktype_filename = *File::MMagic::checktype_byfilename;
}

1; # Magic true value required at end of module
__END__

=head1 NAME

SVN::TracWiki - [One line description of module's purpose here]


=head1 VERSION

This document describes SVN::TracWiki version 0.0.1


=head1 SYNOPSIS

    use SVN::TracWiki;

=for author to fill in:
    Brief code example(s) here showing commonest usage(s).
    This section will be as far as many users bother reading
    so make it as educational and exeplary as possible.
  
  
=head1 DESCRIPTION

=for author to fill in:
    Write a full description of the module and its features here.
    Use subsections (=head2, =head3) as appropriate.


=head1 INTERFACE 

=for author to fill in:
    Write a separate section listing the public components of the modules
    interface. These normally consist of either subroutines that may be
    exported, or methods that may be called on objects belonging to the
    classes provided by the module.


=head1 DIAGNOSTICS

=for author to fill in:
    List every single error and warning message that the module can
    generate (even the ones that will "never happen"), with a full
    explanation of each problem, one or more likely causes, and any
    suggested remedies.

=over

=item C<< Error message here, perhaps with %s placeholders >>

[Description of error here]

=item C<< Another error message here >>

[Description of error here]

[Et cetera, et cetera]

=back


=head1 CONFIGURATION AND ENVIRONMENT

=for author to fill in:
    A full explanation of any configuration system(s) used by the
    module, including the names and locations of any configuration
    files, and the meaning of any environment variables or properties
    that can be set. These descriptions must also include details of any
    configuration language used.
  
SVN::TracWiki requires no configuration files or environment variables.


=head1 DEPENDENCIES

=for author to fill in:
    A list of all the other modules that this module relies upon,
    including any restrictions on versions, and an indication whether
    the module is part of the standard Perl distribution, part of the
    module's distribution, or must be installed separately. ]

None.


=head1 INCOMPATIBILITIES

=for author to fill in:
    A list of any modules that this module cannot be used in conjunction
    with. This may be due to name conflicts in the interface, or
    competition for system or program resources, or due to internal
    limitations of Perl (for example, many modules that use source code
    filters are mutually incompatible).

None reported.


=head1 BUGS AND LIMITATIONS

=for author to fill in:
    A list of known problems with the module, together with some
    indication Whether they are likely to be fixed in an upcoming
    release. Also a list of restrictions on the features the module
    does provide: data types that cannot be handled, performance issues
    and the circumstances in which they may arise, practical
    limitations on the size of data sets, special cases that are not
    (yet) handled, etc.

No bugs have been reported.

Please report any bugs or feature requests to
C<bug-svn-tracwiki@rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org>.


=head1 AUTHOR

Gosuke Miyashita  C<< <gosukenator@gmail.com> >>


=head1 LICENCE AND COPYRIGHT

Copyright (c) 2007, Gosuke Miyashita C<< <gosukenator@gmail.com> >>. All rights reserved.

This module is free software; you can redistribute it and/or
modify it under the same terms as Perl itself. See L<perlartistic>.


=head1 DISCLAIMER OF WARRANTY

BECAUSE THIS SOFTWARE IS LICENSED FREE OF CHARGE, THERE IS NO WARRANTY
FOR THE SOFTWARE, TO THE EXTENT PERMITTED BY APPLICABLE LAW. EXCEPT WHEN
OTHERWISE STATED IN WRITING THE COPYRIGHT HOLDERS AND/OR OTHER PARTIES
PROVIDE THE SOFTWARE "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER
EXPRESSED OR IMPLIED, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE. THE
ENTIRE RISK AS TO THE QUALITY AND PERFORMANCE OF THE SOFTWARE IS WITH
YOU. SHOULD THE SOFTWARE PROVE DEFECTIVE, YOU ASSUME THE COST OF ALL
NECESSARY SERVICING, REPAIR, OR CORRECTION.

IN NO EVENT UNLESS REQUIRED BY APPLICABLE LAW OR AGREED TO IN WRITING
WILL ANY COPYRIGHT HOLDER, OR ANY OTHER PARTY WHO MAY MODIFY AND/OR
REDISTRIBUTE THE SOFTWARE AS PERMITTED BY THE ABOVE LICENCE, BE
LIABLE TO YOU FOR DAMAGES, INCLUDING ANY GENERAL, SPECIAL, INCIDENTAL,
OR CONSEQUENTIAL DAMAGES ARISING OUT OF THE USE OR INABILITY TO USE
THE SOFTWARE (INCLUDING BUT NOT LIMITED TO LOSS OF DATA OR DATA BEING
RENDERED INACCURATE OR LOSSES SUSTAINED BY YOU OR THIRD PARTIES OR A
FAILURE OF THE SOFTWARE TO OPERATE WITH ANY OTHER SOFTWARE), EVEN IF
SUCH HOLDER OR OTHER PARTY HAS BEEN ADVISED OF THE POSSIBILITY OF
SUCH DAMAGES.
