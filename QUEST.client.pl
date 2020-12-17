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
use IO::Socket::INET;

## GLOBS ##
our $conf_file = '/etc/QUEST.conf'; # file di configurazione
our %confs; # parametri di configurazione del socket
our $socket;
our $options = { };
## SBLOG ##

SPLASH: {
    my $splash = <<END
********************************************************************************
QUEST - QUEue your ScripT
release 14.6.a

Copyright (c) 2011-2014, Dario CORRADA <dario.corrada\@gmail.com>

This work is licensed under a Creative Commons
Attribution-NonCommercial-ShareAlike 3.0 Unported License.
********************************************************************************

END
    ;
    print $splash;
}

USAGE: {
    use Getopt::Long;no warnings;
    GetOptions($options, 'help|h', 'list|l','threads|n=i', 'killer|k=s', 'schrodinger|s', 'queue|q=s', 'details|d=s' );
    my $usage = <<END
SYNOPSYS

  $0 -n 4 ./script.sh

  $0 -l
  
  $0 -k 752ENRBU


OPTIONS

  -n <int>              suggested number of threads used (default: 1)

  -l                    list of jobs running/queued

  -k <jobid>            kill a job

  -d <jobid>            details of a job

  -s                    (DEPRECATED) specify that the job comes from 
                        Schrondinger Suite, please read the README.txt file in 
                        order to write a correct script file

  -q <fast|slow>        specify the queue type, "fast" jobs have priority over 
                        "slow" jobs(default: slow)

END
    ;
    if (exists $options->{'help'}) {
        print $usage;
        goto FINE;
    }
}

INIT: {
    # configurazione del socket
    open(CONF, '<' . $conf_file) or croak("E- unable to open <$conf_file>\n\t");
    while (my $newline = <CONF>) {
        if ($newline =~ /^#/) {
            next; # skippo le righe di commento
        } elsif ($newline =~ / = /) {
            chomp $newline;
            my ($key, $value) = $newline =~ m/([\w\d_\.]+) = ([\w\d_\.\/]+)/;
            $confs{$key} = $value;
        } else {
            next;
        }
    }
    close CONF;

    # configurazione delle opzioni
    unless ($ARGV[0] || exists $options->{'list'} || exists $options->{'killer'} || exists $options->{'details'}) {
        print "\nNothing to do";
        goto FINE;
    }
    if ($ARGV[0]) {
        $options->{'user'} = $ENV{'USER'};
        $options->{'workdir'} = getcwd();
        $options->{'threads'} = 1 unless ($options->{'threads'});
        $options->{'script'} = qx/readlink -f $ARGV[0]/;
        chomp  $options->{'script'};
        unless (-x $options->{'script'}) {
            croak(sprintf("\nE- File [%s] is not executable\n\t", $options->{'script'}));
        }
        if ($options->{'threads'} > $confs{'threads'}) {
            croak(sprintf("\nE- Number of threads required (%d) is higher than allowed (%d)\n\t", $options->{'threads'}, $confs{'threads'}));
        }
        if (exists $options->{'schrodinger'}) {
            $options->{'schrodinger'} = 'true';
        } else {
            $options->{'schrodinger'} = 'false';
        }
        if (exists $options->{'queue'}) {
            $options->{'queue'} = 'slow' unless ($options->{'queue'} =~ /(fast|slow)/);
        } else {
            $options->{'queue'} = 'slow';
        }
    } elsif (exists $options->{'killer'}) {
        $options->{'user'} = $ENV{'USER'};
    }
}

CORE: {
    # accesso al server
    $socket = new IO::Socket::INET (
        'PeerAddr'      => $confs{'host'},
        'PeerPort'      => $confs{'port'},
        'Proto'         => 'tcp'
    ) or croak("\nE- Cannot open socket, maybe the server is down?\n\t");
    
    my $mess; # messaggio da spedire al server
    
    # richiedo la lista dei job attivi
    if (exists $options->{'list'}) {
        $mess = 'status';
    
    # ammazzo un job
    } elsif (exists $options->{'killer'}) {
        $mess = sprintf("%s|%s;%s|%s", 
            'killer',   $options->{'killer'}, 
            'user',     $options->{'user'}
        );
    
    # dettagli su di un job
    } elsif (exists $options->{'details'}) {
        $mess = sprintf("%s|%s", 
            'details',   $options->{'details'}
        );
    
    # sottometto un job
    } else {
        foreach my $key (keys %{$options}) {
            $mess .= "$key|$options->{$key};";
        }
        chop($mess);
    }

    $socket->send($mess); # mando un messaggio sul server
    
    # rimango in attesa di una risposta
    my $recieved_data = 'null';
    while (1) {
        $socket->recv($recieved_data,1024);
        my $log = $recieved_data;
        $log =~ s/(QUEST.over&out)$//;
        print $log;
        last if ($recieved_data =~ /QUEST.over&out/); # ho ricevuto il segnale "passo e chiudo" dal server, posso uscire
    }
}

FINE: {
    close $socket if ($socket);
    
    # citazione conclusiva
    my $quote_file = qx/which QUEST.server.pl/;
    chomp $quote_file;
    $quote_file =~ s/QUEST\.server\.pl$/quotes\.txt/;
    my $sep = $/;
    $/ = ">>\n";
    open(CITA, "<$quote_file") or do { print "\n"; exit; };
    my @quotes = <CITA>;
    close CITA;
    my $tot = scalar @quotes;
    $/ = $sep;
    my $end = "\n\n--\n" . $quotes[int(rand($tot))] . "\n";
    $end =~ s/(<<|>>)//g;
    print $end;
    
    exit;
}
