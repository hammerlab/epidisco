open Nonstd
module String = Sosa.Native_string
let (//) = Filename.concat
let or_fail msg = function
| `Ok o -> o
| `Error s -> ksprintf failwith "%s: %s" msg s


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


let run_pipeline
    ?(dry_run = false)
    ?(output_dot_to_png : string option)
    ~biokepi_machine
    ~results_path
    ?work_directory
    params =
  let run_name = Pipeline.Parameters.construct_run_name params in
  let module Mem = Save_result.Mem () in
  let module P2json = Pipeline.Full(Extended_edsl.To_json_with_mem(Mem)) in
  let (_ : Yojson.Basic.json) = P2json.run params in
  let dot_content =
    let module P2dot =
      Pipeline.Full(Extended_edsl.Apply_functions(Extended_edsl.To_dot)) in
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
    begin match output_dot_to_png with
    | None -> ()
    | Some png ->
      printf "Outputing DOT to PNG: %s\n%!" png;
      output_dot dot ~dot:(Filename.chop_extension png ^ ".dot") ~png
    end;
    SmartPrint.to_string 2 72 dot
  in
  let work_directory =
    match work_directory with
    | None  ->
      Biokepi.Machine.work_dir biokepi_machine //
      Pipeline.Parameters.construct_run_directory params
    | Some w -> w
  in
  Mem.save_dot_content dot_content;
  let module Workflow_compiler =
    Extended_edsl.To_workflow
      (struct
        include Biokepi.EDSL.Compile.To_workflow.Defaults
        let machine = biokepi_machine
        let work_dir = work_directory
        let run_name = run_name
        let saving_path = results_path // run_name
      end)
      (Mem)
  in
  let module Ketrew_pipeline_1 = Pipeline.Full(Workflow_compiler) in
  let workflow_1 =
    Ketrew_pipeline_1.run params
    |> Qc.EDSL.Extended_file_spec.get_unit_workflow
      ~name:(sprintf "Epidisco: %s %s"
               params.Pipeline.Parameters.experiment_name run_name)
  in
  begin match dry_run with
  | true ->
    printf "Dry-run, not submitting %s (%s)\n%!"
      (Ketrew.EDSL.node_name workflow_1)
      (Ketrew.EDSL.node_id workflow_1);
  | false ->
    printf "Submitting to Ketrew...\n%!";
    Ketrew.Client.submit_workflow workflow_1
      ~add_tags:[params.Pipeline.Parameters.experiment_name; run_name;
                 "From-" ^ Ketrew.EDSL.node_id workflow_1]
  end


let pipeline ~biokepi_machine ?work_directory =
  let parse_input_file file ~kind =
    match Filename.check_suffix file ".bam" with
    | true ->
      Biokepi.EDSL.Library.Input.(
        fastq_sample
          ~sample_name:(kind ^ "-" ^
                        (Filename.chop_extension file |> Filename.basename))
          [of_bam ~reference_build:"dontcare" `PE file]
      )
    | false ->
      Yojson.Safe.from_file file
      |> Biokepi.EDSL.Library.Input.of_yojson |> or_fail (kind ^ "-json") in
  fun
    (`Dry_run dry_run)
    (`Mouse_run mouse_run)
    (`With_seq2hla with_seq2hla)
    (`With_optitype_normal with_optitype_normal)
    (`With_optitype_tumor with_optitype_tumor)
    (`With_optitype_rna with_optitype_rna)
    (`With_mutect2 with_mutect2)
    (`With_varscan with_varscan)
    (`With_somaticsniper with_somaticsniper)
    (`Bedfile bedfile)
    (`Normal_json normal_json_file)
    (`Tumor_json tumor_json_file)
    (`Rna_json rna_json_file)
    (`Ref reference_build)
    (`Results results_path)
    (`Output_dot output_dot_to_png)
    (`Mhc_alleles mhc_alleles)
    (`Picard_java_max_heap picard_java_max_heap)
    (`Experiment_name experiment_name)
    (`Mailgun_api_key mailgun_api_key)
    (`Mailgun_domain mailgun_domain_name)
    (`From_email from_email)
    (`To_email to_email)
    (`Igv_url_server_prefix igv_url_server_prefix)
    ->
      let normal = parse_input_file normal_json_file ~kind:"normal" in
      let tumor = parse_input_file tumor_json_file ~kind:"tumor" in
      let rna =
        match rna_json_file with
        | "" ->
          eprintf "WARNING: No RNA provided\n%!";
          None
        | file ->
          Some (parse_input_file file ~kind:"rna")
      in
      let email_options =
        match
          to_email, from_email, mailgun_domain_name, mailgun_api_key with
        | Some to_email, Some from_email,
          Some mailgun_domain_name, Some mailgun_api_key ->
          Some (Qc.EDSL.make_email_options
                  ~from_email ~to_email
                  ~mailgun_api_key ~mailgun_domain_name)
        | None, None, None, None -> None
        | _, _, _, _ ->
          failwith "ERROR: If one of `to-email`, `from-email`, \
                    `mailgun-api-key`, `mailgun-domain-name` \
                    are specified, then they all must be."
      in
      let params =
        Pipeline.Parameters.make experiment_name
          ~normal ~tumor ?rna
          ~bedfile
          ~mouse_run
          ~reference_build
          ?mhc_alleles
          ?email_options
          ~with_seq2hla
          ~with_optitype_normal
          ~with_optitype_tumor
          ~with_optitype_rna
          ~with_mutect2
          ~with_varscan
          ~with_somaticsniper
          ?picard_java_max_heap
          ?igv_url_server_prefix
      in
      run_pipeline ~biokepi_machine ~results_path ?work_directory
        ~dry_run params
        ?output_dot_to_png


let args pipeline =
  let open Cmdliner in
  let open Cmdliner.Term in
  let json_file_arg ?(req = true) option_name f =
    let doc = sprintf "JSON file describing the %S sample" option_name in
    let inf = Arg.info [option_name] ~doc ~docv:"PATH" in
    pure f
    $
    Arg.(
      (if req
       then required & opt (some string) None & inf
       else value & opt string "" & inf))
  in
  let tool_option f name =
    pure f
    $ Arg.(
        value & flag & info [sprintf "with-%s" name]
          ~doc:(sprintf "Also run `%s`" name)
      ) in
  let bed_file_opt =
    pure (fun e -> `Bedfile e)
    $ Arg.(
        let doc =
          "Run bedtools intersect on VCFs with the given bed file. \
           file://... or http(s)://..." in
        value
        & opt (some string) None
        & info ["filter-vcfs-to-region-with"] ~doc) in
  app pipeline begin
    pure (fun b -> `Dry_run b)
    $ Arg.(value & flag & info ["dry-run"] ~doc:"Dry-run; do not submit")
  end
  $ begin
    pure (fun b -> `Mouse_run b)
    $ Arg.(
        value & flag & info ["mouse-run"]
          ~doc:"Mouse-run; use mouse-specific config (no COSMIC)"
      )
  end
  $ tool_option (fun e -> `With_seq2hla e) "seq2hla"
  $ tool_option (fun e -> `With_optitype_normal e) "optitype-normal"
  $ tool_option (fun e -> `With_optitype_tumor e) "optitype-tumor"
  $ tool_option (fun e -> `With_optitype_rna e) "optitype-rna"
  $ tool_option (fun e -> `With_mutect2 e) "mutect2"
  $ tool_option (fun e -> `With_varscan e) "varscan"
  $ tool_option (fun e -> `With_somaticsniper e) "somaticsniper"
  $ bed_file_opt
  $ json_file_arg "normal" (fun s -> `Normal_json s)
  $ json_file_arg "tumor" (fun s -> `Tumor_json s)
  $ json_file_arg ~req:false "rna" (fun s -> `Rna_json s)
  $ begin
    pure (fun s -> `Ref s)
    $ Arg.(
        required & opt (some string) None
        & info ["reference-build"; "R"]
          ~doc:"The reference-build" ~docv:"NAME")
  end
  $ begin
    pure (fun s -> `Results s)
    $ Arg.(
        required & opt (some string) None
        & info ["results-path"]
          ~doc:"Where to save the results" ~docv:"NAME")
  end
  $ begin
    pure (fun s -> `Output_dot s)
    $ Arg.(
        value & opt (some string) None
        & info ["dot-png"]
          ~doc:"Output the pipeline as a PNG file" ~docv:"PATH")
  end
  $ begin
    pure (fun s -> `Mhc_alleles s)
    $ Arg.(
        value & opt (list ~sep:',' string |> some) None
        & info ["mhc-alleles"]
          ~doc:"Run pipeline with the given list of MHC alleles \
                in lieu of those generated by Seq2Hla or OptiType: $(docv)"
          ~docv:"LIST")
  end
  $ begin
    pure (fun s -> `Picard_java_max_heap s)
    $ Arg.(
        value & opt (some string) None
        & info ["picard-java-max-heap-size"]
          ~doc:"Max Java heap size used for Picard Mark Dups \
                e.g. 8g, 256m.")
  end
  $ begin
    pure (fun s -> `Experiment_name s)
    $ Arg.(
        required & opt (some string) None
        & info ["experiment-name"; "E"]
          ~doc:"Give a name to the run(s)" ~docv:"NAME")
  end
  $ begin
    pure (fun s -> `Mailgun_api_key s)
    $ Arg.(
        value & opt (some string) None
        & info ["mailgun-api-key"]
          ~doc:"Mailgun API key, used for notification emails."
          ~docv:"MAILGUN_API_KEY")
  end
  $ begin
    pure (fun s -> `Mailgun_domain s)
    $ Arg.(
        value & opt (some string) None
        & info ["mailgun-domain"]
          ~doc:"Mailgun domain, used for notification emails."
          ~docv:"MAILGUN_DOMAIN")
  end
  $ begin
    pure (fun s -> `From_email s)
    $ Arg.(
        value & opt (some string) None
        & info ["from-email"]
          ~doc:"Email address used for notification emails."
          ~docv:"FROM_EMAIL")
  end
  $ begin
    pure (fun s -> `To_email s)
    $ Arg.(
        value & opt (some string) None
        & info ["to-email"]
          ~doc:"Email address to send notification emails to."
          ~docv:"TO_EMAIL")
  end
  $ begin
    pure (fun s -> `Igv_url_server_prefix s)
    $ Arg.(
        value & opt (some string) None
        & info ["igv-url-server-prefix"]
          ~doc:"URL with which to prefix IGV.xml paths."
          ~docv:"IGV_URL_SERVER_PREFIX")
  end


let pipeline_term ~biokepi_machine ?work_directory () =
  let open Cmdliner in
  let info = Term.(info "pipeline" ~doc:"The Epidisco Pipeline") in
  let term = Term.(pure (pipeline ~biokepi_machine ?work_directory)) |> args in
  (term, info)


let main
    ~biokepi_machine ?work_directory () =
  let version = Metadata.version |> Lazy.force in
  let pipe = pipeline_term ~biokepi_machine ?work_directory () in
  let open Cmdliner in
  let default_cmd =
    let doc = "Run the Epidisco pipeline." in
    let man = [
      `S "AUTHORS";
      `P "Sebastien Mondet <seb@mondet.org>"; `Noblank;
      `P "Isaac Hodes <isaachodes@gmail.com>"; `Noblank;
      `S "BUGS";
      `P "Browse and report new issues at"; `Noblank;
      `P "<https://github.com/hammerlab/epidisco>.";
    ] in
    Term.(ret (pure (`Help (`Plain, None)))),
    Term.info Sys.argv.(0) ~version ~doc ~man in
  match Term.eval_choice default_cmd (pipe :: []) with
  | `Ok f -> f
  | `Error _ -> exit 1
  | `Version | `Help -> exit 0
