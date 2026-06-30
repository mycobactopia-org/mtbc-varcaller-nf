/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    BACKEND_CLAIR3 — Clair3 backend (Phase-1 skeleton)
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Clair3 backend wrapper. Platform-aware: Illumina vs ONT R10.4.1 models
    are selected from meta.platform per spec § Implementation notes.

    Phase-1: wires the nf-core clair3 module + stamps backend meta.
    Gated on params.backends containing 'clair3'.

    Contract: see docs/CONTRACT.md § "Per-backend module interface".
*/

include { CLAIR3 } from '../../modules/nf-core/clair3/main'


workflow BACKEND_CLAIR3 {

    take:
    ch_samplesheet   // channel: [ meta(study, sample, library, id, platform), [r1, r2] | [bam] ]
    ch_reference     // value:   [ meta(id:'ref'), fasta, fai, dict, [bwa_index_files] ]

    main:

    // Backend stamp
    def backend_stamp = [
        backend          : 'clair3',
        // backend_version + container_digest stamped per-process by the nf-core module's versions topic
        // model selected per-sample from meta.platform; recorded into meta below
    ]

    // TODO (Phase 1.1):
    //   1. Resolve Clair3 model per sample from meta.platform (Illumina vs ONT R10.4.1)
    //      via params.clair3_models map; stamp into meta.model.
    //   2. Pre-align FASTQ → BAM (Clair3 requires BAM input). Reuse the BWA-MEM
    //      adapter from backend_gatk_vqsr (or factor out as a shared utility) so
    //      both backends use byte-identical alignments — this is essential for
    //      consensus voting to be apples-to-apples.
    //   3. Wire CLAIR3(ch_bam, ch_reference, model)
    //   4. Stamp meta + backend_stamp + [model: <selected>]

    // Placeholder for the contract surface — let consumers wire integration tests
    // against the interface before the full backend lands.
    def ch_vcf = channel.empty()

    emit:
    vcf      = ch_vcf       // [ meta+stamp, vcf, tbi ]
    versions = channel.empty()
}
