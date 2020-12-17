#!/usr/bin/perl
# -d

use strict;
use warnings;
use Data::Dumper;

# This script kill all jobs found in the queue list

my $quest_outlist = qx/QUEST.client.pl -l/;
my @splitted_out = split("\n", $quest_outlist);

my $start;
my @joblist;
foreach my $newline (@splitted_out) {
    next unless ($newline);
    if ($start) {
        if ($newline =~ /^\[/) {
            my ($jobid) = $newline =~ /^\[([\w\d]{8})\]/;
            push(@joblist, $jobid);
        } elsif ($newline =~ /^--$/) {
            last;
        }
    } elsif ($newline =~ /^--- JOB QUEUED ---/) {
        $start = 1;
        next;
    }
}

# inverto la lista, visto che il primo job in coda è quello che più probabilmente va in run
@joblist = reverse @joblist; 

while (my $tokill = shift @joblist) {
    my $log = qx/QUEST.client.pl -k $tokill/;
    print $log;
}

exit;