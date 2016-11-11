open Printf

open Accums
open Debug
open Options
open Plugin
open Program
open Spin
open SymbSkel
open SchemaSmt

open TaSynt

(**
  Synthesizing threshold automata using CEGYS.

  @author Igor Konnov, 2016
 *)
class ta_synt_plugin_t (plugin_name: string) (ta_source: TaSource.ta_source_t) =
    object(self)
        inherit transform_plugin_t plugin_name
        inherit TaSource.ta_source_t

        val mutable m_out_skel: Sk.skel_t option = None
        val m_iter_filename = "iter.ser"

        method transform rt =
            let in_skel = ta_source#get_ta in
            let iter, _ = self#load_iter rt in_skel in
            let vec = iter_to_unknowns_vec iter in
            log INFO ("> Replacing the unknowns: " ^ (unknowns_vec_s vec));
            let out_skel = replace_unknowns in_skel vec in
            m_out_skel <- Some out_skel;
            Sk.to_file "synt.ta" out_skel;
            self#get_input0


        method get_ta =
            match m_out_skel with
            | Some sk -> sk

            | None ->
                let m =
                    "Plugin ta_synt_plugin_t has not been called yet"
                in
                raise (Failure m)

        (** As our refinement loop is iteratively calling the tool,
            we load the iterator from file.
         *)
        method load_iter rt skel: vec_iter_t * C.cex_t list =
            let iter_exists =
                try Unix.access m_iter_filename [Unix.F_OK]; true
                with Unix.Unix_error _ -> false 
            in
            if not iter_exists
            then begin
                let iter = vec_iter_init skel (self#get_bit_len rt) in
                self#save_iter rt iter [];
                iter, []
            end else begin
                let cin = open_in_bin m_iter_filename in
                let (pair: vec_iter_t * C.cex_t list) =
                    try Marshal.from_channel cin
                    with Failure e ->
                        let m = "\nERROR: The serialized iterator is corrupted."
                            ^ " Did you recompile the tool?\n\n" in
                        fprintf stderr "%s" m;
                        raise (Failure e)
                in
                close_in cin;
                pair
            end


        (**
          Save the iterator to file
          *)
        method save_iter rt iter (cexs: C.cex_t list) =
            log INFO (sprintf "saving iterator to %s..." m_iter_filename);
            let cout = open_out_bin m_iter_filename in
            Marshal.to_channel cout (iter, cexs) [Marshal.Closures];
            close_out cout


        method get_bit_len rt =
            if self#has_opt rt "bitlen"
            then int_of_string (self#get_opt rt "bitlen")
            else 2


        method update_runtime rt =
            ()

        method decode_trail _ path =
            path

        method refine rt path =
            let in_skel = ta_source#get_ta in
            let old_iter, cexs = self#load_iter rt in_skel in
            let new_cex = C.load_cex "cex-fixme.scm" in
            C.save_cex (sprintf "cex%d.scm" (List.length cexs)) new_cex;
            let all_cexs = cexs @ [new_cex] in
            let find_applicable_cex iter cexs =
                let flow_opt = SchemaOpt.is_flow_opt_enabled () in
                let type_tab = Program.get_type_tab self#get_input0 in
                let rec find num = function
                    | [] -> -1

                    | hd :: tl ->
                        let vec = iter_to_unknowns_vec iter in
                        let fixed_skel = replace_unknowns in_skel vec in
                        let deps =
                            PorBounds.compute_deps
                                ~against_only:flow_opt rt#solver fixed_skel
                        in
                        if TaSynt.is_cex_applicable_new
                            rt#solver type_tab fixed_skel deps hd
                        then num
                        else find (num + 1) tl
                in
                find 0 cexs
            in
            let rec find_new_iter iter =
                let new_iter = vec_iter_next iter in
                if (vec_iter_end new_iter)
                then new_iter
                else begin
                    let vec = iter_to_unknowns_vec new_iter in
                    log INFO (sprintf "> Checking %s..." (unknowns_vec_s vec));
                    let cex_num = find_applicable_cex new_iter all_cexs in
                    if (cex_num >= 0)
                    then begin
                        log INFO (sprintf "> %s is falsified by counterexample %d: "
                            (unknowns_vec_s vec) cex_num);
                        find_new_iter new_iter
                    end
                    else new_iter
                end
            in
            let next_valid_iter = find_new_iter old_iter in
            self#save_iter rt next_valid_iter all_cexs;
            if vec_iter_end next_valid_iter
            then begin
                let msg = sprintf
                    "Reached the upper bound %d on each unknown. No solution found."
                    (Accums.ipow 2 (self#get_bit_len rt))
                in
                log INFO msg;
                log INFO (sprintf "Collected %d counterexamples in total"
                    (List.length all_cexs));
                (false, self#get_output)
            end else begin
                let vec = iter_to_unknowns_vec next_valid_iter in
                log INFO
                    ("> Next unknowns to try: " ^ (unknowns_vec_s vec));
                (true, self#get_output)
            end

    end

