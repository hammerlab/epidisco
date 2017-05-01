open Nonstd
module String = Sosa.Native_string

include Biokepi.EDSL.Library.Input


let or_fail msg = function
| `Ok o -> o
| `Error s -> ksprintf failwith "%s: %s" msg s


let of_string ~realign_bams ~prefix ~reference_build s =
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

let of_strings ~kind ~realign_bams ~reference_build ss =
  let of_string = of_string ~reference_build ~realign_bams in
  List.mapi ss ~f:(fun i f ->
      let prefix = kind ^ (Int.to_string i) in
      of_string ~prefix f)

let to_string t =
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

let conv ~kind =
  (* the reference & realigning are set here to defaults, since they aren't
     known at the time of this conversion. They are reset to the parameterized
     value when the pipeline "gets" them with normal_inputs, tumor_inputs,
     rna_inputs. *)
  let reference_build = "none" in
  let realign_bams = false in
  ((fun s ->
      try Result.Ok (of_strings ~kind ~realign_bams ~reference_build
                       (String.split ~on:(`Character ',') s))
      with _ -> Result.Error (`Msg (sprintf "Error parsing Input.t for %s" kind))),
   (fun fmt t -> Format.fprintf fmt "%s"
       (String.concat (List.map t ~f:to_string))))
