=head1 LICENSE

Copyright [1999-2014] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package EnsEMBL::Web::Component::Gene;

use strict;

use EnsEMBL::Web::TmpFile::Text;
use EnsEMBL::Web::Tools::RandomString qw(random_ticket);

use base qw(EnsEMBL::Web::Component::Shared);

sub draw_structure {
  my ($self, $display_name, $is_thumbnail) = @_;
  my $html = '';

  ## We want to control where the temp files go, otherwise R2R screws up the image captions!
  my $random_dir  = random_ticket;

  my $img_dir   = sprintf('%s/r2r/%s', 
                              $self->hub->species_defs->ENSEMBL_TMP_DIR_IMG,
                              $random_dir);
  my $name      = $display_name.'-'.$self->hub->param('g');
  my $filename  = $name.($is_thumbnail ? '-thumbnail' : '').'.svg';
  my $svg_path  = $img_dir.'/'.$filename;

  unless (-e $svg_path) { 
    $self->make_directory($img_dir);
    my $database = $self->hub->database('compara');

    my ($found_compara, $found_core, $aln_array, $transcript_stable_id, $model_name, $ss_cons);

    # Let's try to get the secondary structure from the Compara database
    ($found_compara, $aln_array, $transcript_stable_id, $model_name, $ss_cons) = $self->find_ss_in_compara($database) if $database;

    # Or from Core
    ($found_core, $aln_array, $transcript_stable_id, $model_name, $ss_cons) = $self->find_ss_in_core() unless $found_compara;

    # Here, we can do the drawing
    if ($found_compara or $found_core) {
      my $aln_file    = $self->_dump_multiple_alignment($aln_array, $random_dir, $model_name, $ss_cons);
      my ($thumbnail, $plot) = $self->_draw_structure($aln_file, $transcript_stable_id, $random_dir, $img_dir, $model_name, $found_compara ? 1 : 0);
      $filename = $is_thumbnail ? $thumbnail : $plot;
      $svg_path = $img_dir.'/'.$filename;
    }
  }
  return $svg_path;
}

sub find_ss_in_compara {
    my ($self, $database) = @_;

    my $gma = $database->get_GeneMemberAdaptor();
    my $gta = $database->get_GeneTreeAdaptor();

    my $member = $gma->fetch_by_source_stable_id(undef, $self->object->stable_id);
    if ($member and $member->has_GeneTree) {
      my $transcript = $member->get_canonical_SeqMember();
      my $gene_tree  = $gta->fetch_default_for_Member($member);
      if ($gene_tree) {
        my $model_name = $gene_tree->get_tagvalue('model_name');
        my $ss_cons    = $gene_tree->get_tagvalue('ss_cons');
        if ($ss_cons) {
          my $input_aln = $gene_tree->get_SimpleAlign();
          my @aln_array = map {[$_->display_id, $_->seq]} $input_aln->each_seq;
          return (1, \@aln_array, $transcript->stable_id, $model_name, $ss_cons);
        }
      }
    }
    return (0);
}

sub find_ss_in_core {
    my ($self) = @_;
    my $gene        = $self->object->gene;
    my $transcript  = $gene->canonical_transcript;
    if ($transcript) {
      my $model_name  = $gene->display_xref->display_id;
      my $ss_attr     = $transcript->get_all_Attributes('ncRNA');
      if ($ss_attr and scalar(@$ss_attr)) {
        my $ss_cons = $ss_attr->[0]->value;
           $ss_cons =~ s/^.*\t//;
           $ss_cons =~ s/([().])(\d+)/$1 x $2/ge; #Expand
        my $seq     = $transcript->spliced_seq;
        if (length($seq) == length($ss_cons)) {
          my @aln_array = ([$transcript->stable_id, $seq]);
          return (1, [[$transcript->stable_id, $seq]], $transcript->stable_id, $model_name, $ss_cons);
        }
      }
    }
    return (0);
}

sub _dump_multiple_alignment {
    my ($self, $aln_array, $random_dir, $model_name, $ss_cons) = @_;
    if ($ss_cons =~ /^\.+$/) {
      warn "The tree has no structure\n";
      return undef;
    }

    my $aln_file  = EnsEMBL::Web::TmpFile::Text->new(
                        prefix        => "r2r/$random_dir",
                        filename      => $model_name,
                        extension     => ".aln",
                    );

    my $content = "# STOCKHOLM 1.0\n";
    for my $aln_seq (@$aln_array) {
      $content .= sprintf ("%-20s %s\n", @$aln_seq);
    }
    $content .= sprintf ("%-20s\n", "#=GF R2R keep allpairs");
    $content .= sprintf ("%-20s %s\n//\n", "#=GC SS_cons", $ss_cons);

    $aln_file->print($content);
    return $aln_file;
}



sub _draw_structure {
    my ($self, $aln_file, $peptide_id, $random_dir, $img_path, $model_name, $with_consensus_structure) = @_;

    ## Get random directory name being used by meta files
    (my $meta_path  = $aln_file->{'full_path'}) =~ s/\/$model_name\.aln//;

    my $cons_filename  = $model_name.'.cons';
    ## For information about these options, check http://breaker.research.yale.edu/R2R/R2R-manual-1.0.3.pdf
    $self->_run_r2r_and_check("--GSC-weighted-consensus", $aln_file->{'full_path'}, $meta_path, $cons_filename, "3 0.97 0.9 0.75 4 0.97 0.9 0.75 0.5 0.1");

    my $thumbnail = $model_name.'-thumbnail.svg';
    my $th_meta = EnsEMBL::Web::TmpFile::Text->new(
                        prefix    => "r2r/$random_dir",
                        filename  => $model_name.'-thumbnail',
                        extension => ".meta",
                    );
    my $th_content = "$meta_path/$cons_filename\tskeleton-with-pairbonds\n";
    $th_meta->print($th_content);
    $self->_run_r2r_and_check("", $th_meta->{'full_path'}, $img_path, $thumbnail, "");

    my $meta_file  = EnsEMBL::Web::TmpFile::Text->new(
                        prefix    => "r2r/$random_dir",
                        filename  => $model_name,
                        extension => ".meta",
                    );
    my $content = $with_consensus_structure ? "$meta_path/$cons_filename\n" : '';
    $content .= $aln_file->{'full_path'}."\toneseq\t$peptide_id\n";
    $meta_file->print($content);

    my $plot_file = $model_name.'.svg';
    $self->_run_r2r_and_check("", $meta_file->{'full_path'}, $img_path, $plot_file, "");

    return ($thumbnail, $plot_file);
}

sub _run_r2r_and_check {
    my ($self, $opts, $inpath, $outpath, $outfile, $extra_params) = @_;
    my $r2r_exe = $self->hub->species_defs->R2R_BIN;
    warn "$r2r_exe doesn't exist" unless ($r2r_exe);

    ## Make temporary directory
    mkdir($outpath) unless -e $outpath;
    $outpath .= '/'.$outfile;

    my $cmd = "$r2r_exe $opts $inpath $outpath $extra_params";
    system($cmd);
    if (! -e $outpath) {
       warn "Problem running r2r: $outpath doesn't exist\nThis is the command I tried to run:\n$cmd\n";
    }
    return;
}


1;

