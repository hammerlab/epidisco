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
  NUM_OF_PASSES=$(cat ${qcsummary} |grep PASS |wc -l |awk '{ print $1 }')
  NUM_OF_CHECKS=$(cat ${qcsummary} |wc -l |awk '{ print $1 }')

  echo "## File: $qcsummary"
  echo "## Result: $NUM_OF_PASSES/$NUM_OF_CHECKS passed"
  echo "## Issues: "
  cat ${qcsummary} |grep -v "PASS" |cut -f1,2 |sed -e 's/^/ - /g'
  echo -en "\n"
done
|bash}

let summarize_fastqc
    ~machine ~normal_fastqc ~tumor_fastqc ?rna_fastqc summary_file =
  let fqc_cmd name fqc =
    sprintf "bash ${SUMMARIZE} %s %s"
      name
      (String.concat ~sep:" " fqc#product#paths) in
  let opt_map_list o f = Option.value_map o ~default:[] ~f:(fun r -> [f r]) in
  let cmd =
    sprintf
      "SUMMARIZE=$(mktemp);\
       cat << EOF > ${SUMMARIZE}\
       %s
       EOF
       (%s) > %s;"
      summarize_qc_script
      (String.concat ~sep:"; "
         ([fqc_cmd "normal" normal_fastqc;
           fqc_cmd "tumor" tumor_fastqc;
          ] @ opt_map_list rna_fastqc (fqc_cmd "rna")))
      summary_file
  in
  let name = "Summarize FASTQC results" in
  let make =
    Biokepi.Machine.quick_run_program machine Program.(sh cmd)
  in
  let host = Biokepi.Machine.(as_host machine) in
  workflow_node (single_file summary_file ~host)
    ~name
    ~edges:(List.map ~f:(fun n -> depends_on n)
              ([normal_fastqc; tumor_fastqc]
               @ opt_map_list rna_fastqc (fun i -> i)))
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
    val fastqc_email :
      normal:([ `Fastqc ] repr) ->
      tumor:([ `Fastqc ] repr) ->
      ?rna:([ `Fastqc ] repr) ->
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
    open Config

    let flagstat_email ~normal ~tumor ?rna email_options =
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
        let wrapper =
          summarize_flagstats ~machine flgs summary summary_file in
        let subject = "Flagstats for " ^ run_name in
        Email.on_success_send ~machine ~subject
          ~to_email:email_options.to_email
          ~from_email:email_options.from_email
          ~mailgun_api_key:email_options.mailgun_api_key
          ~mailgun_domain_name:email_options.mailgun_domain_name
          wrapper
      in
      Email email

    let fastqc_email ~normal ~tumor ?rna email_options =
      let wrapper =
        let get_fqc =
          Biokepi.EDSL.Compile.To_workflow.File_type_specification.
            get_fastqc_result
        in
        let normal_fastqc, tumor_fastqc, rna_fastqc =
          get_fqc normal,
          get_fqc tumor,
          Option.map ~f:get_fqc rna in
        let summary_file =
          work_dir // "fastqc-summary.txt"
        in
        summarize_fastqc
          ~machine ~normal_fastqc ~tumor_fastqc ?rna_fastqc summary_file
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
      fun ~var_count -> `String "flagstat email"
    let fastqc_email ~normal ~tumor ?rna email_options =
      fun ~var_count -> `String "fastqc email"
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
    let fastqc_email ~normal ~tumor ?rna email_options =
      fun ~var_count ->
        let opt n o =
          Option.value_map ~default:[] o ~f:(fun v -> [n, v ~var_count]) in
        let args = [
          "normal fastqc", normal ~var_count;
          "tumor fastqc", tumor ~var_count;
          "to email", `String email_options.to_email;
          "from email", `String email_options.from_email
        ]
          @ opt "rna fastqc" rna
        in
        let json : Yojson.Basic.json =
          `Assoc [
            "fastqc email",
            `Assoc args
          ]
        in
        json
  end

  module Apply_functions (B:Semantics) = struct
  end

end
