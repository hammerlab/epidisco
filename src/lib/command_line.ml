open Nonstd
module String = Sosa.Native_string
let (//) = Filename.concat


module Options = struct
  type t = {
    dry_run: bool; [@docs "CLIENT"]
    (** Dry-run; does not submit the pipeline to a Ketrew server. *)
    output_dot_to_png: string option; [@docv "PATH"] [@docs "CLIENT"]
    (** Output the pipeline as a PNG file. *)
  } [@@deriving cmdliner,make]

  let default = make ~dry_run:false ()

  let cmdf fmt =
  ksprintf (fun s ->
      match Sys.command s with
      | 0 -> ()
      | n -> ksprintf failwith "CMD failed: %s → %d" s n) fmt

  let output_dot sm ~dot ~png =
    try
      let out = open_out dot in
      SmartPrint.to_out_channel  80 2 out sm;
      close_out out;
      let dotlog = png ^ ".log" in
      cmdf "dot -v -x -Tpng  %s -o %s > %s 2>&1" dot png dotlog;
    with e ->
      eprintf "ERROR outputing DOT: %s\n%!" (Printexc.to_string e)
end


let run_pipeline
    ~biokepi_machine
    ?work_directory
    client_options
    params =
  let run_name = Parameters.construct_run_name params in
  let module Optimizer(B : Extended_edsl.Semantics) =
    (** Extra-safe, two passes of applying functions so that PNGs and
        JSONs look nice (optimization is a no-op in the [To_workflow]
        case). *)
    Extended_edsl.Apply_functions(Extended_edsl.Apply_functions(B)) in
  let dot_content =
    let module P2dot =
      Pipeline.Full(Optimizer(Extended_edsl.To_dot)) in
    let dot_parameters = {
      Biokepi.EDSL.Compile.To_dot.
      color_input = begin fun ~name ~attributes ->
        let contains pat s =
          let re = Re_posix.re pat |> Re.compile in
          Re.execp re s in
        List.find_map attributes ~f:(function
          (* http://www.graphviz.org/doc/info/colors.html *)
          | ("sample_name", s | "path", s) when contains "rna" s -> Some "darkorange"
          | ("sample_name", s | "path", s) when contains "tumor" s -> Some "crimson"
          | ("sample_name", s | "path", s) when contains "normal" s -> Some "darkgreen"
          | ("sample_name", _ | "path", _) -> Some "blue"
          | _ -> None)
      end;
    } in
    let dot = P2dot.run params dot_parameters in
    begin match client_options.Options.output_dot_to_png with
    | None -> ()
    | Some png ->
      printf "Outputing DOT to PNG: %s\n%!" png;
      Options.output_dot dot ~dot:(Filename.chop_extension png ^ ".dot") ~png
    end;
    SmartPrint.to_string 2 72 dot
  in
  let work_directory =
    match work_directory with
    | None  ->
      Biokepi.Machine.work_dir biokepi_machine //
      Parameters.construct_run_directory params
    | Some w -> w
  in
  let module Workflow_compiler =
    Extended_edsl.To_workflow
      (struct
        include Biokepi.EDSL.Compile.To_workflow.Defaults
        let machine = biokepi_machine
        let work_dir = work_directory
        let run_name = run_name
        let dot_content = dot_content
        let results_dir =
          Some (params.Parameters.results_path // run_name)
      end)
  in
  let module Ketrew_pipeline_1 =
    Pipeline.Full(Optimizer(Workflow_compiler)) in
  let workflow_1 =
    Ketrew_pipeline_1.run params
    |> Biokepi.EDSL.Compile.To_workflow.get_workflow
      ~name:(sprintf "Epidisco: %s %s"
               params.Parameters.experiment_name run_name)
  in
  begin match client_options.Options.dry_run with
  | true ->
    printf "Dry-run, not submitting %s (%s)\n%!"
      (Ketrew.EDSL.node_name workflow_1)
      (Ketrew.EDSL.node_id workflow_1);
    printf "%s\n" (Parameters.show params);
  | false ->
    printf "Submitting to Ketrew...\n%!";
    Ketrew.Client.submit_workflow workflow_1
      ~add_tags:[params.Parameters.experiment_name; run_name;
                 "From-" ^ Ketrew.EDSL.node_id workflow_1]
  end


let pipeline_term ~biokepi_machine ~version ?work_directory cmd =
  let open Cmdliner in
  let man =
    [ `S "SAMPLES";
      `P "The sample data (tumor DNA, normal DNA, and, optionally, tumor RNA) \
          to be passed into the pipeline.";
      `P "Use a comma (,) as a delimiter to provide multiple data files \
          and an ampersand (@) when describing paired-end FASTQ files.";
      `P "Examples"; `Noblank;
      `P "- JSON file: file://path/to/sample.json"; `Noblank;
      `P "- BAM file: https://url.to/my.bam"; `Noblank;
      `P "- Single-end FASTQ: /path/to/single.fastq.gz,.."; `Noblank;
      `P "- Paired-end FASTQ: /p/t/pair1.fastq@/p/t/pair2.fastq,..";
      `P "Each comma-separated BAM or FASTQ (paired or single-ended) will be \
          treated as an individual sample before being merged into the single \
          tumor/normal/RNA sample the rest of the pipeline deals with.";
      `S "OPTIONS";
      `S "OTHER TOOLS";
      `S "MAILGUN NOTIFICATIONS";
      `S "ENVIRONMENT";
      `S "AUTHORS";
      `P "Sebastien Mondet <seb@mondet.org>"; `Noblank;
      `P "Isaac Hodes <isaachodes@gmail.com>"; `Noblank;
      `S "BUGS";
      `P "Browse and report new issues at"; `Noblank;
      `P "<https://github.com/hammerlab/epidisco>."; ] in
  let info = Term.(info cmd ~man ~doc:"The Epidisco Pipeline") in
  let term = Term.(pure (run_pipeline ~biokepi_machine ?work_directory)
                   $ Options.cmdliner_term ()
                   $ Parameters.cmdliner_term ()) in
  (term, info)


let main ~biokepi_machine ?work_directory () =
  let version = Metadata.version |> Lazy.force in
  let pipe = pipeline_term ~biokepi_machine ?work_directory ~version Sys.argv.(0) in
  match Cmdliner.Term.eval pipe with
  | `Ok f -> f
  | `Error _ -> exit 1
  | `Version | `Help -> exit 0
