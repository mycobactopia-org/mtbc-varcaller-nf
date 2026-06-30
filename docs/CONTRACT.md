# MTBC_VARCALLING — Building-Block Contract

This document is the **stable interface contract** for the `MTBC_VARCALLING` subworkflow. It follows the `mtbc-*-nf` family contract (`abc-universe/brainstorms/mtbc-building-blocks/2026-06-30-mtbc-nf-building-block-family.md` §2) and is referenced by the canonical spec at `abc-universe/specs/active/mtbc-varcaller-nf.md` §E.

**Status:** Phase-1 — `gatk_vqsr` (via XBS) + `clair3` backends; `majority` / `best_single` consensus; `bcftools norm` normalisation; SV + minority tracks deferred to Phase 3 per spec §F2 / §F.

---

## Building-block conformance (per family-vision §2)

| Requirement | How |
|---|---|
| **Backends** = published tools, pinned, configurable | `gatk_vqsr` (Phase 1) wraps XBS pinned at commit; `clair3` (Phase 1); `deepvariant` (Phase 2); SV: `delly`/`manta`/`gridss` (Phase 3); minority: `lofreq` (Phase 3) |
| **Normalise** to canonical representation | `bcftools norm` (left-align + split multiallelics + `-d` dedup) against reference; per-backend canonical VCF |
| **Converge/select** | `--consensus` = `majority` / `union` / `intersection` / `best_single` / `external`; **`best_single` mode is mandatory** so the substrate is usable as a single-caller pipeline |
| **Provenance** | Merged VCF carries `BACKENDS=clair3,gatk_vqsr;BACKEND_VAF=…` in INFO; provenance survives `bcftools merge` |
| **Importable subworkflow** | `include { MTBC_VARCALLING } from '…'` ; standalone via `main.nf` |
| **ML slot** | Reserved for `mtb-varcaller-ml` as a backend module conforming to the per-backend interface below |
| **Benchmarked** | First-class deliverable (spec §G) — hap.py / vcfeval / Truvari against in-silico truth + held-out real sequencing. Out of scope for Phase 1; lives in `tests/benchmarks/` from Phase 2. |

---

## `take:` channels (subworkflow inputs)

```
workflow MTBC_VARCALLING {
    take:
    ch_samplesheet  // channel  [ meta(study, sample, library, id, platform), [r1, r2] | [bam] ]
    ch_reference    // value    [ meta(id:'ref'), fasta, fai, dict, [bwa_index_files] ]
}
```

### Required

| Channel | Shape | Notes |
|---|---|---|
| `ch_samplesheet` | per-sample reads (FASTQ paired) or pre-aligned BAM | `platform` ∈ `illumina` \| `ont`; drives backend/model selection (e.g. Clair3 model depends on platform) |
| `ch_reference` | reference + index bundle | Standard MTBC reference is NC_000962.3 H37Rv but the contract is organism-agnostic |

### Controlled via `params.*` (not via `take:` for stability)

- `params.backends` — comma-separated list, e.g. `gatk_vqsr,clair3,deepvariant`. Each backend module is gated on its presence in this list.
- `params.consensus` — `majority` (default Phase 2) / `union` / `intersection` / `best_single` / `external`.
- `params.reference_fasta` — used by the XBS backend's reference bundle resolver (see Phase-1 known issue below).

---

## `emit:` channels (subworkflow outputs)

```
emit:
vcf                // [ meta, vcf, tbi ]  — small-variant consensus, normalised, provenance-stamped
sv_vcf             // [ meta, vcf, tbi ]  — merged SV calls, class-labelled (Phase 3; empty channel until then)
per_backend_vcfs   // [ meta, [vcf_per_backend, ...], [tbi_per_backend, ...] ]  — pre-merge per-backend canonical VCFs
versions           // standard nf-core versions topic
```

### `vcf` emit — record-level provenance contract

Each record in the consensus `vcf` carries INFO-field provenance that survives `bcftools merge`:

| INFO field | Type | Value |
|---|---|---|
| `BACKENDS` | string list | comma-separated backend identifiers that called this variant (e.g. `gatk_vqsr,clair3`) |
| `BACKEND_VAF` | float list | per-backend variant allele frequency, same order as `BACKENDS` |
| `BACKEND_FILTER` | string list | per-backend FILTER value, same order |
| `CONSENSUS_MODEL` | string | `majority` / `union` / `intersection` / `best_single` |
| `CONSENSUS_VOTES` | integer | how many backends voted for this variant |

### `per_backend_vcfs` emit

For downstream consumers (e.g. resistotyper's multi-backend voting) that want individual backend outputs before consensus, this emit gives a per-sample tuple of all backends' canonical VCFs.

---

## Per-backend module interface (the reusable contract)

Adding a new backend = adding one module conforming to:

```groovy
process BACKEND_<NAME> {
    input:
    tuple val(meta), path(reads_or_bam)
    tuple val(meta2), path(reference_bundle)
    val   model                                 // platform-specific model (e.g. clair3 model dir)

    output:
    tuple val(meta + [backend: '<name>', backend_version: …, container_digest: …, model: …]),
          path("*.vcf.gz"),
          path("*.vcf.gz.tbi"),                 emit: vcf
    tuple val("${task.process}"), val('<tool>'), eval('<version-command>'),
          topic: versions, emit: versions_<tool>

    when: '<name>' in (params.backends?.tokenize(',') ?: [])

    script:
    // backend-specific command line
}
```

The `meta` stamp `[backend, backend_version, container_digest, model]` is what threads provenance through the rest of the pipeline. Every backend MUST emit it.

---

## Phase-1 backend wiring

### `gatk_vqsr` backend (wraps XBS — first integration)

XBS is pulled in as a **git submodule** pinned at `v0.3.0` (commit `f021ef5`) per spec § *Dependencies & gotchas*. The backend module:

```
subworkflows/local/backend_gatk_vqsr.nf
```

includes XBS's `XBS_VARIANT_CALLING` subworkflow from the submodule path:

```groovy
include { XBS_VARIANT_CALLING } from '../../submodules/xbs-variant-calling/subworkflows/local/xbs_variant_calling_wf'
```

The wrapping logic:
1. Adapt `ch_samplesheet` → XBS's `ch_reads` shape (`[meta(study, sample, library), [r1, r2]]`)
2. Adapt `ch_reference` → XBS's `[meta, fasta, fai, dict, bwa_index]` shape
3. Call `XBS_VARIANT_CALLING(...)` with XBS params already set in `conf/backend_gatk_vqsr.config`
4. Merge XBS's per-sample `snp_filtered` + `indel_filtered` → single per-sample VCF via `bcftools concat`
5. Stamp `meta + [backend: 'gatk_vqsr', backend_version: 'xbs-v0.3.0', model: 'heupink2021']`

### `clair3` backend

Standard nf-core `clair3` module. Platform-aware model selection (Illumina vs ONT R10.4.1) gated on `meta.platform`.

---

## Version semantics

Same as XBS's contract:

| Change | Bump |
|---|---|
| Add new backend, new emit channel, new opt-in flag | minor |
| Rename emit channel, change channel shape, flip a default | **major** |
| Change consensus default (`best_single` → `majority`) | **major** (changes scientific outputs) |
| Per-backend `meta` stamp keys renamed | **major** |

Pin against tagged commits, not against `master`.

---

## What's NOT in the Phase-1 contract

(All deferred per spec §F / §F2.)

- **SV track**: separate variant class, separate backends (DELLY/Manta/GRIDSS for short-read; Sniffles2/cuteSV for ONT), separate merge (SURVIVOR/Jasmine), separate benchmark (Truvari). `sv_vcf` emit channel exists in the contract but is `channel.empty()` until Phase 3.
- **Minority variants**: LoFreq as a separate track (not voted into germline consensus); behind a `--minority` opt-in.
- **VRS-IDs**: `--vrs` flag for GA4GH `ga4gh:VA.*` allele IDs; Phase 3. Until then the methods term is "GA4GH-compatible left-aligned normalisation."
