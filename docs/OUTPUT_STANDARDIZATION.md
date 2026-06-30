# Output standardisation — evaluation

**Status:** evaluation / decision-record. Not yet implemented. Lives on `feat/output-standardization-evaluation`.

**Goal:** make `mtbc-varcaller-nf`'s output directly ingestible by `mtb-resistotyper-ml` (and other database / ML consumers) by aligning with the **CRyPTIC v3.4.0 Zenodo schema** ([10.5281/zenodo.16041005](https://zenodo.org/records/16041005), CC-BY-4.0), with a **hAMRonization-adjacent canonical TSV as default** and **CRyPTIC parquet as opt-in**.

**Why now:** the resistotyper-ml manuscript anchor (`manuscripts/mtb-resistotyper-ml-manuscript-anchor.md`) explicitly names "future re-runs will produce feature-mart variant calls via `mtbc-varcaller-nf` … with `mtb-varcaller-ml` slated to become that pipeline's default backend." Locking output format now means the future re-runs are drop-in compatible with the CRyPTIC-trained ML tool — no schema-translation step in between.

---

## 1. Three output layers (proposed)

| Layer | Format | When emitted | Consumer |
|---|---|---|---|
| **L0 — Native VCF** | `*.vcf.gz` + `tbi`, with INFO provenance (`BACKENDS`, `BACKEND_VAF`, …) | always | Primary substrate; everything else derives from this |
| **L1 — Canonical TSV (default)** | Long-format per-sample TSV: `sample × variant × gene × effect × backend_provenance`. **hAMRonization-adjacent schema** so any AMR aggregator (funcscan, ARO-tagged tooling) can ingest it. | always (default) | Resistotyper, MultiQC, manual inspection, databases that don't need CRyPTIC schema |
| **L2 — CRyPTIC v3.4.0 parquet (opt-in)** | Parquet tables matching the [Zenodo release](https://zenodo.org/records/16041005) `VARIANTS` / `MUTATIONS` / `EFFECTS` schema. Per-sample subset. | `--export_cryptic` | `mtb-resistotyper-ml` direct ingestion; CRyPTIC-comparable databases (who-catalogue-temporal-db); future ML backend training |

**Rationale for the three-layer design:**

- **L0 is the substrate** — every other layer is derived; we can't lose it without losing reproducibility.
- **L1 as default** — hAMRonization is the field's lingua franca for AMR aggregation (covers 17+ tools, peer-reviewed, ARO-mappable). Defaulting to it makes our output joinable with funcscan / bacannot outputs without the user opting in.
- **L2 as opt-in** — CRyPTIC's parquet schema is heavier (994 MB VARIANTS table at consortium scale), and most users won't need it. But for the resistotyper-ml ingestion path (and for users who want to extend the CRyPTIC consortium release with their own samples), `--export_cryptic` produces drop-in-compatible parquets.

---

## 2. CRyPTIC v3.4.0 schema — what we know

From the Zenodo release page (CC-BY-4.0; not all tables' schemas visible without the bundled `DATA_SCHEMA.pdf`):

| Table | Format | Size | Row grain | Notes |
|---|---|---|---|---|
| `WGS_SAMPLES` | parquet | 7.8 MB | one per WGS sample | The sample identity table; presumably joins on `UNIQUE_ID` |
| `DST_SAMPLES` | parquet | 795 kB | one per DST sample | Drug-susceptibility-testing samples |
| **`VARIANTS`** | parquet | **994 MB** | one per variant call | **The feature mart we need to match.** Likely: `sample_id, chromosome, position, ref, alt, gene, effect, ...` |
| `MUTATIONS` | parquet | 734 MB | one per mutation event (aggregates VARIANTS) | Used for ML feature aggregation |
| `EFFECTS` | parquet | 4.6 MB | likely one per (variant, effect-type) | SnpEff-style annotation |
| `PREDICTIONS` | parquet | 1.9 MB | likely per-sample-per-drug | Resistotyper output (not our job to produce) |
| `GENOMES`, `PLATE_LAYOUT`, `DST_MEASUREMENTS` | mixed | small | metadata / phenotype data | Not pipeline-produced |
| `DRUG_CODES`, `COUNTRIES_LOOKUP`, `SITES` | CSV | tiny | lookups | Reference data only |

**🟡 OPEN QUESTION 1 (must resolve before implementation):** What are the exact column names + dtypes for `VARIANTS`, `MUTATIONS`, `EFFECTS`? The Zenodo release bundles `DATA_SCHEMA.pdf` but it's a PDF — needs to be downloaded and read locally. Without this we can only guess at column names. Documented as an explicit blocker in §5.

**🟡 OPEN QUESTION 2:** What is the canonical sample identifier? CRyPTIC uses `UNIQUE_ID` (a composite). Our samplesheet currently uses `sample` as a free-form string. Does `--export_cryptic` need to enforce a `UNIQUE_ID` format or accept arbitrary IDs and let the user join later?

---

## 3. Mapping from our output to CRyPTIC schema

What each pipeline output contributes to which CRyPTIC table:

| CRyPTIC table | Our output → CRyPTIC field mapping (best guess pending schema confirmation) |
|---|---|
| `WGS_SAMPLES` | meta.sample → `UNIQUE_ID` (or `BIOSAMPLE`); meta.lineage (if available from a future `mtbc-lineage-nf` block) → `LINEAGE` |
| `VARIANTS` | VCF `CHROM, POS, REF, ALT` → `chromosome, position, ref, alt`; INFO `BACKEND_VAF` → `vaf` (per backend? consensus?); per-record `BACKENDS` → `caller` (CRyPTIC may have a single-value field — we'd flatten to e.g. `gatk_vqsr+clair3`) |
| `EFFECTS` | SnpEff annotation from VCF `ANN` field (we'd add SnpEff as a Phase-1.1 module) → `gene, effect_type, protein_change, nucleotide_change` |
| `MUTATIONS` | derived from `VARIANTS` × `EFFECTS` — aggregate per (sample, gene, mutation_event). Computed by adapter, not by upstream backends. |
| `PREDICTIONS` | **NOT us** — that's mtbc-resistotyper-nf's job |
| `DST_*`, `PLATE_LAYOUT`, etc. | **NOT us** — phenotype data is experimental, not pipeline-produced |

So the three tables we'd produce parquets for under `--export_cryptic`: **`WGS_SAMPLES`, `VARIANTS`, `EFFECTS`** (plus `MUTATIONS` derived from them).

---

## 4. Default L1 (hAMRonization-adjacent canonical TSV)

Long-format, one row per (sample, variant), columns:

| Column | Type | Source | Notes |
|---|---|---|---|
| `sample_id` | string | meta.sample | The pipeline's primary sample key |
| `chromosome` | string | VCF CHROM | Typically "Chromosome" for H37Rv |
| `position` | int | VCF POS | 1-based, per VCF spec |
| `ref` | string | VCF REF | |
| `alt` | string | VCF ALT | |
| `variant_type` | enum | derived | `snp` / `ins` / `del` / `complex` |
| `filter` | string | VCF FILTER | `PASS` / VQSR tranche / hard-filter name |
| `qual` | float | VCF QUAL | |
| `vaf` | float | INFO/AF | Or per-backend median if multi-backend |
| `backends` | string | INFO/BACKENDS | Comma-separated; matches CRyPTIC convention |
| `consensus_votes` | int | INFO/CONSENSUS_VOTES | Number of backends that called the variant |
| `gene` | string | SnpEff ANN | Only populated when SnpEff is run (Phase 1.1) |
| `effect` | string | SnpEff ANN | e.g. `missense_variant` |
| `protein_change` | string | SnpEff ANN | HGVS p.* notation |
| `nucleotide_change` | string | SnpEff ANN | HGVS c.* notation |
| `aro_terms` | string | optional | If a catalogue overlay is applied; semicolon-separated ARO IDs |

**Why this design:**
- Sample-level long format → trivially joinable with phenotype tables (CRyPTIC's DST_MEASUREMENTS, MAGMA's clinical metadata)
- Column names mirror VCF semantics → familiar to anyone using bcftools / VEP / SnpEff
- `backends`, `consensus_votes` carry the per-record provenance from our spec §E
- `aro_terms` is the hAMRonization hook — populated when the consumer runs an AMR catalogue overlay (or when `mtbc-resistotyper-nf` consumes the output)

---

## 5. Implementation plan

### Phase A — L1 canonical TSV (default-on)

Single adapter module that consumes the consensus VCF + provenance and writes the TSV per sample.

- New local module: `modules/local/vcf_to_canonical_tsv/main.nf`
- Implementation: small Python script (pysam + pandas), shipped in `bin/`, containerised via the existing pysam biocontainer
- Hooks into `MTBC_VARCALLING` as a post-consensus normalisation step
- Adds two emit channels to the contract: `canonical_tsv` (per sample) and `canonical_tsv_cohort` (concatenated)
- Estimate: ~1 day's work + tests

### Phase B — L2 CRyPTIC parquet (`--export_cryptic` opt-in)

- New params: `export_cryptic` (bool, default false), `cryptic_schema_version` (default `'3.4.0'`)
- **PREREQUISITE: resolve OPEN QUESTION 1** (download DATA_SCHEMA.pdf from Zenodo and read it before writing schema-mapping code)
- New local module: `modules/local/tsv_to_cryptic_parquet/main.nf`
- Implementation: Python script using PyArrow, writes `WGS_SAMPLES.parquet`, `VARIANTS.parquet`, `EFFECTS.parquet`, `MUTATIONS.parquet` per cohort (not per sample — CRyPTIC tables are cohort-level)
- A small validation script: load the written parquets with PyArrow, assert dtypes match CRyPTIC's schema, fail fast if column names drift
- Estimate: 2–3 days' work including schema validation tests

### Phase C — End-to-end resistotyper-ml ingestion test

- New integration test in `tests/integration/t4_cryptic_to_resistotyper_ml.sh`
- Runs mtbc-varcaller-nf with `--export_cryptic` on the 3-sample EXIT-RIF test profile
- Loads emitted parquets with the same PyArrow loader resistotyper-ml uses
- Asserts: column names + dtypes match CRyPTIC v3.4.0 spec; sample IDs round-trip; can be concatenated with CRyPTIC tables (no schema errors on `pyarrow.concat_tables`)
- Estimate: 1 day's work; gated on Phase B

---

## 6. SnpEff add (for L1 gene-aware annotation)

L1's `gene / effect / protein_change / nucleotide_change` columns require SnpEff (or equivalent) annotation in the pipeline. Phase 1.1 follow-up logged separately:

- Install nf-core `snpeff` module
- Add `SNPEFF` step between consensus and L1-TSV adapter
- Reuse the H37Rv SnpEff database MAGMA already bundles (`resources/snpeff/data/Mycobacterium_tuberculosis_h37rv/`) — XBS's submodule could be extended to ship it, or we vendor it locally
- Without SnpEff, L1 still works but gene/effect columns are empty (graceful degradation)

---

## 7. mtbc-resistotyper-nf companion change

`mtbc-resistotyper-nf` already has a `docs/RELATED_WORK.md` follow-up logged for **hAMRonization / ARO canonical output**. That follow-up should align with this evaluation:

- Resistotyper outputs the `PREDICTIONS` parquet under `--export_cryptic` (the same flag name across the family)
- Per-prediction provenance: which backend (TBProfiler / Mykrobe / SAM-TB / GenTB / mtb-resistotyper-ml) made each call
- Phase-2: a single companion CLI (`mtbc-cryptic-export` or `mycobactopia export`) can re-package mtbc-varcaller-nf + mtbc-resistotyper-nf outputs together into a complete CRyPTIC-shaped release

---

## 8. Risks and open questions

| Risk / question | Mitigation |
|---|---|
| **OPEN Q1**: CRyPTIC `DATA_SCHEMA.pdf` not read yet — column names are best-guess | Block Phase B on downloading + reading the PDF; document the actual schema in this file once resolved |
| **OPEN Q2**: sample ID convention — `UNIQUE_ID` composite vs free-form | User decision (see below) |
| **OPEN Q3**: per-sample vs cohort parquets — CRyPTIC ships cohort-level; we may want per-sample for streaming | Default to cohort-level (matches CRyPTIC); offer `--cryptic_per_sample` if needed |
| Storage cost — 994 MB VARIANTS table for 54k isolates implies ~18 kB/sample on average. Per 100-sample cohort: ~2 MB. Trivial. | None — storage is not a constraint |
| Schema drift — if CRyPTIC v4.0.0 changes columns | `cryptic_schema_version` param + version-specific adapters; ship a deprecation path |
| Parquet vs Arrow vs CSV — what's the actual format CRyPTIC ships? Tables are listed as `.parquet` on Zenodo | None — match the released format |
| **Resistotyper-ml's actual ingestion code** — does it read CRyPTIC tables directly via PyArrow, or via a pre-derived feature matrix? | User to confirm; if a pre-derived feature matrix, we may also need to emit that |

### Open questions blocking Phase B

These are decisions the user / project lead should make before implementation:

1. **Sample identifier**: enforce `UNIQUE_ID = "${study}.${sample}.${library}"` (or similar composite), or pass the samplesheet `sample` field through verbatim?
2. **resistotyper-ml ingestion target**: does it read CRyPTIC's `VARIANTS.parquet` directly, or a pre-derived feature matrix (sample × variant_id pivot)? If the latter, we should emit that too.
3. **SnpEff dependency**: is requiring SnpEff for the `gene / effect / protein_change` columns acceptable for L1 default, or should those columns be lazy-populated only when `--export_cryptic` is set?
4. **`--cryptic_per_sample` mode**: is per-sample parquet emit useful for streaming pipelines, or always cohort-level?
5. **Catalogue overlay**: should `--export_cryptic` also accept a catalogue VCF (WHO v2 or Coll2018) and pre-populate the `aro_terms` / catalogue-membership columns, or leave that to mtbc-resistotyper-nf downstream?

---

## 9. Recommendation

**Adopt the three-layer model.** Land in two PRs on this branch:

- **PR 1 (this branch, Phase A)**: L0 (already exists) + L1 canonical TSV default-on. Adds `canonical_tsv` emit to `MTBC_VARCALLING` contract. Adds `vcf_to_canonical_tsv` adapter. Updates `docs/CONTRACT.md`. No `--export_cryptic` yet.
- **PR 2 (follow-up branch, Phase B)**: L2 CRyPTIC parquet behind `--export_cryptic`. Blocked on OPEN Q1 (DATA_SCHEMA.pdf read).
- **PR 3 (follow-up, Phase C)**: end-to-end test that resistotyper-ml can ingest the parquets.

Default behaviour after PR 1: every user gets L0 VCF + L1 TSV automatically — funcscan-compatible, joinable with any cohort metadata table, hAMRonization-ready.
Power user behaviour after PR 2: `--export_cryptic` adds L2 parquets — drop-in for resistotyper-ml and CRyPTIC-extension databases.

---

## 10. References

- CRyPTIC v3.4.0 (Zenodo release): [10.5281/zenodo.16041005](https://zenodo.org/records/16041005); CC-BY-4.0; *The CRyPTIC Consortium Dataset.*
- mtb-resistotyper-ml manuscript anchor: `manuscripts/mtb-resistotyper-ml-manuscript-anchor.md` — names this pipeline as the future variant-feature source.
- hAMRonization (PHA4GE): [github.com/pha4ge/hAMRonization](https://github.com/pha4ge/hAMRonization) — 17+ AMR tool harmonisation spec; field's lingua franca.
- mtbc-varcaller-nf spec: `abc-universe/specs/active/mtbc-varcaller-nf.md` — confirms the importable-subworkflow contract; this proposal extends `emit:` with `canonical_tsv` and (opt-in) `cryptic_parquet`.
- Family RELATED_WORK: `docs/RELATED_WORK.md` — funcscan + bacannot as the parallel-backend / aggregation reference points.
