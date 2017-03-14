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
             -F from='%s' \
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

let summarize_flagstats ~machine flagstats summary_file =
  let cmds =
    List.concat_map flagstats ~f:(fun (name, f) ->
        [Program.shf
           "echo 'Flagstat %s @ %s' >> %s" name f#product#path summary_file;
         Program.shf "cat %s >> %s" f#product#path summary_file;
         Program.shf "echo >> %s" summary_file]) in
  let name = "Summarize Flagstats' results" in
  let make =
    Biokepi.Machine.quick_run_program machine (Program.chain cmds) in
  let host = Biokepi.Machine.(as_host machine) in
  workflow_node (single_file summary_file ~host) ~make ~name
    ~edges:(List.map ~f:(fun (_, n) -> depends_on n) flagstats)

let summarize_qc_script =
{bash|
#!/bin/bash

# Usage:
#  $ bash fastqc_to_email.sh REPORT_HEADER /path/to/file1.html /path/to/file2.html ...
#
# requires the unzipped folder containing the summaries to be present in the same folder
# with the HTML report!

JOB_NAME=$1
echo "# FASTQC ran for $JOB_NAME"
shift

# Convert html paths into their summary counter-parts
SUMMARY_FILES=$(echo "$@" |sed -e 's/\.html/\/summary.txt/g')

for qcsummary in $SUMMARY_FILES
do
  NUM_OF_PASSES=$(cat ${qcsummary} | grep PASS | wc -l | awk '{ print $1 }')
  NUM_OF_CHECKS=$(cat ${qcsummary} | wc -l | awk '{ print $1 }')

  echo "## File: $qcsummary"
  echo "## Result: $NUM_OF_PASSES/$NUM_OF_CHECKS passed"
  echo "## Issues: "
  cat ${qcsummary} | grep -v "PASS" | cut -f1,2 | sed -e 's/^/ - /g'
  echo -en "\n"
done
|bash}

let summarize_fastqcs ~machine ~fastqcs summary_file =
  let fqc_cmd name fqc =
    let paths = (String.concat ~sep:" " fqc#product#paths) in
    sprintf "bash ${SUMMARIZE} %s %s" name paths in
  let fastqc_cmds =
    List.map fastqcs ~f:(fun (name, f) ->
        let cmd = fqc_cmd name f in
        Program.shf "%s >> %s" cmd summary_file) in
  let cmd = [Program.sh "export SUMMARIZE=$(mktemp)";
             Program.shf "cat << 'EOF' > ${SUMMARIZE}
%s
EOF"
               summarize_qc_script] @ fastqc_cmds in
  let name = "Summarize FASTQC results" in
  let make =
    Biokepi.Machine.quick_run_program machine (Program.chain cmd)
  in
  let host = Biokepi.Machine.(as_host machine) in
  workflow_node (single_file summary_file ~host)
    ~name ~make
    ~edges:(List.map ~f:(fun (name, f) -> depends_on f) fastqcs)


module EDSL = struct

  type email_options =
    { from_email: string;
      to_email: string;
      mailgun_api_key: string;
      mailgun_domain_name: string; }
  [@@deriving show,make]

  let email_options_cmdliner_term =
    let open Cmdliner.Term in
    pure
      (fun
        (`Mailgun_api_key mailgun_api_key)
        (`Mailgun_domain_name mailgun_domain_name)
        (`Mailgun_from_email from_email)
        (`Mailgun_to_email to_email)
        ->
          match to_email, from_email, mailgun_domain_name, mailgun_api_key with
          | Some to_email, Some from_email,
            Some mailgun_domain_name, Some mailgun_api_key ->
            Some (make_email_options ~to_email ~from_email
                    ~mailgun_domain_name ~mailgun_api_key)
          | None, None, None, None -> None
          | _, _, _, _ ->
            failwith "ERROR: If one of `to-email`, `from-email`, \
                      `mailgun-api-key`, `mailgun-domain-name` \
                      are specified, then they all must be."
      )
    $ begin
      let var_name = "MAILGUN_API_KEY" in
      pure (fun s -> `Mailgun_api_key s)
      $ Cmdliner.Arg.(
          value & opt (some string) None
          & info ["mailgun-api-key"]
            ~doc:"Mailgun API key, used for notification emails."
            ~docv:var_name ~env:(env_var var_name)
            ~docs:"MAILGUN NOTIFICATIONS")
    end
    $ begin
      let var_name = "MAILGUN_DOMAIN" in
      pure (fun s -> `Mailgun_domain_name s)
      $ Cmdliner.Arg.(
          value & opt (some string) None
          & info ["mailgun-domain"]
            ~doc:"Mailgun domain, used for notification emails."
            ~docv:var_name ~env:(env_var var_name)
            ~docs:"MAILGUN NOTIFICATIONS")
    end
    $ begin
      let var_name = "FROM_EMAIL" in
      pure (fun s -> `Mailgun_from_email s)
      $ Cmdliner.Arg.(
          value & opt (some string) None
          & info ["from-email"]
            ~doc:"Email address used for notification emails."
            ~docv:var_name ~env:(env_var var_name)
            ~docs:"MAILGUN NOTIFICATIONS")
    end
    $ begin
      let var_name = "TO_EMAIL" in
      pure (fun s -> `Mailgun_to_email s)
      $ Cmdliner.Arg.(
          value & opt (some string) None
          & info ["to-email"]
            ~doc:"Email address to send notification emails to."
            ~docv:var_name ~env:(env_var var_name)
            ~docs:"MAILGUN NOTIFICATIONS")
    end


  module type Semantics = sig
    type 'a repr

    val flagstat_email :
      normal:([ `Flagstat ] repr) ->
      tumor:([ `Flagstat ] repr) ->
      ?rna:([ `Flagstat ] repr) ->
      email_options ->
      [ `Email ] repr

    val fastqc_email :
      fastqcs:(string * [ `Fastqc ] repr) list ->
      email_options ->
      [ `Email ] repr
  end

  module Extended_file_spec = struct

    include Biokepi.EDSL.Compile.To_workflow.File_type_specification
    open Biokepi.KEDSL

    type t +=
        Email: nothing workflow_node -> t

    let () =
      add_to_string (function
        | Email _ -> Some "QC-Email"
        | other -> None);
      add_to_dependencies_edges_function (function
        | Email wf -> Some [depends_on wf]
        | _ -> None);
      ()

  end

  module To_workflow
      (Config : sig
         include Biokepi.EDSL.Compile.To_workflow.Compiler_configuration
         val saving_path : string
         val run_name : string
       end) = struct

    open Extended_file_spec
    open Config

    let flagstat_email ~normal ~tumor ?rna email_options =
      let email =
        let get_flg =
          Biokepi.EDSL.Compile.To_workflow.File_type_specification.
            get_flagstat_result in
        let nf, tf, rf =
          get_flg normal,
          get_flg tumor,
          Option.map ~f:get_flg rna in
        let flagstats =
          [("normal", nf); ("tumor", tf)]
          @ Option.value_map rf ~default:[] ~f:(fun r -> ["RNA", r]) in
        let summary_file =
          work_dir // "flagstats-summary.txt" in
        let wrapper =
          summarize_flagstats ~machine flagstats summary_file in
        let subject = "Flagstats for " ^ run_name in
        Email.on_success_send ~machine ~subject
          ~to_email:email_options.to_email
          ~from_email:email_options.from_email
          ~mailgun_api_key:email_options.mailgun_api_key
          ~mailgun_domain_name:email_options.mailgun_domain_name
          wrapper in
      Email email

    let fastqc_email ~fastqcs email_options =
      let wrapper =
        let get_fqc =
          Biokepi.EDSL.Compile.To_workflow.File_type_specification.
            get_fastqc_result
        in
        let fastqcs =
          List.map fastqcs ~f:(fun (n, f) -> n, get_fqc f) in
        let summary_file =
          work_dir // "fastqc-summary.txt"
        in
        summarize_fastqcs ~machine ~fastqcs summary_file
      in
      let subject = sprintf "FASTQC results for %s" run_name in
      let email =
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
      fun ~var_count -> Final_report.To_dot.function_call "flagstat_email" [
        ]
    let fastqc_email ~fastqcs email_options =
      fun ~var_count -> Final_report.To_dot.function_call "fastqc_email" [
        ]
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
    let fastqc_email ~fastqcs email_options =
      fun ~var_count ->
        let args =
          List.map fastqcs
            ~f:(fun (name, f) -> sprintf "%s fastqc" name, f ~var_count)
          @ ["to email", `String email_options.to_email;
             "from email", `String email_options.from_email ]
        in
        let json : Yojson.Basic.json =
          `Assoc [
            "fastqc email",
            `Assoc args ] in
        json
  end

  module Apply_functions (B:Semantics) = struct
  end

end
