# mycobactopia-org/mtbc-varcaller-nf

[![GitHub Actions Linting Status](https://github.com/mycobactopia-org/mtbc-varcaller-nf/actions/workflows/linting.yml/badge.svg)](https://github.com/mycobactopia-org/mtbc-varcaller-nf/actions/workflows/linting.yml)
[![nf-test](https://img.shields.io/badge/unit_tests-nf--test-337ab7.svg)](https://www.nf-test.com)
[![Nextflow](https://img.shields.io/badge/version-%E2%89%A525.10.4-green?style=flat&logo=nextflow&logoColor=white&color=%230DC09D&link=https%3A%2F%2Fnextflow.io)](https://www.nextflow.io/)
[![nf-core template version](https://img.shields.io/badge/nf--core_template-4.0.2-green?style=flat&logo=nfcore&logoColor=white&color=%2324B064&link=https%3A%2F%2Fnf-co.re)](https://github.com/nf-core/tools/releases/tag/4.0.2)
[![run with docker](https://img.shields.io/badge/run%20with-docker-0db7ed?labelColor=000000&logo=docker)](https://www.docker.com/)
[![run with singularity](https://img.shields.io/badge/run%20with-singularity-1d355c.svg?labelColor=000000)](https://sylabs.io/docs/)

## Introduction

**mycobactopia-org/mtbc-varcaller-nf** is the **variant-calling building block** of the [`mtbc-*-nf` family](https://github.com/mycobactopia-org) — a multi-backend, consensus-normalised MTBC variant-calling substrate. It runs **multiple variant-calling backends** (XBS / Clair3 / DeepVariant — and SV / minority backends later), **normalises** their outputs to a canonical representation via `bcftools norm`, optionally **converges** them into one consensus, and exposes the logic as an **importable subworkflow** `MTBC_VARCALLING` consumed by mtbc-resistotyper-nf, tbanalyzer, MAGMA-v2, and any downstream database / pipeline that needs reproducible, provenance-stamped MTBC variant calls.

> **The linchpin claim:** consensus is only meaningfully "more accurate" than the best single backend if the benchmark says so. Phase-2 measures that head-to-head; **if convergence doesn't beat best-single, the pipeline still ships** — its value is *provenance + backend-swappability + reproducibility*.

Reference: spec `abc-universe/specs/active/mtbc-varcaller-nf.md`; family vision `abc-universe/brainstorms/mtbc-building-blocks/2026-06-30-mtbc-nf-building-block-family.md`.

### Pipeline shape

| | Phase 1 (this scaffold) | Phase 2 | Phase 3 |
|---|---|---|---|
| Small-variant backends | `gatk_vqsr` (via XBS), `clair3` | `+ deepvariant` | — |
| Normalisation | `bcftools norm` (left-align + split MA + dedup) | — | `+ --vrs` (GA4GH allele IDs) |
| Consensus | `best_single` (mandatory), `majority` | — | `+ external` (ML meta-caller) |
| SV track | — | — | `delly`, `manta`, `gridss` (short-read); `sniffles2`, `cutesv` (ONT); merge via `SURVIVOR`/`Jasmine`; benchmark with Truvari |
| Minority track | — | — | `lofreq` (separate track, not voted into germline consensus) |
| Benchmark harness | — | **first-class deliverable** (hap.py / vcfeval vs in-silico truth + held-out real) | + Truvari for SV |

### The XBS connection (first integration)

XBS (the canonical Heupink 2021 GATK-VQSR caller) is pulled in as the Phase-1 **`gatk_vqsr` backend** via a **git submodule** pinned at `v0.3.0` (commit `f021ef5`). XBS is an **independent unit** — MAGMA imports XBS too, mtbc-varcaller-nf imports XBS too, neither forks it. When XBS updates, bump the submodule pin here; downstream consumers of mtbc-varcaller-nf get the new behaviour by re-pulling.

```
mtbc-varcaller-nf/
├── submodules/
│   └── xbs-variant-calling/      ← pinned at v0.3.0
└── subworkflows/local/
    └── backend_gatk_vqsr.nf      ← wraps XBS_VARIANT_CALLING, stamps backend meta
```

### Position in the family

| Block | Step | Status |
|---|---|---|
| `mtbc-qc-nf` | read QC / trim | future |
| `mtbc-aligner-nf` | read alignment | future |
| **`mtbc-varcaller-nf`** | **variant calling (small + SV + minority)** | **Phase-1 scaffold (this repo)** |
| `mtbc-resistotyper-nf` | resistance prediction | Phase-1 scaffold |
| `mtbc-lineage-nf` | lineage / typing | future |
| `mtbc-phylo-nf` | phylogenetics | future |
| `mtbc-cluster-nf` | SNP-distance clustering | future |
| `mtbc-transmission-nf` | transmission inference | future |

## Usage

> [!NOTE]
> If you are new to Nextflow, refer to [the nf-core docs](https://nf-co.re/docs/get_started/environment_setup/overview).

Clone with submodules:

```bash
git clone --recurse-submodules git@github.com:mycobactopia-org/mtbc-varcaller-nf.git
# or, if already cloned:
git submodule update --init --recursive
```

Run:

```bash
nextflow run mycobactopia-org/mtbc-varcaller-nf \
    -profile <docker|singularity|conda>,test \
    --input samplesheet.csv \
    --backends gatk_vqsr,clair3 \
    --consensus best_single --consensus_backend gatk_vqsr \
    --reference_dir resources/genome --reference_basename NC-000962-3-H37Rv \
    --outdir results/
```

### Switching backends / consensus by config alone

The whole point of the substrate: **a consumer can switch backends and consensus by config alone, without changing the consumer's analytical logic.** From a consumer (tbanalyzer, mtbc-resistotyper-nf, MAGMA-v2):

```groovy
include { MTBC_VARCALLING } from '<this-path>/subworkflows/local/mtbc_varcalling_wf'

workflow {
    MTBC_VARCALLING(ch_samplesheet, ch_reference)
    DOWNSTREAM(MTBC_VARCALLING.out.vcf)   // or .per_backend_vcfs, etc.
}
```

Run-time config drives behaviour:

```
# best-single XBS (Phase-1 default — the "consensus didn't win" path)
--backends gatk_vqsr --consensus best_single

# majority of XBS + Clair3
--backends gatk_vqsr,clair3 --consensus majority --consensus_min_votes 2

# intersection (high-precision; both must agree)
--backends gatk_vqsr,clair3 --consensus intersection
```

## Outputs

- **Per-sample consensus VCF** (`*.vcf.gz`) — normalised + provenance-stamped (`BACKENDS`, `BACKEND_VAF`, `BACKEND_FILTER`, `CONSENSUS_MODEL`, `CONSENSUS_VOTES` in INFO)
- **Per-backend canonical VCFs** (`per_backend_vcfs/`) — pre-consensus, normalised, for downstream consumers that want raw per-backend output
- **SV VCF** (Phase 3) — separate variant class, class-labelled
- **Versions** — standard nf-core `versions.yml`

See [`docs/CONTRACT.md`](docs/CONTRACT.md) for the full `take:` / `emit:` interface contract that consumer pipelines bind to.

## Credits

mycobactopia-org/mtbc-varcaller-nf was developed by Abhinav Sharma as part of the `mtbc-*-nf` building-block family.

Backends wrapped:
- **XBS** ([mycobactopia-org/xbs-variant-calling](https://github.com/mycobactopia-org/xbs-variant-calling)) — Phase-1 `gatk_vqsr` backend (Heupink 2021 GATK-VQSR; pinned at v0.3.0)
- **Clair3** — Phase-1; platform-aware models
- **DeepVariant** — Phase 2
- **DELLY / Manta / GRIDSS / Sniffles2 / cuteSV** — Phase 3 (SV track)
- **LoFreq** — Phase 3 (minority-variant track)

ML default backend slot reserved for `mtb-varcaller-ml` (future; see family vision §6).

## Contributions and Support

If you would like to contribute, please see [`docs/CONTRIBUTING.md`](docs/CONTRIBUTING.md).

## Citations

This pipeline is part of the `mtbc-*-nf` family. Cite the building-block family architecture (Sharma A et al., in preparation) and the backends used — see [`CITATIONS.md`](CITATIONS.md).

This pipeline reuses scaffolding from the [nf-core](https://nf-co.re) community framework under the [MIT license](https://github.com/nf-core/tools/blob/main/LICENSE):

> **The nf-core framework for community-curated bioinformatics pipelines.**
>
> Philip Ewels, Alexander Peltzer, Sven Fillinger, Harshil Patel, Johannes Alneberg, Andreas Wilm, Maxime Ulysse Garcia, Paolo Di Tommaso & Sven Nahnsen.
>
> *Nat Biotechnol.* 2020 Feb 13. doi: [10.1038/s41587-020-0439-x](https://dx.doi.org/10.1038/s41587-020-0439-x).
