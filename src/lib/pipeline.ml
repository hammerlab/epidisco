open Nonstd
module String = Sosa.Native_string
open Tool_configuration


module Full (Bfx: Extended_edsl.Semantics) = struct

  module Stdlib = Biokepi.EDSL.Library.Make(Bfx)

  let to_bam_dna ~parameters ~reference_build samples =
    let sample_to_bam sample =
      let open Biokepi.EDSL.Library.Input in
      let bam =
        match sample with
        | Bam {bam_sample_name; path; how; sorting; reference_build} ->
          (Bfx.bam ?sorting ~sample_name:bam_sample_name
             ~reference_build (Bfx.input_url path))
          |> Bfx.picard_reorder_sam
            ?mem_param:parameters.Parameters.java_max_heap
        | sample ->
          let bwa_mem_of_input_sample input_sample =
            match parameters.Parameters.use_bwa_mem_opt with
            | true ->
              Stdlib.bwa_mem_opt_inputs_exn input_sample
              |> List.map ~f:(Bfx.bwa_mem_opt ~reference_build ?configuration:None)
              |> Bfx.list
            | false ->
              Stdlib.fastq_of_input input_sample
              |> Bfx.list_map
                ~f:(Bfx.lambda
                      (Bfx.bwa_mem ~reference_build ?configuration:None))
          in
          bwa_mem_of_input_sample sample
          |> Bfx.merge_bams
      in
      let md_config =
        mark_dups_config parameters.Parameters.java_max_heap in
      if parameters.Parameters.with_mark_dups
      then Bfx.picard_mark_duplicates bam ~configuration:md_config
      else bam
    in
    List.map samples ~f:sample_to_bam
    |> Bfx.list
    |> Bfx.merge_bams


  let process_dna_bam_pair ~parameters ~normal ~tumor =
    let paired = Bfx.pair normal tumor in
    let pair =
      if parameters.Parameters.with_indel_realigner
      then paired
           |> Bfx.gatk_indel_realigner_joint
             ~configuration:(indel_realigner_config parameters.Parameters.java_max_heap)
      else paired
    in
    let first = Bfx.pair_first pair in
    let second = Bfx.pair_second pair in
    if parameters.Parameters.with_bqsr
    then Bfx.gatk_bqsr first, Bfx.gatk_bqsr second
    else first, second


  let vcf_pipeline ~parameters ?bedfile ~normal ~tumor =
    let open Parameters in
    let {with_mutect2; with_varscan; with_somaticsniper;
         without_cosmic; reference_build; _} = parameters in
    let opt_vcf test name somatic vcf =
      if test then [name, somatic, vcf ()] else []
    in
    let mutect_config =
      if without_cosmic then mutect_config_mouse else mutect_config in
    let vcfs =
      [
        "strelka", true, Bfx.strelka () ~normal ~tumor ~configuration:strelka_config;
        "mutect", true, Bfx.mutect () ~normal ~tumor ~configuration:mutect_config;
        "haplo-normal", false, Bfx.gatk_haplotype_caller normal;
        "haplo-tumor", false, Bfx.gatk_haplotype_caller tumor;
      ]
      @ opt_vcf with_mutect2
        "mutect2" true (fun () ->
            let configuration =
              if without_cosmic then
                Biokepi.Tools.Gatk.Configuration.Mutect2.default_without_cosmic
              else
                Biokepi.Tools.Gatk.Configuration.Mutect2.default
            in
            Bfx.mutect2 ~normal ~tumor ~configuration ())
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


  let fastqc_pipeline fqs = Bfx.concat fqs |> Bfx.fastqc


  (* Makes a list of samples (which are themselves fastqs or BAMs) into one (or
     two, if paired-end) FASTQs. *)
  let concat_samples samples =
    let samplefqs = List.map ~f:(fun (n, f) -> f) samples in
    Bfx.list_map
      ~f:(Bfx.lambda (fun f -> Bfx.concat f))
      (Bfx.list samplefqs)


  let to_bam_rna ~parameters ~reference_build samples =
    let sample_to_bam sample =
      let open Biokepi.EDSL.Library.Input in
      let bam =
        match sample with
        | Bam {bam_sample_name; path; how; sorting; reference_build} ->
          Bfx.bam ?sorting ~sample_name:bam_sample_name
            ~reference_build (Bfx.input_url path)
          |> Bfx.picard_reorder_sam
            ?mem_param:parameters.Parameters.java_max_heap
        | sample ->
          Bfx.list_map (Stdlib.fastq_of_input sample)
            ~f:(Bfx.lambda (fun fq ->
                Bfx.star ~configuration:star_config ~reference_build fq))
          |> Bfx.merge_bams
      in
      let configuration =
        mark_dups_config parameters.Parameters.java_max_heap
      in
      if parameters.Parameters.with_mark_dups
      then Bfx.picard_mark_duplicates ~configuration bam
      else bam
    in
    let merged_bam =
      List.map samples ~f:sample_to_bam
      |> Bfx.list
      |> Bfx.merge_bams in
    (* We split out the spliced and non-spliced reads so that we can run indel
       realignment on all reads that don't span a splice junction (and thus
       cause the GATK IndelRealigner we're using to crash.) We then merge the
       spliced reads back in. *)
    let spliced_bam =
      let filter = Biokepi.Tools.Sambamba.Filter.Defaults.only_split_reads in
      Bfx.sambamba_filter ~filter merged_bam in
    let indel_realigned_bam =
      let filter = Biokepi.Tools.Sambamba.Filter.Defaults.drop_split_reads in
      Bfx.sambamba_filter ~filter merged_bam
      |> Bfx.gatk_indel_realigner
        ~configuration:(indel_realigner_config parameters.Parameters.java_max_heap)
    in
    if parameters.Parameters.with_indel_realigner
    then Bfx.merge_bams @@ Bfx.list [spliced_bam; indel_realigned_bam]
    else merged_bam


  let get_named_fastqs =
    let open Biokepi.EDSL.Library.Input in
    List.map
      ~f:(fun i ->
        let sname =
          match i with
          | Fastq {fastq_sample_name; _} -> fastq_sample_name
          | Bam {bam_sample_name; _} -> bam_sample_name
        in
        sname, Stdlib.fastq_of_input i)

  (** 
     A record to join a value and its saved version.

     Previous versions of Eidisco had a [Bfx.save] construct of type
     ['a repr -> 'a repr] which would “hide” saved values, we would
     then put [Bfx.save ~name] calls everywhere and forget about
     them. The new [save] from Biokepi is explicit, so to avoid too
     much rewriting of this pipeline we pack values together.

  *)
  type 'a saved = {
    content: 'a Bfx.repr;
    saved: [ `Saved of 'a ] Bfx.repr;
  }

  (** This is like {!Biokepi.EDSL.Semantics.save} but packs the saved
      node with its original value.  *)
  let save_through ~name x =
    { content = x; saved = Bfx.save ~name x }

  let seq2hla_hla fqs =
    Bfx.seq2hla (Bfx.concat fqs) |> save_through ~name:"Seq2HLA"


  let optitype_hla fqs ftype name =
    Bfx.optitype ftype (Bfx.concat fqs)
    |> save_through ~name:("OptiType-" ^ name)


  let run_kallisto ~reference_build ~rna_samples () =
    List.map
      ~f:(fun (n, fq) ->
        let name = sprintf "Kallisto: rna-%s" n in
        name, fq
        |> Bfx.concat
        |> Bfx.kallisto ~reference_build
        |> save_through ~name)
      (get_named_fastqs rna_samples)


  type rna_results =
    { rna_bam: [ `Bam ] saved;
      stringtie: [ `Gtf ] saved;
      rna_bam_flagstat: [ `Flagstat ] saved;
      kallisto: (string * [ `Kallisto_result ] saved) list option; }

  let rna_pipeline ~parameters ~reference_build rna_samples =
    let bam = to_bam_rna ~parameters ~reference_build rna_samples in
    let kallisto =
      if parameters.Parameters.with_kallisto
      then Some (run_kallisto ~reference_build ~rna_samples ())
      else None
    in
    { rna_bam = bam |> save_through ~name:"rna-bam";
      stringtie = bam |> Bfx.stringtie |> save_through ~name:"stringtie";
      rna_bam_flagstat = bam |> Bfx.flagstat |> save_through ~name:"rna-bam-flagstat";
      kallisto; }


  type fastqc_results = {
    normal_fastqcs: (string * [ `Fastqc ] saved) list;
    tumor_fastqcs: (string * [ `Fastqc ] saved) list;
    rna_fastqcs: (string * [ `Fastqc ] saved) list option; }
  let fastqc_pipeline ~normal_fastqs ~tumor_fastqs ?rna_fastqs () =
    let run_named_fastqc stype samples =
      List.map
        ~f:(fun (sname, fq) ->
          let qcname = sprintf "QC: %s-%s" stype sname in
          qcname, fastqc_pipeline fq |> save_through ~name:qcname)
        samples
    in
    let normal_fastqcs = run_named_fastqc "normal" normal_fastqs in
    let tumor_fastqcs = run_named_fastqc "tumor" tumor_fastqs in
    let rna_fastqcs = Option.map ~f:(run_named_fastqc "rna") rna_fastqs in
    { normal_fastqcs; tumor_fastqcs; rna_fastqcs }


  let email_pipeline
      ?rna_results ~parameters ~normal_bam_flagstat ~tumor_bam_flagstat ~fastqcs
    =
    let rna_bam_flagstat =
      Option.map rna_results
        ~f:(fun {rna_bam_flagstat; _} -> rna_bam_flagstat.content) in
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
    optitype_normal : [ `Optitype_result ] saved option;
    optitype_tumor : [ `Optitype_result ] saved option;
    optitype_rna: [ `Optitype_result ] saved option;
    seq2hla: [ `Seq2hla_result ] saved option;
    mhc_alleles : [ `MHC_alleles ] Bfx.repr option}
  let hla_pipeline ?rna_fastqs ~parameters ~normal_fastqs ~tumor_fastqs =
    let open Parameters in
    let optitype_normal, optitype_tumor =
      let {with_optitype_normal; with_optitype_tumor; _} = parameters in
      (if with_optitype_normal
       then
         Some (optitype_hla (concat_samples normal_fastqs) `DNA "Normal")
       else None),
      (if with_optitype_tumor
       then
         Some (optitype_hla (concat_samples tumor_fastqs) `DNA "Tumor")
       else None)
    in
    let seq2hla, optitype_rna =
      match rna_fastqs with
      | None -> None, None
      | Some rna_fastqs ->
        let fqs = concat_samples rna_fastqs in
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
      | None, Some s, _ -> Some (Bfx.hlarp (`Seq2hla s.content))
      | None, None, Some s -> Some (Bfx.hlarp (`Optitype s.content))
      | None, None, None -> None
      end
    in
    {optitype_normal; optitype_tumor; seq2hla; optitype_rna; mhc_alleles;}


  let run parameters =
    let open Parameters in
    let parameters = normalize_inputs parameters in
    let { normal_inputs; tumor_inputs; rna_inputs; _ } = parameters in
    let rna_fastqs = Option.map ~f:get_named_fastqs rna_inputs in
    let normal_fastqs = get_named_fastqs normal_inputs in
    let tumor_fastqs = get_named_fastqs tumor_inputs in
    let normal_bam, tumor_bam =
      let to_bam =
        to_bam_dna ~reference_build:parameters.reference_build ~parameters in
      process_dna_bam_pair
        ~parameters
        ~normal:(normal_inputs |> to_bam)
        ~tumor:(tumor_inputs |> to_bam)
      |> (fun (n, t) -> save_through ~name:"normal-bam" n, save_through ~name:"tumor-bam" t)
    in
    let bedfile = parameters.bedfile in
    let vcfs =
      vcf_pipeline ~parameters ?bedfile
        ~normal:normal_bam.content ~tumor:tumor_bam.content in
    let somatic_vcfs =
      List.filter ~f:(fun (_, somatic, _) -> somatic) vcfs
      |> List.map ~f:(fun (_, _, v) -> v) in
    let rna_results =
      let {reference_build; with_seq2hla; with_optitype_rna; _} = parameters in
      match rna_inputs with
      | None -> None
      | Some rna_samples ->
        Some (rna_pipeline rna_samples ~reference_build ~parameters)
    in
    let vcfs =
      match parameters.reference_build with
      | "b37" | "hg19" ->
        List.map vcfs ~f:(fun (k, somatic, vcf) ->
            Bfx.vcf_annotate_polyphen vcf
            |> fun a -> (k, save_through ("VCF-annotated-" ^ k) a))
      | _ -> List.map vcfs ~f:(fun (name, somatic, v) ->
          name, (save_through (sprintf "vcf-%s" name) v))
    in
    let {optitype_normal; optitype_tumor; optitype_rna; mhc_alleles; seq2hla} =
      hla_pipeline ~parameters ~normal_fastqs ~tumor_fastqs ?rna_fastqs
    in
    let topiary =
      let open Option in
      mhc_alleles
      >>= fun alleles ->
      return (
        Bfx.topiary somatic_vcfs parameters.Parameters.binding_predictor alleles
        |> save_through ~name:"Topiary"
      )
    in
    let vaxrank =
      let open Option in
      rna_results
      >>= fun {rna_bam; _} ->
      mhc_alleles
      >>= fun alleles ->
      let configuration =
        vaxrank_config parameters.vaxrank_include_mismatches_after_variant in
      return (
        Bfx.vaxrank ~configuration somatic_vcfs rna_bam.content
          parameters.Parameters.binding_predictor alleles
        |> save_through ~name:"Vaxrank"
      )
    in
    let {normal_fastqcs; tumor_fastqcs; rna_fastqcs} as fastqc_results =
      fastqc_pipeline ~normal_fastqs ~tumor_fastqs ?rna_fastqs ()
    in
    let fastqcs =
      fastqc_results.normal_fastqcs
      @ fastqc_results.tumor_fastqcs
      @ Option.value ~default:[] fastqc_results.rna_fastqcs in
    let normal_bam_flagstat, tumor_bam_flagstat =
      Bfx.flagstat normal_bam.content |> save_through ~name:"normal-bam-flagstat",
      Bfx.flagstat tumor_bam.content |> save_through ~name:"tumor-bam-flagstat"
    in
    let emails =
      email_pipeline ?rna_results
        ~parameters
        ~normal_bam_flagstat:normal_bam_flagstat.content
        ~tumor_bam_flagstat:tumor_bam_flagstat.content
        ~fastqcs:(List.map fastqcs ~f:(fun (k, v) -> (k, v.content)))
    in
    let rna_bam, stringtie, rna_bam_flagstat, kallisto =
      match rna_results with
      | None -> None, None, None, None
      | Some {rna_bam; stringtie; rna_bam_flagstat; kallisto} ->
        Some rna_bam, Some stringtie, Some rna_bam_flagstat, kallisto
    in
    let report =
      let opt_saved = Option.map ~f:(fun v -> v.saved) in
      let kv_list_saved = List.map ~f:(fun (k, v) -> k, v.saved) in
      Bfx.report
        (Parameters.construct_run_name parameters)
        ?igv_url_server_prefix:parameters.igv_url_server_prefix
        ~vcfs:(kv_list_saved vcfs)
        ?bedfile ~fastqcs:(kv_list_saved fastqcs)
        ~normal_bam:normal_bam.saved
        ~tumor_bam:tumor_bam.saved
        ?rna_bam:(opt_saved rna_bam)
        ~normal_bam_flagstat:normal_bam_flagstat.saved
        ~tumor_bam_flagstat:tumor_bam_flagstat.saved
        ?optitype_normal:(opt_saved optitype_normal)
        ?optitype_tumor:(opt_saved optitype_tumor)
        ?optitype_rna:(opt_saved optitype_rna)
        ?vaxrank:(opt_saved vaxrank)
        ?seq2hla:(opt_saved seq2hla)
        ?stringtie:(opt_saved stringtie)
        ?rna_bam_flagstat:(opt_saved rna_bam_flagstat)
        ?topiary:(opt_saved topiary)
        ?kallisto:(Option.map ~f:kv_list_saved kallisto)
        ~metadata:(Parameters.metadata parameters) in
    let results =
      let both v = [Bfx.to_unit v.content; Bfx.to_unit v.saved] in
      let opt v =
        Option.value_map ~default:[] ~f:both v in
      let kv l = List.concat_map l ~f:(fun (k, v) -> both v) in
      List.concat [
        kv vcfs;
        kv fastqcs;
        both normal_bam;
        both tumor_bam;
        opt rna_bam;
        both normal_bam_flagstat;
        both tumor_bam_flagstat;
        opt rna_bam_flagstat;
        opt optitype_normal;
        opt optitype_tumor;
        opt optitype_rna;
        opt vaxrank;
        opt seq2hla;
        opt stringtie;
        opt topiary;
        kv (Option.value ~default:[] kallisto);
      ] in
    let observables =
      report :: begin match emails with
      | None -> []
      | Some e -> List.map ~f:Bfx.to_unit e
      end
      @ results in
    Bfx.observe (fun () -> Bfx.list observables |> Bfx.to_unit)
end
