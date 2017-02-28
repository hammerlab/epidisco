open Nonstd

module To_json_with_mem (Memory: Save_result.Compilation_memory) = struct
  include Biokepi.EDSL.Compile.To_json
  let save key x ~var_count =
    let compiled = x ~var_count in
    Memory.add_json key compiled;
    compiled
  include Final_report.To_json
  include Qc.EDSL.To_json
end

module type Semantics = sig
  include Biokepi.EDSL.Semantics
  include Save_result.Semantics with type 'a any := 'a repr
  include Final_report.Semantics with type 'a repr := 'a repr
  include Qc.EDSL.Semantics with type 'a repr := 'a repr
end

module To_workflow
    (Config : sig
       include Biokepi.EDSL.Compile.To_workflow.Compiler_configuration
       val saving_path : string
       val run_name : string
     end)
    (Mem : Save_result.Compilation_memory)
= struct
  include Biokepi.EDSL.Compile.To_workflow.Make(Config)
  include Save_result.To_workflow(Config)(Mem)
  include Final_report.To_workflow(Config)(Mem)
  include Qc.EDSL.To_workflow(Config)
end

module To_json = struct
  include Biokepi.EDSL.Compile.To_json
  include Save_result.Do_nothing
  include Final_report.To_json
  include Qc.EDSL.To_json
end

module To_dot = struct
  include Biokepi.EDSL.Compile.To_dot
  include Save_result.Do_nothing
  include Final_report.To_dot
  include Qc.EDSL.To_dot
end

module Apply_functions (B : Semantics) = struct
  include Biokepi.EDSL.Transform.Apply_functions(B)
  include Save_result.Do_nothing

  let flagstat_email ~normal ~tumor ?rna email_options =
    let open The_pass.Transformation in
    let email =
      (B.flagstat_email
         ~normal:(bwd normal)
         ~tumor:(bwd tumor)
         ?rna:(Option.map rna bwd)
         email_options)
    in
    fwd email

  let fastqc_email ~fastqcs email_options =
    let open The_pass.Transformation in
    let email =
      (B.fastqc_email
         ~fastqcs:(List.map ~f:(fun (name, f) -> (name, bwd f)) fastqcs)
         email_options)
    in
    fwd email

  let report
      ?igv_url_server_prefix
      ~vcfs
      ~fastqcs
      ~normal_bam
      ~normal_bam_flagstat
      ~tumor_bam
      ~tumor_bam_flagstat
      ?optitype_normal
      ?optitype_tumor
      ?optitype_rna
      ?rna_bam
      ?vaxrank
      ?rna_bam_flagstat
      ?topiary
      ?isovar
      ?seq2hla
      ?stringtie
      ?bedfile
      ~metadata
      meta =
    let open The_pass.Transformation in
    let map_bwd = List.map ~f:(fun (k, v) -> k, bwd v) in
    let opt_bwd = Option.map ~f:bwd in
    fwd (B.report meta
           ~vcfs:(map_bwd vcfs)
           ~fastqcs:(map_bwd fastqcs)
           ~normal_bam:(bwd normal_bam)
           ~normal_bam_flagstat:(bwd normal_bam_flagstat)
           ~tumor_bam:(bwd tumor_bam)
           ~tumor_bam_flagstat:(bwd tumor_bam_flagstat)
           ?optitype_normal:(opt_bwd optitype_normal)
           ?optitype_tumor:(opt_bwd optitype_tumor)
           ?optitype_rna:(opt_bwd optitype_rna)
           ?rna_bam:(opt_bwd rna_bam)
           ?vaxrank:(opt_bwd vaxrank)
           ?rna_bam_flagstat:(opt_bwd rna_bam_flagstat)
           ?topiary:(opt_bwd topiary)
           ?isovar:(opt_bwd isovar)
           ?seq2hla:(opt_bwd seq2hla)
           ?stringtie:(opt_bwd stringtie)
           ?bedfile
           ?igv_url_server_prefix
           ~metadata)
end
