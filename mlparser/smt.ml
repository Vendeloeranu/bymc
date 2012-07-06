(* utility functions to integrate with Yices *)

open Printf;;

open Spin_types;;
open Spin;;
open Spin_ir;;
open Spin_ir_imp;;

exception Smt_error of string;;

let rec var_to_smt var =
    let wrap_arr type_s =
        if var#is_array
        then sprintf "(-> (subrange 0 %d) %s)" (var#get_num_elems - 1) type_s
        else type_s
    in
    let ts = match var#get_type with
    | TBIT -> wrap_arr "bool"
    | TBYTE -> wrap_arr "int"
    | TSHORT -> wrap_arr "int"
    | TINT -> wrap_arr "int"
    | TUNSIGNED -> wrap_arr "nat"
    | TCHAN -> raise (Failure "Type chan is not supported")
    | TMTYPE -> raise (Failure "Type mtype is not supported")
    in
    sprintf "(define %s :: %s)" var#get_name ts
;;

let rec expr_to_smt e =
    match e with
    | Nop comment -> sprintf ";; %s\n" comment
    | Const i -> string_of_int i
    | Var v -> v#get_name
    | Phi (lhs, rhs) ->
            raise (Failure "Phi to SMT is not supported yet")
    | UnEx (tok, f) ->
        begin match tok with
        | UMIN -> sprintf "(- %s)" (expr_to_smt f)
        | NEG  -> sprintf "(not %s)" (expr_to_smt f)
        | _ ->
            raise (Failure
                (sprintf "No idea how to translate %s to SMT" (token_s tok)))
        end
    | BinEx (tok, l, r) ->
        begin match tok with
        | PLUS  -> sprintf "(+ %s %s)" (expr_to_smt l) (expr_to_smt r)
        | MINUS -> sprintf "(- %s %s)" (expr_to_smt l) (expr_to_smt r)
        | MULT  -> sprintf "(* %s %s)" (expr_to_smt l) (expr_to_smt r)
        | DIV   -> sprintf "(/ %s %s)" (expr_to_smt l) (expr_to_smt r)
        | MOD   -> sprintf "(%% %s %s)" (expr_to_smt l) (expr_to_smt r)
        | GT    -> sprintf "(> %s %s)" (expr_to_smt l) (expr_to_smt r)
        | LT    -> sprintf "(< %s %s)" (expr_to_smt l) (expr_to_smt r)
        | GE    -> sprintf "(>= %s %s)"  (expr_to_smt l) (expr_to_smt r)
        | LE    -> sprintf "(<= %s %s)"  (expr_to_smt l) (expr_to_smt r)
        | EQ    -> sprintf "(= %s %s)"  (expr_to_smt l) (expr_to_smt r)
        | NE    -> sprintf "(/= %s %s)"  (expr_to_smt l) (expr_to_smt r)
        | AND   -> sprintf "(and %s %s)" (expr_to_smt l) (expr_to_smt r)
        | OR    -> sprintf "(or %s %s)"  (expr_to_smt l) (expr_to_smt r)
        | ARR_ACCESS -> sprintf "(%s %s)" (expr_to_smt l) (expr_to_smt r)
        | _ -> raise (Failure
                (sprintf "No idea how to translate %s to SMT" (token_s tok)))
        end
;;

(* the wrapper of the actual solver (yices) *)
class yices_smt =
    object(self)
        val mutable pid = 0
        val mutable cin = stdin
        val mutable cout = stdout
        val mutable cerr = stdin
        val mutable clog = stdout
        val mutable debug = false
        val mutable collect_asserts = false
        val mutable asserts_tbl : (int, token expr) Hashtbl.t = Hashtbl.create 0

        method start =
            let pin, pout, perr =
                Unix.open_process_full "yices" (Unix.environment ()) in
            cin <- pin;
            cout <- pout;
            cerr <- perr;
            clog <- open_out "yices.log";
            fprintf cout "(set-verbosity! 3)\n"
        
        method stop =
            close_out clog;
            Unix.close_process_full (cin, cout, cerr)


        method append cmd =
            if debug then printf "%s\n" cmd;
            fprintf cout "%s\n" cmd;
            fprintf clog "%s\n" cmd; flush clog

        method append_assert s =
            self#append (sprintf "(assert %s)" s)

        method append_expr expr =
            if not collect_asserts
            then self#append (sprintf "(assert %s)" (expr_to_smt expr))
            else begin
                (* XXX: may block if the verbosity level < 2 *)
                self#sync;
                self#append (sprintf "(assert+ %s)" (expr_to_smt expr));
                flush cout;
                let line = input_line cin in
                if (Str.string_match (Str.regexp "id: \\([0-9]+\\))") line 0)
                then
                    let id = int_of_string (Str.matched_group 1 line) in
                    Hashtbl.add asserts_tbl id expr
            end

        method push_ctx = self#append "(push)"

        method pop_ctx = self#append "(pop)"

        method sync =
            (* the solver can print more messages, thus, sync! *)
            self#append "(echo \"sync\\n\")"; flush cout;
            let stop = ref false in
            while not !stop do
                if "sync" = (input_line cin) then stop := true
            done

        method check =
            self#sync;
            self#append "(status)"; (* it can be unsat already *)
            flush cout;
            if not (self#is_out_sat true)
            then false
            else begin
                self#append "(check)";
                flush cout;
                self#is_out_sat false
            end

        method set_collect_asserts b =
            collect_asserts <- b;
            if not b then Hashtbl.clear asserts_tbl

        method find_collected id =
            Hashtbl.find asserts_tbl id

        method forget_collected =
            Hashtbl.clear asserts_tbl

        method is_out_sat ignore_errors =
            let l = input_line cin in
            (*printf "%s\n" l;*)
            match l with
            | "sat" -> true
            | "ok" -> true
            | "unsat" -> false
            | _ -> if ignore_errors
                then false
                else raise (Smt_error (sprintf "yices: %s" l))

        method get_cin = cin
        method get_cout = cout
        method set_debug flag = debug <- flag
    end
;;

