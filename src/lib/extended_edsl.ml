open Nonstd

module To_json_with_mem (Memory: Save_result.Compilation_memory) = struct
  include Biokepi.EDSL.Compile.To_json
  let save key x ~var_count =
    let compiled = x ~var_count in
    Memory.add_json key compiled;
    compiled
  include Final_report.To_json
end

module type Semantics = sig
  include Biokepi.EDSL.Semantics
  include Save_result.Semantics with type 'a any := 'a repr
  include Final_report.Semantics with type 'a repr := 'a repr
end

module To_workflow
    (Config : sig
       include Biokepi.EDSL.Compile.To_workflow.Compiler_configuration
       val saving_path : string
     end)
    (Mem : Save_result.Compilation_memory)
= struct
  include Biokepi.EDSL.Compile.To_workflow.Make(Config)
  include Save_result.To_workflow(Config)(Mem)
  include Final_report.To_workflow(Config)(Mem)
end

module To_json = struct
  include Biokepi.EDSL.Compile.To_json
  include Save_result.Do_nothing
  include Final_report.To_json
end

module To_dot = struct
  include Biokepi.EDSL.Compile.To_dot
  include Save_result.Do_nothing
  include Final_report.To_dot
end

module Apply_functions (B : Semantics) = struct
  include Biokepi.EDSL.Transform.Apply_functions(B)
  include Save_result.Do_nothing

  let report
      ~vcfs
      ~qc_normal
      ~qc_tumor
      ~normal_bam
      ~normal_bam_flagstat
      ~tumor_bam
      ~tumor_bam_flagstat
      ?rna_bam
      ?vaxrank
      ?rna_bam_flagstat
      ?topiary
      ?isovar
      ?seq2hla
      ?stringtie
      ~metadata
      meta =
    let open The_pass.Transformation in
    fwd (B.report meta
           ~vcfs:(List.map ~f:(fun (k, v) -> k, bwd v) vcfs)
           ~qc_normal:(bwd qc_normal)
           ~qc_tumor:(bwd qc_tumor)
           ~normal_bam:(bwd normal_bam)
           ~normal_bam_flagstat:(bwd normal_bam_flagstat)
           ~tumor_bam:(bwd tumor_bam)
           ~tumor_bam_flagstat:(bwd tumor_bam_flagstat)
           ?rna_bam:(Option.map rna_bam bwd)
           ?vaxrank:(Option.map vaxrank bwd)
           ?rna_bam_flagstat:(Option.map rna_bam_flagstat bwd)
           ?topiary:(Option.map topiary bwd)
           ?isovar:(Option.map isovar bwd)
           ?seq2hla:(Option.map seq2hla bwd)
           ?stringtie:(Option.map stringtie bwd)
           ~metadata
        )
end
