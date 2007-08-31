package SVN::TracWiki::Plugin::Extract::PowerPoint;

use strict;
use warnings;
use base qw( SVN::TracWiki::Plugin::Extract );
use Encode;
use Carp;

sub ext { 'ppt' }
sub mime_type { 'application/powerpoint' }
sub format { 'text' }

sub extract {
    my ( $self, $file ) = @_;

    my $ppthtml = $self->conf->{ppthtml} || '/usr/bin/ppthtml';
    my $html    = `/usr/local/bin/ppthtml $file`;
    my $text    = $self->strip_html($html);

    $text = Encode::decode('utf8', $text);
    $text = Encode::encode('utf8', $text);

    my $r = File::Extract::Result->new(
        text      => $text,
        filename  => $file,
        mime_type => $self->mime_type,
    );

    return $r;
}

1;

