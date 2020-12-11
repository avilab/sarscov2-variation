__author__ = "Taavi Päll"
__copyright__ = "Copyright 2020, Avilab"
__email__ = "taavi.pall@ut.ee"
__license__ = "MIT"

# Load libraries
import os
import pandas as pd
from snakemake.utils import validate, makedirs
from datetime import datetime


# Load configuration file with sample and path info
configfile: "config.yaml"


validate(config, "schemas/config.schema.yaml")


# Load runs and groups
df = pd.read_csv("samples.tsv", sep="\s+", dtype=str).set_index(
    ["sample", "run"], drop=False
)
validate(df, "schemas/samples.schema.yaml")
samples = df.groupby(level=0).apply(lambda df: df.xs(df.name)["run"].tolist()).to_dict()
SAMPLE = [sample for sample, run in df.index.tolist()]
RUN = [run for sample, run in df.index.tolist()]
PLATFORM = "ILLUMINA"


# Consensus sequence metadata, let's keep it simple for now.
# Will be moved to sample.tsv to allow more flexibility
YEAR = datetime.today().year
COUNTRY = config["country"]
HEXDIG = config["hexdig"]  # should we scramble original sample names


# Path to reference genomes
REF_GENOME = config["refgenome"]
REF_GENOME_DICT = config["refgenome_dict"]
HOST_GENOME = os.getenv("REF_GENOME_HUMAN_MASKED")
RRNA_DB = os.getenv("SILVA")


# Wrappers
# Wrappers repo: https://github.com/avilab/virome-wrappers
WRAPPER_PREFIX = "https://raw.githubusercontent.com/avilab/virome-wrappers"


# Report
report: "report/workflow.rst"


rule all:
    input:
        "output/consensus_masked_hd.fa" if HEXDIG else "output/consensus_masked.fa",
        "output/snpsift.csv",
        "output/multiqc.html",
        expand(["output/{sample}/basecov.txt"], sample=list(samples.keys())),


def get_fastq(wildcards):
    fq_cols = [col for col in df.columns if "fq" in col]
    fqs = df.loc[(wildcards.sample, wildcards.run), fq_cols].dropna()
    assert len(fq_cols) in [1, 2], "Enter one or two FASTQ file paths"
    if len(fq_cols) == 2:
        return {"in1": fqs[0], "in2": fqs[1]}
    else:
        return {"input": fqs[0]}


rule reformat:
    """
    Interleave paired reads.
    """
    input:
        unpack(get_fastq),
    output:
        out=temp("output/{sample}/{run}/interleaved.fq"),
    log:
        "output/{sample}/{run}/log/reformat.log",
    params:
        extra="",
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/bbtools/reformat"


rule trim:
    """
    Quality trimming of the reads.
    """
    input:
        input=rules.reformat.output.out,
    output:
        out=temp("output/{sample}/{run}/trimmed.fq"),
    log:
        "output/{sample}/{run}/log/trim.log",
    params:
        extra="maq=10 qtrim=r trimq=10 ktrim=r k=23 mink=11 hdist=1 tbo tpe minlen=100 ref=adapters ftm=5 ordered",
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/bbtools/bbduk"


rule filter:
    """
    Remove all reads that have a 31-mer match to PhiX and other artifacts.
    """
    input:
        input=rules.trim.output.out,
    output:
        out="output/{sample}/{run}/filtered.fq",
    log:
        "output/{sample}/{run}/log/filter.log",
    params:
        extra="k=31 ref=artifacts,phix ordered cardinality",
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/bbtools/bbduk"


rule correct1:
    input:
        input=rules.filter.output.out,
    output:
        out=temp("output/{sample}/{run}/ecco.fq"),
    params:
        extra="ecco mix vstrict ordered",
    log:
        "output/{sample}/{run}/log/correct1.log",
    resources:
        runtime=120,
        mem_mb=4000,
    threads: 8
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/bbtools/bbmerge"


rule correct2:
    input:
        input=rules.correct1.output.out,
    output:
        out=temp("output/{sample}/{run}/ecct.fq"),
    params:
        extra="mode=correct k=50 ordered",
    log:
        "output/{sample}/{run}/log/correct2.log",
    resources:
        runtime=120,
        mem_mb=lambda wildcards, input: round(4000 + 6 * input.size_mb),
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/bbtools/tadpole"


rule refgenome:
    """
    Map reads to ref genome.
    """
    input:
        input=lambda wildcards: expand(
            "output/{{sample}}/{run}/ecct.fq", run=samples[wildcards.sample]
        ),
        ref=REF_GENOME,
    output:
        out="output/{sample}/refgenome.bam",
        statsfile="output/{sample}/refgenome.txt",
        gchist="output/{sample}/gchist.txt",
        aqhist="output/{sample}/aqhist.txt",
        lhist="output/{sample}/lhist.txt",
        mhist="output/{sample}/mhist.txt",
        bhist="output/{sample}/bhist.txt",
    log:
        "output/{sample}/log/refgenome.log",
    shadow:
        "minimal"
    params:
        extra=(
            lambda wildcards: f"usemodulo slow k=12 nodisk RGPL=Illumina RGID={wildcards.sample} RGSM={wildcards.sample}"
        ),
    resources:
        runtime=120,
        mem_mb=4000,
    threads: 4
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/bbtools/bbwrap"


rule samtools_sort:
    input:
        rules.refgenome.output.out,
    output:
        temp("output/{sample}/sorted.bam"),
    log:
        "output/{sample}/log/samtools_sort.log",
    params:
        extra=lambda wildcards, resources: f"-m {resources.mem_mb}M",
        tmp_dir="/tmp/",
    threads: 8
    resources:
        mem_mb=4000,
        runtime=lambda wildcards, attempt: attempt * 240,
    wrapper:
        "0.68.0/bio/samtools/sort"


rule mark_duplicates:
    input:
        rules.samtools_sort.output[0],
    output:
        bam="output/{sample}/dedup.bam",
        metrics="output/{sample}/dedup.txt",
    log:
        "output/{sample}/log/dedup.log",
    params:
        "USE_JDK_DEFLATER='true' USE_JDK_INFLATER='true' REMOVE_DUPLICATES='true' ASSUME_SORTED='true'  DUPLICATE_SCORING_STRATEGY='SUM_OF_BASE_QUALITIES'  OPTICAL_DUPLICATE_PIXEL_DISTANCE='100'   VALIDATION_STRINGENCY='LENIENT' QUIET='true' VERBOSITY='ERROR'",
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        "0.68.0/bio/picard/markduplicates"


rule indelqual:
    """
    Indel recalibration.
    """
    input:
        ref=REF_GENOME,
        bam=rules.mark_duplicates.output.bam,
    output:
        "output/{sample}/indelqual.bam",
    log:
        "output/{sample}/log/indelqual.log",
    params:
        extra="--verbose",
    resources:
        runtime=120,
        mem_mb=4000,
    threads: 8
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/lofreq/indelqual"


rule lofreq1:
    """
    Variant calling.
    """
    input:
        ref=REF_GENOME,
        bam=rules.indelqual.output[0],
    output:
        "output/{sample}/lofreq1.vcf",
    log:
        "output/{sample}/log/lofreq1.log",
    params:
        extra="--min-cov 50 --max-depth 1000000  --min-bq 30 --min-alt-bq 30 --min-mq 20 --max-mq 255 --min-jq 0 --min-alt-jq 0 --def-alt-jq 0 --sig 0.01 --bonf dynamic --no-default-filter",
    resources:
        runtime=120,
        mem_mb=4000,
    threads: 1
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/lofreq/call"


rule indexfeaturefile:
    """
    Index vcf vile.
    """
    input:
        "output/{sample}/lofreq1.vcf",
    output:
        "output/{sample}/lofreq1.vcf.idx",
    log:
        "output/{sample}/log/indexfeaturefile.log",
    params:
        extra="",
    resources:
        runtime=120,
        mem_mb=4000,
    threads: 1
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6.1/gatk/indexfeaturefile"


rule gatk_baserecalibrator:
    input:
        ref=REF_GENOME,
        bam=rules.mark_duplicates.output.bam,
        dict=REF_GENOME_DICT,
        known="output/{sample}/lofreq1.vcf",
        feature_index=rules.indexfeaturefile.output[0],
    output:
        recal_table="output/{sample}/recal_table.grp",
    log:
        "output/{sample}/log/baserecalibrator.log",
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        "0.68.0/bio/gatk/baserecalibrator"


rule applybqsr:
    """
    Inserts indel qualities into BAM.
    """
    input:
        ref=REF_GENOME,
        bam=rules.mark_duplicates.output.bam,
        recal_table="output/{sample}/recal_table.grp",
    output:
        bam="output/{sample}/recalibrated.bam",
    log:
        "output/{sample}/log/applybqsr.log",
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        "0.68.0/bio/gatk/applybqsr"


rule pileup:
    """
    Calculate coverage.
    """
    input:
        input=rules.applybqsr.output.bam,
        ref=REF_GENOME,
    output:
        out="output/{sample}/covstats.txt",
        basecov="output/{sample}/basecov.txt",
    log:
        "output/{sample}/log/pileup.log",
    params:
        extra="concise",
    resources:
        runtime=lambda wildcards, attempt: attempt * 120,
        mem_mb=lambda wildcards, attempt: attempt * 8000,
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/bbtools/pileup"


rule lofreq2:
    """
    Variant calling.
    """
    input:
        ref=REF_GENOME,
        bam=rules.indelqual.output[0],
    output:
        "output/{sample}/lofreq.vcf",
    log:
        "output/{sample}/log/lofreq2.log",
    params:
        extra="--call-indels --min-cov 50 --max-depth 1000000  --min-bq 30 --min-alt-bq 30 --min-mq 20 --max-mq 255 --min-jq 0 --min-alt-jq 0 --def-alt-jq 0 --sig 0.01 --bonf dynamic --no-default-filter",
    resources:
        runtime=120,
        mem_mb=4000,
    threads: 1
    wrapper:
        f"{WRAPPER_PREFIX}/v0.6/lofreq/call"


rule vcffilter:
    """
    Filter variants based on allele frequency.
    """
    input:
        "output/{sample}/lofreq.vcf",
    output:
        "output/{sample}/filtered.vcf",
    log:
        "output/{sample}/log/vcffilter.log",
    params:
        extra="-f 'AF > 0.5'",
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        f"{WRAPPER_PREFIX}/v0.2/vcflib/vcffilter"


rule genome_consensus:
    """
    Generate consensus genome, 
    mask positions with low coverage.
    """
    input:
        ref=REF_GENOME,
        reads=lambda wildcards: expand(
            "output/{{sample}}/{run}/filtered.fq", run=samples[wildcards.sample],
        ),
        vcf="output/{sample}/filtered.vcf",
    output:
        vcfgz="output/{sample}/filtered.vcf.gz",
        consensus="output/{sample}/consensus_badname.fa",
        sam="output/{sample}/consensus.sam",
        consensus_masked="output/{sample}/consensus_masked_badname.fa",
        bed="output/{sample}/merged.bed",
    log:
        "output/{sample}/log/genome_consensus.log",
    params:
        mask=1,
        extra=(
            lambda wildcards, resources: f"-Xmx{resources.mem_mb}m slow k=12 maxlen=600"
        ), # parameters passed to bbmap
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        f"{WRAPPER_PREFIX}/master/genome-consensus"


rule rename:
    """
    Rename fasta sequences.
    """
    input:
        rules.genome_consensus.output.consensus_masked,
    output:
        "output/{sample}/consensus_masked_hd.fa" if HEXDIG else "output/{sample}/consensus_masked.fa",
    params:
        sample=lambda wildcards: wildcards.sample,
        stub=f"SARS-CoV-2/human/{COUNTRY}/{{}}/{YEAR}",
        hexdigest=HEXDIG,
    resources:
        runtime=120,
        mem_mb=2000,
    wrapper:
        f"{WRAPPER_PREFIX}/v0.2/sequences/rename_fasta"


rule merge_renamed:
    """
    Merge fasta files.
    """
    input:
        expand(
            "output/{sample}/consensus_masked_hd.fa"
            if HEXDIG
            else "output/{sample}/consensus_masked.fa",
            sample=samples.keys(),
        ),
    output:
        "output/consensus_masked_hd.fa" if HEXDIG else "output/consensus_masked.fa",
    resources:
        runtime=120,
        mem_mb=2000,
    shell:
        "cat {input} > {output}"


rule snpeff:
    """
    Functional annotation of variants.
    """
    input:
        calls="output/{sample}/filtered.vcf",
        db="refseq/NC045512",
    output:
        calls="output/{sample}/snpeff.vcf", # annotated calls (vcf, bcf, or vcf.gz)
        stats="output/{sample}/snpeff.html", # summary statistics (in HTML), optional
        csvstats="output/{sample}/snpeff.csv", # summary statistics in CSV, optional
        genes="output/{sample}/snpeff.genes.txt",
    log:
        "output/{sample}/log/snpeff.log",
    params:
        extra="-configOption NC045512.genome=NC045512",
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        "0.68.0/bio/snpeff/annotate"


rule snpsift:
    """
    Parse snpeff output to tabular format.
    """
    input:
        rules.snpeff.output.calls,
    output:
        "output/{sample}/snpsift.txt",
    params:
        extra="-s ',' -e '.'",
        fieldnames="CHROM POS REF ALT DP AF SB DP4 EFF[*].IMPACT EFF[*].FUNCLASS EFF[*].EFFECT EFF[*].GENE EFF[*].CODON",
    wrapper:
        f"{WRAPPER_PREFIX}/v0.2/snpsift"


rule merge_tables:
    """
    Merge variant tables.
    """
    input:
        expand("output/{sample}/snpsift.txt", sample=samples.keys()),
    output:
        "output/snpsift.csv",
    run:
        import pandas as pd

        files = {}
        for file in input:
            files.update({file.split("/")[1]: pd.read_csv(file, sep="\t")})
        concatenated = pd.concat(files, names=["Sample"])
        modified = concatenated.reset_index()
        modified.to_csv(output[0], index=False)


# Run fastq_screen only when databases are present
fastq_screen_db = {
    k: v
    for k, v in dict({"human": HOST_GENOME, "SILVA_138_SSU_132_LSU": RRNA_DB}).items()
    if os.path.exists(v if v else "")
}


rule fastq_screen:
    """
    Estimate reads mapping to host and bacteria (rRNA).
    """
    input:
        rules.filter.output.out,
    output:
        txt="output/{sample}/{run}/fastq_screen.txt",
        html="output/{sample}/{run}/fastq_screen.html",
    log:
        "output/{sample}/{run}/log/fastq_screen.log",
    params:
        fastq_screen_config={"database": fastq_screen_db},
        subset=100000,
    resources:
        runtime=120,
        mem_mb=8000,
    threads: 4
    wrapper:
        f"{WRAPPER_PREFIX}/v0.2.1/fastq_screen"


rule fastqc:
    """
    Calculate input reads quality stats.
    """
    input:
        rules.reformat.output.out,
    output:
        html="output/{sample}/{run}/fastqc.html",
        zip="output/{sample}/{run}/fastqc.zip",
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        "0.27.1/bio/fastqc"


rule bamstats:
    """
    Host genome mapping stats.
    """
    input:
        rules.refgenome.output.out,
    output:
        "output/{sample}/bamstats.txt",
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        "0.42.0/bio/samtools/stats"


rule multiqc:
    """
    Generate comprehensive report.
    """
    input:
        expand(
            [
                "output/{sample}/{run}/fastq_screen.txt",
                "output/{sample}/{run}/fastqc.zip",
            ]
            if fastq_screen_db
            else "output/{sample}/{run}/fastqc.zip",
            zip,
            sample=SAMPLE,
            run=RUN,
        ),
        expand(
            ["output/{sample}/snpeff.csv", "output/{sample}/bamstats.txt"],
            sample=samples.keys(),
        ),
    output:
        report(
            "output/multiqc.html",
            caption="report/multiqc.rst",
            category="Quality control",
        ),
    params:
        "-d -dd 1",
    log:
        "output/multiqc.log",
    resources:
        runtime=120,
        mem_mb=4000,
    wrapper:
        f"{WRAPPER_PREFIX}/v0.2/multiqc"
