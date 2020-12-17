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
use QUEST::lib::SQLite;
use Carp;
use IO::Socket::INET;
use threads;
use threads::shared;
use Thread::Semaphore;

## GLOBS ##

# COMUNICAZIONE CLIENT/SERVER
our $conf_file = '/etc/QUEST.conf'; # file di configurazione
our %confs = ( # valori di default
    'host'      => '127.0.0.1',        # IP address del localhost
    'port'      => '6090',             # porta
    'threads'   => '8',                # numero massimo di threads concorrenti
);
our $socket; # oggetto IO::Socket::INET

# DATABASE
our $database = '/etc/QUEST.db'; # file del database
our $dbobj; # oggetto QUEST::lib::SQLite
our $dbh; # database handler
our $sth; # statement handler

# SHUTDOWN
# lo script sigIntHandler intecetta segnali di interrupt
$SIG{'INT'} = \&sigIntHandler; # segnale dato da Ctrl+C
$SIG{'TERM'} = \&sigIntHandler; # segnale di kill (SIGTERM 15)
our $poweroff; # la variabile gestita dalla suboutine &sigIntHandler

# THREADING
our $semaforo; # semaforo basato per il blocco dei threads 
our $dbaccess :shared; # serve per permettere ad un solo slot per volta di accedere al DB
our @slotobj; # lista degli oggetti 'threads' lanciati (ie gli slot)

# OTHERS
our @children; # elenco dei PID di processi figli di un job

## SBLOG ##

SPLASH: {
    my $splash = <<END
********************************************************************************
QUEST - QUEue your ScripT
release 14.6.a

Copyright (c) 2011-2020, Dario CORRADA <dario.corrada\@gmail.com>

This work is licensed under GNU GENERAL PUBLIC LICENSE Version 3.
********************************************************************************

END
    ;
    print $splash;
}

INIT: {
    my $username = $ENV{'USER'};
    unless ($username eq 'root') {
        croak "E- you must have superuser privileges to run the server\n\t";
    };
    
    # verifico se esiste un file di configurazione
    unless (-e $conf_file) {
        my $ans;
        print "\nQUEST server is not yet configured, do you want to proceed? [Y/n] ";
        $ans = <STDIN>; chomp $ans;
        $ans = 'y' unless ($ans);
        goto FINE if ($ans !~ /[yY]/);
        print "\n";
        open(CONF, '>' . $conf_file) or croak("E- unable to open <$conf_file>\n\t");
        print CONF "# QUEST configuration file\n\n";
        foreach my $key (sort keys %confs) {
            my $default = $confs{$key};
            printf("    %-8s [%s]: ", $key, $default);
            my $ans = <STDIN>; chomp $ans;
            if ($ans) {
                print CONF "$key = $ans\n";
            } else {
                print CONF "$key = $default\n";
            }
        }
        close CONF;
        print "\n";
    }
    
    print "    CONFIGS...: $conf_file\n";
    print "    DATABASE..: $database\n\n";
    
    # inizializzo il server leggendo il file di configurazione
    open(CONF, '<' . $conf_file) or croak("E- unable to open <$conf_file>\n\t");
    while (my $newline = <CONF>) {
        if ($newline =~ /^#/) {
            next; # skippo le righe di commento
        } elsif ($newline =~ / = /) {
            chomp $newline;
            my ($key, $value) = $newline =~ m/([\w\d_\.]+) = ([\w\d_\.\/]+)/;
            $confs{$key} = $value if (exists $confs{$key});
        } else {
            next;
        }
    }
    close CONF;
    
    # inizializzo il database
    $dbobj = QUEST::lib::SQLite->new('database' => $database, 'log' => 0);
    $dbh = $dbobj->access2db();
    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
        'query' => 'SELECT name FROM sqlite_master WHERE type = "table"'
    );
    my $table_list = $sth->fetchall_arrayref();
    $sth->finish();
    if (scalar @{$table_list} == 0) {
        init_database();
    } else {
        rescue_database();
    }
    
    # inizializzo il semaforo
    $semaforo = Thread::Semaphore->new(int($confs{'threads'}));
    
    # lancio gli slot, il numero di slot aperti equivale al numero di threads (ie numero massimo di thread concorrenti)
    for (my $i = 0; $i < $confs{'threads'}; $i++) {
        my $thr = threads->new(\&superslot);
        $thr->detach();
    }
    
    printf("%s server initialized\n", clock());
}

CORE: {
    # apro un socket per comunicare con il client
    my $error = <<END
E- Cannot open socket, maybe the server is already running elsewhere. Otherwise,
   check the parameters in the file <$conf_file>
END
    ;
    $socket = new IO::Socket::INET (
        'LocalHost'       => $confs{'host'},
        'LocalPort'       => $confs{'port'},
        'Proto'           => 'tcp',     # protocollo di connessione
        'Listen'          => 1,         # numero di sockets in ascolto
        'Reuse'           => 1          # riciclare i socket?
    ) or croak("$error\t");
    printf("%s server is listening\n", clock());
    
    while (1) {
        # lascio girare il server fino a che non riceve un SIGTERM
        goto FINE if ($poweroff);
        
        # metto il server in ascolto
        my $client = $socket->accept();
        if ($client) {
            # raccolgo la request dal client
            my $recieved_data;
            $client->recv($recieved_data,1024);
            
# ******************************************************************************
# *** RICHIESTA DI SOTTOMETTERE UN NUOVO JOB ***********************************
# ******************************************************************************
            if ($recieved_data =~ /script/ ) {
                my @params = split(';', $recieved_data);
                my %client_order;
                while (my $order = shift @params) {
                    my ($key, $value) = $order =~ /(.+)\|(.+)/;
                    $client_order{$key} = $value;
                }
                
                my $jobid;
                my $isok = 1;
                while ($isok) {
                    $client->send("assigning jobid...\n");
                    
                    # genero un jobid
                    my @chars = ('A'..'Z', 0..9, 0..9);
                    $jobid = join('', map $chars[rand @chars], 0..7);
                    
                    # mi assicuro che il jobid non sia già assegnato
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'SELECT * FROM status'
                    );
                    my $found;
                    while (my $ref_row = $sth->fetchrow_hashref()) {
                        my $value = $ref_row->{'jobid'};
#                         print "\t$value";
                        $found = 1 if ($value eq $jobid);
                    }
                    $sth->finish();
                    
                    if ($found) {
                        next; sleep 1;
                    } else {
                        undef $isok;
                    }
                }
                
                {   
                    lock $dbaccess;
                    
                    # aggiungo i dettagli del job al DB
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'INSERT INTO details (jobid,threads,queue,user,schrodinger) VALUES (?,?,?,?,?)',
                        'bindings' => [ $jobid, $client_order{'threads'}, $client_order{'queue'}, $client_order{'user'}, $client_order{'schrodinger'} ]
                    );
                    $sth->finish();
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'INSERT INTO paths (jobid,script,workdir) VALUES (?,?,?)',
                        'bindings' => [ $jobid, $client_order{'script'}, $client_order{'workdir'} ]
                    );
                    $sth->finish();
                    
                    # accodo il job sul DB
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'INSERT INTO status (jobid,status) VALUES (?,"queued")',
                        'bindings' => [ $jobid ]
                    );
                    $sth->finish();
                    
                    my $score = sprintf("%04d%s%012d-%s", $client_order{'threads'}, $client_order{'queue'}, time, $jobid);
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'INSERT INTO queuelist (jobid,score) VALUES (?,?)',
                        'bindings' => [ $jobid, $score ]
                    );
                    $sth->finish();
                    
                    my $timex = clock();
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'INSERT INTO timex (jobid, submit)VALUES (?,?)',
                        'bindings' => [ $jobid, $timex ]
                    );
                    $sth->finish();
                }
                
                printf("%s job [%s] submitted\n", clock(), $jobid);
                my $mess = sprintf("%s job [%s] submitted", clock(), $jobid);
                $client->send($mess);
                
# ******************************************************************************
# *** RICHIESTA DELLA LISTA DEI JOB ATTIVI E ACCODATI **************************
# ******************************************************************************
            } elsif ($recieved_data =~ /status/ ) {
                my (%running, %queued);
                
                # leggo quali job sono attivi
                $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                    'query' => 'SELECT * FROM status'
                );
                while (my $ref_row = $sth->fetchrow_hashref()) {
                    if ($ref_row->{'status'} eq 'running') {
                        $running{$ref_row->{'jobid'}} = '';
                    } elsif ($ref_row->{'status'} eq 'queued') {
                        $queued{$ref_row->{'jobid'}} = '';
                    } else {
                        next;
                    }
                }
                $sth->finish();
                
                # raccolgo i dettagli
                foreach my $jobid (keys %running) {
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'SELECT user, threads, queue, script FROM details INNER JOIN paths ON details.jobid = paths.jobid WHERE details.jobid = ?',
                        'bindings' => [ $jobid ]
                    );
                    my $ref_row = $sth->fetchrow_hashref();
                    $sth->finish();
                    $running{$jobid} = sprintf( "[%s]  %s  %s  %s  <%s>",
                        $jobid,
                        $ref_row->{'user'},
                        $ref_row->{'threads'},
                        $ref_row->{'queue'},
                        $ref_row->{'script'}
                    );
                }
                foreach my $jobid (keys %queued) {
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'SELECT user, threads, queue, script FROM details INNER JOIN paths ON details.jobid = paths.jobid WHERE details.jobid = ?',
                        'bindings' => [ $jobid ]
                    );
                    my $ref_row = $sth->fetchrow_hashref();
                    $sth->finish();
                    $queued{$jobid} = sprintf( "[%s]  %s  %s  %s  <%s>",
                        $jobid,
                        $ref_row->{'user'},
                        $ref_row->{'threads'},
                        $ref_row->{'queue'},
                        $ref_row->{'script'}
                    );
                }
                
                # riordino i job accodati secondo lo score
                $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                    'query' => 'SELECT * FROM queuelist'
                );
                my %scored;
                while (my $ref_row = $sth->fetchrow_hashref()) {
                    my $key = $ref_row->{'score'};
                    my $value = $ref_row->{'jobid'};
                    $scored{$key} = $value;
                }
                $sth->finish();
                my @sorted = sort {$a cmp $b} keys %scored;
                
                my $log;
                $log = sprintf("\nAvalaible threads %d of %d\n", ${$semaforo}, $confs{'threads'});
                $log .= "\n--- JOB RUNNING ---\n";
                foreach my $jobid (keys %running) {
                    $log .= sprintf("%s\n", $running{$jobid});
                }
                $log .= "\n--- JOB QUEUED ---\n";
                foreach my $score (@sorted) {
                    $log .= sprintf("%s\n", $queued{$scored{$score}});
                }
                $client->send($log);
                
# ******************************************************************************
# *** RICHIESTA DI DETTAGLI SU DI un JOB ***************************************
# ******************************************************************************
            } elsif ($recieved_data =~ /details/ ) {
                my ($jobid) = $recieved_data =~ /details\|([\w\d]+)/;
                my $mess;
                
                # leggo i dettagli sul job
                $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                    'query' => 'SELECT user, threads, queue, schrodinger, script script FROM details INNER JOIN paths ON details.jobid = paths.jobid WHERE details.jobid = ?',
                    'bindings' => [ $jobid ]
                );
                my $details = $sth->fetchrow_hashref();
                $sth->finish();
                
                unless ($details->{'user'}) {
                    $mess = "unable to find job [$jobid]\n";
                } else {
                    # prendo i tempi del job
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'SELECT status, submit, start, stop FROM status INNER JOIN timex ON status.jobid = timex.jobid WHERE status.jobid = ?',
                        'bindings' => [ $jobid ]
                    );
                    my $timex = $sth->fetchrow_hashref();
                    $sth->finish();
                    
                    $mess = <<END
*** JOB $jobid ***
STATUS........: $timex->{'status'}
USER..........: $details->{'user'}
THREADS.......: $details->{'threads'}
QUEUE.........: $details->{'queue'}
SCHRODINGER...: $details->{'schrodinger'}
SCRIPT........: $details->{'script'}
SUBMITTED.....: $timex->{'submit'}
STARTED.......: $timex->{'start'}
FINISHED......: $timex->{'stop'}

END
                    ;
                }
                
                $client->send($mess);
                
# ******************************************************************************
# *** RICHIESTA DI ABORTIRE UN JOB SOTTOMESSO **********************************
# ******************************************************************************
            } elsif ($recieved_data =~ /killer/ ) {
                my ($jobid, $user) = $recieved_data =~ /killer\|([\w\d]+);user\|([\w\d]+)/;
                my $mess;
                
                # verifico se il job esiste e l'utente ha le credenziali
                $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                    'query' => 'SELECT user,schrodinger FROM details WHERE jobid = ?',
                    'bindings' => [ $jobid ]
                );
                my $ref_row = $sth->fetchrow_hashref();
                $sth->finish();
                unless ($ref_row->{'user'}) {
                    $mess = "REJECTED: unable to find job [$jobid]\n";
                    goto ENDKILL;
                } elsif ($ref_row->{'user'} ne $user) {
                    $mess = "REJECTED: $user is not the owner of this job\n";
                    goto ENDKILL;
                }
                # verifico se il job sta girando oppure se è accodato
                $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                    'query' => 'SELECT status FROM status WHERE jobid = ?',
                    'bindings' => [ $jobid ]
                );
                $ref_row = $sth->fetchrow_hashref();
                $sth->finish();
                if ($ref_row->{'status'} eq 'queued') {
                    # se il job è accodato lo rimuovo dalla lista
                    lock $dbaccess;
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'DELETE FROM queuelist WHERE jobid = ?',
                        'bindings' => [ $jobid ]
                    );
                    $sth->finish();
                } elsif ($ref_row->{'status'} eq 'running') {
                    # il job sta girando, verifico i dettagli
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'SELECT script,schrodinger FROM details INNER JOIN paths ON details.jobid = paths.jobid WHERE details.jobid = ?',
                        'bindings' => [ $jobid ]
                    );
                    $ref_row = $sth->fetchrow_hashref();
                    $sth->finish();
                    
                    if ($ref_row->{'schrodinger'} !~ /false/) {
                        # è un job Schrodinger, non lo uccido direttamente
                        $mess = <<END
REJECTED: try to use the following commad

    \$ \$SCHRODINGER/jobcontrol -kill $ref_row->{'schrodinger'}
END
                        ;
                        goto ENDKILL;
                    } else {
                        # è un job normale, provo ad ucciderlo
                        my $string = "QUEST.job.$jobid.log";
                        my $psaux = qx/ps aux \| grep -P " $ref_row->{'script'} >> .*$string"/;
                        my @procs = split("\n", $psaux);
                        my ($match) = grep(!/grep/, @procs);
                        my ($parent_pid) = $match =~ /\w+\s*(\d+)/;
                        undef @children;
                        push (@children, $parent_pid);
                        &getcpid($parent_pid);
                        @children = sort {$b <=> $a} @children;
                        while (my $child = shift(@children)) {
#                                 print "\tkilling child pid $child...\n";
                            kill 15, $child;
                            sleep 1; # aspetto un poco...
                        }
                    }
                }
                
                # aggiorno il database
                {
                    lock $dbaccess;
                    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                        'query' => 'UPDATE status SET status = "aborted" WHERE jobid = ?',
                        'bindings' => [ $jobid ]
                    );
                    $sth->finish();
                }
                
                printf("%s job [%s] aborted\n", clock(), $jobid);
                $mess = "job [$jobid] killed\n";
                
                ENDKILL: { $client->send($mess) };
            }
            
            # messaggio di "passo e chiudo" dal server al client
            $client->send('QUEST.over&out');
        }
    }
}

FINE: {
    close $socket if ($socket);
    $dbh->disconnect if $dbh;
    printf("%s server stopped\n\n", clock());
    exit;
}

sub superslot {
    # accedo al database
    my $slotdbobj = QUEST::lib::SQLite->new('database' => $database, 'log' => 0);
    my $slotdbh = $slotdbobj->access2db();
    my $slotsth;
        
    STANDBY: while (1) {
        sleep 1;
        my $jobid;
        my $threads;
        
        { 
            lock $dbaccess;
            
            # leggo la lista dei job accodati
            $slotsth = $slotdbobj->query_exec( 'dbh' => $slotdbh, 
                'query' => 'SELECT * FROM queuelist'
            );
            my %queued;
            while (my $ref_row = $slotsth->fetchrow_hashref()) {
                my $key = $ref_row->{'score'};
                my $value = $ref_row->{'jobid'};
                $queued{$key} = $value;
            }
            $slotsth->finish();
            
            # se non ci sono job accodati...
            unless (%queued) { next STANDBY; };
            
            # riordino la lista e prendo il primo
            my @sorted = sort {$a cmp $b} keys %queued;
            $jobid = $queued{$sorted[0]};
            
            # verifico il numero di threads che richiede il job
            $slotsth = $slotdbobj->query_exec( 'dbh' => $slotdbh, 
                'query' => 'SELECT jobid, threads FROM details WHERE jobid = ?',
                'bindings' => [ $jobid ]
            );
            my $ref_row = $slotsth->fetchrow_hashref();
            $slotsth->finish();
            $threads = $ref_row->{'threads'};
            
            # se non ci sono thread liberi...
            if ($threads > ${$semaforo}) { next STANDBY; };
            
            # rimuovo il job dalla queuelist se può partire
            $slotsth = $slotdbobj->query_exec( 'dbh' => $slotdbh, 
                'query' => 'DELETE FROM queuelist WHERE jobid = ?',
                'bindings' => [ $jobid ]
            );
            $slotsth->finish();
            
            # occupo tanti threads quanti richiesti
            for (1..$threads) { $semaforo->down() };
        }
        
        printf("%s job [%s] started\n", clock(), $jobid);
        
        my ($workdir, $user, $script, $schrodinger);
        {
            lock $dbaccess;
            # reperisco dettagli sul job
            $slotsth = $slotdbobj->query_exec( 'dbh' => $slotdbh, 
                'query' => 'SELECT user, workdir, script, schrodinger FROM details INNER JOIN paths ON details.jobid = paths.jobid WHERE details.jobid = ?',
                'bindings' => [ $jobid ]
            );
            my $ref_row = $slotsth->fetchrow_hashref();
            $workdir = $ref_row->{'workdir'};
            $user = $ref_row->{'user'};
            $script = $ref_row->{'script'};
            $schrodinger = $ref_row->{'schrodinger'};
            $slotsth->finish();
            
            # aggiorno lo status del job
            $slotsth = $slotdbobj->query_exec( 'dbh' => $slotdbh, 
                'query' => 'UPDATE status SET status = "running" WHERE jobid = ?',
                'bindings' => [ $jobid ]
            );
            $slotsth->finish();
            
            my $timex = clock();
            $slotsth = $slotdbobj->query_exec( 'dbh' => $slotdbh, 
                'query' => 'UPDATE timex SET start = ? WHERE jobid = ?',
                'bindings' => [ $timex, $jobid ]
            );
            $slotsth->finish();
        }
        
        # genero un file di log in cui raccogliero' l'output del job
        my $logfile = sprintf("%s/QUEST.job.%s.log", $workdir, $jobid);
        
        # lancio il job
        qx/cd $workdir; sudo -u $user touch $logfile; sudo su $user -c "$script >> $logfile 2>&1"/;
        
        if ($schrodinger eq 'true') { # blocco ad-hoc per i job della Schrodinger
            my $signature;
        
            # leggo il logfile per catturare il JobID assegnato da Schrodinger
            my $waitforjobid = 1;
            while ($waitforjobid) {
                my $string = qx/grep "JobId:" $logfile/;
                chomp $string;
                if ($string) {
                    ($signature) = $string =~ /JobId: (.+)/;
                    undef $waitforjobid;
                    # una volta che ottengo il JobID aspetto ancora un po' (se facessi partire subito un top cercando un processo contenente il JobID come stringa non troverei nulla)
                    sleep 5;
                } else {
                    sleep 1; # continuo a ciclare fino a quando non ottengo un JobID
                }
            }
            
            {
                lock $dbaccess;
            
                # aggiorno il database con il JobID
                $slotsth = $slotdbobj->query_exec( 'dbh' => $slotdbh, 
                    'query' => 'UPDATE details SET schrodinger = ? WHERE jobid = ?',
                    'bindings' => [ $signature, $jobid ]
                );
                $slotsth->finish();
            }
            
            # i job della Schrodinger fanno da se' un detach una volta partiti e lo script finirebbe, genero un loop che guarda se il monitor di Schrodinger controlla il JobID specifico
            my $is_running = 1;
            while ($is_running) {
                my $pslog = qx/ps aux | grep "$signature"/;
                my @procs = split("\n", $pslog);
                @procs = grep(!/ps aux/, @procs);
                @procs = grep(!/grep/, @procs);
#                 print Dumper \@procs;
                if (@procs) {
                    sleep 5;
                } else {
                    undef $is_running;
                }
            }
        }
        
        {
            lock $dbaccess;
        
            # aggiorno lo status del job
            $slotsth = $slotdbobj->query_exec( 'dbh' => $slotdbh, 
                'query' => 'UPDATE status SET status = "finished" WHERE jobid = ?',
                'bindings' => [ $jobid ]
            );
            $slotsth->finish();
            
            my $timex = clock();
            $slotsth = $slotdbobj->query_exec( 'dbh' => $slotdbh, 
                'query' => 'UPDATE timex SET stop = ? WHERE jobid = ?',
                'bindings' => [ $timex, $jobid ]
            );
            $slotsth->finish();
        
            # libero tanti threads quanti richiesti
            for (1..$threads) { $semaforo->up() }; 
        }
        
        printf("%s job [%s] finished\n", clock(), $jobid);
    }
    
    $slotdbh->disconnect;
}

# questa subroutine serve per intercettare un segnale di interrupt
sub sigIntHandler {
    $poweroff = 1;
}

sub clock {
    my ($sec,$min,$ore,$giom,$mese,$anno,$gios,$gioa,$oraleg) = localtime(time);
    $mese = $mese+1;
    $mese = sprintf("%02d", $mese);
    $giom = sprintf("%02d", $giom);
    $ore = sprintf("%02d", $ore);
    $min = sprintf("%02d", $min);
    $sec = sprintf("%02d", $sec);
    my $date = '[' . ($anno+1900)."/$mese/$giom $ore:$min:$sec]";
    return $date;
}

sub getcpid {
    my ($pid) = @_;
    my $log = qx/pgrep -P $pid/;
    my @cpids = split("\n", $log);
    foreach my $child (@cpids) {
        push(@children, $child);
        &getcpid($child);
    }
}

sub init_database {
    # status dei job ('queued', 'running', 'finished', 'aborted')
    $dbobj->new_table(
        'dbh' => $dbh,
        'table' => 'status',
        'args' => "`jobid` TEXT PRIMARY KEY NOT NULL, `status` TEXT NOT NULL"
    );
    # scriptfile associati ai job
    $dbobj->new_table(
        'dbh' => $dbh,
        'table' => 'paths',
        'args' => "`jobid` TEXT PRIMARY KEY NOT NULL, `script` TEXT NOT NULL, `workdir` TEXT NOT NULL"
    );
    # parametri di sottomissione
    $dbobj->new_table(
        'dbh' => $dbh,
        'table' => 'details',
        'args' => "`jobid` TEXT PRIMARY KEY NOT NULL, `threads` INT NOT NULL, `queue` TEXT NOT NULL, `user` TEXT NOT NULL, `schrodinger` TEXT NOT NULL"
    );
    # lista dei job accodati, score è un valore su cui si valuta la priorità dei job
    $dbobj->new_table(
        'dbh' => $dbh,
        'table' => 'queuelist',
        'args' => "`jobid` TEXT PRIMARY KEY NOT NULL, `score` TEXT NOT NULL"
    );
    
    # lista dei job accodati, score è un valore su cui si valuta la priorità dei job
    $dbobj->new_table(
        'dbh' => $dbh,
        'table' => 'timex',
        'args' => "`jobid` TEXT PRIMARY KEY NOT NULL, `submit` TEXT NOT NULL DEFAULT 'null', `start` TEXT NOT NULL DEFAULT 'null', `stop` TEXT NOT NULL DEFAULT 'null'"
    );
}

sub rescue_database {
    # re-inizializzo la queuelist
    $dbobj->new_table(
        'dbh' => $dbh,
        'table' => 'queuelist',
        'args' => "`jobid` TEXT PRIMARY KEY NOT NULL, `score` TEXT NOT NULL"
    );
    
    # leggo lo status dei job prima che il server fosse stoppato
    my @alive;
    $sth = $dbobj->query_exec( 'dbh' => $dbh, 
        'query' => 'SELECT * FROM status'
    );
    while (my $ref_row = $sth->fetchrow_hashref()) {
        if ($ref_row->{'status'} =~ /(queued|running)/) {
            push(@alive, $ref_row->{'jobid'});
#             print "[$ref_row->{'jobid'} -> $ref_row->{'status'}]\n";
        }
    }
    $sth->finish();
    
    if (scalar @alive > 0) {
        printf("\n%d jobs were interrupted last time, do you want to restore them? [y/N] ", scalar @alive);
        my $ans = <STDIN>; chomp $ans;
        $ans = 'n' unless ($ans);
        if ($ans =~ /[nN]/) {
            foreach my $jobid (@alive) {
                $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                    'query' => 'UPDATE status SET status = "aborted" WHERE jobid = ?',
                    'bindings' => [ $jobid ]
                );
                $sth->finish();
            }
        } else {
            foreach my $jobid (@alive) {
                $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                    'query' => 'UPDATE status SET status = "queued" WHERE jobid = ?',
                    'bindings' => [ $jobid ]
                );
                $sth->finish();
                
                $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                    'query' => 'SELECT threads, queue FROM details WHERE jobid = ?',
                    'bindings' => [ $jobid ]
                );
                my $ref_row = $sth->fetchrow_hashref();
                $sth->finish();
                
                my $newscore = sprintf("%04d%s%012d-%s", $ref_row->{'threads'}, $ref_row->{'queue'}, time, $jobid);
                
                $sth = $dbobj->query_exec( 'dbh' => $dbh, 
                    'query' => 'INSERT INTO queuelist (jobid,score) VALUES (?,?)',
                    'bindings' => [ $jobid, $newscore ]
                );
                $sth->finish();
                
                printf("%s job [%s] restored\n", clock(), $jobid);
                
                sleep 1;
            }
        }
    }

    
}
