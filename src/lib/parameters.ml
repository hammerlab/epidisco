open Nonstd
module String = Sosa.Native_string


type t = {
  (* SAMPLES *)
  normal_inputs: string list; [@docs "SAMPLES"]
  (** Normal sample(s) for the pipeline. *)
  tumor_inputs: string list; [@docs "SAMPLES"]
  (** Tumor sample(s) for the pipeline. *)
  rna_inputs: string list option; [@docs "SAMPLES"]
  (** RNA sample(s) for the pipeline. *)

  (* OPTIONS *)
  reference_build: string;
  (** The reference build *)
  results_path: string;
  (** Where to save the results. *)
  picard_java_max_heap: string option;
  (** Max Java heap size used for Picard tools e.g. 8g, 256m. *)
  igv_url_server_prefix: string option [@env "IGV_URL_SERVER_PREFIX"];
  (** URL with which to prefix igvxml paths. *)
  realign_bams: bool [@default true]
      [@name "without-realigning-bams"];
  (** Don't realign input BAMs. *)
  use_bwa_mem_opt: bool [@default true]
      [@name "without-bwa-mem-optimized"];
  (** Don't use the optimized workflow-node for bwa-mem \
      (i.e. bam2fq + align + sort + to-bam). *)
  experiment_name: string [@main] [@aka ["E"]];
  (** Give a name to the run(s). *)
  mhc_alleles: string list option; [@docv "ALLELE1,ALLELE2,..."]
  (** Run epitope binding prediction pipeline with the given list \
      of MHC alleles in lieu of those generated by Seq2Hla or \
      OptiType. *)
  without_cosmic: bool; [@default false]
  (** Don't pass cosmic to Mutect (no COSMIC). *)
  vaxrank_include_mismatches_after_variant: bool; [@default false]
  (** Vaxrank option: Ignore mismatches after variant. *)
  bedfile: string option; [@aka ["filter-vcfs-to-region-with"]]
  (** Run bedtools intersect on VCFs with the given bed file. file://... or
      http(s)://... *)

  (* NOTIFICATIONS: *)
  email_options: Qc.EDSL.email_options option [@term Qc.EDSL.cmdliner_term];
  (** Email options for notifications. *)

  (* OTHER TOOLS *)
  with_kallisto: bool [@docs "OTHER TOOLS"] [@default false];
  (** Also run with `kallisto`. *)
  with_topiary: bool [@docs "OTHER TOOLS"] [@default false];
  (** Also run with `topiary`. *)
  with_seq2hla: bool [@docs "OTHER TOOLS"] [@default false];
  (** Also run with `seq2hla`. *)
  with_mutect2: bool [@docs "OTHER TOOLS"] [@default false];
  (** Also run with `mutect2`. *)
  with_varscan: bool [@docs "OTHER TOOLS"] [@default false];
  (** Also run with `varscan`. *)
  with_somaticsniper: bool [@docs "OTHER TOOLS"] [@default false];
  (** Also run with `somaticsniper`. *)
  with_optitype_normal: bool [@docs "OTHER TOOLS"] [@default false];
  (** Also run with `optitype-normal`. *)
  with_optitype_tumor: bool [@docs "OTHER TOOLS"] [@default false];
  (** Also run with `optitype-tumor`. *)
  with_optitype_rna: bool [@docs "OTHER TOOLS"] [@default false];
  (** Also run with `optitype-rna`. *)
  with_bqsr: bool [@default true] [@docs "OTHER TOOLS"]
      [@name "without-bqsr"];
  (** Run without `BQSR`. *)
  with_indel_realigner: bool [@default true] [@docs "OTHER TOOLS"]
      [@name "without-indel-realigner"];
  (** Run without `indel-realigner`. *)
  with_mark_dups: bool [@default true] [@docs "OTHER TOOLS"]
      [@name "without-mark-dups"];
  (** Run without `mark-dups`. *)
} [@@deriving cmdliner,show,make]


let or_fail msg = function
| `Ok o -> o
| `Error s -> ksprintf failwith "%s: %s" msg s

let biokepi_input_of_string ~realign_bams ~prefix ~reference_build s =
  let open Biokepi.EDSL.Library.Input in
  let file_type =
    let check = Filename.check_suffix s in
    if (check ".bam" && (not realign_bams))       then `Bam_no_realign
    else if check ".bam"                          then `Bam
    else if (check ".fastq" || check ".fastq.gz") then `Fastq
    else                                               `Json
  in
  (* Beside serialized sample description files, we also would like to
     capture direct paths to the BAMs/FASTQs to make it easier for the user
     to submit samples. Each comma-separated BAM or FASTQ (paired or
     single-ended) will be treated as an individual sample before being
     merged into the single tumor/normal the rest of the pipeline deals
     with.

     Examples
     - JSON file: /path/to/sample.json
     - BAM file: https://url.to/my.bam
     - Single-end FASTQ: /path/to/single.fastq.gz,..
     - Paired-end FASTQ: /p/t/pair1.fastq@/p/t/pair2.fastq,..
     ...
  *)
  match file_type with
  | `Bam_no_realign -> begin
      let sample_name =
        prefix ^ "-" ^ Filename.(chop_extension s |> basename)
      in
      bam_sample ~sample_name ~how:`PE ~reference_build s
    end
  | `Bam -> begin
      let sample_name =
        prefix ^ "-" ^ Filename.(chop_extension s |> basename)
      in
      fastq_sample ~sample_name [fastq_of_bam ~reference_build `PE s]
    end
  | `Fastq ->  begin
      match (String.split ~on:(`Character '@') s) with
      | [ pair1; pair2; ] ->
        let sample_name =
          let chop f = Filename.(chop_extension f |> basename) in
          sprintf "%s-%s-%s" prefix (chop pair1) (chop pair2)
        in
        fastq_sample ~sample_name [pe pair1 pair2]
      | [ single_end; ] ->
        let sample_name =
          sprintf "%s-%s" prefix Filename.(chop_extension s |> basename)
        in
        fastq_sample ~sample_name [se single_end]
      | _ -> failwith "Couldn't parse FASTQ path."
    end
  | `Json ->
    Yojson.Safe.from_file s |> of_yojson |> or_fail (prefix ^ "-json")


let biokepi_inputs_of_strings ~kind ~realign_bams ~reference_build ss =
  let of_string = biokepi_input_of_string ~reference_build ~realign_bams in
  List.mapi ss ~f:(fun i f ->
      let prefix = kind ^ (Int.to_string i) in
      of_string ~prefix f)


let biokepi_input_to_string t =
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
  | Bam {bam_sample_name; _ } -> sprintf "Bam %s" bam_sample_name
  | Fastq { fastq_sample_name; files } ->
    sprintf "%s, %s"
      fastq_sample_name
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


let normal_inputs t =
  biokepi_inputs_of_strings ~kind:"normal" ~realign_bams:t.realign_bams
    ~reference_build:t.reference_build t.normal_inputs


let tumor_inputs t =
  biokepi_inputs_of_strings ~kind:"tumor" ~realign_bams:t.realign_bams
    ~reference_build:t.reference_build t.tumor_inputs


let rna_inputs t =
  let open Option in
  t.rna_inputs >>= fun inputs ->
  return (biokepi_inputs_of_strings ~kind:"normal" ~realign_bams:t.realign_bams
            ~reference_build:t.reference_build inputs)


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

(* To maximize sharing the run-directory depends only on the experiment name
   (to allow the use to force a fresh one) and the reference-build (since
   Biokepi does not track it yet in the filenames). *)
let construct_run_directory param =
  sprintf "%s-%s" param.experiment_name param.reference_build

let metadata t = [
  "MHC Alleles",
  begin match t.mhc_alleles  with
  | None  -> "None provided"
  | Some l -> sprintf "Alleles: [%s]" (String.concat l ~sep:"; ")
  end;
  "Reference-build", t.reference_build;
  "Normal-inputs",
  List.map ~f:biokepi_input_to_string (normal_inputs t) |> String.concat;
  "Tumor-inputs",
  List.map ~f:biokepi_input_to_string (tumor_inputs t) |> String.concat;
  "RNA-inputs",
  Option.value_map
    ~default:"none"
    ~f:(fun r -> List.map ~f:biokepi_input_to_string r |> String.concat)
    (rna_inputs t);
]

