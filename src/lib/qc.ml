open Nonstd
module String = Sosa.Native_string

open Biokepi.KEDSL

let (//) = Filename.concat

let opt_cat o lst =
  match o with
  | None -> lst
  | Some x -> x :: lst


module Email = struct
  type content_type = [
    | `Text of string
    | `File of string
  ]

  let email_cmd ~api_key ~mailgun_domain ~to_email ~from_email ~subject content =
    let content_txt =
      match content with
      | `Text txt -> "'" ^ txt ^ "'"
      | `File file -> sprintf "$(cat '%s')" file
    in
    sprintf "EMAILTEXT=%s;\
             curl -s --user 'api:%s' \
             https://api.mailgun.net/v3/%s/messages \
             -F from='PGV <%s>' \
             -F to=%s \
             -F subject='%s' \
             -F text=\"$EMAILTEXT\""
      content_txt api_key mailgun_domain from_email to_email subject

  let send
      ?edges ~machine ~to_email ~from_email
      ~mailgun_api_key ~mailgun_domain_name ~subject ~content
    =
    let name = "Send Email: " ^ subject in
    let cmd =
      email_cmd
        mailgun_api_key mailgun_domain_name to_email from_email subject content
    in
    let make = Biokepi.Machine.quick_run_program machine (Program.(sh cmd)) in
    workflow_node ?edges ~name ~make nothing

  let on_success_send
      ?edges ~machine ~to_email ~from_email ~mailgun_api_key
      ~mailgun_domain_name ~subject node
    =
    let content = `File node#product#path in
    let email =
      send
        ?edges ~machine ~to_email ~from_email ~mailgun_api_key
        ~mailgun_domain_name ~subject ~content
    in
    let edges =
      [ depends_on node;
        on_success_activate email ]
    in
    let name = "Wrapped on_success email: " ^ node#render#name in
    workflow_node ~edges ~name nothing
end

let summarize_flagstats ~machine nodes summary summary_file =
  let cmd = sprintf "echo '%s' > %s" summary summary_file in
  let name = "Summarize Flagstats results" in
  let make =
    Biokepi.Machine.quick_run_program machine Program.(sh cmd)
  in
  let host = Biokepi.Machine.(as_host machine) in
  workflow_node (single_file summary_file ~host)
    ~name
    ~edges:(List.map ~f:(fun (n) -> depends_on n) nodes)
    ~make


module EDSL = struct

  type email_options =
    { from_email: string;
      to_email: string;
      mailgun_api_key: string;
      mailgun_domain_name: string; }
      [@@deriving show,make]

  module type Semantics = sig
    type 'a repr
    val flagstat_email :
      normal:([ `Flagstat ] repr) ->
      tumor:([ `Flagstat ] repr) ->
      ?rna:([ `Flagstat ] repr) ->
      email_options ->
      [ `Email ] repr
  end

  module Extended_file_spec = struct
    include Biokepi.EDSL.Compile.To_workflow.File_type_specification
    open Biokepi.KEDSL
    type _ t +=
        Email: nothing workflow_node -> [ `Email ] t

    let rec as_dependency_edges : type a. a t -> workflow_edge list =
      let open Biokepi.EDSL.Compile.To_workflow.File_type_specification in
      let one_depends_on wf = [depends_on wf] in
      function
      | To_unit v -> as_dependency_edges v
      | Email wf -> one_depends_on wf
      | other ->
        as_dependency_edges other
  end

  module To_workflow
      (Config : sig
         include Biokepi.EDSL.Compile.To_workflow.Compiler_configuration
         val saving_path : string
         val run_name : string
       end) = struct

    open Extended_file_spec

    let flagstat_email ~normal ~tumor ?rna email_options =
      let open Config in
      let email =
        let get_flg =
          Biokepi.EDSL.Compile.To_workflow.File_type_specification.
            get_flagstat_result
        in
        let nf, tf, rf =
          get_flg normal,
          get_flg tumor,
          Option.map ~f:get_flg rna in
        let flgs = opt_cat rf [tf; nf] in
        let summary =
          sprintf  "Tumor @ %s\nNormal @ %s\n"
            tf#product#path nf#product#path
        in
        let summary_file =
          work_dir // "flagstats-summary.txt"
        in
        let wrapper = summarize_flagstats ~machine
            flgs summary summary_file in
        let subject = ("Flagstats for " ^ run_name) in
        Email.on_success_send ~machine ~subject
          ~to_email:email_options.to_email
          ~from_email:email_options.from_email
          ~mailgun_api_key:email_options.mailgun_api_key
          ~mailgun_domain_name:email_options.mailgun_domain_name
          wrapper
      in
      Email email
  end

  module To_dot = struct
    let flagstat_email ~normal ~tumor ?rna email_options =
      (fun ~var_count -> `String "flagstat email")
  end

  module To_json = struct
    let flagstat_email ~normal ~tumor ?rna email_options =
      fun ~var_count ->
        let opt n o =
          Option.value_map ~default:[] o ~f:(fun v -> [n, v ~var_count]) in
        let args = [
          "normal flagstat", normal ~var_count;
          "tumor flagstat", tumor ~var_count;
          "to email", `String email_options.to_email;
          "from email", `String email_options.from_email
        ]
          @ opt "rna flagstat" rna
        in
        let json : Yojson.Basic.json =
          `Assoc [
            "flagstat qc email",
            `Assoc args
          ]
        in
        json
  end

  module Apply_functions (B:Semantics) = struct
  end

end
