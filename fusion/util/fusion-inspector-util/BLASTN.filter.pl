#!/usr/bin/env perl

use strict;
use warnings;
use Carp;
use FindBin;
use lib ("$FindBin::Bin/../../PerlLib");
use Fasta_reader;
use Getopt::Long qw(:config posix_default no_ignore_case bundling pass_through);                                                 
use TiedHash;

######################################################
# note, I'm borrowing this from our STAR-Fusion.filter
######################################################

my $FUSION_ANNOTATOR_LIB = $ENV{FUSION_ANNOTATOR_LIB} or die "Error, require env var for FUSION_ANNOTATOR_LIB";

my $cdna_fasta_file = "$FUSION_ANNOTATOR_LIB/gencode.v19.annotation.gtf.exons.cdna";

my $Evalue = 1e-3;
my $tmpdir = "/tmp";

my $usage = <<__EOUSAGE__;

########################################################################
#
# Required:
#
#  --fusion_preds <string>        preliminary fusion predictions
#                                 Required formatting is:  
#                                 geneA--geneB (tab) score (tab) ... rest
#
#
# Optional: 
#
#  --trans_fasta <string>         transcripts fasta file (default: $cdna_fasta_file)
#
#  -E <float>                     E-value threshold for blast searches (default: $Evalue)
#
#  --tmpdir <string>              file for temporary files (default: $tmpdir)
#
########################################################################  


__EOUSAGE__

    ;

my $help_flag;

my $fusion_preds_file;


&GetOptions ( 'h' => \$help_flag, 
              
              'fusion_preds=s' => \$fusion_preds_file,
              
              'trans_fasta=s' => \$cdna_fasta_file,
              
              'E=f' => \$Evalue,
              'tmpdir=s' => \$tmpdir,
    );


if ($help_flag) {
    die $usage;
}

unless ($fusion_preds_file && $cdna_fasta_file) {
    die $usage;
}

my $ref_cdna_idx_file = "$cdna_fasta_file.idx";
unless (-s $ref_cdna_idx_file) {
    die "Error, cannot find indexed fasta file: $cdna_fasta_file.idx; be sure to build an index - see docs.\n";
}


my $CDNA_IDX = new TiedHash({ use => $ref_cdna_idx_file });


main: {

    unless (-d $tmpdir) {
        mkdir $tmpdir or die "Error, cannot mkdir $tmpdir";
    }
    

    my $filter_info_file = "$fusion_preds_file.filt_info";
    open (my $ofh, ">$filter_info_file") or die "Error, cannot write to $filter_info_file";
    
    my @fusions;
    open (my $fh, $fusion_preds_file) or die "Error, cannot open file $fusion_preds_file";
    my $header = <$fh>;
    while (<$fh>) {
        if (/^\#/) { 
            next; 
        }
        chomp;
        my $line = $_;
        my @x = split(/\t/);

        my $geneA = $x[0];
        my $geneB = $x[2];
        my $J = $x[5];
        my $S = $x[6];
        
        my $fusion_name = "$geneA--$geneB";
        
        my $score = sqrt($J**2 + $S**2);
        
        push (@fusions, { fusion_name => $fusion_name,
                          geneA => $geneA,
                          geneB => $geneB,
                          score => $score, 
                          line => $line,
              } );
        
    }
    close $fh;

    print $ofh $header;
    print $header;
    
    @fusions = reverse sort {$a->{score} <=> $b->{score} } @fusions;


    my %AtoB;
    my %BtoA;
    
    foreach my $fusion (@fusions) {
        
        my ($geneA, $geneB) = ($fusion->{geneA}, $fusion->{geneB});

        my @blast_info = &examine_seq_similarity($geneA, $geneB);
        if (@blast_info) {
            push (@blast_info, "SEQ_SIMILAR_PAIR");
        }
        else {
        
            my $altB_aref = $AtoB{$geneA};
            if ($altB_aref) {
                foreach my $altB (@$altB_aref) {
                    my @blast = &examine_seq_similarity($geneB, $altB);
                    if (@blast) {
                        push (@blast, "ALREADY_SELECTED:$geneA--$altB");
                        push (@blast_info, @blast);
                    }
                }
            }
            my $altA_aref = $BtoA{$geneB};
            if ($altA_aref) {
                foreach my $altA (@$altA_aref) {
                    my @blast = &examine_seq_similarity($altA, $geneA);
                    if (@blast) {
                        push (@blast, "ALREADY_SELECTED:$altA--$geneB");
                        push (@blast_info, @blast);
                    }
                }
            }
        }
        
        my $line = $fusion->{line};
        
        if (@blast_info) {
            $line ="#$line"; # comment out the line in the filtered file... an aesthetic.
        }
        print $ofh "$line\t" . join("\t", @blast_info) . "\n";

        unless (@blast_info) {
            print "$line\n";
            push (@{$AtoB{$geneA}}, $geneB);
            push (@{$BtoA{$geneB}}, $geneA);
        }
        
    }

    close $ofh;
    
    exit(0);
}


####
sub examine_seq_similarity {
    my ($geneA, $geneB) = @_;

    print STDERR "-testing $geneA vs. $geneB\n";
    
    my $fileA = "$tmpdir/$$.gA.fa";
    my $fileB = "$tmpdir/$$.gB.fa";
        
    {
        # write file A
        open (my $ofh, ">$fileA") or die "Error, cannot write to $fileA";
        my $cdna_seqs = $CDNA_IDX->get_value($geneA) or confess "Error, no sequences found for gene: $geneA";
        print $ofh $cdna_seqs;
        close $ofh;
    }
        
    
    {
        # write file B
        open (my $ofh, ">$fileB") or die "Error, cannot write to file $fileB";
        my $cdna_seqs = $CDNA_IDX->get_value($geneB) or confess "Error, no sequences found for gene: $geneB";
        print $ofh $cdna_seqs;
        close $ofh;
    }

    #print STDERR "do it? ... ";
    #my $response = <STDIN>;
    
    ## blast them:
    my $cmd = "makeblastdb -in $fileB -dbtype nucl 2>/dev/null 1>&2";
    &process_cmd($cmd);
    
    my $blast_out = "$tmpdir/$$.blastn";
    $cmd = "blastn -db $fileB -query $fileA -evalue $Evalue -outfmt 6 -lcase_masking  -max_target_seqs 1 > $blast_out 2>/dev/null";
    &process_cmd($cmd);

    my @blast_hits;
    if (-s $blast_out) {
        open (my $fh, $blast_out) or die "Error, cannot open file $blast_out";
        while (<$fh>) {
            chomp;
            my @x = split(/\t/);
            my $blast_line = join("^", @x);
            $blast_line =~ s/\s+//g;
            push (@blast_hits, $blast_line);
        }
    }
    

    return(@blast_hits);
}



####
sub process_cmd {
    my ($cmd) = @_;

    print STDERR "CMD: $cmd\n";
        
    my $ret = system($cmd);
    if ($ret) {

        die "Error, cmd $cmd died with ret $ret";
    }
    
    return;
}
    
        
