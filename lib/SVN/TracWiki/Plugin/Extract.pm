package SVN::TracWiki::Plugin::Extract;

use strict;
use warnings;
use base qw( File::Extract SVN::TracWiki::Plugin Class::Data::Inheritable );

sub ext { }
sub mime_type { }
sub extract { }
sub format { }

sub strip_html {
    my ($self, $html ) = @_;

    eval {
        require HTML::FormatText;
        require HTML::TreeBuilder;
    };

    if ($@) {
        # dump stripper
        $html =~ s/<[^>]*>//g;
        return HTML::Entities::decode($html);
    }

    my $tree = HTML::TreeBuilder->new;
    $tree->parse($html);
    $tree->eof;

    my $formatter = HTML::FormatText->new(leftmargin => 0);
    my $text = $formatter->format($tree);
#    utf8::decode($text);
    $text =~ s/\s*$//s;
    $text;
}

1;
