#!/usr/bin/perl -w

##################################################################
### illumina_calling.pm
### - Run gatk variant callers, depending on qscript
###  - Haplotype caller: normal and gvcf mode
###  - Unified genotyper 
### - VCF Prep function if pipeline is started with a vcf file
###
### Authors: R.F.Ernst & H.H.D.Kerstens
##################################################################

package IAP::calling;

use strict;
use POSIX qw(tmpnam);
use lib "$FindBin::Bin"; #locates pipeline directory
use IAP::sge;

sub runVariantCalling {
    ###
    # Run variant callers
    ###
    my $configuration = shift;
    my %opt = %{$configuration};
    my $runName = (split("/", $opt{OUTPUT_DIR}))[-1];
    my @sampleBams;
    my @runningJobs;
    my $jobID = "VC_".get_job_id();

    ### Skip variant calling if .raw_variants.vcf already exists
    if (-e "$opt{OUTPUT_DIR}/logs/VariantCaller.done"){
	print "WARNING: $opt{OUTPUT_DIR}/logs/VariantCaller.done exists, skipping \n";
	return \%opt;
    }

    ### Create gvcf folder if CALLING_GVCF eq yes
    if((! -e "$opt{OUTPUT_DIR}/gvcf" && $opt{CALLING_GVCF} eq 'yes')){
	mkdir("$opt{OUTPUT_DIR}/gvcf") or die "Couldn't create directory: $opt{OUTPUT_DIR}/gvcf\n";
    }
    
    ### Build Queue command
    my $jobNative = &jobNative(\%opt,"CALLING");
    my $determine_sex = ""; #Only used in sex aware calling
    my $command = "java -Xmx".$opt{CALLING_MASTER_MEM}."G -Djava.io.tmpdir=$opt{OUTPUT_DIR}/tmp -jar $opt{QUEUE_PATH}/Queue.jar ";
    $command .= "-jobQueue $opt{CALLING_QUEUE} -jobNative \"$jobNative\" -jobRunner GridEngine -jobReport $opt{OUTPUT_DIR}/logs/VariantCaller.jobReport.txt -memLimit $opt{CALLING_MEM} "; #Queue options

    ### Add caller and UG specific settings
    $command .= "-S $opt{IAP_PATH}/$opt{CALLING_SCALA} ";
    if ($opt{CALLING_UGMODE}) {
	$command .= " -glm $opt{CALLING_UGMODE} ";
    }

    ### Common settings
    $command .= "-R $opt{GENOME} -O $runName -mem $opt{CALLING_MEM} -nct $opt{CALLING_THREADS} -nsc $opt{CALLING_SCATTER} -stand_call_conf $opt{CALLING_STANDCALLCONF} -stand_emit_conf $opt{CALLING_STANDEMITCONF} ";

    ### Add all bams
    foreach my $sample (@{$opt{SAMPLES}}){
	my $sampleBam = "$opt{OUTPUT_DIR}/$sample/mapping/$opt{BAM_FILES}->{$sample}";

	$command .= "-I $sampleBam ";
	push( @sampleBams, $sampleBam);
	## Running jobs
	if ( @{$opt{RUNNING_JOBS}->{$sample}} ){
	    push( @runningJobs, @{$opt{RUNNING_JOBS}->{$sample}} );
	}
    }

    ### Optional settings
    if ( $opt{CALLING_DBSNP} ) {
	$command .= "-D $opt{CALLING_DBSNP} ";
    }
    if ( $opt{CALLING_TARGETS} ) {
	$command .= "-L $opt{CALLING_TARGETS} ";
	if ( $opt{CALLING_INTERVALPADDING} ) {
	    $command .= "-ip $opt{CALLING_INTERVALPADDING} ";
	}
    }
    if ( $opt{CALLING_PLOIDY} ) {
	$command .= "-ploidy $opt{CALLING_PLOIDY} ";
    }
    if($opt{CALLING_GVCF} eq 'yes'){
	$command .= "-gvcf ";
	if($opt{CALLING_SEXAWARE} eq 'yes'){
	    $command .= "-sexAware ";
	    for my $i (0 .. $#sampleBams) {
		$determine_sex .= "\tSEX_$i=`python $opt{IAP_PATH}/scripts/determine_sex.py -b $sampleBams[$i]`\n";
		$command .= "-sex \$SEX_$i ";
	    }
	}
    }
    
    ### retry option
    if($opt{QUEUE_RETRY} eq 'yes'){
	$command  .= "-retry 1 ";
    }
    $command .= "-run";

    #Create main bash script
    my $bashFile = $opt{OUTPUT_DIR}."/jobs/VariantCalling_".$jobID.".sh";
    my $logDir = $opt{OUTPUT_DIR}."/logs";

    open CALLING_SH, ">$bashFile" or die "cannot open file $bashFile \n";
    print CALLING_SH "#!/bin/bash\n\n";
    print CALLING_SH "bash $opt{CLUSTER_PATH}/settings.sh\n\n";
    print CALLING_SH "cd $opt{OUTPUT_DIR}/tmp/\n";
    print CALLING_SH "echo \"Start variant caller\t\" `date` \"\t\" `uname -n` >> $opt{OUTPUT_DIR}/logs/$runName.log\n\n";
    
    print CALLING_SH "if [ -s ".shift(@sampleBams)." ";
    foreach my $sampleBam (@sampleBams){
	print CALLING_SH "-a -s $sampleBam ";
    }
    print CALLING_SH "]\n";
    print CALLING_SH "then\n";
    if($opt{CALLING_GVCF} eq 'yes' && $opt{CALLING_SEXAWARE} eq 'yes'){
	print CALLING_SH $determine_sex;
    }
    print CALLING_SH "\t$command\n";
    print CALLING_SH "else\n";
    print CALLING_SH "\techo \"ERROR: One or more input bam files do not exist.\" >&2\n";
    print CALLING_SH "fi\n\n";
    
    print CALLING_SH "if [ -f $opt{OUTPUT_DIR}/tmp/.$runName\.raw_variants.vcf.done ]\n";
    print CALLING_SH "then\n";
    print CALLING_SH "\tmv $opt{OUTPUT_DIR}/tmp/$runName\.raw_variants.vcf $opt{OUTPUT_DIR}/\n";
    print CALLING_SH "\tmv $opt{OUTPUT_DIR}/tmp/$runName\.raw_variants.vcf.idx $opt{OUTPUT_DIR}/\n";
    if($opt{CALLING_GVCF} eq 'yes'){
	print CALLING_SH "\tmv $opt{OUTPUT_DIR}/tmp/*.g.vcf.gz $opt{OUTPUT_DIR}/gvcf/\n";
	print CALLING_SH "\tmv $opt{OUTPUT_DIR}/tmp/*.g.vcf.gz.tbi $opt{OUTPUT_DIR}/gvcf/\n";
	
    }
    print CALLING_SH "\ttouch $opt{OUTPUT_DIR}/logs/VariantCaller.done\n";
    print CALLING_SH "fi\n\n";
    print CALLING_SH "echo \"Finished variant caller\t\" `date` \"\t\" `uname -n` >> $opt{OUTPUT_DIR}/logs/$runName.log\n";
    
    #Start main bash script
    my $qsub = &qsubJava(\%opt,"CALLING_MASTER");
    if (@runningJobs){
	system "$qsub -o $logDir/VariantCaller_$runName.out -e $logDir/VariantCaller_$runName.err -N $jobID -hold_jid ".join(",",@runningJobs)." $bashFile";
    } else {
	system "$qsub -o $logDir/VariantCaller_$runName.out -e $logDir/VariantCaller_$runName.err -N $jobID $bashFile";
    }
    
    ### Store jobID
    foreach my $sample (@{$opt{SAMPLES}}){
	push (@{$opt{RUNNING_JOBS}->{$sample}} , $jobID);
    }
    return \%opt;
}

sub runFingerprint {
    ###
    # Run single sample UnifiedGenotyper for genetic fingerprint analysis
    ###
    my $configuration = shift;
    my %opt = %{$configuration};
    my $runName = (split("/", $opt{OUTPUT_DIR}))[-1];
    my $jobID = "Fingerprint_".get_job_id();
    my @running_jobs;
    my $log_dir = $opt{OUTPUT_DIR}."/logs";
    my $output_dir = "$opt{OUTPUT_DIR}/fingerprint";

    ### Create output folder
    if(! -e $output_dir){
	mkdir($output_dir) or die "Couldn't create directory: $output_dir\n";
    }
    ### Create bash script
    my $bashFile = $opt{OUTPUT_DIR}."/jobs/".$jobID.".sh";

    open FINGERPRINT_SH, ">$bashFile" or die "cannot open file $bashFile \n";
    print FINGERPRINT_SH "#!/bin/bash\n";
    print FINGERPRINT_SH "bash $opt{CLUSTER_PATH}/settings.sh\n\n";
    print FINGERPRINT_SH "cd $output_dir\n\n";

    foreach my $sample (@{$opt{SAMPLES}}){
	if (-e "$log_dir/Fingerprint_$sample.done"){
	    print "WARNING: $opt{OUTPUT_DIR}/logs/Fingerprint_$sample.done exists, skipping \n";
	} else {
	    my $sample_bam = "$opt{OUTPUT_DIR}/$sample/mapping/$opt{BAM_FILES}->{$sample}";
	    my $output_vcf = $sample."_fingerprint.vcf";

	    ## Running jobs
	    if ( @{$opt{RUNNING_JOBS}->{$sample}} ){
		push( @running_jobs, @{$opt{RUNNING_JOBS}->{$sample}} );
	    }

	    ### Build gatk command
	    my $command = "java -Djava.io.tmpdir=$opt{OUTPUT_DIR}/tmp/ -Xmx".$opt{FINGERPRINT_MEM}."G -jar $opt{QUEUE_PATH}/GenomeAnalysisTK.jar ";
	    $command .= "-T UnifiedGenotyper ";
	    $command .= "-R $opt{GENOME} ";
	    $command .= "-L $opt{FINGERPRINT_TARGET} ";
	    $command .= "-I $sample_bam ";
	    $command .= "-o $output_vcf ";
	    $command .= "--output_mode EMIT_ALL_SITES ";

	    print FINGERPRINT_SH "if [ -s $sample_bam ]\n";
	    print FINGERPRINT_SH "then\n";
	    print FINGERPRINT_SH "\t$command\n";
	    print FINGERPRINT_SH "else\n";
	    print FINGERPRINT_SH "\techo \"ERROR: Sample bam file do not exist.\" >&2\n";
	    print FINGERPRINT_SH "fi\n";

	    print FINGERPRINT_SH "if [ \"\$(tail -n 1 $output_vcf | cut -f 1,2)\" = \"\$(tail -n 1 $opt{FINGERPRINT_TARGET} | cut -f 1,2)\" ]\n";
	    print FINGERPRINT_SH "then\n";
	    print FINGERPRINT_SH "\ttouch $log_dir/Fingerprint_$sample.done\n";
	    print FINGERPRINT_SH "fi\n\n";
	}
    }

    ## Submit fingerprint job
    my $qsub = &qsubJava(\%opt,"FINGERPRINT");
    if (@running_jobs){
	system "$qsub -o $log_dir/Fingerprint.out -e $log_dir/Fingerprint.err -N $jobID -hold_jid ".join(",",@running_jobs)." $bashFile";
    } else {
	system "$qsub -o $log_dir/Fingerprint.out -e $log_dir/Fingerprint.err -N $jobID $bashFile";
    }
    return $jobID;
}


sub runVcfPrep {
    ###
    # Run vcf prep when starting pipeline with a vcf file.
    ##
    my $configuration = shift;
    my %opt = %{$configuration};
    my $runName = (split("/", $opt{OUTPUT_DIR}))[-1];

    symlink($opt{VCF},"$opt{OUTPUT_DIR}/$runName.raw_variants.vcf");
    @{$opt{SAMPLES}} = ($runName);
    
    return \%opt;
}

############
sub get_job_id {
    my $id = tmpnam();
    $id=~s/\/tmp\/file//;
    return $id;
}
############

1;