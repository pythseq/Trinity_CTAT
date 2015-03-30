#!/usr/bin/env perl

use strict;
use warnings;

use FindBin;
use lib ("$FindBin::Bin/../PerlLib");
use Pipeliner;
use __GLOBALS__;

my $left_fq = "reads.left.simPE.fq.gz";
my $right_fq = "reads.right.simPE.fq.gz";

my $INSTALL_DIR = "$FindBin::Bin/../";

main: {

    
    my $pipeliner = new Pipeliner(-verbose => 1);
    
    ####################################
    ## run Trinity, assemble transcripts
    ####################################

    my $cmd = "$TRINITY_HOME/Trinity --left $left_fq --right $right_fq --seqType fq "
        . " --max_memory 2G --CPU 2 --output trinity_out_dir --full_cleanup ";

    $pipeliner->add_commands(new Command($cmd, "trinity_out_dir.ok"));



    #################
    ## Trinity Fusion
    #################
    
    
    $pipeliner->add_commands(
        new Command("$INSTALL_DIR/GMAP-Fusion -T trinity_out_dir.Trinity.fasta --output Trinity_Fusion", 
                    "Trinity_Fusion.ok") 
        ); 
    
    
    ##############
    ## STAR-Fusion
    ##############

    $pipeliner->add_commands(
        new Command("$INSTALL_DIR/star-fusion reads.left.simPE.fq.gz reads.right.simPE.fq.gz Star_Fusion",
                    "Star_Fusion.ok")
        );



    ####################
    ## FusionInspector #
    ####################
    
    $pipeliner->add_commands( 
        new Command("$INSTALL_DIR/FusionInspector --fusions ./test_fusions.list --gtf $FUSION_ANNOTATOR_LIB/gencode.v19.rna_seq_pipeline.gtf --genome_fa $FUSION_ANNOTATOR_LIB/Hg19.fa --left_fq reads.left.simPE.fq --right reads.right.simPE.fq --out_dir Fusion_Inspector/ --out_prefix fi_test",
                    "Fusion_Inspector.ok")
        );
    
    
    

    ## Execute pipeline
    
    $pipeliner->run();

    
    
    exit(0);

}


                             



