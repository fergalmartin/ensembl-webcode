package EnsEMBL::Web::Factory::Search;
use strict;
use base qw(EnsEMBL::Web::Factory);

#########################################################################
# Simple text-based MySQL search (UniSearch) - default unless overridden
#########################################################################

sub createObjects { 
  my $self       = shift;    
  my $idx      = $self->param('type') || $self->param('idx') || 'all';
  ## Action search...
  my $search_method = "search_".uc($idx);
  if( $self->param('q') ) {
    if( $self->can($search_method) ) {
      $self->{to_return} = 30;
      $self->{_result_count} = 0;
      $self->{_results}      = [];
      $self->$search_method();
      $self->DataObjects($self->new_object( 'Search', { 'idx' => $idx , 'q' => $self->param('q'), 'results' => $self->{results} }, $self->__data ));
    } else {
      $self->problem( 'fatal', 'Unknown search method', qq(
      <p>
        Sorry do not know how to search for features of type "$idx"
      </p>) );
    }
  } else {
    $self->DataObjects($self->new_object( 'Search', { 'idx' => $idx , 'q' => '', 'results' => {} }, $self->__data ));
  }

}

sub terms {
  my $self = shift;
  my @list = ();
  foreach my $kw ( split /\s+/, join ' ',$self->param('q') ) {
    my $seq = $kw =~ s/\*+$/%/ ? 'like' : '=';
    push @list, [ $seq, $kw ];
  }
  return @list;
}

sub count {
  my( $self, $db, $sql, $comp, $kw ) = @_;

  my $dbh = $self->database($db);
  return 0 unless $dbh;
  my $full_kw = $kw; 
  $full_kw =~ s/\%/\*/g; 
  $kw = $dbh->dbc->db_handle->quote($kw);
  (my $t = $sql ) =~ s/'\[\[KEY\]\]'/$kw/g;
               $t =~ s/\[\[COMP\]\]/$comp/g;
               $t =~ s/\[\[FULLTEXTKEY\]\]/$full_kw/g; # Eagle extra regexp as we can have ' ' around our search term using full text search 
  #my( $res ) = $dbh->db_handle->selectrow_array( $t );
  my( $res ) = $dbh->dbc->db_handle->selectrow_array( $t );
  # check which database we are connected to here!! 
  my @check = $dbh->dbc->db_handle->selectrow_array( "select database()" );

  return $res;
}

sub _fetch {
  my( $self, $db, $search_SQL, $comparator, $kw, $limit ) = @_;
  my $dbh = $self->database( $db );
  return unless $dbh;
  my $full_kw = $kw; 
  $full_kw =~ s/\%/\*/g; 
  $kw = $dbh->dbc->db_handle->quote($kw);
  (my $t = $search_SQL ) =~ s/'\[\[KEY\]\]'/$kw/g;
  $t =~ s/\[\[COMP\]\]/$comparator/g;
  $t =~ s/\[\[FULLTEXTKEY\]\]/$full_kw/g;
  #my $res = $dbh->db_handle->selectall_arrayref( "$t limit $limit" );
  my $res = $dbh->dbc->db_handle->selectall_arrayref( "$t limit $limit" );
  push @{$self->{_results}}, @$res;
}

sub search_ALL {
  my( $self, $species ) = @_;
  my $package_space = __PACKAGE__.'::';

  no strict 'refs';
  # This gets all the methods in this package ( begining with search and excluding search_all ) 
  my @methods = map { /(search_\w+)/ && $1 ne 'search_ALL' ? $1 : () } keys %$package_space;

   ## Filter by configured indices
  my $SD = EnsEMBL::Web::SpeciesDefs->new();
  
  # These are the methods for the current species that we want to try and run
  my @idxs = @{$SD->ENSEMBL_SEARCH_IDXS};

  # valid methods will contain the methods that we want to run and that are contained in this package
  my @valid_methods;

  if (scalar(@idxs) > 0) {
    foreach my $m (@methods) {
      (my $index = $m) =~ s/search_//;
      foreach my $i (@idxs) {
        if (lc($index) eq lc($i)) {
          push @valid_methods, $m;
          last;
        }
      }
    }
  }
  else {
    @valid_methods = @methods;
  }

  my @ALL = ();
  
  foreach my $method (@valid_methods) {
    $self->{_result_count} = 0;
    $self->{_results}      = [];
    $self->{to_return} = 10;
    if( $self->can($method) ) {
      $self->$method;
    }
  }
  return @ALL;
}

sub _fetch_results {
  my $self = shift;
  my @terms = $self->terms();
  
  foreach my $query (@_) {
    my( $db, $subtype, $count_SQL, $search_SQL ) = @$query;
    
    foreach my $term (@terms ) {
	my $count_new = $self->count( $db, $count_SQL, $term->[0], $term->[1] );
      if( $count_new ) {
        if( $self->{to_return} > 0) {
          my $limit = $self->{to_return} < $count_new ? $self->{to_return} : $count_new; 
          $self->_fetch( $db, $search_SQL, $term->[0], $term->[1], $limit );
          $self->{to_return} -= $count_new;
        }
        $self->{'_result_count'} += $count_new;
      }
    }
  }

}

sub search_SNP {
  my $self = shift;
  my $species = $self->species;
  my $species_path = $self->species_path;
  
  $self->_fetch_results(
   [ 'variation' , 'SNP',
     "select count(*) from variation as v where name = '[[KEY]]'",
   "select s.name as source, v.name
      from source as s, variation as v
     where s.source_id = v.source_id and v.name = '[[KEY]]'" ],
   [ 'variation', 'SNP',
     "select count(*) from variation as v, variation_synonym as vs
       where v.variation_id = vs.variation_id and vs.name = '[[KEY]]'",
   "select s.name as source, v.name
      from source as s, variation as v, variation_synonym as vs
     where s.source_id = v.source_id and v.variation_id = vs.variation_id and vs.name = '[[KEY]]'"
  ]);
  
  foreach ( @{$self->{_results}} ) {
    $_ = {
      'idx'     => 'SNP', 
      'subtype' => "$_->[0] SNP",
      'ID'      => $_->[1],
#      'URL'     => "$species_path/snpview?source=$_->[0];snp=$_->[1]",
      'URL'     => "$species_path/Variation/Summary?source=$_->[0];v=$_->[1]", # v58 link format
      'desc'    => '',
      'species' => $species
    };
  }
  $self->{'results'}{'SNP'} = [ $self->{_results}, $self->{_result_count} ];
}

sub search_GENOMICALIGNMENT {
  my $self = shift;
  my $species = $self->species;
  my $species_path = $self->species_path;
  
  $self->_fetch_results(
    [
      'core', 'DNA',
      "select count(distinct analysis_id, hit_name) from dna_align_feature where hit_name [[COMP]] '[[KEY]]'",
      "select a.logic_name, f.hit_name, 'Dna', 'core',count(*)  from dna_align_feature as f, analysis as a where a.analysis_id = f.analysis_id and f.hit_name [[COMP]] '[[KEY]]' group by a.logic_name, f.hit_name"
    ],
    [
      'core', 'Protein',
      "select count(distinct analysis_id, hit_name) from protein_align_feature where hit_name [[COMP]] '[[KEY]]'",
      "select a.logic_name, f.hit_name, 'Protein', 'core',count(*) from protein_align_feature as f, analysis as a where a.analysis_id = f.analysis_id and f.hit_name [[COMP]] '[[KEY]]' group by a.logic_name, f.hit_name"
    ],
    [
      'vega', 'DNA',
      "select count(distinct analysis_id, hit_name) from dna_align_feature where hit_name [[COMP]] '[[KEY]]'",
      "select a.logic_name, f.hit_name, 'Dna', 'vega', count(*) from dna_align_feature as f, analysis as a where a.analysis_id = f.analysis_id and f.hit_name [[COMP]] '[[KEY]]' group by a.logic_name, f.hit_name"
    ],
    [
      'est', 'DNA',
      "select count(distinct analysis_id, hit_name) from dna_align_feature where hit_name [[COMP]] '[[KEY]]'",
      "select a.logic_name, f.hit_name, 'Dna', 'est', count(*) from dna_align_feature as f, analysis as a where a.analysis_id = f.analysis_id and f.hit_name [[COMP]] '[[KEY]]' group by a.logic_name, f.hit_name"
    ]
  );
  foreach ( @{$self->{_results}} ) {
    $_ = {
      'idx'     => 'GenomicAlignment',
      'subtype' => "$_->[0] $_->[2] alignment feature",
      'ID'      => $_->[1],
      'URL'     => "$species_path/Location/Genome?ftype=$_->[2]AlignFeature;db=$_->[3];id=$_->[1]", # v58 format
      'desc'    => "This $_->[2] alignment feature hits the genome in $_->[4] place(s).",
      'species' => $species
    };
  }
# Eagle change, this should really match the value in the Species DEFs file, ie. GenomicAlignment not GenomicAlignments
# + the others are all singular so keep this consistent
  $self->{'results'}{'GenomicAlignment'} = [ $self->{_results}, $self->{_result_count} ];
#  $self->{'results'}{'GenomicAlignments'} = [ $self->{_results}, $self->{_result_count} ];
}

sub search_DOMAIN {
  my $self = shift;
  my $species = $self->species;
  my $species_path = $self->species_path;
  
  $self->_fetch_results(
    [ 'core', 'Domain',
      "select count(*) from xref as x, external_db as e 
        where e.external_db_id = x.external_db_id and e.db_name = 'Interpro' and x.dbprimary_acc [[COMP]] '[[KEY]]'", # Eagle change, added Interpro to the count too 
      "select x.dbprimary_acc, x.description
         FROM xref as x, external_db as e
        WHERE e.db_name = 'Interpro' and e.external_db_id = x.external_db_id and
              x.dbprimary_acc [[COMP]] '[[KEY]]'" ],
    [ 'core', 'Domain',
      "select count(*) from xref as x, external_db as e 
        where e.external_db_id = x.external_db_id and e.db_name = 'Interpro' and x.description [[COMP]] '[[KEY]]'",# Eagle change, added Interpro to the count too, changed dbprimary_acc to x.description to match search
                                                                                                                   ## The description search will only find the word if its at the begining of the line, so not very good. 
      "SELECT x.dbprimary_acc, x.description                                       
         FROM xref as x, external_db as e
        WHERE e.db_name = 'Interpro' and e.external_db_id = x.external_db_id and
              x.description [[COMP]] '[[KEY]]'" ],
  );
  foreach ( @{$self->{_results}} ) {
    $_ = {
#      'URL'       => "$species_path/domainview?domain=$_->[0]",
      'URL'       => "$species_path/Location/Genome?ftype=Domain;id=$_->[0]", # updated to current ( v58 ) link format
      'idx'       => 'Domain',
      'subtype'   => 'Domain',
      'ID'        => $_->[0],
      'desc'      => $_->[1],
      'species'   => $species
    };
  }
  $self->{'results'}{'Domain'} = [ $self->{_results}, $self->{_result_count} ];
}

sub search_FAMILY {
  my( $self, $species ) = @_;
  my $species = $self->species;
  my $species_path = $self->species_path;
  
  $self->_fetch_results(
    [ 'compara', 'Family',
      "select count(*) from family where stable_id [[COMP]] '[[KEY]]'",
      "select stable_id, description FROM family WHERE stable_id  [[COMP]] '[[KEY]]'" ],
    [ 'compara', 'Family',
      "select count(*) from family where description [[COMP]] '[[KEY]]'",
      "select stable_id, description FROM family WHERE description [[COMP]] '[[KEY]]'" ] );
  foreach ( @{$self->{_results}} ) {
    $_ = {
#      'URL'       => "$species_path/familyview?family=$_->[0]",
      'URL'       => "$species_path/Gene/Family/Genes?family=$_->[0]", # Updated to current ( v58 ) link format
      'idx'       => 'Family',
      'subtype'   => 'Family',
      'ID'        => $_->[0],
      'desc'      => $_->[1],
      'species'   => $species
    };
  }
  $self->{'results'}{ 'Family' }  = [ $self->{_results}, $self->{_result_count} ];
}


sub search_SEQUENCE {
  my $self = shift;
  my $dbh = $self->database('core');
  return unless $dbh;  
  
  my $species = $self->species;
  my $species_path = $self->species_path;
  
  $self->_fetch_results( 
    [ 'core', 'Sequence',
      "select count(*) from seq_region where name [[COMP]] '[[KEY]]'",
      "select sr.name, cs.name, 1, length, sr.seq_region_id from seq_region as sr, coord_system as cs where cs.coord_system_id = sr.coord_system_id and sr.name [[COMP]] '[[KEY]]'" ],
    [ 'core', 'Sequence',
      "select count(distinct misc_feature_id) from misc_attrib join attrib_type as at using(attrib_type_id) where at.code in ( 'name','clone_name','embl_acc','synonym','sanger_project') 
       and value [[COMP]] '[[KEY]]'", # Eagle change, added at.code in count so that it matches the number of results in the actual search query below. 
      "select ma.value, group_concat( distinct ms.name ), seq_region_start, seq_region_end, seq_region_id
         from misc_set as ms, misc_feature_misc_set as mfms,
              misc_feature as mf, misc_attrib as ma, 
              attrib_type as at,
              (
                select distinct ma2.misc_feature_id
                  from misc_attrib as ma2, attrib_type as at2
                 where ma2.attrib_type_id = at2.attrib_type_id and
                       at2.code in ('name','clone_name','embl_acc','synonym','sanger_project') and
                       ma2.value [[COMP]] '[[KEY]]'
              ) as tt
        where ma.misc_feature_id   = mf.misc_feature_id and 
              mfms.misc_feature_id = mf.misc_feature_id and
              mfms.misc_set_id     = ms.misc_set_id     and
              ma.misc_feature_id   = tt.misc_feature_id and
              ma.attrib_type_id    = at.attrib_type_id  and
              at.code in ('name','clone_name','embl_acc','synonym','sanger_project')
        group by mf.misc_feature_id" ]
  );


  my $sa = $dbh->get_SliceAdaptor(); 

  foreach ( @{$self->{_results}} ) {
    my $KEY =  $_->[2] < 1e6 ? 'contigview' : 'cytoview';
    $KEY = 'cytoview' if $self->species_defs->NO_SEQUENCE;
    # The new link format is usually 'r=chr_name:start-end'
    my $slice = $sa->fetch_by_seq_region_id($_->[2], $_->[3], $_->[4] ); 

    $_ = {
#      'URL'       => (lc($_->[1]) eq 'chromosome' && length($_->[0])<10) ? "$species_path/mapview?chr=$_->[0]" :
#                        "$species_path/$KEY?$_->[3]=$_->[0]" ,
      'URL'       => "$species_path/Location/View?r=" . $slice->seq_region_name . ":" . $slice->start . "-" . $slice->end,   # v58 format
      'URL_extra' => [ 'Region overview', 'View region overview', "$species_path/Location/Overview?r=" . $slice->seq_region_name . ":" . $slice->start . "-" . $slice->end ],
      'idx'       => 'Sequence',
      'subtype'   => ucfirst( $_->[1] ),
      'ID'        => $_->[0],
      'desc'      => '',
      'species'   => $species
    };
  }
  $self->{'results'}{ 'Sequence' }  = [ $self->{_results}, $self->{_result_count} ]
}

sub search_OLIGOPROBE {
  my $self = shift;
  my $species = $self->species;
  my $species_path = $self->species_path;
  
  $self->_fetch_results(
    [ 'funcgen', 'OligoProbe',
      "select count(distinct name) from probe_set where name [[COMP]] '[[KEY]]'",
       "select ps.name, group_concat(distinct a.name order by a.name separator ' '), vendor from probe_set ps, array a, array_chip ac, probe p
     where ps.name [[COMP]] '[[KEY]]' AND a.array_id = ac.array_id AND ac.array_chip_id = p.array_chip_id AND p.probe_set_id = ps.probe_set_id group by ps.name"],
  );
  foreach ( @{$self->{_results}} ) {
    $_ = {
#      'URL'       => "$species_path/Location/Genome?ftype=OligoProbe;id=$_->[0]",
      'URL'       => "$species_path/Location/Genome?ftype=ProbeFeature;fdb=funcgen;ptype=pset;id=$_->[0]", # v58 format
      'idx'       => 'OligoProbe',
      'subtype'   => $_->[2] . ' Probe set',
      'ID'        => $_->[0],
      'desc'      => 'Is a member of the following arrays: '.$_->[1],
      'species'   => $species
    };
  }
  $self->{'results'}{ 'OligoProbe' }  = [ $self->{_results}, $self->{_result_count} ];
}

sub search_QTL {
  my $self = shift;
  my $species = $self->species;
  my $species_path = $self->species_path;
  
  $self->_fetch_results(
  [ 'core', 'QTL',
"select count(*)
  from qtl_feature as qf, qtl as q
 where q.qtl_id = qf.qtl_id and q.trait [[COMP]] '[[KEY]]'",
"select q.trait, concat( sr.name,':', qf.seq_region_start, '-', qf.seq_region_end ),
       qf.seq_region_end - qf.seq_region_start
  from seq_region as sr, qtl_feature as qf, qtl as q
 where q.qtl_id = qf.qtl_id and qf.seq_region_id = sr.seq_region_id and q.trait [[COMP]] '[[KEY]]'" ],
  [ 'core', 'QTL',
"select count(*)
  from qtl_feature as qf, qtl_synonym as qs ,qtl as q
 where qs.qtl_id = q.qtl_id and q.qtl_id = qf.qtl_id and qs.source_primary_id [[COMP]] '[[KEY]]'",
"select q.trait, concat( sr.name,':', qf.seq_region_start, '-', qf.seq_region_end ),
       qf.seq_region_end - qf.seq_region_start
  from seq_region as sr, qtl_feature as qf, qtl_synonym as qs ,qtl as q
 where qs.qtl_id = q.qtl_id and q.qtl_id = qf.qtl_id and qf.seq_region_id = sr.seq_region_id and qs.source_primary_id [[COMP]] '[[KEY]]'" ]
  );

  foreach ( @{$self->{_results}} ) {
    $_ = {
#      'URL'       => "$species_path/cytoview?l=$_->[1]",
      'URL'       => "$species_path/Location/View?r=$_->[1]", # Eagle change, updated link to v58 ensembl format
      'idx'       => 'QTL',
      'subtype'   => 'QTL',
      'ID'        => $_->[0],
      'desc'      => '',
      'species'   => $species
    };
  }
  $self->{'results'}{'QTL'} = [ $self->{_results}, $self->{_result_count} ];
}


sub search_MARKER {
  my $self = shift;
  my $species = $self->species;
  my $species_path = $self->species_path;
  
  $self->_fetch_results( 
    [ 'core', 'Marker',
      "select count(distinct name) from marker_synonym where name [[COMP]] '[[KEY]]'",
      "select distinct name from marker_synonym where name [[COMP]] '[[KEY]]'" ]
  );

  foreach ( @{$self->{_results}} ) {
    my $KEY =  $_->[2] < 1e6 ? 'contigview' : 'cytoview';
    $KEY = 'cytoview' if $self->species_defs->NO_SEQUENCE;
    $_ = {
#      'URL'       => "$species_path/markerview?marker=$_->[0]",
      'URL'       => "$species_path/Location/Marker?m=$_->[0]", # v58 format
#     'URL_extra' => [ 'C', 'View marker in ContigView', "$species_path/$KEY?marker=$_->[0]" ],
      'idx'       => 'Marker',
      'subtype'   => 'Marker',
      'ID'        => $_->[0],
      'desc'      => '',
      'species'   => $species
    };
  }
  $self->{'results'}{'Marker'} = [ $self->{_results}, $self->{_result_count} ];
}

sub search_GENE {
  my $self = shift;
  my $species = $self->species;
  my $species_path = $self->species_path;
  my @databases = ('core');
  push @databases, 'vega' if $self->species_defs->databases->{'DATABASE_VEGA'};
  push @databases, 'est' if $self->species_defs->databases->{'DATABASE_OTHERFEATURES'};
  foreach my $db (@databases) {
  $self->_fetch_results( 

      # Search Gene, Transcript, Translation stable ids.. 
    [ $db, 'Gene',
      "select count(*) from gene_stable_id WHERE stable_id [[COMP]] '[[KEY]]'",
      "SELECT gsi.stable_id, g.description, '$db', 'Gene', 'gene' FROM gene_stable_id as gsi, gene as g WHERE gsi.gene_id = g.gene_id and gsi.stable_id [[COMP]] '[[KEY]]'" ],
    [ $db, 'Gene',
      "select count(*) from transcript_stable_id WHERE stable_id [[COMP]] '[[KEY]]'",
      "SELECT gsi.stable_id, g.description, '$db', 'Transcript', 'transcript' FROM transcript_stable_id as gsi, transcript as g WHERE gsi.transcript_id = g.transcript_id and gsi.stable_id [[COMP]] '[[KEY]]'" ],
    [ $db, 'Gene',
      "select count(*) from translation_stable_id WHERE stable_id [[COMP]] '[[KEY]]'",
      "SELECT gsi.stable_id, x.description, '$db', 'Transcript', 'peptide' FROM translation_stable_id as gsi, translation as g, transcript as x WHERE g.transcript_id = x.transcript_id and gsi.translation_id = g.translation_id and gsi.stable_id [[COMP]] '[[KEY]]'" ],

      # search dbprimary_acc ( xref) of type 'Gene'
    [ $db, 'Gene',
      "select count( * ) from object_xref as ox, xref as x
        where ox.ensembl_object_type = 'Gene' and ox.xref_id = x.xref_id and x.dbprimary_acc [[COMP]] '[[KEY]]'",
      "SELECT gsi.stable_id, concat( display_label, ' - ', g.description ), '$db', 'Gene', 'gene' from gene_stable_id as gsi, gene as g, object_xref as ox, xref as x
        where gsi.gene_id = ox.ensembl_id and ox.ensembl_object_type = 'Gene' and gsi.gene_id = g.gene_id and
              ox.xref_id = x.xref_id and x.dbprimary_acc [[COMP]] '[[KEY]]'" ],
      # search display_label(xref) of type 'Gene' where NOT match dbprimary_acc !! - could these two statements be done better as one using 'OR' ?? !! 
      # Eagle change  - added 2 x distinct clauses to prevent returning duplicate stable ids caused by multiple xref entries for one gene
    [ $db, 'Gene',
      "select count( distinct(ensembl_id) ) from object_xref as ox, xref as x
        where ox.ensembl_object_type = 'Gene' and ox.xref_id = x.xref_id and
              x.display_label [[COMP]] '[[KEY]]' and not(x.dbprimary_acc [[COMP]] '[[KEY]]')",
      "SELECT distinct(gsi.stable_id), concat( display_label, ' - ', g.description ), '$db', 'Gene', 'gene' from gene_stable_id as gsi, gene as g, object_xref as ox, xref as x
        where gsi.gene_id = ox.ensembl_id and ox.ensembl_object_type = 'Gene' and gsi.gene_id = g.gene_id and
              ox.xref_id = x.xref_id and x.display_label [[COMP]] '[[KEY]]' and
              not(x.dbprimary_acc [[COMP]] '[[KEY]]')" ],

      # Eagle added this to search gene.description.  Could really do with an index on description field, but still works. 
      [ $db, 'Gene', 
      "SELECT count(distinct(g.gene_id)) from  gene as g, object_xref as ox, xref as x where g.gene_id = ox.ensembl_id and ox.ensembl_object_type = 'Gene' 
           and ox.xref_id = x.xref_id and match(g.description) against('+[[FULLTEXTKEY]]' IN BOOLEAN MODE) and not(x.display_label [[COMP]] '[[KEY]]' ) and not(x.dbprimary_acc [[COMP]] '[[KEY]]')",
      "SELECT distinct(gsi.stable_id), concat( display_label, ' - ', g.description ), 'core', 'Gene', 'gene' from gene_stable_id as gsi, gene as g, object_xref as ox, xref as x
         where gsi.gene_id = ox.ensembl_id and ox.ensembl_object_type = 'Gene' and gsi.gene_id = g.gene_id and ox.xref_id = x.xref_id 
         and match(g.description) against('+[[FULLTEXTKEY]]' IN BOOLEAN MODE) and not(x.display_label [[COMP]] '[[KEY]]' ) and not(x.dbprimary_acc [[COMP]] '[[KEY]]')" ],

      # Eagle added this to search external_synonym.  Could really do with an index on description field, but still works. 
      [ $db, 'Gene', 
      "SELECT count(distinct(g.gene_id)) from  gene as g, object_xref as ox, xref as x, external_synonym as es  where g.gene_id = ox.ensembl_id and ox.ensembl_object_type = 'Gene' 
           and ox.xref_id = x.xref_id and es.xref_id = x.xref_id and es.synonym [[COMP]] '[[KEY]]' and not(match(g.description) against('+[[FULLTEXTKEY]]' IN BOOLEAN MODE)) and not(x.display_label [[COMP]] '[[KEY]]' ) and not(x.dbprimary_acc [[COMP]] '[[KEY]]')",
      "SELECT distinct(gsi.stable_id), concat( display_label, ' - ', g.description ), 'core', 'Gene', 'gene' from gene_stable_id as gsi, gene as g, object_xref as ox, xref as x, external_synonym as es
         where gsi.gene_id = ox.ensembl_id and ox.ensembl_object_type = 'Gene' and gsi.gene_id = g.gene_id and ox.xref_id = x.xref_id  and es.xref_id = x.xref_id
         and es.synonym [[COMP]] '[[KEY]]' and not( match(g.description) against('+[[FULLTEXTKEY]]' IN BOOLEAN MODE)) and not(x.display_label [[COMP]] '[[KEY]]' ) and not(x.dbprimary_acc [[COMP]] '[[KEY]]')" ],


      # search dbprimary_acc ( xref) of type 'Transcript' - this could possibly be combined with Gene above if we return the object_xref.ensembl_object_type rather than the fixed 'Gene' or 'Transcript' 
      # to make things simpler and perhaps faster
    [ $db, 'Gene',
      "select count( * ) from object_xref as ox, xref as x
        where ox.ensembl_object_type = 'Transcript' and ox.xref_id = x.xref_id and x.dbprimary_acc [[COMP]] '[[KEY]]'",
      "SELECT gsi.stable_id, concat( display_label, ' - ', g.description ), '$db', 'Transcript', 'transcript' from transcript_stable_id as gsi, transcript as g, object_xref as ox, xref as x
        where gsi.transcript_id = ox.ensembl_id and ox.ensembl_object_type = 'Transcript' and gsi.transcript_id = g.transcript_id and
              ox.xref_id = x.xref_id and x.dbprimary_acc [[COMP]] '[[KEY]]'" ],
      # search display_label(xref) of type 'Transcript' where NOT match dbprimary_acc !! - could these two statements be done better as one using 'OR' ?? !! -- See also comment about combining with Genes above
    [ $db, 'Gene',
      "select count( distinct(ensembl_id) ) from object_xref as ox, xref as x
        where ox.ensembl_object_type = 'Transcript' and ox.xref_id = x.xref_id and
              x.display_label [[COMP]] '[[KEY]]' and not(x.dbprimary_acc [[COMP]] '[[KEY]]')",
      "SELECT distinct(gsi.stable_id), concat( display_label, ' - ', g.description ), '$db', 'Transcript', 'transcript' from transcript_stable_id as gsi, transcript as g, object_xref as ox, xref as x
        where gsi.transcript_id = ox.ensembl_id and ox.ensembl_object_type = 'Transcript' and gsi.transcript_id = g.transcript_id and
              ox.xref_id = x.xref_id and x.display_label [[COMP]] '[[KEY]]' and
              not(x.dbprimary_acc [[COMP]] '[[KEY]]')" ],


      ## Same again but for Translation - see above
    [ $db, 'Gene',
      "select count( * ) from object_xref as ox, xref as x
        where ox.ensembl_object_type = 'Translation' and ox.xref_id = x.xref_id and x.dbprimary_acc [[COMP]] '[[KEY]]'",
      "SELECT gsi.stable_id, concat( display_label ), '$db', 'Transcript', 'peptide' from translation_stable_id as gsi, object_xref as ox, xref as x
        where gsi.translation_id = ox.ensembl_id and ox.ensembl_object_type = 'Translation' and 
              ox.xref_id = x.xref_id and x.dbprimary_acc [[COMP]] '[[KEY]]'" ],
    [ $db, 'Gene',
      "select count( distinct(ensembl_id) ) from object_xref as ox, xref as x
        where ox.ensembl_object_type = 'Translation' and ox.xref_id = x.xref_id and
              x.display_label [[COMP]] '[[KEY]]' and not(x.dbprimary_acc [[COMP]] '[[KEY]]')",
      "SELECT distinct(gsi.stable_id), concat( display_label ), '$db', 'Transcript', 'peptide' from translation_stable_id as gsi, object_xref as ox, xref as x
        where gsi.translation_id = ox.ensembl_id and ox.ensembl_object_type = 'Translation' and 
              ox.xref_id = x.xref_id and x.display_label [[COMP]] '[[KEY]]' and
              not(x.dbprimary_acc [[COMP]] '[[KEY]]')" ]
  );
  }
  foreach ( @{$self->{_results}} ) {

      # $_->[0] - Ensembl ID/name
      # $_->[1] - description 
      # $_->[2] - db name 
      # $_->[3] - Page type, eg Gene/Transcript 
      # $_->[4] - Page type, eg gene/transcript

#    my $KEY =  $_->[2] < 1e6 ? 'contigview' : 'cytoview';
      my $KEY = 'Location'; 
      $KEY = 'cytoview' if $self->species_defs->NO_SEQUENCE;

      my $page_name_long = $_->[4]; 
      (my $page_name_short = $page_name_long )  =~ s/^(\w).*/$1/; # first letter only for short format. 

      my $summary = 'Summary';  # Summary is used in URL for Gene and Transcript pages, but not for protein
      $summary = 'ProteinSummary' if $page_name_short eq 'p'; 

    $_ = {
#      'URL'       => "$species_path/$_->[3]?db=$_->[2];$_->[4]=$_->[0]", # current ( v58 ) link format  
      'URL'       => "$species_path/$_->[3]/$summary?$page_name_short=$_->[0];db=$_->[2]",
#      'URL_extra' => [ 'C', 'View marker in ContigView', "$species_path/$KEY?db=$_->[2];$_->[4]=$_->[0]" ], # current ( v58 ) link format  
      'URL_extra' => [ 'Region in detail', 'View marker in LocationView', "$species_path/$KEY/View?$page_name_long=$_->[0];db=$_->[2]" ],
      'idx'       => 'Gene',
      'subtype'   => ucfirst($_->[4]),
      'ID'        => $_->[0],
      'desc'      => $_->[1],
      'species'   => $species
    };

  }
  $self->{'results'}{'Gene'} = [ $self->{_results}, $self->{_result_count} ];
}

## Result hash contains the following fields...
## 
## { 'URL' => ?, 'type' => ?, 'ID' => ?, 'desc' => ?, 'idx' => ?, 'species' => ?, 'subtype' =>, 'URL_extra' => [] }  
1;
