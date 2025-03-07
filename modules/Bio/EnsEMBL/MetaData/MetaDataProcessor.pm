
=head1 LICENSE

Copyright [1999-2020] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=head1 NAME

Bio::EnsEMBL::MetaData::MetaDataProcessor

=head1 SYNOPSIS

my $processor = Bio::EnsEMBL::MetaData::MetaDataProcessor->new();
my $info = $processor->process_core($core_dba);

=head1 DESCRIPTION

Object for generating GenomeInfo objects from DBAdaptor objects.

=head1 SEE ALSO

Bio::EnsEMBL::MetaData::BaseInfo
Bio::EnsEMBL::MetaData::DBSQL::GenomeOrganismInfoAdaptor

=head1 AUTHOR

Dan Staines

=cut

package Bio::EnsEMBL::MetaData::MetaDataProcessor;
use Bio::EnsEMBL::MetaData::GenomeInfo;
use Bio::EnsEMBL::MetaData::GenomeComparaInfo;
use Bio::EnsEMBL::MetaData::Base qw(get_division);
use Bio::EnsEMBL::Registry;
use Bio::EnsEMBL::Utils::Exception qw/throw warning/;
use Bio::EnsEMBL::Utils::Argument qw(rearrange);
use Data::Dumper;
use Log::Log4perl qw(get_logger);
use Carp qw/confess croak/;
use strict;
use warnings;

=head1 SUBROUTINES/METHODS

=head2 new
  Arg [-CONTIGS] : Integer
    Set to retrieve a list of sequences
  Arg [-ANNOTATION_ANALYZER] : Bio::EnsEMBL::MetaData::AnnotationAnalyzer
  Arg [-VARIATION] : Integer
    Set to process variation
  Arg [-COMPARA] : Integer
    Set to process compara
  Arg [-INFO_ADAPTOR] : Bio::EnsEMBL::MetaData::DBSQL::GenomeInfoAdaptor
  Arg [-FORCE_UPDATE] : Integer
    Set to force update of existing metadata
  Description: Return a new instance of MetaDataProcessor
  Returntype : Bio::EnsEMBL::MetaData::MetaDataProcessor
  Exceptions : none
  Caller     : general
  Status     : Stable
=cut

sub new {
  my ( $caller, @args ) = @_;
  my $class = ref($caller) || $caller;
  my $self = bless( {}, $class );
  ( $self->{contigs},      $self->{annotation_analyzer},
    $self->{variation},    $self->{compara},
    $self->{info_adaptor}, $self->{force_update},
    $self->{release},      $self->{eg_release} )
    = rearrange( [ 'CONTIGS',      'ANNOTATION_ANALYZER',
                   'VARIATION',    'COMPARA',
                   'INFO_ADAPTOR', 'FORCE_UPDATE' ],
                 @args );
  $self->{logger} = get_logger();
  return $self;
}

=head2 process_metadata
  Arg        : Arrayref of DBAdaptors
  Description: Process supplied DBAdaptors
  Returntype : Arrayref of Bio::EnsEMBL::MetaData::GenomeInfo
  Exceptions : none
  Caller     : general
  Status     : Stable
=cut

sub process_metadata {
  my ( $self, $dbas ) = @_;

  # 1. create hash of DBAs
  my $dba_hash = {};
  my $comparas = [];
  for my $dba ( grep { $_->dbc()->dbname() !~ /ancestral/ } @{$dbas} ) {
    my $type;
    my $species = $dba->species();
    for my $t (qw(core otherfeatures rnaseq cdna variation funcgen)) {
      if ( $dba->dbc()->dbname() =~ m/$t/ ) {
        $type = $t;
        last;
      }
    }
    if ( defined $type ) {
      $dba_hash->{$species}{$type} = $dba if defined $type;
    }
    elsif ( $dba->dbc()->dbname() =~ m/_compara_/ ) {
      push @$comparas, $dba;
    }
  }

  # 2. iterate through each genome
  my $genome_infos = {};
  my $n            = 0;
  my $total        = scalar( keys %$dba_hash );

  while ( my ( $genome, $dbas ) = each %$dba_hash ) {
    $self->{logger}->info( "Processing " . $genome . " (" . ++$n . "/$total)" );
    # 3. Process core database first
    if (exists $dbas->{'core'}){
      $genome_infos->{$genome} = $self->process_core($dbas->{'core'});
      delete $dbas->{'core'};
    }
    # 4. Process core like, variation and regulation databases
    while (my ($db_type, $dba) = each %$dbas){
      my $process_db_type_method = "process_".$db_type;
      $genome_infos->{$genome} = $self->$process_db_type_method($dba);
    }
  }

  # 5. apply compara
  for my $compara (@$comparas) {
    $self->process_compara( $compara, $genome_infos );
  }

  return [ values(%$genome_infos) ];
} ## end sub process_metadata

=head2 process_core
  Arg        : DBAdaptor
  Description: Process supplied genome core database
  Returntype : Bio::EnsEMBL::MetaData::GenomeInfo
  Exceptions : none
  Caller     : general
  Status     : Stable
=cut

sub process_core {
  my ( $self, $dba ) = @_;
  if ( !defined $dba ) {
    confess "DBA not defined for processing";
  }

  # get metadata container
  my $meta   = $dba->get_MetaContainer();
  my $dbname = $dba->dbc()->dbname();
  my $size   = get_dbsize($dba);
  my $tableN =
    $dba->dbc()->sql_helper()->execute_single_result(
        -SQL =>
          "select count(*) from information_schema.tables where table_schema=?",
        -PARAMS => [$dbname] );
  
  my $scientific_name = $meta->single_value_by_key('species.scientific_name');
  my $url_name        = $meta->single_value_by_key('species.url');
  my $display_name    = $meta->single_value_by_key('species.display_name');
  my $strain          = $meta->single_value_by_key('species.strain');
  my $serotype        = $meta->single_value_by_key('species.serotype');
  my $name            = $meta->get_display_name();
  my $taxonomy_id     = $meta->get_taxonomy_id();
  my ($species_taxonomy_id) =
    @{$meta->list_value_by_key('species.species_taxonomy_id')};
  $species_taxonomy_id ||= $taxonomy_id;
  my ($assembly_accession)= @{$meta->list_value_by_key('assembly.accession')};
  my $assembly_name      = $meta->single_value_by_key('assembly.name');
  my $assembly_default   = $meta->single_value_by_key('assembly.default');
  my ($assembly_ucsc)    = @{$meta->list_value_by_key('assembly.ucsc_alias')};
  my ($genebuild)        = @{$meta->list_value_by_key('genebuild.start_date')};
  my ($genebuild_version)= @{$meta->list_value_by_key('genebuild.version')};
  my ($genebuild_upd)    = @{$meta->list_value_by_key('genebuild.last_geneset_update')};
  
  my $gb_string = $genebuild_version;
  if(!defined $gb_string) {
  	$gb_string = $genebuild;
  	$gb_string .= "/".$genebuild_upd if defined $genebuild_upd;
  }

  # get highest assembly level
  my ($assembly_level) =
    @{
    $dba->dbc()->sql_helper()->execute_simple(
         -SQL =>
           'select name from coord_system where species_id=? order by rank asc',
         -PARAMS => [ $dba->species_id() ] ) };
  my $division  = 'EnsemblVertebrates';
  my @divisions = sort @{ $meta->list_value_by_key('species.division') };
  if ( scalar @divisions > 0 ) {
    $division = $divisions[-1];
  }
  my $md = Bio::EnsEMBL::MetaData::GenomeInfo->new(
                      -name                => $dba->species(),
                      -species_id          => $dba->species_id(),
                      -division            => $division,
                      -dbname              => $dbname,
                      -data_release        => $self->{info_adaptor}->data_release(),
                      -strain              => $strain,
                      -serotype            => $serotype,
                      -display_name        => $display_name,
                      -scientific_name     => $scientific_name,
                      -url_name            => $url_name,
                      -taxonomy_id         => $taxonomy_id,
                      -species_taxonomy_id => $species_taxonomy_id,
                      -assembly_accession  => $assembly_accession,
                      -assembly_name       => $assembly_name,
                      -assembly_default    => $assembly_default,
                      -assembly_ucsc       => $assembly_ucsc,
                      -genebuild           => $gb_string,
                      -assembly_level      => $assembly_level );

  # get list of seq names
  my $seqs_arr = [];

  if ( defined $self->{contigs} ) {
    my $seqs = {};

    # 1. get complete list of seq_regions as a hash vs. ENA synonyms
    $dba->dbc()->sql_helper()->execute_no_return(
      -SQL => q/select distinct s.name, ss.synonym 
	  from coord_system c  
	  join seq_region s using (coord_system_id)  
	  left join seq_region_synonym ss on 
	  	(ss.seq_region_id=s.seq_region_id and ss.external_db_id in 
	  		(select external_db_id from external_db where db_name='INSDC')) 
	  where c.species_id=? and attrib like '%default_version%'/,
      -PARAMS   => [ $dba->species_id() ],
      -CALLBACK => sub {
        my ( $name, $acc ) = @{ shift @_ };
        $seqs->{$name} = $acc;
        return;
      } );

    # 2. add accessions where the name is flagged as being in ENA
    $dba->dbc()->sql_helper()->execute_no_return(
      -SQL => q/
	  select s.name 
	  from coord_system c  
	  join seq_region s using (coord_system_id)  	  
	  join seq_region_attrib sa using (seq_region_id)  
	  where sa.value='ENA' and c.species_id=? and attrib like '%default_version%'/,
      -PARAMS   => [ $dba->species_id() ],
      -CALLBACK => sub {
        my ($acc) = @{ shift @_ };
        $seqs->{$acc} = $acc;
        return;
      } );

    while ( my ( $key, $acc ) = each %$seqs ) {
      push @$seqs_arr, { name => $key, acc => $acc };
    }
  } ## end if ( defined $self->{contigs...})

  $md->assembly()->sequences($seqs_arr);
  # get toplevel base count
  my $base_counts = $dba->dbc()->sql_helper()->execute_simple(
      -SQL => q/select sum(s.length) from seq_region s 
join coord_system c using (coord_system_id) 
join seq_region_attrib sa using (seq_region_id) 
join attrib_type a using (attrib_type_id) 
where a.code='toplevel' and species_id=?/,
      -PARAMS => [ $dba->species_id() ] );

  $md->assembly()->base_count( $base_counts->[0] );
  # get associated PMIDs
  $md->organism()->publications(
    $dba->dbc()->sql_helper()->execute_simple(
      -SQL => q/select distinct dbprimary_acc from 
	  xref
	  join external_db using (external_db_id)
	  join seq_region_attrib sa on (xref.xref_id=sa.value)
	  join attrib_type using (attrib_type_id)
	  join seq_region using (seq_region_id)
	  join coord_system using (coord_system_id)
	  where species_id=? and code='xref_id' and db_name in ('PUBMED')/,
      -PARAMS => [ $dba->species_id() ] ) );

  # add aliases
  $md->organism()->aliases(
    $dba->dbc()->sql_helper()->execute_simple(
      -SQL => q/select distinct meta_value from meta
	  where species_id=? and meta_key='species.alias'/,
      -PARAMS => [ $dba->species_id() ] ) );

  if ( defined $self->{annotation_analyzer} ) {

    # core annotation
    $self->{logger}
      ->info( "Processing " . $dba->species() . " core annotation" );
    $md->annotations( $self->{annotation_analyzer}->analyze_annotation($dba) );

    # BAM
    my $core_ali  = $self->{annotation_analyzer}->analyze_alignments($dba);
    $md->features( $self->{annotation_analyzer}->analyze_features($dba) );

    $self->{logger}
      ->info( "Processing " . $dba->species() . " read aligments" );
    my $read_ali =
      $self->{annotation_analyzer}
      ->analyze_tracks( $md->name(), $md->division() );
    my %all_ali = ( %{$core_ali} );

    # add bam tracks by count - use source name
    foreach my $key (keys %$read_ali){
      for my $bam ( @{ $read_ali->{$key} } ) {
        $all_ali{$key}{ $bam->{id} }++;
      }
    }
    $md->other_alignments( \%all_ali );
    $md->db_size($size);

  } ## end if ( defined $self->{annotation_analyzer...})
  return $md;
} ## end sub process_core

=head2 process_otherfeatures
  Arg        : DBAdaptor
  Description: Process supplied genome otherfeatures database
  Returntype : Bio::EnsEMBL::MetaData::GenomeInfo
  Exceptions : none
  Caller     : general
  Status     : Stable
=cut

sub process_otherfeatures {
  my ($self, $dba) = @_;
  if ( !defined $dba ) {
    confess "DBA not defined for processing";
  }
  my $size   = get_dbsize($dba);
  # features
  my $other_ali = {};
  my $gdba = $self->{info_adaptor};
  my $division = get_division($dba);
  my $mds=$gdba->fetch_by_name($dba->species());
  my $md;
  foreach my $genome (@{$mds}){
    $md = $genome if ($genome->division() eq $division);
  }
  $self->{logger}
    ->info( "Processing " . $dba->species() . " otherfeatures annotation" );
  my %features = ( %{ $md->features() },
                    %{$self->{annotation_analyzer}
                        ->analyze_features($dba) } );
  $other_ali =
    $self->{annotation_analyzer}->analyze_alignments($dba);
  $md->features( \%features );
  $md->add_database( $dba->dbc()->dbname() );
  if ( defined $self->{annotation_analyzer} ) {
    my %all_ali = ( %{$other_ali});
    $md->other_alignments( \%all_ali );
    $md->db_size($size);

  } ## end if ( defined $self->{annotation_analyzer...})
  return $md;
}

=head2 process_rnaseq
  Arg        : DBAdaptor
  Description: Process supplied genome rnaseq database
  Returntype : Bio::EnsEMBL::MetaData::GenomeInfo
  Exceptions : none
  Caller     : general
  Status     : Stable
=cut

sub process_rnaseq {
  my ($self, $dba) = @_;
  if ( !defined $dba ) {
    confess "DBA not defined for processing";
  }
  my $size   = get_dbsize($dba);
  # features
  my $rnaseq_ali = {};
  my $gdba = $self->{info_adaptor};
  my $division = get_division($dba);
  my $mds=$gdba->fetch_by_name($dba->species());
  my $md;
  foreach my $genome (@{$mds}){
    $md = $genome if ($genome->division() eq $division);
  }
  $self->{logger}
    ->info( "Processing " . $dba->species() . " rnaseq annotation" );
  my %features = ( %{ $md->features() },
                    %{$self->{annotation_analyzer}
                        ->analyze_features($dba) } );
  $rnaseq_ali =
    $self->{annotation_analyzer}->analyze_alignments($dba);
  $md->features( \%features );
  $md->add_database( $dba->dbc()->dbname() );
  if ( defined $self->{annotation_analyzer} ) {
    my %all_ali = ( %{$rnaseq_ali});
    $md->other_alignments( \%all_ali );
    $md->db_size($size);

  } ## end if ( defined $self->{annotation_analyzer...})
  return $md;
}

=head2 process_cdna
  Arg        : DBAdaptor
  Description: Process supplied genome cdna database
  Returntype : Bio::EnsEMBL::MetaData::GenomeInfo
  Exceptions : none
  Caller     : general
  Status     : Stable
=cut

sub process_cdna {
  my ($self, $dba) = @_;
  if ( !defined $dba ) {
    confess "DBA not defined for processing";
  }
  my $size   = get_dbsize($dba);
  # features
  my $cdna_ali = {};
  my $gdba = $self->{info_adaptor};
  my $division = get_division($dba);
  my $mds=$gdba->fetch_by_name($dba->species());
  my $md;
  foreach my $genome (@{$mds}){
    $md = $genome if ($genome->division() eq $division);
  }
  $self->{logger}
    ->info( "Processing " . $dba->species() . " cdna annotation" );
  my %features = ( %{ $md->features() },
                    %{$self->{annotation_analyzer}
                        ->analyze_features($dba) } );
  $cdna_ali = $self->{annotation_analyzer}->analyze_alignments($dba);
  $md->features( \%features );
  $md->add_database( $dba->dbc()->dbname() );
  if ( defined $self->{annotation_analyzer} ) {
    my %all_ali = ( %{$cdna_ali});
    $md->other_alignments( \%all_ali );
    $md->db_size($size);
  } ## end if ( defined $self->{annotation_analyzer...})
  return $md;
}

=head2 process_variation
  Arg        : DBAdaptor
  Description: Process supplied genome variation database
  Returntype : Bio::EnsEMBL::MetaData::GenomeInfo
  Exceptions : none
  Caller     : general
  Status     : Stable
=cut

sub process_variation {
  my ($self, $dba) = @_;
  if ( !defined $dba ) {
    confess "DBA not defined for processing";
  }
  my $size   = get_dbsize($dba);
  my $gdba = $self->{info_adaptor};
  my $division = get_division($dba);
  my $mds=$gdba->fetch_by_name($dba->species());
  my $md;
  foreach my $genome (@{$mds}){
    $md = $genome if ($genome->division() eq $division);
  }
  $self->{logger}
    ->info( "Processing " . $dba->species() . " variation annotation" );
  $md->variations(
              $self->{annotation_analyzer}->analyze_variation($dba) );
  $md->add_database( $dba->dbc()->dbname() );
  $md->db_size($size);
  return $md;
}

=head2 process_funcgen
  Arg        : DBAdaptor
  Description: Process supplied genome regulation database
  Returntype : Bio::EnsEMBL::MetaData::GenomeInfo
  Exceptions : none
  Caller     : general
  Status     : Stable
=cut

sub process_funcgen {
  my ($self, $dba) = @_;
  if ( !defined $dba ) {
    confess "DBA not defined for processing";
  }
  my $size   = get_dbsize($dba);
  my $gdba = $self->{info_adaptor};
  my $division = get_division($dba);
  my $mds=$gdba->fetch_by_name($dba->species());
  my $md;
  foreach my $genome (@{$mds}){
    $md = $genome if ($genome->division() eq $division);
  }
  $self->{logger}->info( "Processing " . $dba->species() . " regulation annotation" );
  $md->add_database( $dba->dbc()->dbname() );
  $md->db_size($size);
  return $md;
}

my $DIVISION_NAMES = { 'bacteria'     => 'EnsemblBacteria',
                       'plants'       => 'EnsemblPlants',
                       'protists'     => 'EnsemblProtists',
                       'fungi'        => 'EnsemblFungi',
                       'metazoa'      => 'EnsemblMetazoa',
                       'pan_homology' => 'EnsemblPan' };

=head2 process_compara
  Arg        : Bio::EnsEMBL::Compara::DBSQL::DBAdaptor
  Arg        : Arrayref of Bio::EnsEMBL::MetaData::GenomeInfo
  Description: Process supplied compara
  Returntype : Bio::EnsEMBL::MetaData::GenomeComparaInfo
  Exceptions : none
  Caller     : general
  Status     : Stable
=cut

sub process_compara {
  my ( $self, $compara, $genomes ) = @_;
  if ( !defined $genomes ) {
    $genomes = {};
  }
  my $comparas = [];
  eval {
    $self->{logger}
      ->info( "Processing compara database " . $compara->dbc()->dbname() );

    ( my $division = $compara->dbc()->dbname() ) =~
      s/ensembl_compara_([a-z_]+)_[0-9]+_[0-9]+/$1/;

    $division = $DIVISION_NAMES->{$division} || $division;

    if($division =~ m/ensembl_compara_[0-9]+/) {
      $division = 'EnsemblVertebrates';
    }

    my $adaptor = $compara->get_MethodLinkSpeciesSetAdaptor();

    for my $method (
      qw/PROTEIN_TREES BLASTZ_NET LASTZ_NET TRANSLATED_BLAT TRANSLATED_BLAT_NET SYNTENY FAMILY/
      )
    {

      $self->{logger}
        ->info( "Processing method type $method from compara database " .
                $compara->dbc()->dbname() );

      # group by species_set
      my $mlss_by_ss = {};
      for my $mlss ( @{ $adaptor->fetch_all_by_method_link_type($method) } ) {
        push @{ $mlss_by_ss->{ $mlss->species_set()->dbID() } }, $mlss;
      }

      for my $mlss_list ( values %$mlss_by_ss ) {

        my $dbs = {};
        my $ss_name;
        for my $mlss ( @{$mlss_list} ) {

          $ss_name ||= $mlss->species_set()->get_tagvalue('name');
          for my $gdb ( @{ $mlss->species_set()->genome_dbs() } ) {
            $dbs->{ $gdb->name() } = $gdb;
          }
          if ( !defined $ss_name ) {
            $ss_name = $mlss->name();
          }
          if ( defined $ss_name ) {
            last;
          }
        }

        $self->{logger}->info(
"Processing species set $ss_name for method $method from compara database "
            . $compara->dbc()->dbname() );

        my $compara_info =
          Bio::EnsEMBL::MetaData::GenomeComparaInfo->new(
                                           -DBNAME => $compara->dbc()->dbname(),
                                           -DIVISION => $division,
                                           -METHOD   => $method,
                                           -SET_NAME => $ss_name,
                                           -GENOMES  => [] );

        for my $gdb ( values %{$dbs} ) {

          $self->{logger}->info( "Processing species " . $gdb->name() .
" from species set $ss_name for method $method from compara database "
            . $compara->dbc()->dbname() );

          my $genomeInfo = $genomes->{ $gdb->name() };
          # have we got one in the database already?
          if ( !defined $genomeInfo && defined $self->{info_adaptor} ) {
            $self->{logger}->debug("Checking in the database");
            my $genomeInfos = $self->{info_adaptor}->fetch_by_name( $gdb->name() );
            foreach my $gen (@{$genomeInfos}){
              # Check for species common between Vert and non-vert, we want to use the non-vert for pan
              if ($gen->name() eq "caenorhabditis_elegans" or $gen->name() eq "drosophila_melanogaster" or $gen->name() eq "saccharomyces_cerevisiae"){
                if ($division eq "EnsemblPan" or $division eq "EnsemblPlants"){
                  if ($gen->division() ne "EnsemblVertebrates"){
                    $genomeInfo=$gen;
                  }
                }
                # Make sure species division match the compara division
                elsif ($gen->division() eq $division){
                  $genomeInfo=$gen;
                }
              }
              else{
                $genomeInfo=$gen;
              }
            }
          }
          if ( !defined $genomeInfo ) {
            my $current_release = $self->{info_adaptor}->data_release();
            if ( defined $current_release->ensembl_genomes_version() ) {
              # try the ensembl release
              my $ensembl_release =
                  $self->{info_adaptor}->db()->get_DataReleaseInfoAdaptor()
                  ->fetch_by_ensembl_release(
                                          $current_release->ensembl_version() );
              $self->{info_adaptor}->data_release($ensembl_release);
              my $genomeInfos = $self->{info_adaptor}->fetch_by_name( $gdb->name() );
              foreach my $gen (@{$genomeInfos}){
                # When using ensembl release we should only look at vertebrates
                if ($gen->division() eq "EnsemblVertebrates"){
                  $genomeInfo=$gen;
                }
                $self->{info_adaptor}->data_release($current_release);
              }
            }
            croak "Could not find genome info for " . $gdb->name() unless defined $genomeInfo;
            $self->{logger}->debug("Got one from the database");
            $genomes->{ $gdb->name() } = $genomeInfo;
          } ## end if ( !defined $genomeInfo...)

          push @{ $compara_info->genomes() }, $genomeInfo;

          if ( !defined $genomeInfo->compara() ) {
            $genomeInfo->compara( [$compara_info] );
          }
          else {
            push @{ $genomeInfo->compara() }, $compara_info;
          }
        } ## end for my $gdb ( values %{...})
        $self->{logger}
          ->info("Adding compara info to list of analyses to store");
        push @$comparas, $compara_info if defined $compara_info;
      } ## end for my $mlss_list ( values...)
    } ## end for my $method ( ...)

    $self->{logger}->info(
         "Completed processing compara database " . $compara->dbc()->dbname() );
  };    ## end eval
  if ($@) {
    die "Could not process compara: " . $@;
  }
  return $comparas;
} ## end sub process_compara

=head2 get_dbsize
  Arg        : DBAdaptor
  Description: Calculate size of supplied database
  Returntype : Long
  Exceptions : none
  Caller     : general
  Status     : Stable
=cut

sub get_dbsize {
  my ($dba) = @_;
  return
    $dba->dbc()->sql_helper()->execute_single_result(
    -SQL =>
"select SUM(data_length + index_length) from information_schema.tables where table_schema=?",
    -PARAMS => [ $dba->dbc()->dbname() ] );
}

1;
