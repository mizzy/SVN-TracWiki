package SVN::TracWiki::Plugin::Extract::Pod;

use strict;
use warnings;
use base qw( SVN::TracWiki::Plugin::Extract );
use Encode;
use Carp;
use Pod::Simple::Wiki;

sub ext { [ 'pl', 'pm' ] }
sub mime_type { 'application/x-perl' }

sub extract {
    my ( $self, $file ) = @_;

    my $parser = Pod::Simple::Wiki->new( 'moinmoin' );
    $parser->output_string( \my $text );
    $parser->parse_file( $file );

    my $r = File::Extract::Result->new(
        text      => $text,
        filename  => $file,
        mime_type => $self->mime_type,
    );

    return $r;
}

1;

