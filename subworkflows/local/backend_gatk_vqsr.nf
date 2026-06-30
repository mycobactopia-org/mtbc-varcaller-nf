/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    BACKEND_GATK_VQSR — wraps XBS as the gatk_vqsr backend (Phase-1)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    XBS is pulled in as a git submodule pinned at v0.3.0 (commit f021ef5)
    per spec § "Dependencies & gotchas". This wrapper:

      1. Adapts our ch_samplesheet → XBS's ch_reads shape
      2. Adapts ch_reference → XBS's reference channel shape
      3. Calls XBS_VARIANT_CALLING with XBS-side params already set
         in conf/backend_gatk_vqsr.config
      4. Merges XBS's per-sample SNP + INDEL filtered VCFs into a single
         per-sample VCF via bcftools concat
      5. Stamps meta + [backend: 'gatk_vqsr', backend_version: 'xbs-v0.3.0', ...]
         so downstream consensus + provenance can attribute calls

    Gated on params.backends containing 'gatk_vqsr'.

    Contract: see docs/CONTRACT.md § "Per-backend module interface".
*/

include { XBS_VARIANT_CALLING } from '../../submodules/xbs-variant-calling/subworkflows/local/xbs_variant_calling_wf'
include { BCFTOOLS_CONCAT     } from '../../modules/nf-core/bcftools/concat/main'


workflow BACKEND_GATK_VQSR {

    take:
    ch_samplesheet  // channel: [ meta(study, sample, library, id, platform), [r1, r2] ]
    ch_reference    // value:   [ meta(id:'ref'), fasta, fai, dict, [bwa_index_files] ]

    main:

    // Backend stamp threaded through every emit
    def backend_stamp = [
        backend          : 'gatk_vqsr',
        backend_version  : 'xbs-v0.3.0',
        model            : 'heupink2021',
        // container_digest: stamped per-process from the XBS modules themselves;
        //                    not threaded through subworkflow output meta because
        //                    XBS uses multiple containers (per Heupink stage)
    ]

    // Truth-set + dbsnp channels resolved here (Phase-1 default mirrors XBS test
    // profile defaults; consumers override via params); for the MVP scaffold these
    // are documented as required when their respective filter mode is 'vqsr'.
    def ch_snp_truth   = channel.value([ [id: 'snp_truth'],   [], [] ])
    def ch_indel_truth = channel.value([ [id: 'indel_truth'], [], [] ])
    def ch_dbsnp       = channel.value([ [id: 'dbsnp'],       [], [] ])

    // TODO (Phase 1.1): build the truth-set + dbsnp channels from params, mirroring
    //                   xbs-variant-calling/workflows/xbs-variant-calling.nf §"Truth sets".
    //                   For now this scaffold compiles and lets consumers wire integration
    //                   tests against the contract.

    XBS_VARIANT_CALLING(
        ch_samplesheet,
        ch_reference,
        ch_snp_truth,
        ch_indel_truth,
        ch_dbsnp,
    )

    // Per-sample concat: XBS emits snp_filtered + indel_filtered separately. The
    // backend interface wants ONE per-sample VCF (so consensus voting can be done
    // per record). bcftools concat with -a (allow overlap) handles the join.
    def ch_per_sample_pairs = XBS_VARIANT_CALLING.out.snp_filtered
        .join(XBS_VARIANT_CALLING.out.indel_filtered)
        .map { meta, snp_vcf, snp_tbi, indel_vcf, indel_tbi ->
            // group SNP + INDEL VCFs (and their tbis) into the lists bcftools/concat expects
            [ meta + backend_stamp, [snp_vcf, indel_vcf], [snp_tbi, indel_tbi] ]
        }

    BCFTOOLS_CONCAT(ch_per_sample_pairs)

    emit:
    // Stable per-backend interface (see docs/CONTRACT.md § "Per-backend module interface")
    vcf      = BCFTOOLS_CONCAT.out.vcf.join(BCFTOOLS_CONCAT.out.tbi)   // [ meta+stamp, vcf, tbi ]
    gvcfs    = XBS_VARIANT_CALLING.out.gvcfs                          // [ meta, gvcf, tbi ]  (for cohort-stage replacement)
    versions = channel.empty()                                         // versions come via topic
}
