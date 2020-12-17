package QUEST::lib::FileIO;

# to make STDOUT flush immediately, simply set the variable
# this can be useful if you are writing to STDOUT in a loop
# many times the buffering will cause unexpected output results
$| =1;

use lib $ENV{HOME};

###################################################################
use Cwd;
use base ( 'QUEST::lib::Generic_class' ); # eredito la classe generica contenente il costruttore, l'AUTOLOAD ecc..
use Carp;
our $AUTOLOAD;

# Definizione degli attributi della classe
# chiave        -> nome dell'attributo
# valore [0]    -> valore di default
# valore [1]    -> permessi di accesso all'attributo
#                  (lettura, modifica...)
# STRUTTURA DATI
our %_attribute_properties = (
    _filename    => [ '',   'read.write.'],
    _filedata    => [ [ ],  'read.write.'],
);

# Unisco gli attributi della classe madre QUEST::lib::Generic_class e della classe figlia
my $ref = QUEST::lib::Generic_class::_hash_joiner(\%QUEST::lib::Generic_class::_attribute_properties, \%_attribute_properties);
%_attribute_properties = %$ref;


# apre il file, ritorna il FileHandle del file aperto
sub _openfile {
    my($self, $filename, $writemode) = @_;
    my $fh;
    # aggiunge una modalita' di accesso al file se specificata (>, >>, +> ...)
    $writemode and my $mode = $writemode . $filename;

    open($fh, $mode) or $self->_raise_error("\nE- [FileIO] unable to open <$filename>\n\t");
    return $fh;
}

# Cerca files contraddistinti da un pattern specifico e ritorna una lista di essi completa di path in un array
sub search_files {
    my ($self, %arg) = @_;

    $self->_raise_error("\nE- [FileIO] pattern not found\n\t")
        unless ($arg{pattern});

    my $workdir; # path in cui cercare i files (pwd di default)
    if (exists $arg{path}) {
        $workdir = $arg{path};
    } else {
        $workdir = getcwd;
    };

    # mi salvo in un array la lista di file presente nel path specificato
    my $dh;opendir ($dh, $workdir) or $self->_raise_error("\nE- [FileIO] path <$workdir> not found\n\t");
    my @all_file_list = readdir($dh);
    closedir $dh;

    # seleziono i file che mi interessano...
    my @selected_files = grep /$arg{pattern}/, @all_file_list;

    my $list = \@selected_files;
#     # aggiungo il path ad ogni file trovato
#     my $list = [ ];
#     foreach my $filename (@selected_files) {
#         push (@$list, $workdir . '/' . $filename);
#     }

    # ...e li ritorno come un refarray
    return $list;
}

# Cerca folders contraddistinte da un pattern specifico e ritorna una lista di essi completa di path in un array
sub search_dir {
    use Cwd;
    my ($self, %arg) = @_;

    $self->_raise_error("\nE- [FileIO] pattern not found\n\t")
        unless ($arg{pattern});

    my $workdir = $arg{pattern}; # path in cui cercare i files (pwd di default)

    # mi salvo in un array la lista di file presente nel path specificato
    my $dh;opendir ($dh, $workdir) or $self->_raise_error("\nE- [FileIO] path <$workdir> not found\n\t");
    my @all_file_list = readdir($dh);
    closedir $dh;

    chdir $workdir;
    # seleziono solo le directory...
    my $list = { };
    foreach my $elem (@all_file_list) {
        next if ($elem =~ m/^\.{1,2}$/); # rimuovo i path "." e ".."
        next unless ( -d $elem);
        $list->{$elem} = getcwd . "/$elem/";
    }
    # ...e li ritorno come un hashref
    return $list;
}

# Legge il file e ritorna un array con il contenuto
sub read {
   my ($self, $filename) = @_;
   
   $self->set_filename($filename) if $filename;

   my $fh = $self->_openfile($self->get_filename, '<');
   $self->set_filedata([ <$fh> ]);
   close $fh;
   return $self->get_filedata();
}

# Scrive su file
# Il contenuto da inserire nel file ($filedata) DEVE essere
# passato come REF di un ARRAY
#
# Se non vengono specificati argomenti scrive un file utilizzando gli
# attributi impostati per l'oggetto (_filename e _filedata)
sub write {
    my ($self, %arg) = @_;
    my $inputs = {
        filename    => $arg{'filename'}     || $self->get_filename(),
        filedata    => $arg{'filedata'}     || $self->get_filedata(),
    };
    
    
    # Definisce la modalità di scrittura sul file
    # di default è '>' (prima scrittura su un file nuovo, cancella
    # l'eventuale file esistente, anche se il metodo $self->_openfile
    # te lo chiede prima)
    my $write_mode = '>';
    $write_mode = $arg{'mode'} if $arg{'mode'};

    my $fh = $self->_openfile($inputs->{'filename'}, $write_mode);
    $self->set_filename($inputs->{'filename'});
    @{$inputs->{'filedata'}} and my @filedata = @{$inputs->{'filedata'}};
    $self->set_filedata($inputs->{'filedata'});
    print $fh @filedata;
    close $fh;
}

1;

=head1 QUEST::lib::FileIO

FileIO: classe per la gestione di files

=head1 Synopsis

    use QUEST::lib::FileIO;

    my $file_obj = QUEST::lib::FileIO->new();

    my $new_file_content = [
        "Oggi e\' proprio una bella giornata,\n",
        "quindi mi sento in vena di dire:\n\n",
        "\t\"CIAO MONDO!!!\"\n",
        ];

    # Aggiorno l'attributo _filedata con il contenuto di $new_file_content
    $file_obj->set_filedata($new_file_content);

    # Creo un nuovo file in cui riverso il contenuto dell'attributo _filedata
    $file_obj->write(filename => 'test_file.txt');

    # Leggo il file appena creato
    print @{$file_obj->read('test_file.txt')};


=head1 METHODS

=head2 read($nomefile)

    legge un file e ritorna un array-ref con il contenuto del file;
    $nomefile e' un argomento opzionale, modifica l'attributo _nomefile
    dell'oggetto.

=head2 write([filedata => \@contenutofile], [filename => $nomefile], [mode => '>','>>'])

    scrive su un file; i parametri opzionali <filedata> e <filename> modificano 
    gli attributi _nomefile e _filedata dell'oggetto. <mode> definisce la modalità 
    di scrittura sul file: '>' (default) cancella il file precedente e ne crea uno nuovo, 
    '>>' sovrascrive su un file esistente, altrimenti lo crea

=head2 search_files(pattern => $stringa, [path => $stringa])

    Cerca files contraddistinti da un pattern specifico e ritorna una
    lista di essi completa di path in un array_ref.
    Di default il percorso (path) in cui viene cercato il pattern e' pwd

=head2 search_dir(pattern => $stringa)

    Cerca folders contraddistinte da un pattern specifico e ritorna una
    lista di essi completa di path in un hash_ref (le chiavi sono i nomi
    delle directory, i valori il loro percorso assoluto)

=head1 UPDATES

=head2 2009-feb-4

    * aggiornamento del metodo <write>: aggiunta del parametro
      $arg{'mode'} x definire le modalità di scrittura


=head2 2009-jun-24

    * definizione del metodo search_files

=head2 2010-jan-08

    * definizione del metodo search_dir

=cut
