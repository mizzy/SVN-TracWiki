#!/usr/bin/perl

use strict;
use warnings;

use FindBin;
use File::Spec;
use Getopt::Long;

use lib File::Spec->catdir($FindBin::Bin, 'lib');
use SVN::TracWiki;

my $config = File::Spec->catfile($FindBin::Bin, 'config.yaml');
GetOptions(
    '--config=s' => \$config,
);

SVN::TracWiki->bootstrap({
    config => $config,
    repos  => shift,
    rev    => shift,
});

exit;
