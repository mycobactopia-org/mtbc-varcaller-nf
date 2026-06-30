/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    BACKEND_GATK_VQSR — wraps XBS as the gatk_vqsr backend (Phase-1)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    XBS is pulled in as a git submodule pinned at v0.3.0 (commit f021ef5)
    per spec § "Dependencies & gotchas". This wrapper:

      1. Builds XBS's required input channels from mtbc-varcaller-nf params:
         - ch_snp_truth   (required iff params.snp_filter_mode == 'vqsr')
         - ch_indel_truth (required iff params.indel_filter_mode == 'vqsr')
         - ch_dbsnp       (required iff !params.skip_bqsr)
      2. Reshapes our ch_samplesheet meta so XBS's per-library mapping +
         per-sample groupTuple works (meta.id = study.sample.library)
      3. Calls XBS_VARIANT_CALLING; XBS's own params (snp_filter_mode,
         skip_bqsr, target_titv, etc.) are set in conf or by the user.
      4. Concatenates XBS's per-sample SNP + INDEL filtered VCFs into one
         per-sample VCF via bcftools concat — the backend interface wants
         a single per-sample VCF so consensus can vote per record.
      5. Stamps meta + [backend, backend_version, model] for downstream
         consensus + provenance.

    Gated on params.backends containing 'gatk_vqsr'.
    Contract: see docs/CONTRACT.md § "Per-backend module interface".
*/

include { XBS_VARIANT_CALLING } from '../../submodules/xbs-variant-calling/subworkflows/local/xbs_variant_calling_wf'
include { BCFTOOLS_CONCAT     } from '../../modules/nf-core/bcftools/concat/main'


workflow BACKEND_GATK_VQSR {

    take:
    ch_samplesheet  // channel: [ meta(study, sample, library, ...), [r1, r2] ]
    ch_reference    // value:   [ meta(id:'ref'), fasta, fai, dict, [bwa_index_files] ]

    main:

    // ---- backend stamp threaded through every emit ----
    def backend_stamp = [
        backend         : 'gatk_vqsr',
        backend_version : 'xbs-v0.3.0',
        model           : 'heupink2021',
    ]

    // ---- build XBS truth-set + dbsnp channels from params ----
    // Mirrors xbs-variant-calling/workflows/xbs-variant-calling.nf §"Truth sets":
    // truth-set VCFs are required only when the corresponding filter mode is 'vqsr';
    // dbsnp_vcf is required only when !skip_bqsr. For not-required cases the channel
    // carries empty list-elements (the nf-core convention for optional inputs).

    def ch_snp_truth
    if (params.snp_filter_mode == 'vqsr') {
        def snp_truth_vcf = file(params.snp_truth_vcf, checkIfExists: true)
        def snp_truth_tbi = file(params.snp_truth_vcf_tbi ?: "${params.snp_truth_vcf}.tbi", checkIfExists: true)
        ch_snp_truth = channel.value([ [id: 'snp_truth'], snp_truth_vcf, snp_truth_tbi ])
    } else {
        ch_snp_truth = channel.value([ [id: 'snp_truth'], [], [] ])
    }

    def ch_indel_truth
    if (params.indel_filter_mode == 'vqsr') {
        def indel_truth_vcf = file(params.indel_truth_vcf, checkIfExists: true)
        def indel_truth_tbi = file(params.indel_truth_vcf_tbi ?: "${params.indel_truth_vcf}.tbi", checkIfExists: true)
        ch_indel_truth = channel.value([ [id: 'indel_truth'], indel_truth_vcf, indel_truth_tbi ])
    } else {
        ch_indel_truth = channel.value([ [id: 'indel_truth'], [], [] ])
    }

    def ch_dbsnp
    if (!params.skip_bqsr) {
        def dbsnp_vcf = file(params.dbsnp_vcf, checkIfExists: true)
        def dbsnp_tbi = file(params.dbsnp_vcf_tbi ?: "${params.dbsnp_vcf}.tbi", checkIfExists: true)
        ch_dbsnp = channel.value([ [id: 'dbsnp'], dbsnp_vcf, dbsnp_tbi ])
    } else {
        ch_dbsnp = channel.value([ [id: 'dbsnp'], [], [] ])
    }

    // ---- reshape samplesheet meta so XBS's per-library mapping works ----
    // XBS_PER_SAMPLE maps per-library on meta.id and collapses libraries into
    // per-sample BAMs by groupTuple on meta.sample. So meta.id must be unique
    // per library (study.sample.library), and meta.sample must be set.
    def ch_reads = ch_samplesheet.map { meta, reads ->
        def study   = meta.study   ?: 'na'
        def sample  = meta.sample  ?: meta.id
        def library = meta.library ?: '1'
        def new_meta = meta + [
            id      : "${study}.${sample}.${library}",
            study   : study,
            sample  : sample,
            library : library,
        ]
        [ new_meta, reads ]
    }

    // ---- call XBS ----
    XBS_VARIANT_CALLING(
        ch_reads,
        ch_reference,
        ch_snp_truth,
        ch_indel_truth,
        ch_dbsnp,
    )

    // ---- per-sample SNP + INDEL → single VCF (bcftools concat) ----
    // bcftools/concat expects [meta, [vcfs], [tbis]]; group SNP + INDEL pair per sample.
    def ch_per_sample_pairs = XBS_VARIANT_CALLING.out.snp_filtered
        .join(XBS_VARIANT_CALLING.out.indel_filtered)
        .map { meta, snp_vcf, snp_tbi, indel_vcf, indel_tbi ->
            // Stamp backend identity into meta — this is what consensus+provenance bind to.
            [ meta + backend_stamp, [snp_vcf, indel_vcf], [snp_tbi, indel_tbi] ]
        }

    BCFTOOLS_CONCAT(ch_per_sample_pairs)

    emit:
    // Stable per-backend interface (see docs/CONTRACT.md § "Per-backend module interface")
    vcf      = BCFTOOLS_CONCAT.out.vcf.join(BCFTOOLS_CONCAT.out.index)   // [ meta+stamp, vcf, tbi ]
    gvcfs    = XBS_VARIANT_CALLING.out.gvcfs                             // [ meta, gvcf, tbi ]  (for cohort-stage replacement)
    versions = channel.empty()                                            // versions come via topic
}
