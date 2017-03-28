open Nonstd


let indel_realigner_config =
  let open Biokepi.Tools.Gatk.Configuration in
  (* We need to ignore reads with no quality scores that BWA includes in the
     BAM, but the GATK's Indel Realigner chokes on (even though the reads are
     unmapped).

     cf. http://gatkforums.broadinstitute.org/discussion/1429/error-bam-file-has-a-read-with-mismatching-number-of-bases-and-base-qualities *)
  let indel_cfg = {
    Indel_realigner.
    name = "ignore-mismatch";
    filter_reads_with_n_cigar = true;
    filter_mismatching_base_and_quals = true;
    filter_bases_not_stored = true;
    parameters = [] }
  in
  let target_cfg = {
    Realigner_target_creator.
    name = "ignore-mismatch";
    filter_reads_with_n_cigar = true;
    filter_mismatching_base_and_quals = true;
    filter_bases_not_stored = true;
    parameters = [] }
  in
  (indel_cfg, target_cfg)

let star_config params =
  let parameters =
    match params.Parameters.machine_memory with
    | None -> []
    | Some gb ->
      let mem_bytes = gb * 1000 * 1000 * 1000 in
      ["--limitBAMsortRAM", sprintf "%d" mem_bytes]
  in
  let open Biokepi.Tools.Star.Configuration.Align in
  {
    name = "mapq_default_60";
    parameters;
    (* Cf. https://www.broadinstitute.org/gatk/guide/article?id=3891

       In particular:

       STAR assigns good alignments a MAPQ of 255 (which technically means
       “unknown” and is therefore meaningless to GATK). So we instead reassign
       all good alignments to the default value of 60.  *)
    sam_mapq_unique = Some 60;
    overhang_length = None;
  }

let vaxrank_config include_mismatches_after_variant =
  let open Biokepi.Tools.Vaxrank.Configuration in
  {name = "epidisco-40pep";
   vaccine_peptide_length = 25;
   padding_around_mutation = 5;
   max_vaccine_peptides_per_mutation = 3;
   max_mutations_in_report = 40;
   min_mapping_quality = 1;
   min_variant_sequence_coverage = 1;
   min_alt_rna_reads = 3;
   include_mismatches_after_variant;
   use_duplicate_reads = false;
   drop_secondary_alignments = false;
   mhc_epitope_lengths = [8; 9; 10; 11];
   reviewers = None;
   final_reviewer = None;
   xlsx_report = true;
   pdf_report = true;
   ascii_report = true;
   parameters = []}

let strelka_config = Biokepi.Tools.Strelka.Configuration.exome_default

let mutect_config = Biokepi.Tools.Mutect.Configuration.default
let mutect_config_mouse =
  Biokepi.Tools.Mutect.Configuration.default_without_cosmic

let mark_dups_config heap =
  Biokepi.Tools.Picard.Mark_duplicates_settings.
    { default with
      name = "picard-with-heap";
      mem_param = heap }
