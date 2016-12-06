
open Nonstd
module String = Sosa.Native_string

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

let star_config =
  let open Biokepi.Tools.Star.Configuration.Align in
  {
    name = "mapq_default_60";
    parameters = [];
    (* Cf. https://www.broadinstitute.org/gatk/guide/article?id=3891

    In particular:

       STAR assigns good alignments a MAPQ of 255 (which technically means
       “unknown” and is therefore meaningless to GATK). So we instead reassign
       all good alignments to the default value of 60.  *)
    sam_mapq_unique = Some 60;
    overhang_length = None;
  }

let vaxrank_config =
  let open Biokepi.Tools.Vaxrank.Configuration in
  { default with
    name = "PGV-configuration";
    padding_around_mutation = 5;
    max_vaccine_peptides_per_mutation = 3;
    max_mutations_in_report = 20; }

let strelka_config = Biokepi.Tools.Strelka.Configuration.exome_default

let mutect_config = Biokepi.Tools.Mutect.Configuration.default
let mutect_config_mouse =
  Biokepi.Tools.Mutect.Configuration.default_without_cosmic

let mark_dups_config heap =
  Biokepi.Tools.Picard.Mark_duplicates_settings.
    { default with
      name = "picard-with-heap";
      mem_param = heap }


module Parameters = struct

  type t = {
    (* MHC Alleles which take precedence over those generated by Seq2HLA. *)
    mhc_alleles: string list option;
    mouse_run: bool [@default false];
    with_topiary: bool [@default false];
    with_seq2hla: bool [@default false];
    with_mutect2: bool [@default false];
    with_varscan: bool [@default false];
    with_somaticsniper: bool [@default false];
    with_optitype_normal: bool [@default false];
    with_optitype_tumor: bool [@default false];
    with_optitype_rna: bool [@default false];
    email_options: Qc.EDSL.email_options option;
    bedfile: string option [@default None];
    experiment_name: string [@main];
    reference_build: string;
    normal_inputs: Biokepi.EDSL.Library.Input.t list; (* 1+ items *)
    tumor_inputs: Biokepi.EDSL.Library.Input.t list;  (* 1+ items *)
    rna_inputs: Biokepi.EDSL.Library.Input.t list option;    (* 0+ items *)
    picard_java_max_heap: string option;
    igv_url_server_prefix: string option;
  } [@@deriving show,make]

  let construct_run_name params =
    let {normal_inputs;  tumor_inputs; rna_inputs;
         experiment_name; reference_build; _} = params in
    String.concat ~sep:"-" [
      experiment_name;
      sprintf "%dnormals" (List.length normal_inputs);
      sprintf "%dtumors" (List.length tumor_inputs);
      begin
        match rna_inputs with
          None -> "" |
          Some is -> sprintf "%drnas" (List.length is) end;
      reference_build;
    ]

  (* To maximize sharing the run-directory depends only on the
     experiement name (to allow the use to force a fresh one) and the
     reference-build (since Biokepi does not track it yet in the filenames). *)
  let construct_run_directory param =
    sprintf "%s-%s" param.experiment_name param.reference_build


  let input_to_string t =
    let open Biokepi.EDSL.Library.Input in
    let fragment =
      function
      | (_, PE (r1, r2)) -> sprintf "Paired-end FASTQ"
      | (_, SE r) -> sprintf "Single-end FASTQ"
      | (_, Of_bam (`SE,_,_, p)) -> "Single-end-from-bam"
      | (_, Of_bam (`PE,_,_, p)) -> "Paired-end-from-bam"
    in
    let same_kind a b =
      match a, b with
      | (_, PE _)              , (_, PE _)               -> true
      | (_, SE _)              , (_, SE _)               -> true
      | (_, Of_bam (`SE,_,_,_)), (_, Of_bam (`SE,_,_,_)) -> true
      | (_, Of_bam (`PE,_,_,_)), (_, Of_bam (`PE,_,_,_)) -> true
      | _, _ -> false
    in
    match t with
    | Fastq { sample_name; files } ->
      sprintf "%s, %s"
        sample_name
        begin match files with
        | [] -> "NONE"
        | [one] ->
          sprintf "1 fragment: %s" (fragment one)
        | one :: more ->
          sprintf "%d fragments: %s"
            (List.length more + 1)
            (if List.for_all more ~f:(fun f -> same_kind f one)
             then "all " ^ (fragment one)
             else "heterogeneous")
        end

  let metadata t = [
    "MHC Alleles",
    begin match t.mhc_alleles  with
    | None  -> "None provided"
    | Some l -> sprintf "Alleles: [%s]" (String.concat l ~sep:"; ")
    end;
    "Reference-build", t.reference_build;
    "Normal-inputs",
    List.map ~f:input_to_string t.normal_inputs |> String.concat;
    "Tumor-inputs",
    List.map ~f:input_to_string t.tumor_inputs |> String.concat;
    "RNA-inputs",
    Option.value_map
      ~default:"none"
      ~f:(fun r -> List.map ~f:input_to_string r |> String.concat)
      t.rna_inputs;
  ]
end


module Full (Bfx: Extended_edsl.Semantics) = struct

  module Stdlib = Biokepi.EDSL.Library.Make(Bfx)


  let to_bam_dna ~parameters ~reference_build samples =
    let sample_to_bam sample =
      let list_of_inputs = Stdlib.bwa_mem_opt_inputs sample in
      List.map list_of_inputs ~f:(Bfx.bwa_mem_opt ~reference_build ?configuration:None)
      |> Bfx.list
      |> Bfx.merge_bams
      |> Bfx.picard_mark_duplicates
        ~configuration:(mark_dups_config parameters.Parameters.picard_java_max_heap)
    in
    List.map samples ~f:sample_to_bam
    |> Bfx.list
    |> Bfx.merge_bams


  let process_dna_bam_pair ~normal ~tumor =
    let pair =
      Bfx.pair normal tumor
      |> Bfx.gatk_indel_realigner_joint
        ~configuration:indel_realigner_config
    in
    Bfx.gatk_bqsr (Bfx.pair_first pair), Bfx.gatk_bqsr (Bfx.pair_second pair)


  let vcf_pipeline ~parameters ?bedfile ~normal ~tumor =
    let open Parameters in
    let {with_mutect2; with_varscan; with_somaticsniper;
           mouse_run; reference_build; _} = parameters in
    let opt_vcf test name somatic vcf =
      if test then [name, somatic, vcf ()] else []
    in
    let mutect_config =
      if mouse_run then mutect_config_mouse else mutect_config in
    let vcfs =
      [
        "strelka", true, Bfx.strelka () ~normal ~tumor ~configuration:strelka_config;
        "mutect", true, Bfx.mutect () ~normal ~tumor ~configuration:mutect_config;
        "haplo-normal", false, Bfx.gatk_haplotype_caller normal;
        "haplo-tumor", false, Bfx.gatk_haplotype_caller tumor;
      ]
      @ opt_vcf with_mutect2
        "mutect2" true (fun () -> Bfx.mutect2 ~normal ~tumor ())
      @ opt_vcf with_varscan
        "varscan" true (fun () -> Bfx.varscan_somatic ~normal ~tumor ())
      @ opt_vcf with_somaticsniper
        "somatic-sniper" true (fun () -> Bfx.somaticsniper ~normal ~tumor ())
    in
    match bedfile with
    | None -> vcfs
    | Some bedfile ->
      let bed = (Bfx.bed (Bfx.input_url bedfile)) in
      List.map vcfs ~f:(fun (name, s, v) -> name, s, Bfx.filter_to_region v bed)


  let qc fqs = Bfx.concat fqs |> Bfx.fastqc

  (* Makes a list of samples (which are themselves fastqs or BAMs) into one (or
     two, if paired-end) FASTQs. *)
  let concat_samples samples =
    Bfx.list_map
      ~f:(Bfx.lambda (fun f -> Bfx.concat f))
      (Bfx.list samples)

  let to_bam_rna ~parameters ~reference_build samples =
    let sample_to_bam sample =
      Bfx.list_map sample
        ~f:(Bfx.lambda (fun fq ->
            Bfx.star ~configuration:star_config ~reference_build fq))
      |> Bfx.merge_bams
      |> Bfx.picard_mark_duplicates
        ~configuration:(mark_dups_config parameters.Parameters.picard_java_max_heap)
    in
    List.map samples ~f:sample_to_bam
    |> Bfx.list
    |> Bfx.merge_bams
    |> Bfx.gatk_indel_realigner
      ~configuration:indel_realigner_config


  let seq2hla_hla fqs =
    Bfx.seq2hla (Bfx.concat fqs) |> Bfx.save "Seq2HLA"


  let optitype_hla fqs ftype name =
    Bfx.optitype ftype (Bfx.concat fqs) |> Bfx.save ("OptiType-" ^ name)


  type rna_results =
    { rna_bam: [ `Bam ] Bfx.repr;
      stringtie: [ `Gtf ] Bfx.repr;
      rna_bam_flagstat: [ `Flagstat ] Bfx.repr }

  let rna_pipeline
      ~parameters ~reference_build samples =
    let bam = to_bam_rna ~parameters ~reference_build samples in
    (* Seq2HLA does not work on mice: *)
    { rna_bam = bam |> Bfx.save "rna-bam";
      stringtie = bam |> Bfx.stringtie |> Bfx.save "stringtie";
      rna_bam_flagstat = bam |> Bfx.flagstat |> Bfx.save "rna-bam-flagstat";}

  type fastqc_results = {
    normal_fastqcs: [ `Fastqc ] Bfx.repr list;
    tumor_fastqcs: [ `Fastqc ] Bfx.repr list;
    rna_fastqcs: [ `Fastqc ] Bfx.repr list option; }
  let fastqc_pipeline ~normal_samples ~tumor_samples ?rna_samples () =
    let normal_fastqcs =
      List.mapi
        ~f:(fun i fq -> qc fq |> Bfx.save (sprintf "QC:normal-%d" i))
        normal_samples
    in
    let tumor_fastqcs =
      List.mapi
        ~f:(fun i fq -> qc fq |> Bfx.save (sprintf "QC:tumor-%d" i))
        tumor_samples
    in
    let rna_fastqcs =
      match rna_samples with
      | None -> None
      | Some rna_samples ->
        Some
          (List.mapi
             ~f:(fun i fq -> qc fq |> Bfx.save (sprintf "QC:rna-%d" i))
             rna_samples)
    in
    { normal_fastqcs; tumor_fastqcs; rna_fastqcs }


  let email_pipeline
      ?rna_results ~parameters ~normal_bam_flagstat ~tumor_bam_flagstat ~fastqcs
    =
    let rna_bam_flagstat =
      Option.map rna_results
        ~f:(fun {rna_bam_flagstat; _} -> rna_bam_flagstat) in
    match parameters.Parameters.email_options with
    | None -> None
    | Some email_options ->
      let flagstat_email =
        Bfx.flagstat_email
          ~normal:normal_bam_flagstat ~tumor:tumor_bam_flagstat
          ?rna:rna_bam_flagstat email_options
      in
      let fastqc_email =
        Bfx.fastqc_email ~fastqcs email_options in
      Some [flagstat_email; fastqc_email]


  type hla_results = {
    optitype_normal : [ `Optitype_result ] Bfx.repr option;
    optitype_tumor : [ `Optitype_result ] Bfx.repr option;
    optitype_rna: [ `Optitype_result ] Bfx.repr option;
    seq2hla: [ `Seq2hla_result ] Bfx.repr option;
    mhc_alleles : [ `MHC_alleles ] Bfx.repr option}
  let hla_pipeline ?rna_samples ~parameters ~normal_samples ~tumor_samples =
    let open Parameters in
    let optitype_normal, optitype_tumor =
      let {with_optitype_normal; with_optitype_tumor; _} = parameters in
      (if with_optitype_normal
       then
         Some (optitype_hla (concat_samples normal_samples) `DNA "Normal")
       else None),
      (if with_optitype_tumor
       then
         Some (optitype_hla (concat_samples tumor_samples) `DNA "Tumor")
       else None)
    in
    let seq2hla, optitype_rna =
      match rna_samples with
      | None -> None, None
      | Some rna_samples ->
        let fqs = concat_samples rna_samples in
        begin match parameters.with_seq2hla, parameters.with_optitype_rna with
        | false, false -> (None, None)
        | false, true -> (None, Some (optitype_hla fqs `RNA "RNA"))
        | true, false -> (Some (seq2hla_hla fqs), None)
        | true, true ->
          (Some (seq2hla_hla fqs), Some (optitype_hla fqs `RNA "RNA"))
        end
    in
    (* HLA priority list
         - Manual HLAs
         - Seq2HLA results
         - OptiType on Normal DNA
         - OptiType on Tumor DNA
         - OptiType on Tumor RNA *)
    let mhc_alleles =
      let optitype_hla =
        match optitype_normal, optitype_tumor, optitype_rna with
        | Some n, _, _ -> Some n
        | None, Some t, _ -> Some t
        | None, None, Some r -> Some r
        | None, None, None -> None
      in
      begin match parameters.mhc_alleles, seq2hla, optitype_hla with
      | Some alleles, _, _ -> Some (Bfx.mhc_alleles (`Names alleles))
      | None, Some s, _ -> Some (Bfx.hlarp (`Seq2hla s))
      | None, None, Some s -> Some (Bfx.hlarp (`Optitype s))
      | None, None, None -> None
      end
    in
    {optitype_normal; optitype_tumor; seq2hla; optitype_rna; mhc_alleles;}

  let run parameters =
    let open Parameters in
    let rna_samples =
      Option.map ~f:(List.map ~f:Stdlib.fastq_of_input) parameters.rna_inputs in
    let normal_samples =
        List.map ~f:Stdlib.fastq_of_input parameters.normal_inputs in
    let tumor_samples =
        List.map ~f:Stdlib.fastq_of_input parameters.tumor_inputs in
    let normal_bam, tumor_bam =
      let to_bam =
        to_bam_dna ~reference_build:parameters.reference_build ~parameters in
      process_dna_bam_pair
        ~normal:(parameters.normal_inputs |> to_bam)
        ~tumor:(parameters.tumor_inputs |> to_bam)
      |> (fun (n, t) -> Bfx.save "normal-bam" n, Bfx.save "tumor-bam" t)
    in
    let bedfile = parameters.bedfile in
    let vcfs =
      vcf_pipeline ~parameters ?bedfile ~normal:normal_bam ~tumor:tumor_bam in
    let somatic_vcfs =
      List.filter ~f:(fun (_, somatic, _) -> somatic) vcfs
      |> List.map ~f:(fun (_, _, v) -> v) in
    let rna_results =
      let {reference_build; with_seq2hla; with_optitype_rna; _} = parameters in
      match rna_samples with
      | None -> None
      | Some rnas ->
        Some (rna_pipeline rnas
                ~reference_build ~parameters)
    in
    let vcfs =
      match parameters.reference_build with
      | "b37" | "hg19" ->
        List.map vcfs ~f:(fun (k, somatic, vcf) ->
            Bfx.vcf_annotate_polyphen vcf
            |> fun a -> (k, Bfx.save ("VCF-annotated-" ^ k) a))
      | _ -> List.map vcfs ~f:(fun (name, somatic, v) ->
          name, (Bfx.save (sprintf "vcf-%s" name) v))
    in
    let {optitype_normal; optitype_tumor; optitype_rna; mhc_alleles; seq2hla} =
      hla_pipeline ~parameters ~normal_samples ~tumor_samples ?rna_samples in
    let vaxrank =
      let open Option in
      rna_results
      >>= fun {rna_bam; _} ->
      mhc_alleles
      >>= fun alleles ->
      return (
        Bfx.vaxrank ~configuration:vaxrank_config somatic_vcfs rna_bam
          `NetMHCcons alleles
        |> Bfx.save "Vaxrank"
      ) in
    let {normal_fastqcs; tumor_fastqcs; rna_fastqcs} as fastqc_results =
      fastqc_pipeline ~normal_samples ~tumor_samples ?rna_samples () in
    let fastqcs =
      let f name = fun i f ->
        let name = name ^ "-" ^ Int.to_string i in
        name, f
      in
      List.mapi ~f:(f "normal") fastqc_results.normal_fastqcs
      @ List.mapi ~f:(f "tumor") fastqc_results.tumor_fastqcs
      @ List.mapi ~f:(f "RNA")
        (Option.value ~default:[] fastqc_results.rna_fastqcs) in
    let normal_bam_flagstat, tumor_bam_flagstat =
      Bfx.flagstat normal_bam |> Bfx.save "normal-bam-flagstat",
      Bfx.flagstat tumor_bam |> Bfx.save "tumor-bam-flagstat"
    in
    let emails =
      email_pipeline
        ?rna_results ~parameters ~normal_bam_flagstat ~tumor_bam_flagstat ~fastqcs in
    let report =
      let rna_bam, optitype_rna, stringtie, seq2hla, rna_bam_flagstat =
        match rna_results with
        | None -> None, None, None, None, None
        | Some {rna_bam; stringtie; rna_bam_flagstat} ->
          Some rna_bam, optitype_rna, Some stringtie,
          seq2hla, Some rna_bam_flagstat
      in
      Bfx.report
        (Parameters.construct_run_name parameters)
        ?igv_url_server_prefix:parameters.igv_url_server_prefix
        ~vcfs ?bedfile ~fastqcs
        ~normal_bam ~tumor_bam ?rna_bam
        ~normal_bam_flagstat ~tumor_bam_flagstat
        ?optitype_normal ?optitype_tumor ?optitype_rna
        ?vaxrank ?seq2hla ?stringtie ?rna_bam_flagstat
        ~metadata:(Parameters.metadata parameters) in
    let observables =
      report :: begin match emails with
      | None -> []
      | Some e -> List.map ~f:Bfx.to_unit e
      end in
    Bfx.observe (fun () -> Bfx.list observables |> Bfx.to_unit)
end
