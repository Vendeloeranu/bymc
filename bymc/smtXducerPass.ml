(* Translate a program to an SSA representation and then construct
   SMT assumptions.

   Igor Konnov, 2012
 *)

open Printf

open Accums
open Cfg
open CfgSmt
open Debug
open SpinIr
open SpinIrImp
open Ssa

let write_exprs name exprs =
    let out = open_out (sprintf "%s.xd" name) in
    let write_e e = fprintf out "%s\n" (expr_s e) in
    List.iter write_e exprs;
    close_out out

let to_xducer caches prog p =
    let roles = caches#get_analysis#get_var_roles in
    let reg_tbl = caches#get_struc#get_regions p#get_name in

    let loop_prefix = reg_tbl#get "loop_prefix" in
    let loop_body = reg_tbl#get "loop_body" in
    let lirs = (mir_to_lir (loop_body @ loop_prefix)) in
    let globals =
        (Program.get_shared prog) @ (Program.get_instrumental prog) in
    let locals = List.filter
        (Program.is_not_global prog) (hashtbl_keys roles#get_all) in
    let cfg = mk_ssa true globals locals (mk_cfg lirs) in
    if may_log DEBUG
    then print_detailed_cfg ("Loop of " ^ p#get_name ^ " in SSA: " ) cfg;
    Cfg.write_dot (sprintf "ssa_%s.dot" p#get_name) cfg;
    let transd = cfg_to_constraints cfg in
    write_exprs p#get_name transd;
    (* XXX: this pass produces not a Program.program, but proc_xducer! *)
    (new proc_xducer p transd)

let do_xducers caches prog =
    List.map (to_xducer caches prog) (Program.get_procs prog)

