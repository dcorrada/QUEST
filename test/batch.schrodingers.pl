#!/usr/bin/perl
# -d

use strict;
use warnings;
use Cwd;

my $workdir = getcwd();
my $bin = qx/which QUEST.client.pl/; chomp $bin;

opendir DH, $workdir;
my @scripts = grep { /mmgbsa.\d+.sh/ } readdir(DH);
closedir DH;

foreach my $script (@scripts) {
    sleep 1;
    my $log = qx/clear; $bin -s $script/;
    print "$log\n";
}

exit;