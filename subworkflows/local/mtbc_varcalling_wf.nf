/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    MTBC_VARCALLING — top-level composer (Phase-1 scaffold)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Runs one or more configurable variant-calling backends over a samplesheet
    of MTBC reads, normalises each backend's VCF via bcftools norm, optionally
    converges the per-backend canonical VCFs into a consensus, and emits a
    provenance-stamped result.

    Phase-1 backends: gatk_vqsr (via XBS submodule) + clair3.
    Phase-1 consensus modes: best_single (mandatory) + majority.
    Phase-2 backends: deepvariant.
    Phase-3 tracks: SV (sv_vcf emit) + minority (lofreq).

    See docs/CONTRACT.md for the stable interface contract that consumer
    pipelines (tbanalyzer, mtbc-resistotyper-nf, MAGMA-v2) bind to.
*/

include { BACKEND_GATK_VQSR        } from './backend_gatk_vqsr'
include { BACKEND_CLAIR3           } from './backend_clair3'
include { BCFTOOLS_NORM            } from '../../modules/nf-core/bcftools/norm/main'


workflow MTBC_VARCALLING {

    take:
    ch_samplesheet  // channel: [ meta(study, sample, library, id, platform), [r1, r2] | [bam] ]
    ch_reference    // value:   [ meta(id:'ref'), fasta, fai, dict, [bwa_index_files] ]

    main:

    // Backend selection — params.backends is the canonical knob (spec §B / §E.take).
    def selected_backends = (params.backends ?: 'gatk_vqsr').tokenize(',').collect { backend_name -> backend_name.trim() }

    // ============= Run each selected backend =============
    // Each backend emits [meta+stamp, vcf, tbi]; the stamp carries backend identity
    // through normalisation + consensus + provenance.

    def ch_backend_vcfs = channel.empty()

    if ('gatk_vqsr' in selected_backends) {
        BACKEND_GATK_VQSR(ch_samplesheet, ch_reference)
        ch_backend_vcfs = ch_backend_vcfs.mix(BACKEND_GATK_VQSR.out.vcf)
    }

    if ('clair3' in selected_backends) {
        BACKEND_CLAIR3(ch_samplesheet, ch_reference)
        ch_backend_vcfs = ch_backend_vcfs.mix(BACKEND_CLAIR3.out.vcf)
    }

    // TODO (Phase 2): add 'deepvariant' branch — same shape as above.

    // ============= Normalise each backend's VCF =============
    // Left-align + split multiallelics + dedup (spec §C). Phase-1 default
    // is bcftools norm only; --vrs (GA4GH allele IDs) is Phase-3.

    def ch_fasta_tuple = ch_reference.map { m, f, _fai, _d, _b -> [m, f] }

    BCFTOOLS_NORM(ch_backend_vcfs, ch_fasta_tuple)

    def ch_normalised_per_backend = BCFTOOLS_NORM.out.vcf.join(BCFTOOLS_NORM.out.tbi)

    // ============= Consensus (Phase-1: best_single + majority) =============

    def ch_consensus_vcf = channel.empty()
    // consensus mode driven by params.consensus — branches to be wired in Phase 1.1 (see TODO below)

    // TODO (Phase 1.1): implement consensus modes per spec §D
    //   best_single  — pass through the named backend (--consensus_backend gatk_vqsr)
    //   majority     — ≥N of M backends; bcftools merge + custom voting script
    //   union        — bcftools merge with all calls retained
    //   intersection — bcftools isec with -n=M (all backends must agree)
    //   external     — hook for ML meta-caller (Phase 3+)
    //
    // For best_single (the resource-constrained / single-caller path), this is
    // a passthrough that selects records from the named backend's normalised VCF.
    // For majority (the headline consensus mode), need to:
    //   1. Group ch_normalised_per_backend by meta.sample
    //   2. bcftools merge across backends per sample
    //   3. Custom script: keep records where ≥ N of M backends called the variant;
    //      stamp INFO with BACKENDS, BACKEND_VAF, BACKEND_FILTER, CONSENSUS_VOTES.
    //   This is the linchpin claim (spec § "linchpin"): only worth the complexity
    //   if it beats best_single on Phase-2 benchmark.

    // ============= SV track (Phase-3) =============
    def ch_sv_vcf = channel.empty()

    emit:
    // ============= STABLE INTERFACE CONTRACT (see docs/CONTRACT.md) =============
    vcf              = ch_consensus_vcf        // [ meta, vcf, tbi ]  small-variant consensus, provenance-stamped
    sv_vcf           = ch_sv_vcf               // [ meta, vcf, tbi ]  Phase-3; empty channel in Phase 1
    per_backend_vcfs = ch_normalised_per_backend  // [ meta+stamp, vcf, tbi ]  per-backend canonical VCFs for downstream consumers
    versions         = channel.empty()         // versions come via standard nf-core topic
}
