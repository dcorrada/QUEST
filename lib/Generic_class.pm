package QUEST::lib::Generic_class;

# to make STDOUT flush immediately, simply set the variable
# this can be useful if you are writing to STDOUT in a loop
# many times the buffering will cause unexpected output results
$| =1;

use lib $ENV{HOME};

###################################################################
use strict;
use warnings;
use Carp;
our $AUTOLOAD;
use Cwd;

# STRUTTURA DATI
our %_attribute_properties = (
    _errfile             => [ '', 'read.write.'], # file in cui loggare i messaggi di errore
    _exception           => [ '',   'read.'],   # Eventuale messaggio di errore
    _workdir             => [ getcwd(), 'read.write.'], # Working Dir path
);

# Ritorna la lista degli attributi
sub _all_attributes {
    my($self) = @_;
    no strict;
    return keys %{ref($self) . '::_attribute_properties'};
}

# Verifica gli accessi dell'attributo
sub _permissions {
    my($self, $attribute, $permissions) = @_;
    no strict; 
    return (${ref($self) . '::_attribute_properties'}{$attribute}[1] =~ /$permissions/);
}

# Re-inizializza gli attributi dell'oggetto
# (gli attributi in sola lettura vengono inizializzati come indefiniti)
# DEPRECATED: usare il metodo <_source> al suo posto
sub _reinit {
    my ($self) = @_;
    
    foreach my $attribute ($self->_all_attributes()) {
        unless ($self->_permissions($attribute, 'write')) {
            undef ($self->{$attribute});
        }
    }
}

# Re-inizializza gli attributi dell'oggetto
# (vengono inizializzati solo gli attributi flaggati con ".init", nell'hash <%_attribute_properties>)
# MODIFICARE QUESTA SUB per metodi di inizializzazione differenti
sub _source {
    my ($self, $name) = @_;
    
    print "\nW- [Generic_class] reinitializing attributes...";
    foreach my $attribute ($self->_all_attributes()) {
        if ($self->_permissions($attribute, 'init')) { # verifico se l'attributo può essere inizializzato
            # verifico la tipologia dell'attributo
            if ($self->{$attribute} =~ /^ARRAY\(\w+\)$/) {
                $self->{$attribute} = [ ]; next;
            } elsif ($self->{$attribute} =~ /^HASH\(\w+\)$/) {
                $self->{$attribute} = { }; next;
            } else {
                $self->{$attribute} = ''; next;
            };
        }
    }
    print "done";
}

# Ritorna il valore di default dell'attributo
sub _attribute_default {
    my($self, $attribute) = @_;
    no strict;
    return ${ref($self) . '::_attribute_properties'}{$attribute}[0];
}

# Verifica che le chiavi di hash passate come argomento corrispondano agli attributi della classe
sub _check_attributes {
    my ($self, @arg_list) = @_;
    my @attribute_list = $self->_all_attributes();
    my $attributes_not_found = 0;

    foreach my $arg (@arg_list) {
        unless (exists $self->{'_'.$arg}) {
            print "\nW- [Generic_class] Attribute _$arg unknown\n";
            $attributes_not_found++;
        }
    }
    return $attributes_not_found;
}

# Manda un messaggio di errore stampando il contenuto dell'attributo _exception e interrompendo il programma
sub _raise_error {
   my ($self, $mess) = @_;
   $mess and do {
        $self->{'_exception'} = $mess;
   };
   
   # scrivo il trailer sul file di log
   my ($sec,$min,$ore,$giom,$mese,$anno,$gios,$gioa,$oraleg) = localtime(time);
   $mese = $mese+1;
   $mese = sprintf("%02d", $mese);
   $giom = sprintf("%02d", $giom);
   $ore = sprintf("%02d", $ore);
   $min = sprintf("%02d", $min);
   $sec = sprintf("%02d", $sec);
   my $date = ($anno+1900)."/$mese/$giom - $ore:$min:$sec";
   
   $self->{'_errfile'} and do { # se un logfile è settato scrivo il messaggio di errore
        my $fh;
        open($fh, '>>' . $self->{'_errfile'}) or croak (sprintf("\n\tE- [Generic_class] Unable to open file <%s>\n\t", $self->{'_errfile'}));
        print $fh $mess . " < $date";
        close $fh;
   };
   
   croak $self->get_exception();
}

# Manda un messaggio di warning stampando il contenuto dell'attributo _exception e interrompendo il programma
sub _raise_warning {
   my ($self, $mess) = @_;
   $mess and do {
        $self->{'_exception'} = $mess;
   };
   
   # scrivo il trailer sul file di log
   my ($sec,$min,$ore,$giom,$mese,$anno,$gios,$gioa,$oraleg) = localtime(time);
   $mese = $mese+1;
   $mese = sprintf("%02d", $mese);
   $giom = sprintf("%02d", $giom);
   $ore = sprintf("%02d", $ore);
   $min = sprintf("%02d", $min);
   $sec = sprintf("%02d", $sec);
   my $date = ($anno+1900)."/$mese/$giom - $ore:$min:$sec";
   
   $self->{'_errfile'} and do { # se un logfile è settato scrivo il messaggio di errore
        my $fh;
        open($fh, '>>' . $self->{'_errfile'}) or croak (sprintf("\n\tE- [Generic_class] Unable to open file <%s>\n\t", $self->{'_errfile'}));
        print $fh $mess . " < $date";
        close $fh;
   };
   
   print $self->get_exception();
}

# unisce due hash dando la precedenza ai valori contenuti nella hash referenziata con $child; serve per unire le liste di attributi tra una classe madre e quella che eredita. Ritorna un hash_ref della combinazione dei due.
sub _hash_joiner {
    my ($mother, $child) = @_;
    
    my %inherited = %$mother;
    
    foreach my $id (keys(%$child)) {
        $inherited{$id} = $child->{$id};
    }
    
    return \%inherited;
}

# COSTRUTTORE
sub new {
    my ($class, %arg) = @_;

    # crea un nuovo oggetto
    my $self = bless { }, $class;
    # inizializza gli attributi dell'oggetto...
    foreach my $attribute ($self->_all_attributes()) {
        $attribute =~ m/^_(\w+)$/;
        # ...con il valore passato in argomento...
        if (exists $arg{$1}) {
            # (verifica dei privilegi in scrittura per l'attributo)
            if ($self->_permissions($attribute, 'write')) {
                $self->{$attribute} = $arg{$1};
            } else {
                print "\nW- [Generic_class] $attribute is a readonly attribute\n";
                $self->{$attribute} = $self->_attribute_default($attribute);
            }
        # ...o con il valore di default altrimenti
        } else {
            $self->{$attribute} = $self->_attribute_default($attribute);
        }
    }

    # verifico se sono stati chiamati degli attributi che non sono previsti in questa classe
    $self->_check_attributes(keys %arg);

    # redirigo lo standard error su un file, invece che a schermo.
#     my $stderr_filename = '>' . $self->get_workdir() . '/stderr.log';
#     open(ERROR, $stderr_filename ) or die $!;
#     STDERR->fdopen( \*ERROR, 'w' ) or die $!;

    return $self;
}

# Gestisce metodi non esplicitamente definiti nella classe
sub AUTOLOAD {
    # disabilito i messaggi di warnings derivanti da un mancato
    # uso di $AUTOLOAD
    no warnings;

    my ($self, $newvalue) = @_;

    # Se viene chiamato qualche metodo non definito...
    # analizza il nome del metodo, es. con "get_filename":
    # $operation = 'get' e $attribute = '_filename'
    #
    # ATTENZIONE: la sintassi nel pattern matching di $AUTOLOAD dipende dalla sintassi
    # data nel package. Ad esempio nel caso volessi individuare il package di questa
    # classe ("my_mir::UCSC::Fasta_Table") dovrei anteporre "\w+::\w+::\w+::" alla
    # stringa "([a-zA-Z0-9]+)_(\w+)$".
    my ($operation, $attribute) = $AUTOLOAD =~ /^\w+::\w+::\w+::([a-zA-Z0-9]+)_(\w+)$/;

    if ($operation, $attribute) {
        $self->_check_attributes($attribute) and $self->_raise_error("\nE- [Generic_class] Method $AUTOLOAD unknown\n\t");
        $attribute = '_'.$attribute;

        # metodi per la lettura di attributi
        # ATTENZIONE: se l'attributo in questione NON è uno scalare
        #             viene ritornata una REF del dato e NON il
        #             dato stesso
        if ($operation eq 'get') {
            # controlla che l'attributo abbia il permesso in lettura
            if ($self->_permissions($attribute, 'read')) {
                return $self->{$attribute};
            } else {
                print "\nW- Attributo $attribute senza accesso in lettura";
            }

        # metodi per la scrittura di attributi
        # ATTENZIONE: se l'attributo in questione NON è uno scalare
        #             occorre passare una REF del dato e NON il
        #             dato stesso
        } elsif ($operation eq 'set') {
            # controlla che l'attributo abbia il permesso in scrittura
            if ($self->_permissions($attribute, 'write')) {
                $self->{$attribute} = $newvalue;
            } else {
                print "\nW- Attributo $attribute senza accesso in scrittura";
            }

        } else {
            $self->_raise_error("\nE- [Generic_class] Metodo $AUTOLOAD non previsto\n\t");
        }
    } else {
        $self->_raise_error("\nE- [Generic_class] Metodo $AUTOLOAD non previsto\n\t");
    }
    use warnings;
}

# Definisce come si comporta l'oggetto chiamato una volta uscito dal proprio scope
sub DESTROY {
    my ($self) = @_;

}


# ritorna l'ora locale
sub date {
    my ($sec,$min,$ore,$giom,$mese,$anno,$gios,$gioa,$oraleg) = localtime(time);
    my $date = '['.($anno+1900).'/'.($mese+1).'/'."$giom - $ore:$min:$sec]";

    return $date;
}

1;

=head1 QUEST::lib::Generic_class

    Questa classe contiene attributi e metodi generici per costruire una nuova
    classe

=head1 Synopsis

    # eredito la classe
    use base ( 'QUEST::lib::Generic_class' );

    # STRUTTURA DATI
    our %_attribute_properties = (
        _summary_table     => [ '',   'read.write.'],     # Nome della tabella mySQL che raccogliera' i dati
        _tmp_table         => [ { },   'read.write.'],
        _overlap           => [ '23',   'read.write.'],
    );
    
    # Unisco gli attributi della classe madre QUEST::lib::Generic_class e della classe figlia
    my $ref = QUEST::lib::Generic_class::_hash_joiner(\%QUEST::lib::Generic_class::_attribute_properties, \%_attribute_properties);
    %_attribute_properties = %$ref;

=head1 UPDATES

=head2 2010-mar-8

    * NUOVO ATTRIBUTO <_workdir>: memorizza la working dir su cui sta girando l'oggetto istanziato
    * REDIREZIONE dello STDERR sul file <stderr.log>

=head2 2010-mar-24

    * metodo _reinit DEPRECATED; usare _source al suo posto
    * REDIREZIONE dello STDERR sul file <stderr.log> disattivata; all'occorrenza decommentare le righe nel metodo costruttore

=head2 2011-nov-30
    
    * modifiche al metodo _raise_error
    * nuovo metodo _raise_warning
    
=head2 2011-dec-14
    
    * metodo date, ritorna l'ora locale
=cut
