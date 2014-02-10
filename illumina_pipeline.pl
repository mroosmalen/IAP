#!/usr/bin/perl -w
use strict;


##################################################################################################################################################
###This script is designed to run the various parts of the illumina 'pipeline' using a single .conf configuration file.
###
###
###Author: S.W.Boymans
###Latest change: Created first version
###
###TODO: Add poststats, indelrealignment, baserecalibration, variantcalling
##################################################################################################################################################




use POSIX qw(tmpnam);
use Getopt::Long;

use illumina_prestats;
use illumina_mapping;
use illumina_poststats;
use illumina_realign;

my %opt;
my $configurationFile;


%opt = (
    'BWA_PATH'      		=> undef,
    'PICARD_PATH'   		=> undef,
    'SAMBAMBA_PATH'		=> undef,
    'FASTQC_PATH' 		=> undef,
    'QUALIMAP_PATH' 		=> undef,
    'QUEUE_PATH' 		=> undef,
    'GATK_PATH'			=> undef,
    'CLUSTER_PATH'  		=> undef,
    'CLUSTER_THREADS'		=> undef,
    'CLUSTER_MEM'		=> undef,
    'CLUSTER_TMP'		=> undef,
    'PRESTATS_QUEUE'		=> undef,
    'PRESTATS_PROJECT'		=> undef,
    'PRESTATS_THREADS'		=> undef,
    'PRESTATS_MEM'		=> undef,
    'MAPPING_QUEUE'		=> undef,
    'MAPPING_PROJECT'		=> undef,
    'MAPPING_THREADS'		=> undef,
    'MAPPING_MEM'		=> undef,
    'POSTSTATS_QUEUE'		=> undef,
    'POSTSTATS_PROJECT'		=> undef,
    'POSTSTATS_THREADS'		=> undef,
    'POSTSTATS_MEM'		=> undef,
    'REALIGNMENT_QUEUE'		=> undef,
    'REALIGNMENT_PROJECT'	=> undef,
    'REALIGNMENT_THREADS'	=> undef,
    'REALIGNMENT_MEM'		=> undef,
    'RECALIBRATION_QUEUE'	=> undef,
    'RECALIBRATION_PROJECT'	=> undef,
    'RECALIBRATION_THREADS'	=> undef,
    'RECALIBRATION_MEM'		=> undef,
    'CALLING_QUEUE'		=> undef,
    'CALLING_PROJECT'		=> undef,
    'CALLING_THREADS'		=> undef,
    'CALLING_MEM'		=> undef,
    'CHECKING_QUEUE'		=> undef,
    'CHECKING_PROJECT'		=> undef,
    'CHECKING_THREADS'		=> undef,
    'CHECKING_MEM'		=> undef,
    'GENOME'			=> undef,
    'PRESTATS'			=> "yes",
    'MAPPING'			=> "yes",
    'POSTSTATS'			=> "yes",
    'INDELREALIGNMENT'		=> "no",
    'BASEQUALITYRECAL'		=> "no",
    'VARIANT_CALLING'		=> "no",
    'OUTPUT_DIR'		=> undef,
    'FASTQ'			=> {},
    'KNOWN_SITES'		=> [],
    'RUNNING_JOBS'		=> {} #do not use in .conf
);


###########READ MAIN SETTINGS FROM .ini FILE####################
my $iniFile = $0; $iniFile =~ s/pl$/ini/;
open (INI, "<$iniFile") or die "Couldn't open .ini file $iniFile\n";

while(<INI>){
    chomp;
    next if m/^#/ or ! $_;
    my ($key, $val) = split("\t");
    $opt{$key} = $val;
    
}

close INI;
    
    
############READ RUN SPECIFIC SETTINGS FORM .conf FILE############
$configurationFile = $ARGV[0];
    
open (CONFIGURATION, "<$configurationFile") or die "Couldn't open .conf file: $configurationFile\n";
while(<CONFIGURATION>){
    chomp;
    next if m/^#/ or ! $_;
    my ($key, $val) = split("\t");

    if($key eq 'FASTQ'){
        $opt{$key}->{$val} = 1;
    }elsif($key eq 'KNOWN_SITES'){
        push(@{$opt{$key}}, $val); 
    }else{
        $opt{$key} = $val;	
    }

}
close CONFIGURATION;


if(! $opt{OUTPUT_DIR}){ die "ERROR: No OUTPUT_DIR found in .conf file\n" }
if(! $opt{FASTQ}){ die "ERROR: No FASTQ or BAM files specified\n" }
    
if(! -e $opt{OUTPUT_DIR}){
    mkdir($opt{OUTPUT_DIR});
}


if($opt{PRESTATS} eq "yes"){
    print "###SCHEDULING PRESTATS###\n";
    
    
    illumina_prestats::runPreStats(\%opt);
    
}


if($opt{MAPPING} eq "yes"){
    print "\n###SCHEDULING MAPPING###\n";
    
    my $mappingJobs = illumina_mapping::runMapping(\%opt);
    foreach my $sample (keys %{$mappingJobs}){
	push (@{$opt{RUNNING_JOBS}->{$sample}} , $mappingJobs->{$sample});
    }
    
    

}

if($opt{POSTSTATS} eq "yes"){
    print "\n###SCHEDULING POSTSTATS###\n";

    #illumina_poststats::runPostStats(\%opt);

}


if($opt{INDELREALIGNMENT} eq "yes"){
    
    my $realignJobs = illumina_realign::runRealignment(\%opt);
    foreach my $sample (keys %{$realignJobs}){
	push (@{$opt{RUNNING_JOBS}->{$sample}} , $realignJobs->{$sample});
    }

}

if($opt{BASEQUALITYRECAL} eq "yes"){


}

if($opt{VARIANT_CALLING} eq "yes"){



}




=cut
############
sub get_job_id {
   my $id = tmpnam(); 
      $id=~s/\/tmp\/file//;
   return $id;
}