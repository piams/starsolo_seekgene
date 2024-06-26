#!/usr/bin/bash

## v3.2 of STARsolo wrappers is set up to guess the chemistry automatically
## newest version of the script uses STAR v2.7.10a with EM multimapper processing 
## in STARsolo which on by default; the extra matrix can be found in /raw subdir

#Increase ulimit -n from 1024 to 8096 (Due to run into following error:\
#BAMoutput.cpp:27:BAMoutput: exiting because \
#of *OUTPUT FILE* error: could not create output file ./_STARtmp//BAMsort/2/3 \
#SOLUTION: check that the path exists and you have write permission for this file. \
#Also check ulimit -n and increase it to allow more open files)

FQDIR=$1
TAG=$2

if [[ $FQDIR == "" || $TAG == "" ]]
then
  >&2 echo "Usage: ./starsolo_seekgene.sh <fastq_dir> <sample_id>"
  >&2 echo "(make sure you set the correct REF, WL, and BAM variables below)"
  exit 1
fi


TMP='/mnt/data/piam/tmp'
export TMPDIR=$TMP

FQDIR=`readlink -f $FQDIR`
CPUS=5	                                                            									## typically bsub this into normal queue with 16 cores and 64 Gb RAM.   
REF=/mnt/ssd/pavel/analysis/202403_STARsolo_HdC_scRNAseq_SeekGene/reference/GRCh38/star                 ## choose the appropriate reference 
WL=/mnt/ssd/pavel/analysis/202403_STARsolo_HdC_scRNAseq_SeekGene/barcode                                ## directory with all barcode whitelists

## choose one of the two otions, depending on whether you need a BAM file 
BAM="--outSAMtype BAM SortedByCoordinate --outBAMsortingBinsN 500 --limitBAMsortRAM 60000000000 --outMultimapperOrder Random --runRNGseed 1 --outSAMattributes NH HI AS nM CB UB CR CY UR UY GX GN"
#BAM="--outSAMtype None"

###################################################################### DONT CHANGE OPTIONS BELOW THIS LINE ##############################################################################################

mkdir $TAG
cd $TAG

## three popular cases: <sample>_1.fastq/<sample>_2.fastq, <sample>.R1.fastq/<sample>.R2.fastq, and <sample>_L001_R1_S001.fastq/<sample>_L001_R2_S001.fastq
## the command below will generate a comma-separated list for each read
R1=""
R2=""
if [[ `find $FQDIR/* | grep -P "\/$TAG[\/\._]" | grep "_1\.f.*q"` != "" ]]
then 
  R1=`find $FQDIR/* | grep -P "\/$TAG[\/\._]" | grep "_1\.f.*q" | sort | tr '\n' ',' | sed "s/,$//g"`
  R2=`find $FQDIR/* | grep -P "\/$TAG[\/\._]" | grep "_2\.f.*q" | sort | tr '\n' ',' | sed "s/,$//g"`
elif [[ `find $FQDIR/* | grep -P "\/$TAG[\/\._]" | grep "R1\.f.*q"` != "" ]]
then
  R1=`find $FQDIR/* | grep -P "\/$TAG[\/\._]" | grep "R1\.f.*q" | sort | tr '\n' ',' | sed "s/,$//g"`
  R2=`find $FQDIR/* | grep -P "\/$TAG[\/\._]" | grep "R2\.f.*q" | sort | tr '\n' ',' | sed "s/,$//g"`
elif [[ `find $FQDIR/* | grep -P "\/$TAG[\/\._]" | grep "_R1_.*\.f.*q"` != "" ]]
then
  R1=`find $FQDIR/* | grep -P "\/$TAG[\/\._]" | grep "_R1_.*\.f.*q" | sort | tr '\n' ',' | sed "s/,$//g"`
  R2=`find $FQDIR/* | grep -P "\/$TAG[\/\._]" | grep "_R2_.*\.f.*q" | sort | tr '\n' ',' | sed "s/,$//g"`
else 
  >&2 echo "ERROR: No appropriate fastq files were found! Please check file formatting, and check if you have set the right FQDIR."
  exit 1
fi

## define some key variables, in order to evaluate reads for being 1) gzipped/bzipped/un-archived; 
## 2) having barcodes from the whitelist, and which; 3) having consistent length; 4) being single- or paired-end. 
GZIP=""
BC=""
R1LEN=""
R2LEN=""
R1DIS=""
ZCMD="cat"

## see if the original fastq files are archived: 
if [[ `find $FQDIR/* | grep -P "$TAG[\/\._]" | grep "\.gz$"` != "" ]]
then  
  GZIP="--readFilesCommand zcat"
  ZCMD="zcat"
elif [[ `find $FQDIR/* | grep -P "$TAG[\/\._]" | grep "\.bz2$"` != "" ]]
then
  GZIP="--readFilesCommand bzcat"
  ZCMD="bzcat"
fi


## we need a small and random selection of reads. the solution below is a result of much trial and error.
## in the end, we select 200k reads that represent all of the files present in the FASTQ dir for this sample.
## have to use numbers because bamtofastq likes to make files with identical names in different folders..
COUNT=0
for i in `echo $R1 | tr ',' ' '`
do
  $ZCMD $i | head -4000000 > $COUNT.R1_head &
  COUNT=$((COUNT+1))
done
wait 

COUNT=0
for i in `echo $R2 | tr ',' ' ' `                                                
do 
  $ZCMD $i | head -4000000 > $COUNT.R2_head &
  COUNT=$((COUNT+1))
done
wait

## same random seed makes sure you select same reads from R1 and R2
cat *.R1_head | seqtk sample -s100 - 200000 > test.R1.fastq &
cat *.R2_head | seqtk sample -s100 - 200000 > test.R2.fastq &
wait 
rm *.R1_head *.R2_head

NBC1=`cat test.R1.fastq | awk 'NR%4==2' | cut -c-17 | grep -F -f $WL/P3CB.barcode.txt | wc -l`

BC=$WL/P3CB.barcode.txt
R1LEN=`cat test.R1.fastq | awk 'NR%4==2' | awk '{sum+=length($0)} END {printf "%d\n",sum/NR+0.5}'`
R2LEN=`cat test.R2.fastq | awk 'NR%4==2' | awk '{sum+=length($0)} END {printf "%d\n",sum/NR+0.5}'`
R1DIS=`cat test.R1.fastq | awk 'NR%4==2' | awk '{print length($0)}' | sort | uniq -c | wc -l`



## check read lengths, fail if something funky is going on: 
PAIRED=False
UMILEN=""
CBLEN=""
if (( $R1DIS > 1 && $R1LEN <= 30 ))
then 
  >&2 echo "ERROR: Read 1 (barcode) has varying length; possibly someone thought it's a good idea to quality-trim it. Please check the fastq files."
  exit 1
elif (( $R1LEN < 29 )) 
then
  >&2 echo "ERROR: Read 1 (barcode) is less than 29 bp in length. Please check the fastq files."
  exit 1
elif (( $R2LEN < 40 )) 
then
  >&2 echo "ERROR: Read 2 (biological read) is less than 40 bp in length. Please check the fastq files."
  exit 1
fi



### assign the necessary variables for barcode/UMI length/paired-end processing. 
### scripts was changed to not rely on read length for the UMIs because of the epic Hassan case
## (v2 16bp barcodes + 10bp UMIs were sequenced to 28bp, effectively removing the effects of the UMIs)
if (( $R1LEN > 51 )) 
then
  PAIRED=True
fi


#SeekGene CB and UMI structure
#structure: 'B17U12X7' X - random primer
CBLEN=17
UMILEN=12



## yet another failsafe! Some geniuses managed to sequence v3 10x with a 26bp R1, which also causes STARsolo grief. This fixes it.
if (( $CBLEN + $UMILEN > $R1LEN ))
then
  NEWUMI=$((R1LEN-CBLEN))
  BCUMI=$((UMILEN+CBLEN))
  >&2 echo "WARNING: Read 1 length ($R1LEN) is less than the sum of appropriate barcode and UMI ($BCUMI). Changing UMI setting from $UMILEN to $NEWUMI!"
  UMILEN=$NEWUMI
elif (( $CBLEN + $UMILEN < $R1LEN ))
then
  BCUMI=$((UMILEN+CBLEN))
  >&2 echo "WARNING: Read 1 length ($R1LEN) is more than the sum of appropriate barcode and UMI ($BCUMI)."
fi

### it's hard to come up with a universal rule to correctly infer strand-specificity of the experiment. 
### this is the best I could come up with: 1) check if fraction of test reads (200k random ones) maps to GeneFull forward strand 
### with higher than 50% probability; 2) if not, run the same quantification with "--soloStand Reverse" and calculate the same stat; 
### 3) output a warning, and choose the strand with higher %; 4) if both percentages are below 10, 

STRAND=Forward

STAR --runThreadN $CPUS --genomeDir $REF --readFilesIn test.R2.fastq test.R1.fastq --runDirPerm All_RWX --outSAMtype None \
     --soloType CB_UMI_Simple --soloCBwhitelist $BC --soloBarcodeReadLength 0 --soloCBlen $CBLEN --soloUMIstart $((CBLEN+1)) \
     --soloUMIlen $UMILEN --soloStrand Forward \
     --soloUMIdedup 1MM_CR --soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts --soloUMIfiltering MultiGeneUMI_CR \
     --soloCellFilter EmptyDrops_CR --clipAdapterType CellRanger4 --outFilterScoreMin 30 \
     --soloFeatures Gene GeneFull --soloOutFileNames test_forward/ features.tsv barcodes.tsv matrix.mtx &> /dev/null 

STAR --runThreadN $CPUS --genomeDir $REF --readFilesIn test.R2.fastq test.R1.fastq --runDirPerm All_RWX --outSAMtype None \
     --soloType CB_UMI_Simple --soloCBwhitelist $BC --soloBarcodeReadLength 0 --soloCBlen $CBLEN --soloUMIstart $((CBLEN+1)) \
     --soloUMIlen $UMILEN --soloStrand Reverse \
     --soloUMIdedup 1MM_CR --soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts --soloUMIfiltering MultiGeneUMI_CR \
     --soloCellFilter EmptyDrops_CR --clipAdapterType CellRanger4 --outFilterScoreMin 30 \
     --soloFeatures Gene GeneFull --soloOutFileNames test_reverse/ features.tsv barcodes.tsv matrix.mtx &> /dev/null

PCTFWD=`grep "Reads Mapped to GeneFull: Unique GeneFull" test_forward/GeneFull/Summary.csv | awk -F "," '{printf "%d\n",$2*100+0.5}'`
PCTREV=`grep "Reads Mapped to GeneFull: Unique GeneFull" test_reverse/GeneFull/Summary.csv | awk -F "," '{printf "%d\n",$2*100+0.5}'`

if (( $PCTREV >= $PCTFWD )) 
then
  STRAND=Reverse
fi

if (( $PCTREV < 50 && $PCTFWD < 50)) 
then
  >&2 echo "WARNING: Low percentage of reads mapping to GeneFull: forward = $PCTFWD , reverse = $PCTREV"
fi 

#SeekGene full length assay uses forward strand!
#### finally, if paired-end experiment turned out to be 3' (yes, they do exist!), process it as single-end: 
##if [[ $STRAND == "Forward" && $PAIRED == "True" ]]
##then
##  PAIRED=False
##fi

if [[ $PAIRED == "True" ]]
then
  ## note the R1/R2 order of input fastq reads and --soloStrand Forward for 5' paired-end experiment
  ## Note 2: same R1/R2 order of input fastq reads but --soloStrand Reverse for full-length SeekGene
  
	#Test best performing 5p clipping length (29 or 36(remove random primer))- Better alignment rate if retain random primer (i.e. 5p clip 29 bp)
	STAR --runThreadN $CPUS --genomeDir $REF --readFilesIn test.R1.fastq test.R2.fastq --runDirPerm All_RWX --outSAMtype None \
		--soloBarcodeMate 1 --clip5pNbases 36 0 \
		--soloType CB_UMI_Simple --soloCBwhitelist $BC --soloBarcodeReadLength 0 --soloCBstart 1 --soloCBlen $CBLEN --soloUMIstart $((CBLEN+1)) \
		--soloUMIlen $UMILEN --soloStrand Reverse \
		--soloUMIdedup 1MM_CR --soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts --soloUMIfiltering MultiGeneUMI_CR \
		--soloCellFilter EmptyDrops_CR --outFilterScoreMin 30 \
		--soloFeatures Gene GeneFull --soloOutFileNames test_36clip5p/ features.tsv barcodes.tsv matrix.mtx &> /dev/null 
	
	
	STAR --runThreadN $CPUS --genomeDir $REF --readFilesIn test.R1.fastq test.R2.fastq --runDirPerm All_RWX --outSAMtype None \
		--soloBarcodeMate 1 --clip5pNbases $((UMILEN+CBLEN)) 0 \
		--soloType CB_UMI_Simple --soloCBwhitelist $BC --soloBarcodeReadLength 0 --soloCBstart 1 --soloCBlen $CBLEN --soloUMIstart $((CBLEN+1)) \
		--soloUMIlen $UMILEN --soloStrand Reverse \
		--soloUMIdedup 1MM_CR --soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts --soloUMIfiltering MultiGeneUMI_CR \
		--soloCellFilter EmptyDrops_CR --outFilterScoreMin 30 \
		--soloFeatures Gene GeneFull --soloOutFileNames test_29clip5p/ features.tsv barcodes.tsv matrix.mtx &> /dev/null
		
		PCT36clip=`grep "Reads Mapped to GeneFull: Unique GeneFull" test_36clip5p/GeneFull/Summary.csv | awk -F "," '{printf "%d\n",$2*100+0.5}'`
		PCT29clip=`grep "Reads Mapped to GeneFull: Unique GeneFull" test_29clip5p/GeneFull/Summary.csv | awk -F "," '{printf "%d\n",$2*100+0.5}'`
fi

## write a file in the sample dir too, these metrics are not crucial but useful 
echo "Done setting up the STARsolo run; here are final processing options:"
echo "============================================================================="
echo "Sample: $TAG" | tee strand.txt
echo "Paired-end mode: $PAIRED" | tee -a strand.txt
echo "Strand (Forward = 3', Reverse = 5'): $STRAND, %reads mapped to GeneFull: forward = $PCTFWD , reverse = $PCTREV" | tee -a strand.txt
echo "CB whitelist: $BC, matches out of 200,000: $NBC1 (SeekGene CBs) " | tee -a strand.txt
echo "CB length: $CBLEN" | tee -a strand.txt
echo "UMI length: $UMILEN" | tee -a strand.txt
echo "GZIP: $GZIP" | tee -a strand.txt
echo "-----------------------------------------------------------------------------" | tee -a strand.txt
echo "Read 1 files: $R1" | tee -a strand.txt
echo "-----------------------------------------------------------------------------" | tee -a strand.txt
echo "Read 2 files: $R2" | tee -a strand.txt
echo "-----------------------------------------------------------------------------" | tee -a strand.txt


if [[ $PAIRED == "True" ]]
then
	echo "--clip5pNbases 36 0 %reads mapped to GeneFull: $PCT36clip" | tee -a strand.txt
	echo "--clip5pNbases 29 0 %reads mapped to GeneFull: $PCT29clip" | tee -a strand.txt
fi


#Clip 5p retaining random primer (7 bp after CB+UMI)

####PAIRED=False

if [[ $PAIRED == "True" ]]
then
  ## note the R1/R2 order of input fastq reads and --soloStrand Forward for 5' paired-end experiment (10x Genomics 5p)
  ## Note 2: same R1/R2 order of input fastq reads but --soloStrand Reverse for full-length (SeekGene full-length)
  
  STAR --runThreadN $CPUS --genomeDir $REF --readFilesIn $R1 $R2 --runDirPerm All_RWX $GZIP $BAM \
		--soloBarcodeMate 1 --clip5pNbases 29 0 --soloStrand Reverse \
		--soloType CB_UMI_Simple --soloCBwhitelist $BC --soloBarcodeReadLength 0 --soloCBstart 1 --soloCBlen $CBLEN --soloUMIstart $((CBLEN+1)) --soloUMIlen $UMILEN \
		--soloUMIdedup 1MM_CR --soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts --soloUMIfiltering MultiGeneUMI_CR \
		--soloCellFilter EmptyDrops_CR --outFilterScoreMin 30 \
		--soloFeatures Gene GeneFull --soloOutFileNames output/ features.tsv barcodes.tsv matrix.mtx --soloMultiMappers EM --outReadsUnmapped Fastx
else 
  STAR --runThreadN $CPUS --genomeDir $REF --readFilesIn $R2 $R1 --runDirPerm All_RWX $GZIP $BAM \
     --soloType CB_UMI_Simple --soloCBwhitelist $BC --soloBarcodeReadLength 0 --soloCBlen $CBLEN --soloUMIstart $((CBLEN+1)) --soloUMIlen $UMILEN --soloStrand $STRAND \
     --soloUMIdedup 1MM_CR --soloCBmatchWLtype 1MM_multi_Nbase_pseudocounts --soloUMIfiltering MultiGeneUMI_CR \
     --soloCellFilter EmptyDrops_CR --clipAdapterType CellRanger4 --outFilterScoreMin 30 \
     --soloFeatures Gene GeneFull Velocyto --soloOutFileNames output/ features.tsv barcodes.tsv matrix.mtx --soloMultiMappers EM --outReadsUnmapped Fastx
fi


## index the BAM file
if [[ -s Aligned.sortedByCoord.out.bam ]]
then
  samtools index -@16 Aligned.sortedByCoord.out.bam
fi

# max-CR bzip all unmapped reads with multicore pbzip2 
 pbzip2 -9 Unmapped.out.mate1 &
 pbzip2 -9 Unmapped.out.mate2 &
wait

## remove test files 
rm -rf test.R?.fastq test_* test_*

gzip `find ./output/ | grep features.tsv`
gzip `find ./output/ | grep barcodes.tsv`
gzip `find ./output/ | grep .mtx`

wait


echo "ALL DONE!"
