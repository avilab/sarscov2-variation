__author__ = "Taavi Päll"
__copyright__ = "Copyright 2020, Avilab"
__email__ = "taavi.pall@ut.ee"
__license__ = "MIT"

# Load libraries
import os
import json
import glob
import pandas as pd
from snakemake.remote.FTP import RemoteProvider as FTPRemoteProvider
from snakemake.utils import validate, makedirs


# Load configuration file with sample and path info
configfile: "config.yaml"
validate(config, "schemas/config.schema.yaml")


# Load runs and groups
SAMPLES = pd.read_csv(config["samples"], sep="\s+", dtype=str).set_index(["run"], drop=False)
validate(SAMPLES, "schemas/samples.schema.yaml")
RUN = SAMPLES.index.tolist()


# Path to reference genomes
REF_GENOME = config["refgenome"]
HOST_GENOME = os.environ["REF_GENOME_HUMAN_MASKED"]
RRNA_DB = os.environ["SILVA"]


# Wrappers
WRAPPER_PREFIX = "https://raw.githubusercontent.com/avilab/virome-wrappers/"


# Report
report: "report/workflow.rst"


onsuccess:
    email = config["email"]
    shell("mail -s 'Forkflow finished successfully' {email} < {log}")


rule all:
    input: expand(["output/{run}/multiqc.html", "output/{run}/freebayes.vcf", "output/{run}/filtered.fq", "output/{run}/unmaphost.fq", "output/{run}/fastq_screen.txt", "output/{run}/fastqc.zip"], run = RUN)


def get_fastq(wildcards):
    fq_cols = [col for col in SAMPLES.columns if "fq" in col]
    fqs = SAMPLES.loc[wildcards.run, fq_cols].dropna()
    assert len(fq_cols) in [1, 2], "Enter one or two FASTQ file paths"
    if len(fq_cols) == 2:
        return {"in1": fqs[0], "in2": fqs[1]}
    else:
        return {"input": fqs[0]}


rule clumpify:
    input:
        unpack(get_fastq)
    output:
        out = temp("output/{run}/clumpify.fq")
    params:
        extra = "dedupe optical qin=33 -da" # suppress assertions
    resources:
        runtime = 20,
        mem_mb = 4000
    log: 
        "output/{run}/log/clumpify.log"
    wrapper:
        WRAPPER_PREFIX + "master/bbmap/clumpify"


rule trim:
    input:
        input = rules.clumpify.output.out
    output:
        out = temp("output/{run}/trimmed.fq")
    params:
        extra = "ktrim=r k=23 mink=11 hdist=1 tbo tpe minlen=70 ref=adapters ftm=5 ordered qin=33"
    resources:
        runtime = 20,
        mem_mb = 4000
    log: 
        "output/{run}/log/trim.log"
    wrapper:
        WRAPPER_PREFIX + "master/bbduk"


rule filter:
    input:
        input = rules.trim.output.out
    output:
        out = "output/{run}/filtered.fq"
    params:
        extra = "k=31 ref=artifacts,phix ordered cardinality"
    resources:
        runtime = 20,
        mem_mb = 4000
    log: 
        "output/{run}/log/filter.log"
    wrapper:
        WRAPPER_PREFIX + "master/bbduk"


# Remove rRNA sequences
rule maprRNA:
    input:
        input = rules.filter.output.out,
        ref = RRNA_DB
    output:
        outu = "output/{run}/unmaprRNA.fq",
        outm = "output/{run}/maprRNA.fq",
        statsfile = "output/{run}/maprrna.txt"
    params:
        extra = "maxlen=600 nodisk -Xmx16000m"
    resources:
        runtime = 30,
        mem_mb = 16000
    threads: 4
    wrapper:
        WRAPPER_PREFIX + "master/bbmap/bbwrap"


# Remove host sequences
rule maphost:
    input:
        input = rules.maprRNA.output.outu,
        ref = HOST_GENOME
    output:
        outu = "output/{run}/unmaphost.fq",
        outm = "output/{run}/maphost.fq",
        statsfile = "output/{run}/maphost.txt"
    params:
        extra = "maxlen=600 nodisk -Xmx16000m"
    resources:
        runtime = 30,
        mem_mb = 16000
    threads: 4
    wrapper:
        WRAPPER_PREFIX + "master/bbmap/bbwrap"


# Map reads to ref genome
rule refgenome:
    input:
        input = rules.maphost.output.outu,
        ref = REF_GENOME
    output:
        out = "output/{run}/refgenome.sam",
        statsfile = "output/{run}/refgenome.txt"
    params:
        extra = "maxlen=600 nodisk -Xmx8000m"
    resources:
        runtime = 30,
        mem_mb = 8000
    threads: 4
    wrapper:
        WRAPPER_PREFIX + "master/bbmap/bbwrap"


rule samtools_sort:
    input:
        rules.refgenome.output.out
    output:
        "output/{run}/refgenome.bam"
    params:
        "-m 4G"
    resources:
        runtime = 20,
        mem_mb = 4000
    threads: 4 # Samtools takes additional threads through its option -@
    wrapper:
        "0.50.4/bio/samtools/sort"


rule genomecov:
    input:
        ibam = rules.samtools_sort.output
    output:
        "output/{run}/genomecov.bg"
    params:
        extra = "-bg"
    resources:
        runtime = 20,
        mem_mb = 16000
    wrapper: 
        WRAPPER_PREFIX + "master/bedtools/genomecov"


# Variant calling
rule freebayes:
    input:
        ref = REF_GENOME,
        samples = rules.samtools_sort.output
    output:
        "output/{run}/freebayes.vcf" 
    params:
        extra="--pooled-continuous --ploidy 1",
        pipe = """| vcffilter -f 'QUAL > 20'"""
    resources:
        runtime = 20,
        mem_mb = 4000
    threads: 1
    wrapper:
        WRAPPER_PREFIX + "master/freebayes"


rule snpeff:
    input:
        "output/{run}/freebayes.vcf"
    output:
        calls = "output/{run}/snpeff.vcf",   # annotated calls (vcf, bcf, or vcf.gz)
        stats = "output/{run}/snpeff.html",  # summary statistics (in HTML), optional
        csvstats = "output/{run}/snpeff.csv", # summary statistics in CSV, optional
        genes = "output/{run}/snpeff.genes.txt"
    log:
        "output/{run}/log/snpeff.log"
    params:
        data_dir = "data",
        reference = "NC045512", # reference name (from `snpeff databases`)
        extra = "-c ../refseq/snpEffect.config -Xmx4g"          # optional parameters (e.g., max memory 4g)
    resources:
        runtime = 20,
        mem_mb = 4000    
    wrapper:
        "0.50.4/bio/snpeff"


rule referencemaker:
    input:
        vcf = "output/{run}/freebayes.vcf",
        ref = REF_GENOME
    output:
        idx = temp("output/{run}/freebayes.vcf.idx"),
        fasta = "output/{run}/consensus.fa",
        dic = "output/{run}/consensus.dict",
        fai = "output/{run}/consensus.fa.fai"
    params:
        refmaker = "--lenient",
        bam = rules.samtools_sort.output
    resources:
        runtime = 20,
        mem_mb = 4000    
    wrapper:
        WRAPPER_PREFIX + "master/gatk/fastaalternatereferencemaker"


# QC
fastq_screen_config = {
    "database": {
        "human": HOST_GENOME,
        "SILVA_138_SSU_132_LSU": RRNA_DB
    }
}
rule fastq_screen:
    input:
        rules.trim.output.out
    output:
        txt = "output/{run}/fastq_screen.txt",
        png = "output/{run}/fastq_screen.png"
    params:
        fastq_screen_config = fastq_screen_config,
        subset = 100000
    resources:
        runtime = 30,
        mem_mb = 8000    
    threads: 4
    wrapper:
        WRAPPER_PREFIX + "master/fastq_screen"


rule fastqc:
    input:
        unpack(get_fastq)
    output:
        html = "output/{run}/fastqc.html",
        zip = "output/{run}/fastqc.zip"
    resources:
        runtime = 20,
        mem_mb = 4000    
    wrapper:
        "0.27.1/bio/fastqc"


# Host mapping stats
rule bamstats:
    input:
        rules.samtools_sort.output
    output:
        "output/{run}/bamstats.txt"
    resources:
        runtime = 20,
        mem_mb = 8000
    wrapper:
        "0.42.0/bio/samtools/stats"


rule multiqc:
    input:
        "output/{run}/fastq_screen.txt",
        "output/{run}/bamstats.txt",
        "output/{run}/fastqc.zip",
        "output/{run}/snpeff.csv"
    output:
        report("output/{run}/multiqc.html", caption = "report/multiqc.rst", category = "Quality control")
    log:
        "output/{run}/log/multiqc.log"
    resources:
        runtime = 20,
        mem_mb = 4000    
    wrapper:
      WRAPPER_PREFIX + "master/multiqc"
