open Batteries

open OUnit
open Printf

open Accums
open Spin
open SpinIr
open SpinIrImp
open SymbSkel

open SchemaSmt
open SchemaCheckerLtl

(* wrap a test with this function to see the tracing output *)
let with_tracing test_fun arg =
    Debug.enable_tracing () Trc.scl;
    let cleanup _ = Debug.disable_tracing () Trc.pos in
    finally cleanup test_fun arg

let keep x = BinEx (EQ, UnEx (NEXT, Var x), Var x)

let asgn l e = BinEx (EQ, UnEx (NEXT, Var l), e)

let sum v i = BinEx (PLUS, Var v, IntConst i)

let mk_rule src dst guard act = { Sk.src; Sk.dst; Sk.guard; Sk.act }

let declare_parameters sk tt =
    let append_var v = !(SmtTest.solver)#append_var_def v (tt#get_type v) in
    List.iter append_var sk.Sk.params;
    let append_expr e = ignore (!(SmtTest.solver)#append_expr e) in
    List.iter append_expr sk.Sk.assumes


let pad_list lst len desired_len =
    if len < desired_len
    then lst @ (BatList.make (desired_len - len) "()")
    else lst


let assert_eq_hist expected_hist hist =
    let nexpected, nfound = List.length expected_hist, List.length hist in
    let expected_hist = pad_list expected_hist nexpected nfound in
    let hist = pad_list hist nfound nexpected in
    let pp a b =
        let delim = if a = b then "======" else "<<<>>>" in
        sprintf "    %-30s %s    %-30s" a delim b
    in
    assert_equal expected_hist hist
        ~msg:("The histories do not match (expected <<<>>> encountered):\n"
            ^ (str_join "\n" (List.map2 pp expected_hist hist)))



(*
  Create a symbolic skeleton of the reliable broadcast (STRB).
  *)
let prepare_strb () =
    let tt = new data_type_tab in
    let pc = new_var "pc" in
    let nlocs = 4 in
    tt#set_type pc (mk_int_range 0 (nlocs + 1));
    let x, n, t, f = new_var "x", new_var "n", new_var "t", new_var "f" in
    n#set_symbolic; t#set_symbolic; f#set_symbolic;
    List.iter
        (fun v -> tt#set_type v (new data_type SpinTypes.TUNSIGNED))
        [x; n; t; f];
    let add_loc map i =
        let loc = new_var (sprintf "loc%d" i) in
        IntMap.add i loc map
    in
    let loc_map = List.fold_left add_loc IntMap.empty (range 0 (nlocs + 1)) in
    let mk_eq loc_map loc_no e =
        BinEx (EQ, Var (IntMap.find loc_no loc_map), e)
    in
    let g1 = (* x >= t + 1 - f *)
        BinEx (GE, Var x,
            BinEx (MINUS,
                    (BinEx (PLUS, IntConst 1, Var t)),
                    Var f))
    in
    let g2 = (* x >= n - t - f *)
        BinEx (GE, Var x,
            BinEx (MINUS,
                    BinEx (MINUS, Var n, Var t),
                    Var f))
    in
    let sk = {
        Sk.name = "asyn-agreement";
        Sk.nlocs = nlocs; Sk.locs = [ [0]; [1]; [2]; [3]; [4] ];
        Sk.locals = [ pc ]; Sk.shared = [ x ]; Sk.params = [ n; t; f ];
        Sk.nrules = 7;
        Sk.rules = [
            mk_rule 1 2 (IntConst 1) [ asgn x (sum x 1) ];
            mk_rule 0 2 g1 [ asgn x (sum x 1) ];
            mk_rule 0 3 g2 [ asgn x (sum x 1) ];
            mk_rule 2 3 g2 [ keep x ];

            mk_rule 1 1 (IntConst 1) [ keep x ];
            mk_rule 2 2 g1 [ keep x ];
            mk_rule 3 3 g2 [ keep x ];
        ];
        Sk.inits = [
            BinEx (EQ, Var x, IntConst 0);
            mk_eq loc_map 0 (BinEx (MINUS, Var n, Var f));
            mk_eq loc_map 1 (IntConst 0);
            mk_eq loc_map 2 (IntConst 0);
            mk_eq loc_map 3 (IntConst 0);
        ];
        Sk.loc_vars = loc_map;
        Sk.assumes = [
            BinEx (GT, Var n, BinEx (MULT, IntConst 3, Var t));
            BinEx (GE, Var t, Var f);
            BinEx (GE, Var f, IntConst 0);
        ];
    }
    in
    declare_parameters sk tt;
    let set_type v = tt#set_type v (new data_type SpinTypes.TUNSIGNED) in
    BatEnum.iter set_type  (IntMap.values sk.Sk.loc_vars);
    SymbSkel.optimize_guards sk, tt


let make_strb_unforg sk =
    let get_loc i = Var (IntMap.find i sk.Sk.loc_vars) in
    let eq0 i = BinEx (EQ, get_loc i, IntConst 0) in
    let all_at_loc0 =
        list_to_binex AND [eq0 1; eq0 2; eq0 3; eq0 4]
    in
    BinEx (AND, all_at_loc0, (UnEx (EVENTUALLY, eq0 4)))


let make_strb_corr sk =
    let get_loc i = Var (IntMap.find i sk.Sk.loc_vars) in
    let eq0 i = BinEx (EQ, get_loc i, IntConst 0) in
    let all_at_loc1 =
        list_to_binex AND [eq0 0; eq0 2; eq0 3; eq0 4]
    in
    BinEx (AND, all_at_loc1, (UnEx (ALWAYS, eq0 4)))


let make_strb_relay sk =
    let get_loc i = Var (IntMap.find i sk.Sk.loc_vars) in
    let eq0 i = BinEx (EQ, get_loc i, IntConst 0) in
    let ne0 i = BinEx (NE, get_loc i, IntConst 0) in
    let ex4 = ne0 4 in
    let exNot4 = list_to_binex OR [ne0 0; ne0 2; ne0 3; ne0 4] in
    UnEx (EVENTUALLY,
        BinEx (AND, ex4, (UnEx (ALWAYS, exNot4))))


let make_strb_fairness sk =
    let get_loc i = Var (IntMap.find i sk.Sk.loc_vars) in
    let eq0 i = BinEx (EQ, get_loc i, IntConst 0) in
    let eq0s lst = list_to_binex AND (List.map eq0 lst) in
    let plus l r = BinEx (PLUS, Var l, Var r) in
    let minus l r = BinEx (MINUS, Var l, Var r) in
    let lt l r = BinEx (LT, Var l, r) in
    let ge l r = BinEx (GE, Var l, r) in
    let zand l r = BinEx (AND, l, r) in
    let zor l r = BinEx (OR, l, r) in
    let nsnt = List.hd sk.Sk.shared in
    let param = List.at sk.Sk.params in
    let n, t, f = param 0, param 1, param 2 in
    let e1 = zor (lt nsnt (minus n t)) (eq0 4) in
    let e2 = zor (lt nsnt (minus n t)) (eq0s [2; 3]) in
    let e3 = zor (lt nsnt (minus n t)) (eq0s [0; 1]) in
    let e4 =
        zor (zor (lt nsnt (BinEx (PLUS, Var t, IntConst 1)))
                 (ge nsnt (minus n t)))
            (eq0s [0; 1; 2; 3]) in
    let expr =
        zand (zand (zand (e1) (e2)) (e3)) (e4)
    in
    UnEx (ALWAYS,
        UnEx (EVENTUALLY, expr))



(*
  Create a symbolic skeleton. This is in fact the example that appeared in our CAV'15 paper.
  *)
let prepare_aba () =
    let tt = new data_type_tab in
    let pc = new_var "pc" in
    let nlocs = 5 in
    tt#set_type pc (mk_int_range 0 (nlocs + 1));
    let x, y, n, t, f = new_var "x", new_var "y", new_var "n", new_var "t", new_var "f" in
    n#set_symbolic; t#set_symbolic; f#set_symbolic;
    List.iter
        (fun v -> tt#set_type v (new data_type SpinTypes.TUNSIGNED))
        [x; y; n; t; f];
    let add_loc map i =
        let loc = new_var (sprintf "loc%d" i) in
        IntMap.add i loc map
    in
    let loc_map = List.fold_left add_loc IntMap.empty (range 0 (nlocs + 1)) in
    let mk_eq loc_map loc_no e =
        BinEx (EQ, Var (IntMap.find loc_no loc_map), e)
    in
    let g1 = (* x >= (n + t) / 2 + 1 - f  (rounding up is omitted) *)
        BinEx (GE, Var x,
            BinEx (MINUS,
                BinEx (PLUS,
                    IntConst 1,
                    BinEx (DIV, (BinEx (MINUS, Var n, Var t)), IntConst 2)),
                Var f))
    in
    let g2 = (* y >= t + 1 -f *)
        BinEx (GE, Var y, BinEx (MINUS, BinEx (PLUS, Var t, IntConst 1), Var f))
    in
    let g3 = (* y >= 2t + 1 -f *)
        BinEx (GE, Var y,
            BinEx (MINUS,
                BinEx (PLUS, BinEx (MULT, IntConst 2, Var t), IntConst 1), Var f))
    in
    let sk = {
        Sk.name = "asyn-agreement";
        Sk.nlocs = nlocs; Sk.locs = [ [0]; [1]; [2]; [3]; [4] ];
        Sk.locals = [ pc ]; Sk.shared = [ x; y ]; Sk.params = [ n; t; f ];
        Sk.nrules = 6;
        Sk.rules = [
            mk_rule 1 2 (IntConst 1) [ asgn x (sum x 1); keep y ];
            mk_rule 0 1 g1 [ asgn x (sum x 1); keep y ];
            mk_rule 0 1 g2 [ asgn x (sum x 1); keep y ];
            mk_rule 2 3 g1 [ keep x; asgn y (sum y 1) ];
            mk_rule 2 3 g2 [ keep x; asgn y (sum y 1) ];
            mk_rule 3 4 g3 [ keep x; keep y ];
        ];
        Sk.inits = [
            BinEx (EQ, Var x, IntConst 0);
            BinEx (EQ, Var y, IntConst 0);
            mk_eq loc_map 0 (BinEx (MINUS, Var n, Var f));
            mk_eq loc_map 1 (IntConst 0);
            mk_eq loc_map 2 (IntConst 0);
            mk_eq loc_map 3 (IntConst 0);
            mk_eq loc_map 4 (IntConst 0);
        ];
        Sk.loc_vars = loc_map;
        Sk.assumes = [
            BinEx (GT, Var n, BinEx (MULT, IntConst 3, Var t));
            BinEx (GE, Var t, Var f);
            BinEx (GE, Var f, IntConst 0);
        ];
    }
    in
    declare_parameters sk tt;
    let set_type v = tt#set_type v (new data_type SpinTypes.TUNSIGNED) in
    BatEnum.iter set_type (IntMap.values sk.Sk.loc_vars);
    SymbSkel.optimize_guards sk, tt


let make_aba_unforg sk =
    let get_loc i = Var (IntMap.find i sk.Sk.loc_vars) in
    let eq0 i = BinEx (EQ, get_loc i, IntConst 0) in
    let all_at_loc0 =
        list_to_binex AND [eq0 1; eq0 2; eq0 3; eq0 4]
    in
    BinEx (AND, all_at_loc0, (UnEx (EVENTUALLY, eq0 4)))


type frame_stack_elem_t =
    | Frame of F.frame_t    (* just a frame *)
    | Node of int           (* a node marker *)
    | Context of int        (* a context marker *)


let node_type_s = function
    | Leaf -> "Leaf"
    | Intermediate -> "Intermediate"
    | LoopStart -> "LoopStart" (* not required for safety *)


(**
 A tactic that does not nothing but records the executed methods.
 It is a stripped version of SchemaChecker.tree_tac_t
 *)
class mock_tac_t (tt: SpinIr.data_type_tab) =
    object(self)
        inherit SchemaSmt.tac_t

        val mutable m_frames = []       (** the frame stack *)
        val mutable m_call_stack = []   (** we record the method calls here *)

        (** get the history of calls collected so far *)
        method get_call_history =
            List.rev m_call_stack

        method top =
            let rec find = function
                | (Frame f) :: _ -> f
                | _ :: tl -> find tl
                | [] -> raise (Failure "Frame stack is empty")
            in
            find m_frames

        method frame_hist =
            let m l = function
                | Frame f -> f :: l
                | _ -> l
            in
            (* do not reverse the second time *)
            List.fold_left m [] m_frames
 
        method private top2 =
            let rec find = function
                | (Frame f) :: tl -> f, tl
                | _ :: tl -> find tl
                | [] -> raise (Failure "Frame stack is empty")
            in
            let top, tl = find m_frames in
            let prev, _ = find tl in
            top, prev

        method push_frame f =
            m_frames <- (Frame f) :: m_frames

        method assert_top es =
            let each e =
                let tag = sprintf "(assert_top %s _)" (SpinIrImp.expr_s e) in
                m_call_stack <- tag :: m_call_stack
            in
            List.iter each es

        method assert_top2 es =
            let each e =
                let tag = sprintf "(assert_top2 %s _)" (SpinIrImp.expr_s e) in
                m_call_stack <- tag :: m_call_stack
            in
            List.iter each es

        method assert_frame_eq sk frame =
            let tag = sprintf "(assert_frame_eq _ %d)" frame.F.no in
            m_call_stack <- tag :: m_call_stack

        method enter_node tp =
            let tag = sprintf "(enter_node %s)" (node_type_s tp) in
            m_call_stack <- tag :: m_call_stack

        method leave_node tp =
            let tag = sprintf "(leave_node %s)" (node_type_s tp) in
            m_call_stack <- tag :: m_call_stack

        method check_property exp _ =
            let tag = sprintf "(check_property %s _)" (SpinIrImp.expr_s exp) in
            m_call_stack <- tag :: m_call_stack;
            false (* no bug found *)

        method enter_context =
            m_call_stack <- "(enter_context)" :: m_call_stack

        method leave_context =
            m_call_stack <- "(leave_context)" :: m_call_stack

        method push_rule _ sk rule_no =
            let tag = sprintf "(push_rule _ _ %d)" rule_no in
            m_call_stack <- tag :: m_call_stack;
            let new_frame = F.advance_frame tt sk self#top (fun _ _ -> true) in
            self#push_frame new_frame

    end


let gen_and_check_schemas_on_the_fly_strb _ =
    let sk, tt = prepare_strb () in
    let deps = PorBounds.compute_deps ~against_only:false !SmtTest.solver sk in
    let tac = new mock_tac_t tt in
    let ltl_form = make_strb_unforg sk in
    let spec = extract_safety_or_utl tt sk ltl_form in
    let bad_form =
        match spec with
        | SchemaCheckerLtl.Safety (_, bf) -> bf
        | _ -> assert_failure "Unexpected formula"
    in
    let ntt = tt#copy in
    let initf = F.init_frame ntt sk in
    tac#push_frame initf;
    let result =
        SchemaCheckerLtl.gen_and_check_schemas_on_the_fly
            !SmtTest.solver sk spec deps (tac :> tac_t) in
    assert_equal false result.m_is_err_found
        ~msg:"Expected no errors, found one";

    let hist = tac#get_call_history in
    let check_prop = sprintf "(check_property %s _)" (SpinIrImp.expr_s bad_form) in
    let expected_hist = [
        (* the only path *)
        "(enter_context)";
        "(assert_top ((((loc1 == 0) && (loc2 == 0)) && (loc3 == 0)) && (loc4 == 0)) _)";
        "(enter_node Intermediate)";
        "(push_rule _ _ 4)";
        "(push_rule _ _ 0)";
        check_prop;
        "(enter_context)";
        "(push_rule _ _ 4)";
        "(push_rule _ _ 0)";    (* enables g1 *)
        "(assert_top (x >= ((1 + t) - f)) _)"; (* g1 is actually enabled *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 1)";
        "(push_rule _ _ 4)";
        "(push_rule _ _ 0)";
        "(push_rule _ _ 5)";
        check_prop;
        "(enter_context)";
        "(push_rule _ _ 1)";
        "(push_rule _ _ 4)";
        "(push_rule _ _ 0)";
        "(push_rule _ _ 5)";    (* enables g2 *)
        "(assert_top (x >= ((n - t) - f)) _)"; (* g2 is actually enabled *)
        "(enter_node Leaf)";
        "(push_rule _ _ 1)";
        "(push_rule _ _ 2)";
        "(push_rule _ _ 4)";
        "(push_rule _ _ 0)";
        "(push_rule _ _ 5)";
        "(push_rule _ _ 3)";
        "(push_rule _ _ 6)";
        check_prop;
        "(leave_node Leaf)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
    ] in
    assert_eq_hist expected_hist hist


let gen_and_check_schemas_on_the_fly_aba _ =
    let sk, tt = prepare_aba () in
    let deps = PorBounds.compute_deps ~against_only:false !SmtTest.solver sk in
    let tac = new mock_tac_t tt in
    let ltl_form = make_aba_unforg sk in
    let spec = extract_safety_or_utl tt sk ltl_form in
    let bad_form =
        match spec with
        | SchemaCheckerLtl.Safety (_, bf) -> bf
        | _ -> assert_failure "Unexpected formula"
    in
    let ntt = tt#copy in
    let initf = F.init_frame ntt sk in
    tac#push_frame initf;
    let result =
        SchemaCheckerLtl.gen_and_check_schemas_on_the_fly
            !SmtTest.solver sk spec deps (tac :> tac_t) in
    assert_equal false result.m_is_err_found
        ~msg:"Expected no errors, found one";

    let hist = tac#get_call_history in
    let check_prop = sprintf "(check_property %s _)" (SpinIrImp.expr_s bad_form) in
    let expected_hist = [
        (* the first path *)
        "(enter_context)";
        "(assert_top ((((loc1 == 0) && (loc2 == 0)) && (loc3 == 0)) && (loc4 == 0)) _)";
        "(enter_node Intermediate)";
        "(push_rule _ _ 0)";
        check_prop;
        "(enter_context)";
        "(push_rule _ _ 0)"; (* enables g1 *)
        "(assert_top (x >= ((1 + ((n - t) / 2)) - f)) _)"; (* g1 is enabled *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 1)"; "(push_rule _ _ 0)"; "(push_rule _ _ 3)";
        check_prop;
        "(enter_context)";
        "(push_rule _ _ 1)"; "(push_rule _ _ 0)"; "(push_rule _ _ 3)"; (* enables g2 *)
        "(assert_top (y >= ((t + 1) - f)) _)";  (* g2 is enabled *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 1)"; "(push_rule _ _ 2)";
        "(push_rule _ _ 0)"; "(push_rule _ _ 4)"; "(push_rule _ _ 3)";
        check_prop;
        "(enter_context)";
        "(push_rule _ _ 1)"; "(push_rule _ _ 2)";
        "(push_rule _ _ 0)"; "(push_rule _ _ 4)"; "(push_rule _ _ 3)"; (* enables g3 *)
        "(assert_top (y >= (((2 * t) + 1) - f)) _)";    (* g3 is enabled *)
        "(enter_node Leaf)";
        "(push_rule _ _ 1)"; "(push_rule _ _ 2)"; "(push_rule _ _ 0)";
        "(push_rule _ _ 4)"; "(push_rule _ _ 3)"; "(push_rule _ _ 5)";
        check_prop;
        "(leave_node Leaf)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
        (* the second path *)
        "(enter_context)";
        "(assert_top ((((loc1 == 0) && (loc2 == 0)) && (loc3 == 0)) && (loc4 == 0)) _)";
        "(enter_node Intermediate)";
        "(push_rule _ _ 0)";
        check_prop;
        "(enter_context)";
        "(push_rule _ _ 0)"; (* enables g2 *)
        "(assert_top (y >= ((t + 1) - f)) _)"; (* g2 is enabled *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 2)"; "(push_rule _ _ 0)"; "(push_rule _ _ 4)";
        check_prop;
        "(enter_context)";
        "(push_rule _ _ 2)"; "(push_rule _ _ 0)"; "(push_rule _ _ 4)"; (* enables g3 *)
        "(assert_top (y >= (((2 * t) + 1) - f)) _)";    (* g3 is enabled *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 2)"; "(push_rule _ _ 0)";
        "(push_rule _ _ 4)"; "(push_rule _ _ 5)";
        check_prop;
        "(enter_context)";
        "(push_rule _ _ 2)"; "(push_rule _ _ 0)";
        "(push_rule _ _ 4)"; "(push_rule _ _ 5)"; (* enables g1 *)
        "(assert_top (x >= ((1 + ((n - t) / 2)) - f)) _)";  (* g1 is enabled *)
        "(enter_node Leaf)";
        "(push_rule _ _ 1)"; "(push_rule _ _ 2)"; "(push_rule _ _ 0)";
        "(push_rule _ _ 4)"; "(push_rule _ _ 3)"; "(push_rule _ _ 5)";
        check_prop;
        "(leave_node Leaf)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
        (* the third path *)
        "(enter_context)";
        "(assert_top ((((loc1 == 0) && (loc2 == 0)) && (loc3 == 0)) && (loc4 == 0)) _)";
        "(enter_node Intermediate)";
        "(push_rule _ _ 0)";
        check_prop;
        "(enter_context)";
        "(push_rule _ _ 0)"; (* enables g2 *)
        "(assert_top (y >= ((t + 1) - f)) _)";  (* g2 is enabled *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 2)"; "(push_rule _ _ 0)"; "(push_rule _ _ 4)";
        check_prop;
        "(enter_context)";
        "(push_rule _ _ 2)"; "(push_rule _ _ 0)"; "(push_rule _ _ 4)"; (* enables g1 *)
        "(assert_top (x >= ((1 + ((n - t) / 2)) - f)) _)"; (* g1 is enabled *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 1)"; "(push_rule _ _ 2)";
        "(push_rule _ _ 0)"; "(push_rule _ _ 4)"; "(push_rule _ _ 3)";
        check_prop;
        "(enter_context)";
        "(push_rule _ _ 1)"; "(push_rule _ _ 2)";
        "(push_rule _ _ 0)"; "(push_rule _ _ 4)"; "(push_rule _ _ 3)"; (* enables g3 *)
        "(assert_top (y >= (((2 * t) + 1) - f)) _)";    (* g3 is enabled *)
        "(enter_node Leaf)";
        "(push_rule _ _ 1)"; "(push_rule _ _ 2)"; "(push_rule _ _ 0)";
        "(push_rule _ _ 4)"; "(push_rule _ _ 3)"; "(push_rule _ _ 5)";
        check_prop;
        "(leave_node Leaf)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
    ] in
    assert_eq_hist expected_hist hist


let gen_and_check_schemas_on_the_fly_strb_corr _ =
    let sk, tt = prepare_strb () in
    let deps = PorBounds.compute_deps ~against_only:false !SmtTest.solver sk in
    let tac = new mock_tac_t tt in
    let ltl_form = make_strb_corr sk in
    let spec = extract_safety_or_utl tt sk ltl_form in
    let ntt = tt#copy in
    let initf = F.init_frame ntt sk in
    tac#push_frame initf;
    let result =
        SchemaCheckerLtl.gen_and_check_schemas_on_the_fly
            !SmtTest.solver sk spec deps (tac :> tac_t) in
    assert_equal false result.m_is_err_found
        ~msg:"Expected no errors, found one";

    let hist = tac#get_call_history in
    let expected_hist = [
        (* a schema that does not unlock anything and goes to a loop *)
        "(enter_context)";
             (* the initial constraint *)
        "(assert_top ((((loc4 == 0) && (loc3 == 0)) && (loc0 == 0)) && (loc2 == 0)) _)";
        "(assert_top (loc4 == 0) _)";    (* k[4] = 0 *)
        "(assert_top (loc4 == 0) _)";    (* G k[4] = 0 *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 4)";             (* a self-loop *)
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 0)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(enter_node LoopStart)";        (* entering the loop *)
        "(push_rule _ _ 4)";             (* a self-loop *)
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 0)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(assert_frame_eq _ 2)";    (* the reached frame equals to the loop start *)
        "(assert_top ((F3_warp > 0) || (F4_warp > 0)) _)"; (* at least one step was made *)
        "(check_property 1 _)";     (* the point where the property should be checked *)
        "(leave_node LoopStart)";
        "(leave_node Intermediate)";
        "(leave_context)";

        (* a schema that unlocks g1, then g2 and then reaches a loop *)
        "(enter_context)";
        "(assert_top ((((loc4 == 0) && (loc3 == 0)) && (loc0 == 0)) && (loc2 == 0)) _)";
        "(assert_top (loc4 == 0) _)";    (* k[4] = 0 *)
        "(assert_top (loc4 == 0) _)";    (* G k[4] = 0 *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 4)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 0)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(enter_context)";
        "(push_rule _ _ 4)"; (* enables g1 *)
        "(push_rule _ _ 0)"; (* enables g1 *)
        "(assert_top (x >= ((1 + t) - f)) _)"; (* g1 is actually enabled *)
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 1)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 4)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 0)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 5)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(enter_context)";
        "(push_rule _ _ 1)";
        "(push_rule _ _ 4)";
        "(push_rule _ _ 0)";
        "(push_rule _ _ 5)"; (* enables g2 *)
        "(assert_top (x >= ((n - t) - f)) _)"; (* g2 is actually enabled *)
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 1)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 2)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 4)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 0)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 5)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 3)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 6)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(enter_node LoopStart)";                      (* entering the loop *)
        "(push_rule _ _ 1)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 2)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 4)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 0)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 5)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 3)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 6)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(assert_frame_eq _ 23)";         (* the loop is closed *)
        "(assert_top (((((((F24_warp > 0) || (F25_warp > 0)) || (F26_warp > 0)) || (F27_warp > 0)) || (F28_warp > 0)) || (F29_warp > 0)) || (F30_warp > 0)) _)";
            (* at least one step was made *)
        "(check_property 1 _)";     (* the point where the property should be checked *)
        "(leave_node LoopStart)";
        "(leave_node Intermediate)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";

        (* a schema that unlocks g1 and then reaches a loop *)
        "(enter_context)";
        "(assert_top ((((loc4 == 0) && (loc3 == 0)) && (loc0 == 0)) && (loc2 == 0)) _)";
        "(assert_top (loc4 == 0) _)";    (* k[4] = 0 *)
        "(assert_top (loc4 == 0) _)";    (* G k[4] = 0 *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 4)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 0)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(enter_context)";
        "(push_rule _ _ 4)";
        "(push_rule _ _ 0)";            (* enables g1 *)
        "(assert_top (x >= ((1 + t) - f)) _)"; (* g1 is actually enabled *)
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(enter_node Intermediate)";
        "(push_rule _ _ 1)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 4)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 0)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 5)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(enter_node LoopStart)";                      (* entering the loop *)
        "(push_rule _ _ 1)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 4)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 0)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(push_rule _ _ 5)";
        "(assert_top (loc4 == 0) _)";    (* the G k[4] = 0 *)
        "(assert_frame_eq _ 38)";         (* the loop is closed *)
        "(assert_top ((((F39_warp > 0) || (F40_warp > 0)) || (F41_warp > 0)) || (F42_warp > 0)) _)"; (* at least one step is made *)
        "(check_property 1 _)";     (* the point where the property should be checked *)
        "(leave_node LoopStart)";
        "(leave_node Intermediate)";
        "(leave_context)";
        "(leave_node Intermediate)";
        "(leave_context)";
    ] in
    assert_eq_hist expected_hist hist


let extract_utl_corr _ =
    let sk, tt = prepare_strb () in
    let ltl_form = make_strb_corr sk in
    let expected_utl =
        TL_and [TL_p (And_Keq0 [4; 3; 0; 2]); TL_G (TL_p (And_Keq0 [4]))]
    in
    let result_utl = SchemaCheckerLtl.extract_utl sk ltl_form in
    assert_equal expected_utl result_utl
        ~msg:(sprintf "Expected %s, found %s"
            (utl_spec_s expected_utl) (utl_spec_s result_utl))


let extract_utl_relay _ =
    let sk, _ = prepare_strb () in
    let ltl_form = make_strb_relay sk in
    let expected_utl =
        TL_F (TL_and [TL_p (AndOr_Kne0 [[4]]); TL_G (TL_p (AndOr_Kne0 [[4; 3; 0; 2]]))])
    in
    let result_utl = SchemaCheckerLtl.extract_utl sk ltl_form in
    assert_equal expected_utl result_utl
        ~msg:(sprintf "Expected %s, found %s"
            (utl_spec_s expected_utl) (utl_spec_s result_utl))


let can_handle_corr _ =
    let sk, tt = prepare_strb () in
    let ltl_form = make_strb_corr sk in
    let result = SchemaCheckerLtl.can_handle_spec tt sk ltl_form in
    assert_equal true result ~msg:(sprintf "Cannot handle corr")


let can_handle_relay _ =
    let sk, tt = prepare_strb () in
    let ltl_form = make_strb_relay sk in
    let result = SchemaCheckerLtl.can_handle_spec tt sk ltl_form in
    assert_equal true result ~msg:(sprintf "Cannot handle relay")


let can_handle_fairness _ =
    let sk, tt = prepare_strb () in
    let ltl_form = make_strb_fairness sk in
    let result = SchemaCheckerLtl.can_handle_spec tt sk ltl_form in
    assert_equal true result ~msg:(sprintf "Cannot handle fairness")


let extract_utl_fairness _ =
    let sk, tt = prepare_strb () in
    let ltl_form = make_strb_fairness sk in
    let expected_utl_s =
        "G (F (((((x < (t + 1)) || (x >= (n - t)))) \\/ (k[3] = 0 /\\ k[2] = 0 /\\ k[0] = 0 /\\ k[1] = 0) /\\ ((x < (n - t))) \\/ (k[0] = 0 /\\ k[1] = 0) /\\ ((x < (n - t))) \\/ (k[4] = 0) /\\ ((x < (n - t))) \\/ (k[2] = 0 /\\ k[3] = 0))))"
    in
    let result_utl = SchemaCheckerLtl.extract_utl sk ltl_form in
    let result_utl_s = utl_spec_s result_utl in
    assert_equal expected_utl_s result_utl_s
        ~msg:(sprintf "Expected %s, found %s" expected_utl_s result_utl_s)


let suite = "schemaCheckerLtl-suite" >:::
    [
        "extract_utl_corr"
            >::(bracket SmtTest.setup_smt2 extract_utl_corr SmtTest.shutdown_smt2);
        "extract_utl_relay"
            >::(bracket SmtTest.setup_smt2 extract_utl_relay SmtTest.shutdown_smt2);
        "extract_utl_fairness"
            >::(bracket SmtTest.setup_smt2 extract_utl_fairness SmtTest.shutdown_smt2);

        "can_handle_corr"
            >::(bracket SmtTest.setup_smt2 can_handle_corr SmtTest.shutdown_smt2);
        "can_handle_relay"
            >::(bracket SmtTest.setup_smt2 can_handle_relay SmtTest.shutdown_smt2);
        "can_handle_fairness"
            >::(bracket SmtTest.setup_smt2 can_handle_fairness SmtTest.shutdown_smt2);

        "compute_schema_tree_on_the_fly_strb"
            >::(bracket SmtTest.setup_smt2
                gen_and_check_schemas_on_the_fly_strb SmtTest.shutdown_smt2);
        "compute_schema_tree_on_the_fly_aba"
            >::(bracket SmtTest.setup_smt2
                gen_and_check_schemas_on_the_fly_aba SmtTest.shutdown_smt2);

        "gen_and_check_schemas_on_the_fly_strb_corr"
            >::(bracket SmtTest.setup_smt2
                gen_and_check_schemas_on_the_fly_strb_corr SmtTest.shutdown_smt2);
    ]

