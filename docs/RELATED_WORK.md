# Related work — bacterial-pipeline lineage informing the `mtbc-*-nf` family

This document credits the prior art that shaped the `mtbc-*-nf` building-block contract and catalogs **what we adopt**, **what we intentionally diverge from**, and **what's worth borrowing later**. It's a design-rationale doc, not a competitive survey.

Surveyed (2026-06-30):

- [**Bactopia**](https://github.com/bactopia/bactopia) — Robert Petit's broad bacterial-genomics framework; main-pipeline + Bactopia Tools architecture; mature reproducibility story (mSystems 2020).
- [**nf-core/funcscan**](https://github.com/nf-core/funcscan) — parallel multi-backend AMR / antibiotic-resistance / functional-annotation screening (AMRFinderPlus, RGI, ABRicate, fARGene, DeepARG, …).
- [**bacannot**](https://github.com/fmalmeida/bacannot) — Felipe Almeida's bacterial annotation pipeline; modular multi-tool composition (Prokka / Bakta / AMRFinderPlus / antiSMASH); interactive R Markdown + Shiny + JBrowse reporting.
- [**nf-core/bacass**](https://github.com/nf-core/bacass) — bacterial assembly (short / long / hybrid); samplesheet conventions; assembler-choice patterns.

---

## 1. Patterns we adopt

### 1.1 Bactopia Tools = `mtbc-*-nf` building-block model (architectural validation)

Bactopia's split of a per-sample analysis pipeline + independently composable "Bactopia Tools" subworkflows is **the same architecture** we landed on — see family vision §2 and §4. Bactopia validates the model at scale (~150 tools).

Difference: we scope each `mtbc-*-nf` block to **one analytical step with multiple swappable backends** (variant-calling, resistance prediction, lineage, …), whereas Bactopia Tools is closer to "one tool per Bactopia Tool." Our slightly higher-altitude framing is the multi-backend + consensus + ML-slot contract.

### 1.2 funcscan's multi-backend parallel-execution pattern

funcscan runs ARG screeners (AMRFinderPlus, RGI, ABRicate, fARGene, DeepARG) as **independent parallel processes**, each wrapped as a separate nf-core module, with backend-specific reference databases configured per-tool. **This is exactly the wrapping pattern for `mtbc-varcaller-nf`'s `BACKEND_GATK_VQSR` / `BACKEND_CLAIR3` / future `BACKEND_DEEPVARIANT`.** Validates that the substrate works at scale.

### 1.3 funcscan's hAMRonization for canonical aggregation

funcscan adopts **[hAMRonization](https://github.com/pha4ge/hAMRonization)** and **argNorm** to map heterogeneous backend outputs to the **Antibiotic Resistance Ontology (ARO)** — a community standard rather than a custom schema. This is **directly applicable to `mtbc-resistotyper-nf`** — see Section 4 below ("Pending follow-up").

### 1.4 Per-tool container isolation

bacannot and funcscan both keep tool containers **separate per backend** to avoid dependency conflicts. We already do this via the standard nf-core module pattern (`environment.yml` per module, biocontainer per process). No change needed.

### 1.5 Optional / opt-out backend gating

funcscan's `--run_arg_screening` / `--run_amp_screening` / `--run_bgc_screening` flags let users disable entire backend classes. Our equivalent is the **comma-list `--backends gatk_vqsr,clair3`** param — more explicit about which backends *run together*, while funcscan's pattern is more about which *classes* run. Both work.

### 1.6 bacass platform flexibility

bacass handles Illumina / Nanopore / hybrid via a single pipeline configuration. We mirror this with `--platform illumina|ont` driving backend/model selection in `mtbc-varcaller-nf` (e.g. Clair3 model choice). Aligned.

### 1.7 Bactopia `bactopia prepare` CLI helper

Bactopia ships a companion CLI (`bactopia-py`) that builds samplesheets, fetches from SRA, and reduces upstream-of-pipeline legwork. **Worth borrowing post-MVP** as `mtbc-prepare-py` or absorbed into a single `mycobactopia` family CLI. Not in Phase-1 scope.

---

## 2. Patterns we intentionally diverge from

### 2.1 Bactopia's "flexible samplesheet / multiple input flags"

Bactopia accepts `--R1/--R2`, `--SE`, `--fastqs`, `--accession(s)`, batch CSV, etc. — convenience-first.

We use a **strict nf-core-style CSV samplesheet with a `meta` map** because (a) nf-core convention, (b) **consumer pipelines** (MAGMA, tbanalyzer, mtbc-resistotyper-nf) need a deterministic input contract to bind to. The strict samplesheet IS the consumer contract; loosening it would push complexity onto every consumer.

### 2.2 Bactopia's conda-first dependencies

Bactopia mandates Conda-installable tools; container is secondary.

We follow the spec's **container-digest-pinning** mandate (`abc-universe/specs/active/mtbc-varcaller-nf.md` §A: *"Every backend tool is pinned by container DIGEST (`process.container = '…@sha256:…'`) in `conf/`, not by tag"*). Stronger reproducibility for downstream database authors.

### 2.3 bacannot's "no cross-tool consensus reconciliation"

bacannot deliberately **avoids** voting / merging across tools — it outputs all annotations in parallel tracks and lets downstream interpretation handle disagreements.

We **explicitly attempt consensus voting** for `mtbc-varcaller-nf` (spec §D). But we hedge with the linchpin: if consensus doesn't beat best-single on the Phase-2 benchmark, the substrate still ships — its value is *provenance + backend-swappability*, not the consensus claim. bacannot's "let downstream decide" remains the safer default; we're testing whether the harder claim holds.

### 2.4 Bactopia's broad-bacterial scope vs our MTBC-specific framing

Bactopia is organism-agnostic; we are **MTBC-focused** (the `c` in `mtbc-*-nf`). The MTBC-specific decisions that justify the narrower scope:

- Ploidy = 1 across the whole complex
- Lineage assignment uses MTBC-specific catalogues (Coll 2014 / 2018)
- Resistance prediction backends (TB-Profiler, Mykrobe-TB) are MTBC-specific
- Reference panel is the small MTBC pan-genome, not the entire bacterial kingdom

XBS sits **orthogonally** — it's an organism-agnostic single-method GATK-VQSR tool that we import as one backend; XBS's breadth-of-organism axis is independent of our MTBC-scoped composition layer.

### 2.5 bacannot's R Markdown + Shiny + JBrowse interactive reporting

bacannot ships rich interactive reports. We **defer interactive reporting** — Phase-1 emits canonical TSV / VCF / JSON for programmatic consumption by mtbc-resistotyper-nf, tbanalyzer, and database authors. Interactive reporting is a downstream consumer's job (tbanalyzer or a future `mtbc-report-nf`); building it into every block duplicates effort.

---

## 3. Other nf-core bacterial pipelines surveyed (and our position vs each)

| Pipeline | Scope | Our position |
|---|---|---|
| [nf-core/bacass](https://github.com/nf-core/bacass) | Bacterial assembly (short/long/hybrid) | Upstream of us — assembled genomes are NOT our input (we take reads or BAMs); they could chain together for studies that need both assembly + variant calling |
| [nf-core/funcscan](https://github.com/nf-core/funcscan) | Multi-tool AMR/AMP/BGC screening on contigs | Pattern source for our backend wrapping; **downstream of mtbc-varcaller-nf** in workflows where AMR is called on assembled rather than mapped data |
| [nf-core/createtaxdb](https://github.com/nf-core/createtaxdb) | Build taxonomic / k-mer databases | Adjacent — relevant when we generate reference databases from cohort variants (spec §"Database-generation pathway") |
| [nf-core/createpanrefs](https://github.com/nf-core/createpanrefs) | Build pan-reference panels | Adjacent — relevant for the future `mtbc-panref-nf` block |
| [nf-core/phyloplace](https://github.com/nf-core/phyloplace) | Phylogenetic placement | Adjacent — overlaps with the future `mtbc-phylo-nf` block |

---

## 4. Pending follow-ups informed by this survey

These are scoped TODOs for follow-up commits in this repo and `mtbc-resistotyper-nf`:

### 4.1 Adopt hAMRonization for `mtbc-resistotyper-nf` canonical output

When `mtbc-resistotyper-nf` Phase-1.1 wires the TB-Profiler backend, the canonical DR table should map to **hAMRonization / ARO** terms rather than a custom schema. This makes our resistotyper output **drop-in compatible with funcscan-trained downstream tooling** and aligns with the PHA4GE standards work. Logged in `mtbc-resistotyper-nf/docs/CONTRACT.md`.

### 4.2 Companion CLI (`mtbc-prepare-py` or family-level `mycobactopia` CLI)

Post-Phase-2 polish item — borrow Bactopia's `bactopia prepare` pattern for samplesheet building and SRA fetching. Single CLI across the family rather than per-block.

### 4.3 Container digest pinning (not just tag pinning)

Per spec §A. Phase-1 has containers from `nf-core modules install` (tag-pinned). Phase-2 deliverable: convert all `process.container` entries in `conf/` to digest-pinned form (`@sha256:…`). Worth a single PR before the Phase-2 benchmark — guarantees the benchmark's container manifest is exactly what consumers will re-run.

### 4.4 Per-track "no-consensus" mode (bacannot-style fallback)

For the SV track (Phase 3), the spec already says SVs use SURVIVOR/Jasmine breakpoint-tolerance merge rather than per-allele voting (SV alleles don't normalize the way SNPs do). The bacannot pattern of "emit all tracks in parallel and let downstream interpret" is the right default for low-confidence convergence questions. Document this in the SV-track design when Phase 3 lands.

---

## 5. What we contribute back to the field

If the patterns above flow inward from prior art, here's what flows outward from `mtbc-*-nf`:

- **`docs/CONTRACT.md` style** — explicit `take:` / `emit:` shape + per-backend-meta-stamp + version-semantics table. None of the surveyed projects ship a contract doc of this form. It's the reusable asset of the family architecture (vision doc §2.7).
- **Multi-backend + consensus + benchmark-as-linchpin discipline** — bacannot says "no consensus", funcscan aggregates via ontology, Bactopia is single-tool-per-Tool. Our explicit "we attempt consensus; we benchmark the claim; we ship anyway if best-single wins" discipline is novel.
- **The `mtbc-*-nf` family pattern itself** — composable, ML-slot-reserving, organism-scoped subworkflow library. Once ≥ 2 blocks exist and are consumed by tbanalyzer / MAGMA / resistotyper, the family architecture itself is publishable as the high-altitude perspective paper (vision doc §7).
