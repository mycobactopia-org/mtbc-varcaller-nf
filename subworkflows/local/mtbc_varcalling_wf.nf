/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    MTBC_VARCALLING — top-level composer (Phase-1)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Runs one or more configurable variant-calling backends over a samplesheet
    of MTBC reads, normalises each backend's VCF via bcftools norm, converges
    the per-backend canonical VCFs into a consensus, and emits a provenance-
    stamped result.

    Phase-1 backends:        gatk_vqsr (via XBS submodule) + clair3 (skeleton)
    Phase-1 consensus modes: best_single (default, mandatory)
                             majority    (stub — implemented in Phase 2 once
                                          the benchmark proves it's worth the
                                          complexity; see spec linchpin)
    Phase-2 backends:        deepvariant
    Phase-3 tracks:          SV (sv_vcf emit) + minority (lofreq)

    See docs/CONTRACT.md for the stable interface contract that consumer
    pipelines (tbanalyzer, mtbc-resistotyper-nf, MAGMA-v2) bind to.
*/

include { BACKEND_GATK_VQSR        } from './backend_gatk_vqsr'
include { BACKEND_CLAIR3           } from './backend_clair3'
include { BCFTOOLS_NORM            } from '../../modules/nf-core/bcftools/norm/main'


workflow MTBC_VARCALLING {

    take:
    ch_samplesheet  // channel: [ meta(study, sample, library, ...), [r1, r2] | [bam] ]
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

    // TODO (Phase 2): add 'deepvariant' branch — same shape.

    // ============= Normalise each backend's VCF (spec §C) =============
    // Left-align + split multiallelics + dedup. Phase-1 default is bcftools norm
    // only; --vrs (GA4GH allele IDs) is Phase-3.

    def ch_fasta_tuple = ch_reference.map { m, f, _fai, _d, _b -> [m, f] }

    BCFTOOLS_NORM(ch_backend_vcfs, ch_fasta_tuple)

    def ch_normalised_per_backend = BCFTOOLS_NORM.out.vcf.join(BCFTOOLS_NORM.out.index)

    // ============= Consensus (spec §D) =============
    // Modes:
    //   best_single  — pass through the backend named in params.consensus_backend
    //                  (resource-constrained / "consensus didn't win" path; mandatory)
    //   majority     — Phase-2 (bcftools merge + voting script)
    //   union        — Phase-2 (bcftools merge, keep all)
    //   intersection — Phase-2 (bcftools isec -n=M)
    //   external     — Phase-3+ (ML meta-caller hook)
    //
    // For best_single we simply filter the per-backend stream to the named backend.
    // The provenance stamp survives in the meta — consumers reading the emit
    // can still see which backend produced each record.

    def consensus_mode = params.consensus ?: 'best_single'
    def consensus_backend = params.consensus_backend ?: 'gatk_vqsr'

    def ch_consensus_vcf
    if (consensus_mode == 'best_single') {
        ch_consensus_vcf = ch_normalised_per_backend
            .filter { meta, _vcf, _tbi -> meta.backend == consensus_backend }
            .map { meta, vcf, tbi ->
                // strip backend-stamp keys from meta so the consensus emit's meta
                // is the per-sample identity (not backend-flavoured). Provenance
                // moves into the VCF's INFO via modules.config (Phase 1.1+).
                def consumer_meta = meta - meta.subMap('backend', 'backend_version', 'model')
                [ consumer_meta + [consensus_mode: 'best_single', consensus_backend: consensus_backend], vcf, tbi ]
            }
    } else {
        // Other modes are not yet implemented; fail loudly so the user sees the
        // gap rather than silently producing an empty channel.
        error("MTBC_VARCALLING: consensus mode '${consensus_mode}' is not implemented in Phase 1. " +
              "Use --consensus best_single (the default) until majority/union/intersection land in Phase 2.")
    }

    // ============= SV track (Phase-3) =============
    def ch_sv_vcf = channel.empty()

    emit:
    // ============= STABLE INTERFACE CONTRACT (see docs/CONTRACT.md) =============
    vcf              = ch_consensus_vcf          // [ meta, vcf, tbi ]
    sv_vcf           = ch_sv_vcf                 // [ meta, vcf, tbi ]  Phase-3; empty in Phase 1
    per_backend_vcfs = ch_normalised_per_backend // [ meta+stamp, vcf, tbi ]
    versions         = channel.empty()           // versions come via standard nf-core topic
}
