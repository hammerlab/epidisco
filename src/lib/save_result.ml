
open Nonstd
module String = Sosa.Native_string
let (//) = Filename.concat
module Name_file = Biokepi_run_environment.Common.Name_file

module type Semantics = sig

  type 'a any
  val save :
    string ->
    'a any ->
    'a any
end

module Do_nothing = struct
  let save _ x = x
end

let construct_relative_path ~work_dir original_path =
  let prefix_length = String.length work_dir in
  match String.sub original_path ~index:0 ~length:prefix_length with
  | Some p when work_dir = p ->
    "./" ^
    String.sub_exn
      original_path ~index:prefix_length
      ~length:(String.length original_path - prefix_length)
  | Some _ | None ->
    ksprintf failwith "ERROR: %s is not a prefix of %s"
      work_dir original_path

let json_dump_path path = Name_file.from_path ".json" path []

let make_saving_node
    ~saving_path ~json_pipeline ~key ~run_with ~work_dir ~name
    ?(gzip = false) ?(is_directory = false)
    edge path =
  let open Ketrew.EDSL in
  let copied_path = saving_path // construct_relative_path ~work_dir path in
  let json : Yojson.Basic.json =
    `Assoc [
      "file", `String copied_path;
      "key", `String key;
      "name", `String name;
      "pipeline", json_pipeline;
    ] in
  let make =
    Biokepi.Machine.run_stream_processor
      run_with
      Program.(
        let optional cond l =
          chain (if cond then l else []) in
        chain [
          shf "mkdir -p %s" (Filename.dirname copied_path);
          shf "cp -r %s %s"
            (Filename.quote path)
            (Filename.quote copied_path);
          optional gzip [
            shf "gzip --force --keep %s" (Filename.quote copied_path);
          ];
          shf "echo %s > %s"
            (Yojson.Basic.pretty_to_string json |> Filename.quote)
            (Filename.quote (json_dump_path copied_path));
        ]
      )
  in
  let name =
    sprintf "Saved: %s" name in
  let product =
    single_file ~host:(Biokepi.Machine.as_host run_with) copied_path in
  let ensures =
    `Is_verified Condition.(
        volume_exists Volume.(
            let opt_file cond p = if cond then [file p] else [] in
            create ~host:(Biokepi.Machine.as_host run_with)
              ~root:(Filename.dirname copied_path)
              (dir "." (
                  begin match is_directory with
                  | false -> file (Filename.basename copied_path)
                  | true -> dir (Filename.basename copied_path) []
                  end
                  ::
                  file (Filename.basename (json_dump_path copied_path))
                  :: opt_file gzip (Filename.basename copied_path ^ ".gz")
                  @ []
                )
              )
          )
      )
  in
  workflow_node product
    ~ensures
    ~edges:([edge])
    ~make ~name

module type Compilation_memory = sig
  val look_up_json: string -> Yojson.Basic.json
  val add_json: string -> Yojson.Basic.json -> unit

  type to_save =
    < path: string;
      is_directory : bool;
      gzip : bool;
      name: string;
      edge: Ketrew.EDSL.workflow_edge >

  val add_to_save: string -> to_save list -> unit

  val all_to_save: unit ->
    (string * to_save list) list


  val save_dot_content: string -> unit
  val get_dot_content: unit -> string
end
module Mem () : Compilation_memory = struct
  let json_metadata = ref []
  let add_json m x =
    match List.find !json_metadata (fun (k, _) -> k = m) with
    | Some (_, s) ->
      if (s <> x)
      then eprintf "WARNING: Duplicate metadata-key: %S\n" m
      else ()
    | None ->
      printf "Saving %S\n%!" m;
      json_metadata := (m, x) :: !json_metadata
  let display () =
    List.iter !json_metadata ~f:(fun (m, x) ->
        printf "%s:\n%s\n%!" m (Yojson.Basic.pretty_to_string x)
      );
    ()

  let look_up_json s =
    List.find_map !json_metadata ~f:(fun (x, j) ->
        if x = s then Some j else None)
    |> Option.value_exn ~msg:(sprintf "Can't find metadata: %S" s)

  let dot_content : string option ref = ref None
  let save_dot_content s = dot_content := Some s
  let get_dot_content () =
    Option.value_exn !dot_content ~msg:"dot_content is None!"

  type to_save =
    < path: string;
      is_directory : bool;
      gzip : bool;
      name: string;
      edge: Ketrew.EDSL.workflow_edge >
  let to_save = ref []
  let add_to_save key things =
    to_save := (key, things) :: !to_save
  let all_to_save () = !to_save
end

module To_workflow
    (Config : sig
       include Biokepi.EDSL.Compile.To_workflow.Compiler_configuration
       val saving_path : string
     end)
    (Mem : Compilation_memory)
= struct

  open Biokepi.EDSL.Compile.To_workflow.File_type_specification

  let save : string -> t -> t = fun key x ->
    let saved ?(gzip = false) ?(is_directory = false) ?name path wf =
      object
        method path = path
        method edge = Ketrew.EDSL.depends_on wf
        method is_directory = is_directory
        method gzip = gzip
        method name = match name with Some n -> n | None -> key
      end in
    begin match x with
    | Bam wf ->
      let bai =
        Biokepi.Tools.Samtools.index_to_bai
          ~run_with:Config.machine
          ~check_sorted:false wf
      in
      Mem.add_to_save key [
        saved wf#product#path wf;
        saved ~name:(key ^ "-index") bai#product#path bai;
      ];
    | Vcf wf ->
      Mem.add_to_save key [
        saved ~gzip:true wf#product#path wf;
      ]
    | Topiary_result wf ->
      Mem.add_to_save key [
        saved wf#product#path wf;
      ]
    | Fastqc_result wf ->
      let path = (wf#product#paths |> List.hd_exn |> Filename.dirname) in
      Mem.add_to_save key [
        saved ~is_directory:true path wf;
      ]
    | Isovar_result wf ->
      Mem.add_to_save key [
        saved wf#product#path wf;
      ]
    | Flagstat_result wf ->
      Mem.add_to_save key [
        saved wf#product#path wf;
      ]
    | Gtf wf ->
      Mem.add_to_save key [
        saved wf#product#path wf;
      ]
    | Optitype_result wf ->
      Mem.add_to_save key [
        saved ~is_directory:true wf#product#path wf;
      ]
    | Vaxrank_result wf ->
      Mem.add_to_save key [
        saved ~is_directory:true wf#product#output_folder_path wf;
      ]
    | Seq2hla_result wf ->
      Mem.add_to_save key [
        saved ~is_directory:true wf#product#work_dir_path wf;
      ]
    | Kallisto_result wf ->
      Mem.add_to_save key [
        saved ~is_directory:true wf#product#path wf;
      ]
    | other ->
      ksprintf failwith
        "To_workflow.register non-{Bam or Vcf}: not implemented: %s"
        (to_string other)
    end;
    x

end

