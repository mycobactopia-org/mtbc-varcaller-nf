/*
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    MTBC_VARCALLER_NF — top-level pipeline workflow
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
    Builds the reference value channel from params and invokes the
    MTBC_VARCALLING subworkflow (the importable contract surface that
    tbanalyzer / mtbc-resistotyper-nf / MAGMA-v2 consume).
*/

include { paramsSummaryMap            } from 'plugin/nf-schema'
include { softwareVersionsToYAML      } from '../subworkflows/nf-core/utils_nfcore_pipeline'
include { methodsDescriptionText      } from '../subworkflows/local/utils_nfcore_mtbc-varcaller-nf_pipeline'
include { MTBC_VARCALLING             } from '../subworkflows/local/mtbc_varcalling_wf'


workflow MTBC_VARCALLER_NF {

    take:
    ch_samplesheet // channel: samplesheet rows from --input
    outdir

    main:

    def ch_versions = channel.empty()

    //
    // Build the reference bundle value channel from params.
    // Layout (same as xbs-variant-calling):
    //   ${reference_dir}/${reference_basename}.fa{,.fai,.amb,.ann,.bwt,.pac,.sa}
    //   ${reference_dir}/${reference_basename}.dict
    //
    def ref_fasta = file("${params.reference_dir}/${params.reference_basename}.fa",     checkIfExists: true)
    def ref_fai   = file("${params.reference_dir}/${params.reference_basename}.fa.fai", checkIfExists: true)
    def ref_dict  = file("${params.reference_dir}/${params.reference_basename}.dict",   checkIfExists: true)
    def bwa_index = [
        file("${params.reference_dir}/${params.reference_basename}.fa.amb", checkIfExists: true),
        file("${params.reference_dir}/${params.reference_basename}.fa.ann", checkIfExists: true),
        file("${params.reference_dir}/${params.reference_basename}.fa.bwt", checkIfExists: true),
        file("${params.reference_dir}/${params.reference_basename}.fa.pac", checkIfExists: true),
        file("${params.reference_dir}/${params.reference_basename}.fa.sa",  checkIfExists: true),
    ]
    def ch_reference = channel.value([ [id: 'ref'], ref_fasta, ref_fai, ref_dict, bwa_index ])

    //
    // Run the multi-backend variant-calling substrate.
    //
    MTBC_VARCALLING(ch_samplesheet, ch_reference)

    //
    // Collate software versions (standard nf-core boilerplate, kept verbatim).
    //
    def topic_versions = channel.topic("versions")
        .distinct()
        .branch { entry ->
            versions_file: entry instanceof Path
            versions_tuple: true
        }

    def topic_versions_string = topic_versions.versions_tuple
        .map { process, tool, version ->
            [ process[process.lastIndexOf(':')+1..-1], "  ${tool}: ${version}" ]
        }
        .groupTuple(by: 0)
        .map { process, tool_versions ->
            tool_versions.unique().sort()
            "${process}:\n${tool_versions.join('\n')}"
        }

    softwareVersionsToYAML(ch_versions.mix(topic_versions.versions_file))
        .mix(topic_versions_string)
        .collectFile(
            storeDir: "${outdir}/pipeline_info",
            name:  'mtbc-varcaller-nf_software_versions.yml',
            sort: true,
            newLine: true
        )

    emit:
    vcf              = MTBC_VARCALLING.out.vcf
    sv_vcf           = MTBC_VARCALLING.out.sv_vcf
    per_backend_vcfs = MTBC_VARCALLING.out.per_backend_vcfs
    versions         = ch_versions
}
