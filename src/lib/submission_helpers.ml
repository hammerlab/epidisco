open Nonstd
module String = Sosa.Native_string


let generate_input_from_directory ~host_name ~run_name ~kind directory =
  let ks = match kind with
  | `Rna -> "rna"
  | `Normal -> "normal"
  | `Tumor -> "tumor"
  in
  let host = match Ketrew_pure.Host.of_string host_name with
  | `Ok host -> host
  | `Error msg -> failwith (sprintf "Error parsing host \"%s\".\n%!" host_name)
  in
  let open Pvem_lwt_unix.Deferred_result in
  Input.Derive.fastqs ~host:host directory
  >>= fun fqs ->
  let sample_name = sprintf "%s-%s" run_name ks in
  let fs = Input.fastq_sample ~sample_name fqs in
  return fs


let get ~host_name ~run_name kind dir =
  let res =
    generate_input_from_directory ~host_name ~run_name ~kind dir in
  match Lwt_main.run res with
  | `Ok res -> res
  | `Error err ->
    begin match err with
    | `Host hosterr ->
      failwith ("Host could not be used: " ^
                (Ketrew.Host_io.Error.log hosterr
                 |> Ketrew_pure.Internal_pervasives.Log.to_long_string))
    | `Multiple_flowcells flowcells ->
      failwith (sprintf "Too many flowcells detected (can't handle multiple)\
                         : '%s'\n%!"
                  (String.concat ~sep:"," flowcells))
    | `Re_group_error msg -> failwith msg
    | `R2_expected_for_r1 r1 ->
      failwith (sprintf "Didn't find an r2 for r1 %s" r1)
    end
