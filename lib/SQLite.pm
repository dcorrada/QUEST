package QUEST::lib::SQLite;

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
use base ( 'QUEST::lib::Generic_class' ); # eredito la classe generica contenente il costruttore, l'AUTOLOAD ecc..
use base ( 'QUEST::lib::FileIO' ); # eredito la classe per gestire le lettura/scrittura di file
use DBI;
our $AUTOLOAD;

# Definizione degli attributi della classe
# chiave        -> nome dell'attributo
# valore [0]    -> valore di default
# valore [1]    -> permessi di accesso all'attributo
#                  ('read.[write.[...]]')

# STRUTTURA DATI
our %_attribute_properties = (
# ACCESS features
    _database          => [ '',   'read.write.'],
    _user              => [ '',   'read.write.'],
    _password          => [ '',   'read.write.'],
# QUERY features
    _query_string      => [ '',   'read.write.'],
    _csv_file          => [ '',   'read.write.'],     # Nome del file CSV da esportare da una query
    _table_name        => [ '',   'read.write.'],     
# LOG file
    _log               => [ 0,   'read.write.'],      # abilito la scrittura del file dbi.log
);

# Unisco gli attributi della classe madre QUEST::lib::Generic_class e della classe figlia
my $ref = QUEST::lib::Generic_class::_hash_joiner(\%QUEST::lib::Generic_class::_attribute_properties, \%_attribute_properties);
%_attribute_properties = %$ref;
QUEST::lib::Generic_class::_hash_joiner(\%QUEST::lib::FileIO::_attribute_properties, \%_attribute_properties);
%_attribute_properties = %$ref;

# accede ad un DB con le credenziali date negli attributi e restituisce un database-handle
sub access2db {
    my ($self, %arg) = @_;

    $self->set_database($arg{'database'}) if exists $arg{'database'};
    $self->set_user($arg{'user'}) if exists $arg{'user'};
    $self->set_password($arg{'password'}) if exists $arg{'password'};

    $self->_raise_error(sprintf("\nE- [SQLite] undef credential\n\t"))
        unless ($self->get_database);

    my $datasource = sprintf("DBI:SQLite:dbname=%s", $self->get_database);
    
    # Connessione al DB
    my $dbh = DBI->connect($datasource, $self->get_user, $self->get_password, {'PrintError' => 0, 'RaiseError' => 0})
        or $self->_raise_error(sprintf("\nE- [SQLite] unable to connect [%s]\n\t", DBI->errstr));

    # faccio un tracing di tutte le operazioni effettuate e le scrivo su un log file
    ($self->get_log) and do {
        my $fh_dbilog; open($fh_dbilog, ">>dbi.log");
        print $fh_dbilog "\n\n*** DBI ACCESS " . $self->date() . " ***\n";

        DBI->trace(1,"dbi.log");
    };

    # messaggio di log
    # printf ("\nI- connected as [%s@%s:%s]", $self->get_user, $self->get_host, $self->get_database);

    return $dbh;
}

# genero nuove tabelle, ritorna una stringa con la query usata
sub new_table {
    my ($self, %arg) = @_;
    
    CHECK_PARAMS: { # check dei parametri necessari
        $self->_raise_error(sprintf("\nE- [SQLite] undef DB handle\n\t"))
            unless ($arg{'dbh'});
        
        $self->set_table_name($arg{'table'})
            if ($arg{'table'});
        
        $self->_raise_error(sprintf("\nE- [SQLite] undef table name\n\t"))
            unless ($self->get_table_name);
        
        $self->_raise_error(sprintf("\nE- [SQLite] undef arguments for the new table\n\t"))
            unless ( $arg{'args'} );
    };
    
    # printf ("\nI- creating table [%s.%s]...", $self->get_database, $self->get_table_name);
    
    my $dbh = $arg{'dbh'};
    my $table_name = $self->get_table_name;
    
    # cancello eventuali tabelle pre-esistenti con lo stesso nome
    $dbh->do("DROP TABLE IF EXISTS `$table_name`")
        or $self->_raise_error(sprintf("\nE- [SQLite] statement handle error [%s]\n\t", $dbh->errstr));
    
    # allestimento della query
    my $query_string = "CREATE TABLE IF NOT EXISTS `$table_name` ( $arg{'args'} )";
    
    # eseguo la query
    $self->set_query_string($query_string);
    my $sth = $self->query_exec('dbh' => $dbh);
    $sth->finish;
    
    # print "done";
    
    return $query_string;
}

# esegue una query, richiede un database handle già predefinito <$dbh>. Ritorna uno statement handle <$sth>
sub query_exec {
    my ($self, %arg) = @_;
    
    CHECK_PARAMS: { # check dei parametri necessari
        $self->_raise_error(sprintf("\nE- [SQLite] undef DB handle\n\t"))
            unless ($arg{'dbh'});
            
        $self->set_query_string($arg{'query'}) if ($arg{'query'});
        
        $self->_raise_error(sprintf("\nE- [SQLite] undef query\n\t"))
            unless ($self->get_query_string);
    };

    my $dbh = $arg{'dbh'};

    # preparazione query
    # printf ("I- exec query on DB <%s>...\n\t\"%s\"", $self->get_database,$self->get_query_string) if ($arg{'verbose'});
    
    my $sth = $dbh->prepare($self->get_query_string())
        or $self->_raise_error(sprintf("\nE- [SQLite] statement handle error [%s]\n\t", $dbh->errstr));
        
    if ($arg{bindings}) { # se ci sono bind values li aggiungo
#         print "\n-- binding values:\n\t@$bind_values";
        $sth->execute(@{$arg{'bindings'}})
            or $self->_raise_error(sprintf("\nE- [SQLite] statement handle error [%s]\n\t", $sth->errstr));
    } else {
        $sth->execute()
            or $self->_raise_error(sprintf("\nE- [SQLite] statement handle error [%s]\n\t", $sth->errstr));
    }
    return $sth;
}


# salva i dati estratti da una query su un file CSV
sub query2csv {
    my ($self, %arg) = @_;

    CHECK_PARAMS: { # check dei parametri necessari
        $self->_raise_error(sprintf("\nE- [SQLite] undef DB handle\n\t"))
            unless ($arg{'dbh'});
        
        $self->set_csv_file($arg{'file'})
            if ($arg{'file'});
        
        $self->_raise_error(sprintf("\nE- [SQLite] undef CSV file\n\t"))
            unless ($self->get_csv_file);
        
        
    };
    
    # printf ("\nI- creating file [%s]...", $self->get_csv_file);
    
    my $dbh = $arg{'dbh'};

    # esecuzione query
    my $sth;
    if ($arg{'bindings'}) {
        $sth = $self->query_exec('dbh' => $dbh, 'bindings' => $arg{'bindings'});
    } else {
        $sth = $self->query_exec('dbh' => $dbh);
    };

    my ($row_number, $single_data);
    my $file_content = [ ];

    # fetching dal DB
    while (my @ref_row = $sth->fetchrow_array()) {
        $row_number++;
        @ref_row = map { $_='NULL' unless $_ } @ref_row;
        $single_data = join(';', @ref_row) . ";";
        # print "[$row_number] $single_data\n";
        push(@$file_content, $single_data);
    };

    $sth->finish(); # chiudo lo statement

    # scrittura su file
    my $file_obj = QUEST::lib::FileIO->new();
    unshift(@$file_content, $arg{'header'}) if ($arg{'header'}); #aggiungo un header se c'è
    @$file_content = map("$_\n" , @$file_content);
    # print "\n-- @file_content";
    $file_obj->write('filedata' => $file_content, 'filename' => $self->get_csv_file);
    #  print "done [$row_number voci copiate]";

    # print "done";
}


1;

=head1 QUEST::lib::SQLite

SQLite - classe generica per la gestione di database

=head1 SYNOPSIS

    use QUEST::lib::SQLite;
    
    # instanzio un nuovo oggetto
    my $obj = QUEST::lib::SQLite->new('user' => 'foo', 'password' => 'barbaz');
    
    # accedo al DB
    my $dbh = $obj->access2db('database' => 'sparta');
    
    # creo una nuova tabella definendo campi e indici
    my $args = "`species` varchar(255) NOT NULL DEFAULT '', `ID` float(10,3) NOT NULL DEFAULT '0',  `start` int(10) NOT NULL DEFAULT '0', `end` int(10) NOT NULL DEFAULT '0'";
    $obj->new_table(
        'dbh' => $dbh,
        'table' => 'tabella',
        'args' => $args,
    );
    
    # eseguo una query con binding values
    my $query = "SELECT species, ID, FROM tabella WHERE (species LIKE ?)";
    my $bind_values = ['homosapiens'];
    my $sth = $obj->query_exec('dbh' => $dbh, 'query' => $query, 'bindings' => $bind_values);
    
    # salvo il risultato su un file CSV
    $dbm->query2csv('dbh' => $dbh, 'query' => $query, 'bindings' => $bind_values, 'file' => "TABELLA.csv",);
    
    
    # mi disconnetto
    $dbh->disconnect;
    printf ("\nI- connection [%s@%s] closed", $obj->get_user, $obj->get_host);



=head1 METHODS

=head2 access2db([database => $string, user => $string, password => $string])
    
    Fornisce l'accesso a un database esistente. Ritorna un database handle $dbh.
    
    DEFAULTS:
        database    => $self->get_database
        user        => $self->get_user
        password    => $self->get_password
    

=head2 new_table(dbh => $dbh, [table => $string, args => $string, keys => $string])
    
    Crea una nuova tabella su un database esistente. Richiede in input un database
    handle (v. metodo access2db). Ritorna una stringa con la query usata per creare
    la tabella.
    ATTENZIONE: se esiste gia' una tabella con lo stesso nome verra' sovrascritta.
    
    I parametri opzionali args e key definiscono i campi e gli indici della nuova
    tabella (v. SYNOPSIS per la sintassi).
    ATTENZIONE: per ogni tabella creata con questo metodo viene creato in automatico
    un campo 'acc' autoincrementale, definito come chiave primaria.
    
    DEFAULTS:
        table   => $self->get_table_name
        args    => ''
        keys    => ''
    

=head2 query2csv(dbh => $dbh, [file => $string, header => $string, query => $string, bindings => $arrayref])

    Salva il risultato di una query su un file in formato CSV. Richiede in input
    un database handle (v. metodo access2db).
    
    Aggiunge una riga di header al file se specificato il parametro header.

    Se lo statement della query contiene dei binding values questi possono
    venire specificati come in un array di valori definito da bindings.
    
    DEFAULTS:
        bindings    => [ ]
        file        => $self->get_csv_file
        header      => ''
        query       => $self->get_query_string
        

=head2 query_exec(dbh => $dbh, [query => $string, bindings => $arrayref, verbose => 1])

    Esegue una query. Richiede in input un database handle (v. metodo access2db).
    Ritorna uno statement handle, $sth.
    
    Il parametro opzionale bindings consente di accoppiare dei binding values alla
    stringa della query (v. SYNOPSIS per la sintassi).
    
    Il parametro opzionale verbose visualizza sullo STDOUT la query lanciata.
    
    DEFAULTS:
        bindings    => [ ]
        query       => $self->get_query_string
        verbose     => 0


=head1 UPDATES

=head2 2009-dec-23

    * implementazione metodo query2csv

=head2 2010-jan-07

    * patch metodo query2csv integrandovi il metodo query_exec
    * implementazione metodo query_exec

=head2 2010-feb-26

    * patch metodo query_exec; aggiunta del parametro verbose
    per notificare a video la query eseguita

=head2 2011-dec-14

    * ridefinizione dei metodi esistenti
    * metodo new_database per la creazione di nuovi DB

=head2 2011-dec-19

    * metodo db_dump

=cut

