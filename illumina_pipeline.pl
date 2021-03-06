#!/usr/bin/perl -w
##########################################
### illumina_pipeline.pl
### - Main pipeline script
### - Read and check config and ini file
### - Start selected modules
###
### Author: S.W.Boymans & R.F.Ernst
##########################################

### Load common perl modules ####
use strict;
use POSIX qw(tmpnam strftime);
use Getopt::Long;
use FindBin;
use File::Path qw(make_path);
use File::Copy qw(copy);
use Cwd qw( abs_path );
use File::Basename qw( dirname );

### Load pipeline modules ####
use lib "$FindBin::Bin"; #locates pipeline directory
use IAP::prestats;
use IAP::mapping;
use IAP::poststats;
use IAP::realign;
use IAP::baseRecal;
use IAP::calling;
use IAP::filterVariants;
use IAP::somaticVariants;
use IAP::copyNumber;
use IAP::structuralVariants;
use IAP::baf;
use IAP::callableLoci;
use IAP::annotateVariants;
use IAP::vcfutils;
use IAP::nipt;
use IAP::check;
use IAP::telomerecat;

### Check correct usage
die usage() if @ARGV == 0;

### initiate opt hash with settings
my %opt;
my $configurationFile;

%opt = (
    'RUNNING_JOBS'		=> {}, #do not use in .conf or .ini
    'BAM_FILES'			=> {}, #do not use in .conf or .ini
    'SAMPLES'			=> undef, #do not use in .conf or .ini
    'IAP_PATH'			=> dirname(abs_path($0)) # current IAP root directory
);

############ READ RUN SETTINGS FORM .conf FILE ############
$configurationFile = $ARGV[0];

open (CONFIGURATION, "<$configurationFile") or die "Couldn't open .conf file: $configurationFile\n";
while(<CONFIGURATION>){
    chomp;
    next if m/^#/ or ! $_;
    my ($key, $val) = split("\t",$_,2);
    #parse ini file
    if($key eq 'INIFILE') {
	$opt{$key} = $val;
	open (INI, "<$val") or die "Couldn't open .ini file $val\n";
	while(<INI>){
	    chomp;
	    next if m/^#/ or ! $_;
	    my ($key, $val) = split("\t",$_,2);
	    $opt{$key} = $val;
	}
	close INI;
    #parse other config attributes
    } elsif($key eq 'FASTQ' || $key eq 'BAM') {
        $opt{$key}->{$val} = 1;
    } else {
        $opt{$key} = $val;
    }

}
close CONFIGURATION;

############ START PIPELINE  ############

### Check config file
checkConfig();

### Create main output directory
if(! -e $opt{OUTPUT_DIR}){
    make_path($opt{OUTPUT_DIR}) or die "Couldn't create directory: $opt{OUTPUT_DIR}\n";
}

### Setup sumbit log
$| = 1;

# Fork to log
my $date = strftime "%m%d%Y_%H%M", localtime;
open( my $SUBMITLOG, "|-", "tee $opt{OUTPUT_DIR}/submit_$date.log" ) || die $!;
open( STDOUT, '>&', $SUBMITLOG ) || die $!;
open( STDERR, '>&', $SUBMITLOG ) || die $!;

###Parse samples from FASTQ or BAM files
getSamples();
createOutputDirs();

### Copy ini file to logs dir
system "cp $opt{INIFILE} $opt{OUTPUT_DIR}/logs";

### Start pipeline components
my $opt_ref;

### Mapping or bam input
if( $opt{FASTQ} ){
    if($opt{PRESTATS} eq "yes"){
	print "###SCHEDULING PRESTATS###\n";
	$opt_ref = IAP::prestats::runPreStats(\%opt);
	%opt = %$opt_ref;
    }

    if($opt{MAPPING} eq "yes"){
	print "\n###SCHEDULING MAPPING###\n";
	$opt_ref = IAP::mapping::runMapping(\%opt);
	%opt = %$opt_ref;
    }

} if( $opt{BAM} ) {
    print "\n###SCHEDULING BAM PREP###\n";
    $opt_ref = IAP::mapping::runBamPrep(\%opt);
    %opt = %$opt_ref;
}

### Post mapping
if(! $opt{VCF} ){
    if($opt{POSTSTATS} eq "yes"){
	print "\n###SCHEDULING POSTSTATS###\n";
	my $postStatsJob = IAP::poststats::runPostStats(\%opt);
	$opt{RUNNING_JOBS}->{'postStats'} = $postStatsJob;
    }

    if($opt{INDELREALIGNMENT} eq "yes"){
	print "\n###SCHEDULING INDELREALIGNMENT###\n";
	$opt_ref = IAP::realign::runRealignment(\%opt);
	%opt = %$opt_ref;
    }

    if($opt{BASEQUALITYRECAL} eq "yes"){
	print "\n###SCHEDULING BASERECALIBRATION###\n";
	$opt_ref = IAP::baseRecal::runBaseRecalibration(\%opt);
	%opt = %$opt_ref;
    }

    if($opt{NIPT} eq "yes"){
	print "\n###SCHEDULING NIPT###\n";
	my $niptJob = IAP::nipt::runNipt(\%opt);
	$opt{RUNNING_JOBS}->{'nipt'} = $niptJob;
    }

    if($opt{TELOMERECAT} eq "yes"){
    print "\n###SCHEDULING TELOMERECAT###\n";
    	my $telomerecatJob = IAP::telomerecat::runTelomerecat(\%opt);
    	$opt{RUNNING_JOBS}->{'telomerecat'} = $telomerecatJob;

    }

### Variant Caller
    ### Somatic variant callers
    if($opt{SOMATIC_VARIANTS} eq "yes"){
	print "\n###SCHEDULING SOMATIC VARIANT CALLERS####\n";
	my $somVar_jobs = IAP::somaticVariants::runSomaticVariantCallers(\%opt);
	$opt{RUNNING_JOBS}->{'somVar'} = $somVar_jobs;
    }
    if($opt{COPY_NUMBER} eq "yes"){
	print "\n###SCHEDULING COPY NUMBER TOOLS####\n";
	my $cnv_jobs = IAP::copyNumber::runCopyNumberTools(\%opt);
	$opt{RUNNING_JOBS}->{'CNV'} = $cnv_jobs;
    }
    ### SV - Delly/Manta/Gridss

    if($opt{SV_CALLING} eq "yes"){
	print "\n###SCHEDULING SV CALLING####\n";
	my $sv_jobs = IAP::structuralVariants::runStructuralVariantCallers(\%opt);
	$opt{RUNNING_JOBS}->{'sv'} = $sv_jobs;
    }
    ### BAF
    if($opt{BAF} eq "yes"){
	print "\n###SCHEDULING BAF Analysis###\n";
	my $baf_jobs = IAP::baf::runBAF(\%opt);
	$opt{RUNNING_JOBS}->{'baf'} = $baf_jobs;
    }
    ### CALLABLE LOCI
    if($opt{CALLABLE_LOCI} eq "yes"){
	print "\n###SCHEDULING CALLABLE LOCI Analysis###\n";
	my $callable_loci_jobs = IAP::callableLoci::runCallableLoci(\%opt);
	$opt{RUNNING_JOBS}->{'callable_loci'} = $callable_loci_jobs;
    }

    ### SNPPanel
    if($opt{FINGERPRINT} eq "yes"){
	print "\n###SCHEDULING FINGERPRINT Analysis###\n";
	my $fingerprint_job = IAP::calling::runFingerprint(\%opt);
	$opt{RUNNING_JOBS}->{'fingerprint'} = $fingerprint_job;
    }

    ### GATK
    if($opt{VARIANT_CALLING} eq "yes"){
	print "\n###SCHEDULING VARIANT CALLING####\n";
	$opt_ref = IAP::calling::runVariantCalling(\%opt);
	%opt = %$opt_ref;
    }
} elsif ( $opt{VCF} ) {
    print "\n###RUNNING VCF PREP###\n";
    $opt_ref = IAP::calling::runVcfPrep(\%opt);
    %opt = %$opt_ref;
}

### Filter variants
if($opt{FILTER_VARIANTS} eq "yes"){
    print "\n###SCHEDULING VARIANT FILTRATION####\n";
    my $FVJob = IAP::filterVariants::runFilterVariants(\%opt);

    foreach my $sample (@{$opt{SAMPLES}}){
	push (@{$opt{RUNNING_JOBS}->{$sample}} , $FVJob);
    }
}

### Annotate variants
if($opt{ANNOTATE_VARIANTS} eq "yes"){
    print "\n###SCHEDULING VARIANT ANNOTATION####\n";
    my $AVJob = IAP::annotateVariants::runAnnotateVariants(\%opt);

    foreach my $sample (@{$opt{SAMPLES}}){
	push (@{$opt{RUNNING_JOBS}->{$sample}} , $AVJob);
    }
}

### VCFUTILS step
if($opt{VCF_UTILS} eq "yes"){
    print "\n###SCHEDULING VCF UTILS Module Jobs####\n";
    my $vcfutils_job = IAP::vcfutils::runVcfUtils(\%opt);
    $opt{RUNNING_JOBS}->{'VCF_UTILS'} = $vcfutils_job;
}

if($opt{CHECKING} eq "yes"){
    print "\n###SCHEDULING CHECK AND CLEAN####\n";
    IAP::check::runCheck(\%opt);
}

### Close submit log
close(STDERR);
close(STDOUT);
close($SUBMITLOG);

############ SUBROUTINES  ############
sub getSamples{
    my %samples;

    #parse fastq files
    if ($opt{FASTQ}){
	foreach my $input (keys %{$opt{FASTQ}}){
	    my $fastqFile = (split("/", $input))[-1];
	    my $sampleName = (split("_", $fastqFile))[0];
	    $samples{$sampleName} ++;
	    @{$opt{RUNNING_JOBS}->{$sampleName}} = ();
	}
    }

    #parse bam files
    if ($opt{BAM}){
	foreach my $input (keys %{$opt{BAM}}){
	    my $bamFile = (split("/", $input))[-1];
	    my $sampleName = $bamFile;
	    $sampleName =~ s/\.bam//g;
	    $samples{$sampleName} ++;
	    @{$opt{RUNNING_JOBS}->{$sampleName}} = ();
	}
    }

    @{$opt{SAMPLES}} = keys(%samples);

    ###
    # Parse sample names based on somatic_regex, store samples in single_sample array or somatic_sample hash
    ###
    my %somatic_samples;
    my @somatic_samples_uniq; #usefull for pileup
    my @single_samples;

    ### Parse samples
    foreach my $sample (@{$opt{SAMPLES}}){
	if ($opt{SOMATIC_REGEX}){
	    my ($sample_name,$origin) = (undef, undef);
	    ($sample_name,$origin) = ($sample =~ /$opt{SOMATIC_REGEX}/);
	    if ( (! defined $sample) || (! defined $origin) ){
		print "Running single sample analysis for: $sample\n";
		push(@single_samples, $sample);
	    } else {
		print "Running somatic sample analysis for: $sample\n";
		# Reference sample
		my @ref_codes = split(",", $opt{SOMATIC_REGEX_REF_CODE});
		foreach my $ref_code (@ref_codes){
		    if ($origin =~ m/$ref_code.*/){
			push(@{$somatic_samples{$sample_name}{"ref"}},$sample);
		    }
		}
		my @tumor_codes = split(",", $opt{SOMATIC_REGEX_TUMOR_CODE});
		foreach my $tumor_code (@tumor_codes){
		    if ($origin =~ m/$tumor_code.*/){
			push(@{$somatic_samples{$sample_name}{"tumor"}},$sample);
		    }
		}
	    }
	} else {
	    print "Running single sample analysis for: $sample\n";
	    push(@single_samples, $sample);
	}
    }

    ### Check pairs
    foreach my $sample (keys %somatic_samples){
	## If no ref or tumor found at samples to single_samples
	if ( ! $somatic_samples{$sample}{"ref"}){
	    print "WARNING: No ref found for $sample, switching to single sample mode\n";
	    push(@single_samples, @{$somatic_samples{$sample}{"tumor"}});
	    delete $somatic_samples{$sample};
	}
	elsif ( ! $somatic_samples{$sample}{"tumor"}){
	    print "WARNING: No tumor found for $sample, switching to single sample mode\n";
	    push(@single_samples, @{$somatic_samples{$sample}{"ref"}});
	    delete $somatic_samples{$sample};
	} else {
	    push(@somatic_samples_uniq, @{$somatic_samples{$sample}{"tumor"}});
	    push(@somatic_samples_uniq, @{$somatic_samples{$sample}{"ref"}});
	}
    }

    @{$opt{SINGLE_SAMPLES}} = @single_samples;
    %{$opt{SOMATIC_SAMPLES}} = %somatic_samples;
    @{$opt{SOMATIC_SAMPLES_UNIQ}} = @somatic_samples_uniq;
}

sub createOutputDirs{
    ### Create main output directories
    if(! -e "$opt{OUTPUT_DIR}/QCStats"){
	mkdir("$opt{OUTPUT_DIR}/QCStats") or die "Couldn't create directory: $opt{OUTPUT_DIR}/QCStats\n";
    }
    if(! -e "$opt{OUTPUT_DIR}/jobs"){
	mkdir("$opt{OUTPUT_DIR}/jobs") or die "Couldn't create directory: $opt{OUTPUT_DIR}/jobs\n";
    }
    if(! -e "$opt{OUTPUT_DIR}/logs"){
	mkdir("$opt{OUTPUT_DIR}/logs") or die "Couldn't create directory: $opt{OUTPUT_DIR}/logs\n";
    }
    if(! -e "$opt{OUTPUT_DIR}/tmp"){
	mkdir("$opt{OUTPUT_DIR}/tmp") or die "Couldn't create directory: $opt{OUTPUT_DIR}/tmp\n";
    }

    ### Create sample specific output directories
    foreach my $sample (@{$opt{SAMPLES}}){
	if(! -e "$opt{OUTPUT_DIR}/$sample"){
	    mkdir("$opt{OUTPUT_DIR}/$sample") or die "Couldn't create directory: $opt{OUTPUT_DIR}/$sample\n";
	}
	if(! -e "$opt{OUTPUT_DIR}/$sample/mapping"){
	    mkdir("$opt{OUTPUT_DIR}/$sample/mapping") or die "Couldn't create directory: $opt{OUTPUT_DIR}/$sample/mapping\n";
	}
	if(! -e "$opt{OUTPUT_DIR}/$sample/QCStats"){
	    mkdir("$opt{OUTPUT_DIR}/$sample/QCStats") or die "Couldn't create directory: $opt{OUTPUT_DIR}/$sample/QCStats\n";
	}
	if(! -e "$opt{OUTPUT_DIR}/$sample/jobs"){
	    mkdir("$opt{OUTPUT_DIR}/$sample/jobs") or die "Couldn't create directory: $opt{OUTPUT_DIR}/$sample/jobs\n";
	}
	if(! -e "$opt{OUTPUT_DIR}/$sample/logs"){
	    mkdir("$opt{OUTPUT_DIR}/$sample/logs") or die "Couldn't create directory: $opt{OUTPUT_DIR}/$sample/logs\n";
	}
	if(! -e "$opt{OUTPUT_DIR}/$sample/tmp"){
	    mkdir("$opt{OUTPUT_DIR}/$sample/tmp") or die "Couldn't create directory: $opt{OUTPUT_DIR}/$sample/tmp\n";
	}
    }
}

sub usage{
    warn <<END;
    Usage: perl illumina_pipeline.pl configurationFile.conf
END
    exit;
}

sub get_job_id {
    my $id = tmpnam();
    $id =~ s/\/tmp\/file//;
    return $id;
}

sub checkConfig{
    my $checkFailed = 0;
    my $runName = "";
    ### Input and Output
    if(! $opt{INIFILE}){ print "ERROR: No INIFILE option found in config files.\n"; $checkFailed = 1; }
    if(! $opt{OUTPUT_DIR}){ print "ERROR: No OUTPUT_DIR found in config files.\n"; $checkFailed = 1; } else { $runName = (split("/", $opt{OUTPUT_DIR}))[-1];}
    if(! ($opt{FASTQ} || $opt{BAM} || $opt{VCF}) ){ print "ERROR: No FASTQ/BAM/VCF files found in config files.\n"; $checkFailed = 1; }
    if(! $opt{MAIL}){ print "ERROR: No MAIL address specified in config files.\n"; $checkFailed = 1; }

    ### Check fastq input
    if($opt{FASTQ}){
	foreach my $input (keys %{$opt{FASTQ}}){
	    my $fastqFile = (split("/", $input))[-1];
	    my $fastqPattern = qr/^(?<sampleName>[^_]+)_(?<flowcellID>[^_]+)_(?<index>[^_]+)_(?<lane>[^_]+)_(?<tag>R1|R2)_(?<suffix>[^\.]+)(?<ext>\.fastq\.gz)$/x;
	    $fastqFile =~ $fastqPattern or do {
		print "ERROR: FASTQ filename '$fastqFile' must match regex '$fastqPattern'. \n\t For example: SAMPLENAME_FLOWCELLID_S1_L001_R1_001.fastq.gz)\n";
		$checkFailed = 1;
	    }
	}
    }

    ### Cluster settings
    if(! $opt{CLUSTER_PATH}){ print "ERROR: No CLUSTER_PATH option found in config files.\n"; $checkFailed = 1; }
    if(! $opt{CLUSTER_TMP}){ print "ERROR: No CLUSTER_TMP option found in config files.\n"; $checkFailed = 1; }
    if(! $opt{CLUSTER_RESERVATION}){ print "ERROR: No CLUSTER_RESERVATION option found in config files.\n"; $checkFailed = 1; }
    if(! $opt{CLUSTER_PROJECT}){ print "ERROR: No CLUSTER_PROJECT option found in config files.\n"; $checkFailed = 1; }

    ### Module yes or No
    if(! $opt{PRESTATS}){ print "ERROR: No PRESTATS option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{MAPPING}){ print "ERROR: No MAPPING option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{POSTSTATS}){ print "ERROR: No POSTSTATS option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{INDELREALIGNMENT}){ print "ERROR: No INDELREALIGNMENT option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{BASEQUALITYRECAL}){ print "ERROR: No BASEQUALITYRECAL option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{VARIANT_CALLING}){ print "ERROR: No VARIANT_CALLING option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{FILTER_VARIANTS}){ print "ERROR: No FILTER_VARIANTS option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{SOMATIC_VARIANTS}){ print "ERROR: No SOMATIC_VARIANTS option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{COPY_NUMBER}){ print "ERROR: No COPY_NUMBER option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{TELOMERECAT}){ print "ERROR: No TELOMERECAT option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{SV_CALLING}){ print "ERROR: No SV_CALLING option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{BAF}){ print "ERROR: No BAF option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{FINGERPRINT}){ print "ERROR: No FINGERPRINT option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{CALLABLE_LOCI}){ print "ERROR: No CALLABLE_LOCI option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{ANNOTATE_VARIANTS}){ print "ERROR: No ANNOTATE_VARIANTS option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{VCF_UTILS}){ print "ERROR: No VCF_UTILS option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{NIPT}){ print "ERROR: No NIPT option found in config files. \n"; $checkFailed = 1; }
    if(! $opt{CHECKING}){ print "ERROR: No CHECKING option found in config files. \n"; $checkFailed = 1; }

    ### Module Settings / tools
    if(! $opt{GENOME}){ print "ERROR: No GENOME option found in config files.\n"; $checkFailed = 1; }
    elsif(! -e $opt{GENOME}){ print"ERROR: $opt{GENOME} does Not exist\n"}
    if(! $opt{SAMBAMBA_PATH}){ print "ERROR: No SAMBAMBA_PATH option found in config files.\n"; $checkFailed = 1; }
    if(! $opt{QUEUE_PATH}){ print "ERROR: No QUEUE_PATH option found in config files.\n"; $checkFailed = 1; }
    if(! $opt{GATK_JAVA_MODULE}){ print "ERROR: No GATK_JAVA_MODULE option found in config files.\n"; $checkFailed = 1; }
    ## PRESTATS
    if($opt{PRESTATS} eq "yes"){
	if(! $opt{FASTQC_PATH}){ print "ERROR: No FASTQC_PATH option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{PRESTATS_THREADS}){ print "ERROR: No PRESTATS_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{PRESTATS_MEM}){ print "ERROR: No PRESTATS_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{PRESTATS_QUEUE}){ print "ERROR: No PRESTATS_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{PRESTATS_TIME}){ print "ERROR: No PRESTATS_TIME option found in config files.\n"; $checkFailed = 1; }
    }
    ## MAPPING
    if($opt{MAPPING} eq "yes"){
	if(! $opt{BWA_PATH}){ print "ERROR: No BWA_PATH option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{MAPPING_THREADS}){ print "ERROR: No MAPPING_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{MAPPING_MEM}){ print "ERROR: No MAPPING_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{MAPPING_QUEUE}){ print "ERROR: No MAPPING_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{MAPPING_TIME}){ print "ERROR: No MAPPING_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{MAPPING_SETTINGS}){ print "ERROR: No MAPPING_SETTINGS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{MARKDUP_LEVEL}){ print "ERROR: No MARKDUP_LEVEL option found in config files.\n"; $checkFailed = 1; }
	if( ($opt{MARKDUP_LEVEL} ne "lane") && ($opt{MARKDUP_LEVEL} ne "sample") && ($opt{MARKDUP_LEVEL} ne "no")){
	    print "ERROR: MARKDUP_LEVEL should be set to sample, lane or no.\n"; $checkFailed = 1;
	}
	## MARKDUP OPTIONS, also used for merging.
	if( ($opt{MARKDUP_LEVEL} eq "lane") || ($opt{MARKDUP_LEVEL} eq "sample")){
	    if(! $opt{MARKDUP_QUEUE}){ print "ERROR: No MARKDUP_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MARKDUP_TIME}){ print "ERROR: No MARKDUP_TIME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MARKDUP_THREADS}){ print "ERROR: No MARKDUP_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MARKDUP_MEM}){ print "ERROR: No MARKDUP_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MARKDUP_OVERFLOW_LIST_SIZE}){ print "ERROR: No MARKDUP_OVERFLOW_LIST_SIZE option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{FLAGSTAT_QUEUE}){ print "ERROR: No FLAGSTAT_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FLAGSTAT_THREADS}){ print "ERROR: No FLAGSTAT_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FLAGSTAT_MEM}){ print "ERROR: No FLAGSTAT_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FLAGSTAT_TIME}){ print "ERROR: No FLAGSTAT_TIME option found in config files.\n"; $checkFailed = 1; }
    }
    ## POSTSTATS
    if($opt{POSTSTATS} eq "yes"){
	if(! $opt{BAMMETRICS_PATH}){ print "ERROR: No BAMMETRICS_PATH option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{PICARD_PATH}){ print "ERROR: No PICARD_PATH option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{POSTSTATS_THREADS}){ print "ERROR: No POSTSTATS_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{POSTSTATS_MEM}){ print "ERROR: No POSTSTATS_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{POSTSTATS_QUEUE}){ print "ERROR: No POSTSTATS_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{POSTSTATS_TIME}){ print "ERROR: No POSTSTATS_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! ($opt{POSTSTATS_TARGETS}) && ! ($opt{POSTSTATS_BAITS}) ){
	    if(! $opt{POSTSTATS_COVERAGECAP}){ print "ERROR: No POSTSTATS_COVERAGECAP or (POSTSTATS_TARGETS & POSTSTATS_BAITS) options found in config files.\n"; $checkFailed = 1; }
	}
	if( $opt{POSTSTATS_TARGETS} && ! -e $opt{POSTSTATS_TARGETS}){ print "ERROR: $opt{POSTSTATS_TARGETS} does Not exist\n"; $checkFailed = 1; }
	if( $opt{POSTSTATS_BAITS} && ! -e $opt{POSTSTATS_BAITS}){ print "ERROR: $opt{POSTSTATS_BAITS} does Not exist\n"; $checkFailed = 1; }
	if(! $opt{EXONCALLCOV}){ print "ERROR: No EXONCALLCOV option found in config files.\n"; $checkFailed = 1; }
	if( $opt{EXONCALLCOV} eq "yes"){
	    if(! $opt{EXONCALLCOV_QUEUE}){ print "ERROR: No EXONCALLCOV_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{EXONCALLCOV_TIME}){ print "ERROR: No EXONCALLCOV_TIME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{EXONCALLCOV_MEM}){ print "ERROR: No EXONCALLCOV_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{EXONCALLCOV_PATH}){ print "ERROR: No EXONCALLCOV_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{EXONCALLCOV_BED}){ print "ERROR: No EXONCALLCOV_BED option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{EXONCALLCOV_PREF}){ print "ERROR: No EXONCALLCOV_PREF option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{EXONCALLCOV_PANEL}){ print "ERROR: No EXONCALLCOV_PANEL option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{EXONCALLCOV_ENS}){ print "ERROR: No EXONCALLCOV_ENS option found in config files.\n"; $checkFailed = 1; }
	}
    }
    ## INDELREALIGNMENT
    if($opt{INDELREALIGNMENT} eq "yes"){
	if(! $opt{REALIGNMENT_MASTER_QUEUE}){ print "ERROR: No REALIGNMENT_MASTER_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{REALIGNMENT_MASTER_THREADS}){ print "ERROR: No REALIGNMENT_MASTER_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{REALIGNMENT_MASTER_TIME}){ print "ERROR: No REALIGNMENT_MASTER_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{REALIGNMENT_MASTER_MEM}){ print "ERROR: No REALIGNMENT_MASTER_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{REALIGNMENT_QUEUE}){ print "ERROR: No REALIGNMENT_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{REALIGNMENT_THREADS}){ print "ERROR: No REALIGNMENT_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{REALIGNMENT_MEM}){ print "ERROR: No REALIGNMENT_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{REALIGNMENT_TIME}){ print "ERROR: No REALIGNMENT_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{REALIGNMENT_MERGETHREADS}){ print "ERROR: No REALIGNMENT_MERGETHREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{REALIGNMENT_SCALA}){ print "ERROR: No REALIGNMENT_SCALA option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{REALIGNMENT_SCATTER}){ print "ERROR: No REALIGNMENT_SCATTER option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{REALIGNMENT_MODE}){ print "ERROR: No REALIGNMENT_MODE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{QUEUE_RETRY}){ print "ERROR: No QUEUE_RETRY option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FLAGSTAT_QUEUE}){ print "ERROR: No FLAGSTAT_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FLAGSTAT_THREADS}){ print "ERROR: No FLAGSTAT_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FLAGSTAT_MEM}){ print "ERROR: No FLAGSTAT_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FLAGSTAT_TIME}){ print "ERROR: No FLAGSTAT_TIME option found in config files.\n"; $checkFailed = 1; }
    }
    ## BASEQUALITYRECAL
    if($opt{BASEQUALITYRECAL} eq "yes"){
	if(! $opt{BASERECALIBRATION_MASTER_QUEUE}){ print "ERROR: No BASERECALIBRATION_MASTER_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BASERECALIBRATION_MASTER_TIME}){ print "ERROR: No BASERECALIBRATION_MASTER_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BASERECALIBRATION_MASTER_THREADS}){ print "ERROR: No BASERECALIBRATION_MASTER_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BASERECALIBRATION_MASTER_MEM}){ print "ERROR: No BASERECALIBRATION_MASTER_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BASERECALIBRATION_QUEUE}){ print "ERROR: No BASERECALIBRATION_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BASERECALIBRATION_THREADS}){ print "ERROR: No BASERECALIBRATION_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BASERECALIBRATION_MEM}){ print "ERROR: No BASERECALIBRATION_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BASERECALIBRATION_TIME}){ print "ERROR: No BASERECALIBRATION_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BASERECALIBRATION_SCALA}){ print "ERROR: No BASERECALIBRATION_SCALA option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BASERECALIBRATION_SCATTER}){ print "ERROR: No BASERECALIBRATION_SCATTER option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BASERECALIBRATION_QC}){ print "ERROR: No BASERECALIBRATION_QC option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{QUEUE_RETRY}){ print "ERROR: No QUEUE_RETRY option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FLAGSTAT_QUEUE}){ print "ERROR: No FLAGSTAT_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FLAGSTAT_THREADS}){ print "ERROR: No FLAGSTAT_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FLAGSTAT_MEM}){ print "ERROR: No FLAGSTAT_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FLAGSTAT_TIME}){ print "ERROR: No FLAGSTAT_TIME option found in config files.\n"; $checkFailed = 1; }
    }
    ## VARIANT_CALLING
    if($opt{VARIANT_CALLING} eq "yes"){
	if(! $opt{CALLING_MASTER_QUEUE}){ print "ERROR: No CALLING_MASTER_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLING_MASTER_TIME}){ print "ERROR: No CALLING_MASTER_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLING_MASTER_THREADS}){ print "ERROR: No CALLING_MASTER_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLING_MASTER_MEM}){ print "ERROR: No CALLING_MASTER_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLING_QUEUE}){ print "ERROR: No CALLING_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLING_THREADS}){ print "ERROR: No CALLING_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLING_MEM}){ print "ERROR: No CALLING_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLING_TIME}){ print "ERROR: No CALLING_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLING_SCATTER}){ print "ERROR: No CALLING_SCATTER option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLING_GVCF}){ print "ERROR: No CALLING_GVCF option found in config files.\n"; $checkFailed = 1; }
	elsif( $opt{CALLING_GVCF} eq "yes" ){
	    if(! $opt{CALLING_GVCFGQBANDS}){ print "ERROR: No CALLING_GVCFGQBANDS option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{CALLING_SEXAWARE}){ print "ERROR: No CALLING_SEXAWARE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLING_SCALA}){ print "ERROR: No CALLING_SCALA option found in config files.\n"; $checkFailed = 1; }
	if($opt{CALLING_UGMODE}){
	    if($opt{CALLING_UGMODE} ne "SNP" and $opt{CALLING_UGMODE} ne "INDEL" and $opt{CALLING_UGMODE} ne "BOTH"){ print "ERROR: UGMODE: $opt{CALLING_UGMODE} does Not exist use SNP, INDEL or BOTH\n"; $checkFailed = 1; }
	}
	if(! $opt{CALLING_STANDCALLCONF}){ print "ERROR: No CALLING_STANDCALLCONF option found in config files.\n"; $checkFailed = 1; }
	if( $opt{CALLING_TARGETS} && ! -e $opt{CALLING_TARGETS}) { print"ERROR: $opt{CALLING_TARGETS} does Not exist\n"; $checkFailed = 1; }
	if( $opt{CALLING_TARGETS} && $opt{CALLING_SEXAWARE} eq "yes") { print"ERROR: Sex aware variant calling does not work for targeted sequencing data. Disable CALLING_TARGETS or CALLING_SEXAWARE.\n"; $checkFailed = 1; }
	if( $opt{CALLING_SEXAWARE} eq "yes" && $opt{CALLING_GVCF} eq "no") { print"ERROR: Sex aware variant calling does only work in gvcf mode. Set CALLING_GVCF to yes or CALLING_SEXAWARE to no.\n"; $checkFailed = 1; }
	if( $opt{CALLING_DBSNP} && ! -e $opt{CALLING_DBSNP}) { print"ERROR: $opt{CALLING_DBSNP} does Not exist\n"; $checkFailed = 1; }
	if(! $opt{QUEUE_RETRY}){ print "ERROR: No QUEUE_RETRY option found in config files.\n"; $checkFailed = 1; }
    }
    ## FILTER_VARIANTS
    if($opt{FILTER_VARIANTS} eq "yes"){
	if(! $opt{FILTER_MASTER_QUEUE}){ print "ERROR: No FILTER_MASTER_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FILTER_MASTER_TIME}){ print "ERROR: No FILTER_MASTER_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FILTER_MASTER_THREADS}){ print "ERROR: No FILTER_MASTER_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FILTER_MASTER_MEM}){ print "ERROR: No FILTER_MASTER_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FILTER_QUEUE}){ print "ERROR: No FILTER_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FILTER_THREADS}){ print "ERROR: No FILTER_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FILTER_MEM}){ print "ERROR: No FILTER_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FILTER_TIME}){ print "ERROR: No FILTER_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FILTER_SCATTER}){ print "ERROR: No FILTER_SCATTER option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FILTER_SCALA}){ print "ERROR: No FILTER_SCALA option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FILTER_MODE}){ print "ERROR: No FILTER_MODE  option found in config files.\n"; $checkFailed = 1; }
	if($opt{FILTER_MODE} ne "SNP" and $opt{FILTER_MODE} ne "INDEL" and $opt{FILTER_MODE} ne "BOTH"){ print "ERROR: FILTER_MODE $opt{FILTER_MODE} does Not exist use SNP, INDEL or BOTH\n"; $checkFailed = 1; }
	if ($opt{FILTER_MODE} eq "SNP" || $opt{FILTER_MODE} eq "BOTH") {
	    if(! $opt{FILTER_SNPTYPES}){ print "ERROR: No FILTER_SNPTYPES option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FILTER_SNPNAME}){ print "ERROR: No FILTER_SNPNAME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FILTER_SNPEXPR}){ print "ERROR: No FILTER_SNPEXPR  option found in config files.\n"; $checkFailed = 1; }
	}
	if ($opt{FILTER_MODE} eq "INDEL" || $opt{FILTER_MODE} eq "BOTH") {
	    if(! $opt{FILTER_INDELTYPES}){ print "ERROR: No FILTER_INDELTYPES option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FILTER_INDELNAME}){ print "ERROR: No FILTER_INDELNAME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FILTER_INDELEXPR}){ print "ERROR: No FILTER_INDELEXPR option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{QUEUE_RETRY}){ print "ERROR: No QUEUE_RETRY option found in config files.\n"; $checkFailed = 1; }
    }
    ## SOMATIC_VARIANTS
    if($opt{SOMATIC_VARIANTS} eq "yes"){
	if(! $opt{SAMTOOLS_PATH}){ print "ERROR: No SAMTOOLS_PATH option found in config files.\n"; $checkFailed = 1; }
	if( $opt{SOMVAR_TARGETS} && ! -e $opt{SOMVAR_TARGETS}) { print"ERROR: $opt{SOMVAR_TARGETS} does not exist\n"; $checkFailed = 1; }
	if(! $opt{SOMATIC_REGEX}){ print "ERROR: No SOMATIC_REGEX option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{SOMATIC_REGEX_REF_CODE}){ print "ERROR: No SOMATIC_REGEX_REF_CODE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{SOMATIC_REGEX_TUMOR_CODE}){ print "ERROR: No SOMATIC_REGEX_TUMOR_CODE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{SOMVAR_STRELKA}){ print "ERROR: No SOMVAR_STRELKA option found in config files.\n"; $checkFailed = 1; }
	if($opt{SOMVAR_STRELKA} eq "yes"){
	    if(! $opt{STRELKA_PATH}){ print "ERROR: No STRELKA_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{STRELKA_INI}){ print "ERROR: No STRELKA_INI option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{STRELKA_QUEUE}){ print "ERROR: No STRELKA_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{STRELKA_THREADS}){ print "ERROR: No STRELKA_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{STRELKA_MEM}){ print "ERROR: No STRELKA_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{STRELKA_TIME}){ print "ERROR: No STRELKA_TIME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{HMFTOOLS_PROFILE}){ print "ERROR: No HMFTOOLS_PROFILE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{GIAB_HIGH_CONFIDENCE_BED}){ print "ERROR: No GIAB_HIGH_CONFIDENCE_BED option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{SOMVAR_VARSCAN}){ print "ERROR: No SOMVAR_VARSCAN option found in config files.\n"; $checkFailed = 1; }
	if($opt{SOMVAR_VARSCAN} eq "yes"){
	    if(! $opt{VARSCAN_PATH}){ print "ERROR: No VARSCAN_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{TABIX_PATH}){ print "ERROR: No TABIX_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{VARSCAN_QUEUE}){ print "ERROR: No VARSCAN_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{VARSCAN_THREADS}){ print "ERROR: No VARSCAN_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{VARSCAN_TIME}){ print "ERROR: No VARSCAN_TIME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{VARSCAN_MEM}){ print "ERROR: No VARSCAN_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{VARSCAN_SETTINGS}){ print "ERROR: No VARSCAN_SETTINGS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{VARSCAN_POSTSETTINGS}){ print "ERROR: No VARSCAN_POSTSETTINGS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{PILEUP_QUEUE}){ print "ERROR: No PILEUP_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{PILEUP_THREADS}){ print "ERROR: No PILEUP_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{PILEUP_MEM}){ print "ERROR: No PILEUP_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{PILEUP_TIME}){ print "ERROR: No PILEUP_TIME option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{SOMVAR_FREEBAYES}){ print "ERROR: No SOMVAR_FREEBAYES option found in config files.\n"; $checkFailed = 1; }
	if($opt{SOMVAR_FREEBAYES} eq "yes"){
	    if(! $opt{FREEBAYES_PATH}){ print "ERROR: No FREEBAYES_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{BIOVCF_PATH}){ print "ERROR: No BIOVCF_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{VCFLIB_PATH}){ print "ERROR: No VCFLIB_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{VT_PATH}){ print "ERROR: No VT_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEBAYES_QUEUE}){ print "ERROR: No FREEBAYES_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEBAYES_THREADS}){ print "ERROR: No FREEBAYES_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEBAYES_MEM}){ print "ERROR: No FREEBAYES_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEBAYES_TIME}){ print "ERROR: No FREEBAYES_TIME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEBAYES_SETTINGS}){ print "ERROR: No FREEBAYES_SETTINGS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEBAYES_SOMATICFILTER}){ print "ERROR: No FREEBAYES_SOMATICFILTER option found in config files.\n"; $checkFailed = 1; }
	    #if(! $opt{FREEBAYES_GERMLINEFILTER}){ print "ERROR: No FREEBAYES_GERMLINEFILTER option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{SOMVAR_MUTECT}){ print "ERROR: No SOMVAR_MUTECT option found in config files.\n"; $checkFailed = 1; }
	if($opt{SOMVAR_MUTECT} eq "yes"){
	    if(! $opt{MUTECT_PATH}){ print "ERROR: No MUTECT_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MUTECT_QUEUE}){ print "ERROR: No MUTECT_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MUTECT_THREADS}){ print "ERROR: No MUTECT_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MUTECT_MEM}){ print "ERROR: No MUTECT_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MUTECT_TIME}){ print "ERROR: No MUTECT_TIME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MUTECT_COSMIC}){ print "ERROR: No MUTECT_COSMIC option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{SOMVARMERGE_QUEUE}){ print "ERROR: No SOMVARMERGE_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{SOMVARMERGE_THREADS}){ print "ERROR: No SOMVARMERGE_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{SOMVARMERGE_MEM}){ print "ERROR: No SOMVARMERGE_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{SOMVARMERGE_TIME}){ print "ERROR: No SOMVARMERGE_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{SOMVAR_ANNOTATE}){ print "ERROR: No SOMVAR_ANNOTATE option found in config files.\n"; $checkFailed = 1; }
	if($opt{SOMVAR_ANNOTATE} eq "yes"){
	    if(! $opt{ANNOTATE_DB}){ print "ERROR: No ANNOTATE_DB option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{ANNOTATE_FLAGS}){ print "ERROR: No ANNOTATE_FLAGS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{ANNOTATE_IDNAME}){ print "ERROR: No ANNOTATE_IDNAME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{ANNOTATE_IDDB}){ print "ERROR: No ANNOTATE_IDDB option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{CALLING_DBSNP}){ print "ERROR: No CALLING_DBSNP option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{SOMVAR_MELT}){ print "ERROR: No SOMVAR_MELT option found in config files.\n"; $checkFailed = 1; }
    }
    ## COPY_NUMBER
    if($opt{COPY_NUMBER} eq "yes"){
	if(! $opt{CNVCHECK_QUEUE} ) { print "ERROR: No CNVCHECK_QUEUE in config files.\n"; $checkFailed = 1; }
	if(! $opt{CNVCHECK_THREADS} ) { print "ERROR: No CNVCHECK_THREADS  in config files.\n"; $checkFailed = 1; }
	if(! $opt{CNVCHECK_MEM} ) { print "ERROR: No CNVCHECK_MEM in config files.\n"; $checkFailed = 1; }
	if(! $opt{CNVCHECK_TIME} ) { print "ERROR: No CNVCHECK_TIME in config files.\n"; $checkFailed = 1; }
	if(! $opt{CNV_CONTRA}){ print "ERROR: No CNV_CONTRA  in config files.\n"; $checkFailed = 1; }
	if(! $opt{CNV_MODE}){ print "ERROR: No CNV_MODE in config files. \n"; $checkFailed = 1; }
	if($opt{CNV_MODE} eq "sample_control"){
	    if(! $opt{SOMATIC_REGEX}){ print "ERROR: No SOMATIC_REGEX in config files. \n"; $checkFailed = 1; }
	}
	if($opt{CNV_CONTRA} eq "yes"){
	    if($opt{CNV_MODE} eq "sample"){ print "ERROR: Running Contra in CNV_MODE sample is not possible.\n"; $checkFailed = 1;}
	    if(! $opt{CONTRA_PATH}){ print "ERROR: No CONTRA_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{CONTRA_QUEUE}){ print "ERROR: No CONTRA_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{CONTRA_THREADS}){ print "ERROR: No CONTRA_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{CONTRA_MEM}){ print "ERROR: No CONTRA_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{CNV_TARGETS}){ print "ERROR: No CNV_TARGETS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{CONTRA_FLAGS}){ print "ERROR: No CONTRA_FLAGS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{CONTRA_VISUALIZATION}){ print "ERROR: No CONTRA_VISUALIZATION option found in config files.\n"; $checkFailed = 1; }
	    if($opt{CONTRA_VISUALIZATION} eq "yes"){
		if(! $opt{CONTRA_PLOTSCRIPT}){ print "ERROR: No CONTRA_PLOTSCRIPT option found in config files.\n"; $checkFailed = 1; }
		if(! $opt{CONTRA_PLOTDESIGN}){ print "ERROR: No CONTRA_PLOTDESIGN option found in config files.\n"; $checkFailed = 1; }
	    }
	}
	if(! $opt{CNV_FREEC}){ print "ERROR: No CNV_FREEC  in config files.\n"; $checkFailed = 1; }
	if($opt{CNV_FREEC} eq "yes"){
	    if(! $opt{FREEC_PATH}){ print "ERROR: No FREEC_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEC_QUEUE}){ print "ERROR: No FREEC_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEC_THREADS}){ print "ERROR: No FREEC_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEC_MEM}){ print "ERROR: No FREEC_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEC_TIME}){ print "ERROR: No FREEC_TIME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEC_CHRLENFILE}){ print "ERROR: No FREEC_CHRLENFILE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEC_CHRFILES}){ print "ERROR: No FREEC_CHRFILES option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEC_PLOIDY}){ print "ERROR: No FREEC_PLOIDY option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEC_WINDOW}){ print "ERROR: No FREEC_WINDOW option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{FREEC_TELOCENTROMERIC}){ print "ERROR: No FREEC_TELOCENTROMERIC option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{CNV_QDNASEQ}){ print "ERROR: No CNV_QDNASEQ  in config files.\n"; $checkFailed = 1; }
	if($opt{CNV_QDNASEQ} eq "yes"){
	    if(! $opt{QDNASEQ_PATH}){ print "ERROR: No QDNASEQ_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{QDNASEQ_QUEUE}){ print "ERROR: No QDNASEQ_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{QDNASEQ_THREADS}){ print "ERROR: No QDNASEQ_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{QDNASEQ_MEM}){ print "ERROR: No QDNASEQ_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{QDNASEQ_TIME}){ print "ERROR: No QDNASEQ_TIME option found in config files.\n"; $checkFailed = 1; }
	}
    }
    ## Telomere
    if($opt{TELOMERECAT} eq "yes"){
      if(! $opt{TELOMERECAT_PATH}){ print "ERROR: No TELOMERECAT_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{TELOMERECAT_QUEUE}){ print "ERROR: No TELOMERECAT_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{TELOMERECAT_THREADS}){ print "ERROR: No TELOMERECAT_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{TELOMERECAT_MEM}){ print "ERROR: No TELOMERECAT_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{TELOMERECAT_TIME}){ print "ERROR: No TELOMERECAT_TIME option found in config files.\n"; $checkFailed = 1; }
    }
    ## SV_CALLING
    if($opt{SV_CALLING} eq "yes"){
	if(! $opt{SV_MANTA}){ print "ERROR: No SV_MANTA option found in config files.\n"; $checkFailed = 1; }
	if($opt{SV_MANTA} eq "yes"){
	    if(! $opt{MANTA_PATH}){ print "ERROR: No MANTA_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MANTA_QUEUE}){ print "ERROR: No MANTA_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MANTA_THREADS}){ print "ERROR: No MANTA_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MANTA_MEM}){ print "ERROR: No MANTA_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{MANTA_TIME}){ print "ERROR: No MANTA_TIME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{HMFTOOLS_PROFILE}){ print "ERROR: No HMFTOOLS_PROFILE option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{SV_DELLY}){ print "ERROR: No SV_DELLY option found in config files.\n"; $checkFailed = 1; }
	if($opt{SV_DELLY} eq "yes"){
	    if(! $opt{DELLY_PATH}){ print "ERROR: No DELLY_PATH option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_QUEUE}){ print "ERROR: No DELLY_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_THREADS}){ print "ERROR: No DELLY_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_MEM}){ print "ERROR: No DELLY_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_TIME}){ print "ERROR: No DELLY_TIME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_MERGE_QUEUE}){ print "ERROR: No DELLY_MERGE_QUEUE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_MERGE_TIME}){ print "ERROR: No DELLY_MERGE_TIME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_MERGE_THREADS}){ print "ERROR: No DELLY_MERGE_THREADS option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_MERGE_MEM}){ print "ERROR: No DELLY_MERGE_MEM option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_SVTYPE}){ print "ERROR: No DELLY_SVTYPE option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_SPLIT}){ print "ERROR: No DELLY_SPLIT option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_MAPQUAL}){ print "ERROR: No DELLY_MAPQUAL option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_MAD}){ print "ERROR: No DELLY_MAD option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_FLANK}){ print "ERROR: No DELLY_FLANK option found in config files.\n"; $checkFailed = 1; }
	    #if(! $opt{DELLY_VCF_GENO}){ print "ERROR: No DELLY_VCF_GENO option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{DELLY_GENO_QUAL}){ print "ERROR: No DELLY_GENO_QUA option found in config files.\n"; $checkFailed = 1; }
	}
  if(! $opt{SV_GRIDSS}){ print "ERROR: No SV_GRIDSS option found in config files.\n"; $checkFailed = 1; }
  if($opt{SV_GRIDSS} eq "yes") {
      if(! $opt{GRIDSS_PATH}){ print "ERROR: No GRIDSS_PATH option found in config files.\n"; $checkFailed = 1; }
      if(! $opt{GRIDSS_QUEUE}){ print "ERROR: No GRIDSS_QUEUE option found in config files.\n"; $checkFailed = 1; }
      if(! $opt{GRIDSS_THREADS}){ print "ERROR: No GRIDSS_THREADS option found in config files.\n"; $checkFailed = 1; }
      if(! $opt{GRIDSS_MEM}){ print "ERROR: No GRIDSS_MEM option found in config files.\n"; $checkFailed = 1; }
      if(! $opt{GRIDSS_TIME}){ print "ERROR: No GRIDSS_TIME option found in config files.\n"; $checkFailed = 1; }

  }
    }
    ##BAF Analysis
    if($opt{BAF} eq "yes"){
	if(! $opt{BAF_QUEUE}){ print "ERROR: No BAF_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BAF_THREADS}){ print "ERROR: No BAF_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BAF_MEM}){ print "ERROR: No BAF_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BAF_TIME}){ print "ERROR: No BAF_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BIOVCF_PATH}){ print "ERROR: No BIOVCF_PATH option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{BAF_SNPS}){ print "ERROR: No BAF_SNPS option found in config files.\n"; $checkFailed = 1; }
    }
    ## Callable Loci
    if($opt{CALLABLE_LOCI} eq "yes"){
	if(! $opt{CALLABLE_LOCI_QUEUE}){ print "ERROR: No CALLABLE_LOCI_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLABLE_LOCI_THREADS}){ print "ERROR: No CALLABLE_LOCI_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLABLE_LOCI_MEM}){ print "ERROR: No CALLABLE_LOCI_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLABLE_LOCI_TIME}){ print "ERROR: No CALLABLE_LOCI_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLABLE_LOCI_BASEQUALITY}){ print "ERROR: No CALLABLE_LOCI_BASEQUALITY option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLABLE_LOCI_MAPQUALITY}){ print "ERROR: No CALLABLE_LOCI_MAPQUALITY option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLABLE_LOCI_DEPTH}){ print "ERROR: No CALLABLE_LOCI_DEPTH option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{CALLABLE_LOCI_DEPTHLOWMAPQ}){ print "ERROR: No CALLABLE_LOCI_DEPTHLOWMAPQ option found in config files.\n"; $checkFailed = 1; }

    }
    ##SNP Panel Analysis
    if($opt{FINGERPRINT} eq "yes"){
	if(! $opt{FINGERPRINT_QUEUE}){ print "ERROR: No FINGERPRINT_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FINGERPRINT_THREADS}){ print "ERROR: No FINGERPRINT_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FINGERPRINT_MEM}){ print "ERROR: No FINGERPRINT_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FINGERPRINT_TIME}){ print "ERROR: No FINGERPRINT_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{FINGERPRINT_TARGET}){ print "ERROR: No FINGERPRINT_TARGET option found in config files.\n"; $checkFailed = 1; }
    }
    ## ANNOTATE_VARIANTS
    if($opt{ANNOTATE_VARIANTS} eq "yes"){
	if(! $opt{SNPEFF_PATH}){ print "ERROR: No SNPEFF_PATH option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{IGVTOOLS_PATH}){ print "ERROR: No IGVTOOLS_PATH option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{ANNOTATE_QUEUE}){ print "ERROR: No ANNOTATE_QUEUE option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{ANNOTATE_THREADS}){ print "ERROR: No ANNOTATE_THREADS option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{ANNOTATE_MEM}){ print "ERROR: No ANNOTATE_MEM option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{ANNOTATE_TIME}){ print "ERROR: No ANNOTATE_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{ANNOTATE_SNPEFF}){ print "ERROR: No ANNOTATE_SNPEFF option found in config files.\n"; $checkFailed = 1; }
	if($opt{ANNOTATE_SNPEFF} eq "yes"){
	    if(! $opt{ANNOTATE_DB}){ print "ERROR: No ANNOTATE_DB option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{ANNOTATE_FLAGS}){ print "ERROR: No ANNOTATE_FLAGS option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{ANNOTATE_SNPSIFT}){ print "ERROR: No ANNOTATE_SNPSIFT option found in config files.\n"; $checkFailed = 1; }
	if($opt{ANNOTATE_SNPSIFT} eq "yes"){
	    if(! $opt{ANNOTATE_DBNSFP}){ print "ERROR: No ANNOTATE_DBNSFP option found in config files.\n"; $checkFailed = 1; }
	    elsif( $opt{ANNOTATE_DBNSFP} && ! -e $opt{ANNOTATE_DBNSFP}) { print"ERROR: $opt{ANNOTATE_DBNSFP} does Not exist\n"; $checkFailed = 1; }
	    if(! $opt{ANNOTATE_FIELDS}){ print "ERROR: No ANNOTATE_FIELDS option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{ANNOTATE_FREQUENCIES}){ print "ERROR: No ANNOTATE_FREQUENCIES option found in config files.\n"; $checkFailed = 1; }
	if($opt{ANNOTATE_FREQUENCIES} eq "yes"){
	    if(! $opt{ANNOTATE_FREQNAME}){ print "ERROR: No ANNOTATE_FREQNAME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{ANNOTATE_FREQDB}){ print "ERROR: No ANNOTATE_FREQDB option found in config files.\n"; $checkFailed = 1; }
	    elsif( $opt{ANNOTATE_FREQDB} && ! -e $opt{ANNOTATE_FREQDB}) { print"ERROR: $opt{ANNOTATE_FREQDB} does Not exist\n"; $checkFailed = 1; }
	    if(! $opt{ANNOTATE_FREQINFO}){ print "ERROR: No ANNOTATE_FREQINFO option found in config files.\n"; $checkFailed = 1; }
	}
	if(! $opt{ANNOTATE_IDFIELD}){ print "ERROR: No ANNOTATE_IDFIELD option found in config files.\n"; $checkFailed = 1; }
	if($opt{ANNOTATE_IDFIELD} eq "yes"){
	    if(! $opt{ANNOTATE_IDNAME}){ print "ERROR: No ANNOTATE_IDNAME option found in config files.\n"; $checkFailed = 1; }
	    if(! $opt{ANNOTATE_IDDB}){ print "ERROR: No ANNOTATE_IDDB option found in config files.\n"; $checkFailed = 1; }
	}
    }
    ## VCF_UTILS
    if($opt{VCF_UTILS} eq "yes"){
	if(! $opt{VCFUTILS_QUEUE}){ print "ERROR: No VCFUTILS_QUEUE found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{VCFUTILS_THREADS}){ print "ERROR: No VCFUTILS_THREADS found in .ini file\n"; $checkFailed = 1; }
	#if(! $opt{VCFUTILS_SCATTER}){ print "ERROR: No VCFUTILS_SCATTER found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{VCFUTILS_MEM}){ print "ERROR: No VCFUTILS_MEM found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{VCFUTILS_TIME}){ print "ERROR: No VCFUTILS_TIME option found in config files.\n"; $checkFailed = 1; }
	if(! $opt{VCFUTILS_KINSHIP}){ print "ERROR: No VCFUTILS_KINSHIP found in .ini file\n"; $checkFailed = 1; }
	if ( $opt{VCFUTILS_KINSHIP} eq "yes" ) {
	    if(! $opt{PLINK_PATH}){ print "ERROR: No PLINK_PATH found in .ini file\n"; $checkFailed = 1; }
	    if(! $opt{KING_PATH}){ print "ERROR: No KING_PATH found in .ini file\n"; $checkFailed = 1; }
	    if(! $opt{VCFTOOLS_PATH}){ print "ERROR: No VCFTOOLS_PATH found in .ini file\n"; $checkFailed = 1; }
	}
	if(! $opt{VCFUTILS_PHASE}){ print "ERROR: No VCFUTILS_PHASE found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{VCFUTILS_GENDERCHECK}){ print "ERROR: No VCFUTILS_GENDERCHECK found in .ini file\n"; $checkFailed = 1; }
	if ( $opt{VCFUTILS_GENDERCHECK} eq "yes" ) {
	    if(! $opt{GENDERCHECK_FEMALE_MAX_F}){ print "ERROR: No GENDERCHECK_FEMALE_MAX_F found in .ini file\n"; $checkFailed = 1; }
	    if(! $opt{GENDERCHECK_MALE_MIN_F}){ print "ERROR: No GENDERCHECK_MALE_MIN_F found in .ini file\n"; $checkFailed = 1; }
	}
	if(! $opt{VCFUTILS_ROH}){ print "ERROR: No VCFUTILS_ROH found in .ini file\n"; $checkFailed = 1; }
	if ( $opt{VCFUTILS_ROH} eq "yes" ) {
	    if(! $opt{BCFTOOLS_PATH}){ print "ERROR: No BCFTOOLS_PATH found in .ini file\n"; $checkFailed = 1; }
	    if(! $opt{ROH_SETTINGS}){ print "ERROR: No ROH_SETTINGS found in .ini file\n"; $checkFailed = 1; }
	}
	if(! $opt{VCFUTILS_SINGLE_SAMPLE_VCF}){ print "ERROR: No VCFUTILS_SINGLE_SAMPLE_VCF found in .ini file\n"; $checkFailed = 1; }
	## Check and copy ped file needed for phasing and gendercheck
	## Ped file is copied to output_dir to make sure it is accessible on compute nodes
	if ( $opt{VCFUTILS_GENDERCHECK} eq "yes" || $opt{VCFUTILS_PHASE} eq "yes" ) {
	    if(! $opt{PED_PATH}){
		print "ERROR: No PED_PATH found in .conf file\n"; $checkFailed = 1;
	    } else {
		if(! -f "$opt{PED_PATH}/$runName.ped") {
		    print "ERROR: The ped file for this run does not exist: $opt{PED_PATH}/$runName.ped.\n"; $checkFailed = 1;
		} else {
		    copy("$opt{PED_PATH}/$runName.ped","$opt{OUTPUT_DIR}/$runName.ped");
		}
	    }
	}
    }
    ## NIPT
    if($opt{NIPT} eq "yes"){
	if(! $opt{NIPT_MASTER_QUEUE}){ print "ERROR: No NIPT_MASTER_QUEUE found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{NIPT_MASTER_TIME}){ print "ERROR: No NIPT_MASTER_TIME found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{NIPT_MASTER_THREADS}){ print "ERROR: No NIPT_MASTER_TRHEADS found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{NIPT_MASTER_MEM}){ print "ERROR: No NIPT_MASTER_MEM found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{NIPT_QUEUE}){ print "ERROR: No NIPT_QUEUE found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{NIPT_TIME}){ print "ERROR: No NIPT_TIME found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{NIPT_THREADS}){ print "ERROR: No NIPT_THREADS found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{NIPT_MEM}){ print "ERROR: No NIPT_MEM found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{CHROMATE_PATH}){ print "ERROR: No CHROMATE_PATH found in .ini file\n"; $checkFailed = 1; }
	if(! $opt{NIPT_REFERENCESET}){ print "ERROR: No NIPT_REFERENCESET found in .ini file\n"; $checkFailed = 1; }
    }

    ## CHECKING
    if($opt{CHECKING} eq "yes"){
	if(! $opt{CHECKING_QUEUE}){ print "ERROR: No CHECKING_QUEUE found in .ini file\n"; $checkFailed = 1; }
        if(! $opt{CHECKING_THREADS}){ print "ERROR: No CHECKING_THREADS found in .ini file\n"; $checkFailed = 1; }
        if(! $opt{CHECKING_MEM}){ print "ERROR: No CHECKING_MEM found in .ini file\n"; $checkFailed = 1; }
        if(! $opt{CHECKING_TIME}){ print "ERROR: No CHECKING_TIME found in .ini file\n"; $checkFailed = 1; }
        if(! $opt{CHECKING_RM}){ print "ERROR: No CHECKING_RM found in .ini file\n"; $checkFailed = 1; }
        if(! $opt{CHECKING_CLEANUP}){ print "ERROR: No CHECKING_CLEANUP found in .ini file\n"; $checkFailed = 1; }
        if($opt{CHECKING_CLEANUP} eq "yes"){
	    if(! $opt{CHECKING_CLEANUP_SCRIPT}){ print "ERROR: No CHECKING_CLEANUP_SCRIPT found in .ini file\n"; $checkFailed = 1; }
        }
    }

    if ($checkFailed) {
	print "One or more errors found in config files.";
	die;
    }
}

1;
