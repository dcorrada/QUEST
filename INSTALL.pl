#!/usr/bin/perl
# -d

use strict;
use warnings;

# to make STDOUT flush immediately, simply set the variable
# this can be useful if you are writing to STDOUT in a loop
# many times the buffering will cause unexpected output results
$| = 1;

# paths di librerie personali
use lib $ENV{HOME};

# il metodo Dumper restituisce una stringa (con ritorni a capo \n)
# contenente la struttura dati dell'oggetto in esame.
#
# Esempio:
#   $obj = Class->new();
#   print Dumper($obj);
use Data::Dumper;
###################################################################
use Cwd;
use Carp;

my $workdir = getcwd();
my ($pruned) = $workdir =~ /(.+)\/QUEST$/;
my $path_string = <<END

# QUEST package [https://github.com/dcorrada/QUEST]
export PATH=$workdir:\$PATH
export PERL5LIB=$pruned:$workdir:\$PERL5LIB

END
;

# aggiorno il file bashrc
my $bashrc_file = $ENV{HOME} . '/.bashrc';
print "Set your bashrc file [$bashrc_file]: ";
my $ans = <STDIN>; chomp $ans;
$bashrc_file = $ans if ($ans);
open (BASHRC, '>>' . $bashrc_file) or croak("\nE- unable to open <$bashrc_file>\n\t");
print BASHRC $path_string;
close BASHRC;

# rendo esesguibili i vari script
&recurs($workdir); 

print "All done, please re-source <$bashrc_file>\n";
exit;

sub recurs {
    my ($path) = @_;
    my $dh;
    opendir ($dh, $path);
    my @path_list = readdir $dh;
    closedir $dh;
    while (my $new_path = shift @path_list) {
        if ($new_path eq '.') {
            next;
        } elsif ($new_path eq '..') {
            next;
        } elsif (-d "$path/$new_path") {
            my $child = "$path/$new_path";
            &recurs($child);
        } elsif ($path =~ /\.(py|pl|pm|sh)$/) {
            qx/chmod +x $path/;
        }
    }
}
