/* OCaml version of the (extended) Promela parser       */
/* Adapted from the original yacc grammar of Spin 6.0.1 */
/*                                                      */
/* Igor Konnov 2012                                     */

/***** spin: spin.y *****/

/* Copyright (c) 1989-2003 by Lucent Technologies, Bell Laboratories.     */
/* All Rights Reserved.  This software is for educational purposes only.  */
/* No guarantee whatsoever is expressed or implied by the distribution of */
/* this code.  Permission is given to distribute this code provided that  */
/* this introductory message is not removed and no monies are exchanged.  */
/* Software written by Gerard J. Holzmann.  For tool documentation see:   */
/*             http://spinroot.com/                                       */
/* Send all bug-reports and/or questions to: bugs@spinroot.com            */

%{

open Printf

open Lexing
open SpinIr
open SpinlexGlue
open SpinParserState

let met_else = ref false
let fwd_labels = Hashtbl.create 10
let lab_stack = ref []

let push_new_labs () =
    let e = mk_uniq_label () in (* one label for entry to do *)
    let b = mk_uniq_label () in (* one label to break from do/if *)
    lab_stack := (e, b) :: !lab_stack


let pop_labs () = lab_stack := List.tl !lab_stack 

let top_labs () = List.hd !lab_stack

(* it uses tokens, so we cannot move it outside *)
let rec is_expr_symbolic e =
    match e with
    | Const _ -> true
    | Var v -> v#is_symbolic
    | UnEx (op, se) -> op = UMIN && is_expr_symbolic se
    | BinEx (op, le, re) ->
        (List.mem op [PLUS; MINUS; MULT; DIV; MOD])
            && (is_expr_symbolic le) && (is_expr_symbolic re)
    | _ -> false


let curr_pos () =
    let p = Parsing.symbol_start_pos () in
    let fname = if p.pos_fname != "" then p.pos_fname else "<filename>" in
    let col = max (p.pos_cnum - p.pos_bol + 1) 1 in
    (fname, p.pos_lnum, col)


let parse_error s =
    let f, l, c = curr_pos() in
    Printf.printf "%s:%d,%d %s\n" f l c s;
    inc_err_cnt ()


let fatal msg payload =
    let f, l, c = curr_pos() in
    raise (Failure (Printf.sprintf "%s:%d,%d %s %s\n" f l c msg payload))

%}

%token	ASSERT PRINT PRINTM
%token	C_CODE C_DECL C_EXPR C_STATE C_TRACK
%token	RUN LEN ENABLED EVAL PC_VAL
%token	TYPEDEF MTYPE INLINE LABEL OF
%token	GOTO BREAK ELSE SEMI
%token	IF FI DO OD FOR SELECT IN SEP DOTDOT
%token	ATOMIC NON_ATOMIC D_STEP UNLESS
%token  TIMEOUT NONPROGRESS
%token	ACTIVE PROCTYPE D_PROCTYPE
%token	HIDDEN SHOW ISLOCAL
%token	PRIORITY PROVIDED
%token	FULL EMPTY NFULL NEMPTY
%token	<int> CONST                 /* val */
%token  <SpinTypes.var_type> TYPE
%token  <SpinTypes.xu_type> XU			    /* val */
%token	<string> NAME
%token  <string> UNAME
%token  <string> PNAME
%token  <string> INAME		        /* sym */
%token  <string> FNAME		        /* atomic proposition name */
%token	<string> STRING
%token  CLAIM TRACE INIT	LTL	/* sym */
%token  NE EQ LT GT LE GE OR AND BITNOT BITOR BITXOR BITAND ASGN
%token  MULT PLUS MINUS DIV MOD DECR INCR
%token  LSHIFT RSHIFT
%token  COLON DOT COMMA LPAREN RPAREN LBRACE RBRACE LCURLY RCURLY
%token  O_SND SND RCV R_RCV AT
%token  NEVER NOTRACE TRACE ASSERT
%token	ALWAYS EVENTUALLY		    /* ltl */
%token	UNTIL WEAK_UNTIL RELEASE	/* ltl */
%token	NEXT IMPLIES EQUIV          /* ltl */
%token  <string * string> DEFINE
%token  <string> INCLUDE
%token  MACRO_IF MACRO_IFDEF MACRO_ELSE MACRO_ENDIF
%token  <string> MACRO_OTHER
%token  EOF
/* FORSYTE extensions { */
%token  ASSUME SYMBOLIC ALL SOME CARD POR PAND HAVOC
/* FORSYTE extensions } */
/* imaginary tokens not directly used in the grammar, but used in the
   intermediate representations
 */
%token  UMIN NEG VARREF ARR_ACCESS ARR_UPDATE

%right	ASGN
%left	O_SND R_RCV SND RCV
%left	IMPLIES EQUIV			/* ltl */
%left	OR
%left	AND
%left	ALWAYS EVENTUALLY		    /* ltl */
%left	UNTIL WEAK_UNTIL RELEASE	/* ltl */
%right	NEXT				        /* ltl */
%left	BITOR BITXOR BITAND
%left	EQ NE
%left	GT LT GE LE
%left	LSHIFT RSHIFT
%left	PLUS MINUS
%left	MULT DIV MOD
%left	INCR DECR
%right	UMIN BITNOT NEG
%left	DOT
%start program
%type <token SpinIr.prog_unit list * SpinIr.data_type_tab> program
%start expr
%type <token SpinIr.expr> expr
%%

/** PROMELA Grammar Rules **/

program	: units	EOF { ($1, type_tab ()) }
	;

units	: unit      { $1 }
    | units unit    { List.append $1 $2 }
	;

unit	: proc	/* proctype        */    { [Proc $1] }
    | init		/* init            */    { [] }
	| claim		/* never claim        */ { [] }
    | ltl		/* ltl formula        */ { [$1] }
	| events	/* event assertions   */ { [] }
	| one_decl	/* variables, chans   */ { List.map (fun e -> Stmt e) $1 }
	| utype		/* user defined types */ { [] }
	| c_fcts	/* c functions etc.   */ { [] }
	| ns		/* named sequence     */ { [] }
	| SEMI		/* optional separator */ { [] }
    /* FORSYTE extensions */
    | prop_decl /* atomic propositions */ { [Stmt $1] }
	| ASSUME full_expr /* assumptions */
        {
            [Stmt (MAssume (fresh_id (), $2))]
        }
    | PROVIDED NAME LPAREN prargs RPAREN {
        let args = list_to_binex COMMA $4 in
        [Stmt (MExpr (fresh_id (), BinEx (PROVIDED, Var (new_var $2), args)))] }
	| error { fatal "Unexpected top-level statement" ""}
	;

proc	: inst		/* optional instantiator */
	  proctype_name
	  LPAREN decl RPAREN
	  Opt_priority
	  Opt_enabler
	  body	{
                let my_scope = top_scope () in
                let p = new proc my_scope#tab_name $1 in
                let unpack e =
                    match e with    
                    | MDecl (_, v, i) -> v#add_flag HFormalPar; v
                    | _ -> fatal "Not a decl in proctype args" p#get_name
                in
                p#set_args (List.map unpack $4);
                p#set_stmts $8;
                p#add_all_symb my_scope#get_symbs;
                pop_scope ();
                Hashtbl.clear fwd_labels;
                p
            }
        ;

proctype_name: PROCTYPE NAME {
        push_scope (new symb_tab $2)
        }
    | D_PROCTYPE NAME {
        push_scope (new symb_tab $2)
        }
    ;

inst	: /* empty */	{ Const 0 }
    | ACTIVE	{ Const 1 }
    /* FORSYTE extension: any constant + a symbolic arith expression */
    | ACTIVE LBRACE expr RBRACE {
            match $3 with
            | Const i -> Const i
            | Var v ->
                if v#is_symbolic
                then Var v
                else fatal (sprintf "%s is neither symbolic nor a constant" v#get_name) ""
            | _ -> if is_expr_symbolic $3 then $3 else
                fatal "active [..] must be constant or symbolic" ""
        }
    ;

init	: INIT		/* { (* context = $1->sym; *) } */
      Opt_priority
      body		{ (* ProcList *rl;
              rl = ready(context, ZN, $4->sq, 0, ZN, I_PROC);
              runnable(rl, $3?$3->val:1, 1);
              announce(":root:");
              context = ZS; *)
                }
    ;

ltl	: ltl_prefix FNAME ltl_body	{
        set_lexer_normal();
        (* TODO: put it somewhere *)
        Ltl($2, $3)
    }
;

ltl_prefix: LTL
    { set_lexer_ltl() }
;

ltl_body: LCURLY ltl_expr RCURLY { $2 }
    | error		{ fatal "Incorrect inline LTL formula" "" }
    ;

/* this rule is completely different from Spin's ltl_expr  */
ltl_expr:
      LPAREN ltl_expr RPAREN        { $2 }
    | NEG ltl_expr                  { UnEx(NEG, $2) }
    | ltl_expr UNTIL ltl_expr	    { BinEx(UNTIL, $1, $3) }
	| ltl_expr RELEASE ltl_expr	    { BinEx(RELEASE, $1, $3) }
	| ltl_expr WEAK_UNTIL ltl_expr	{ BinEx(WEAK_UNTIL, $1, $3) }
	| ltl_expr IMPLIES ltl_expr     { BinEx(OR, UnEx(NEG, $1), $3) }
	| ltl_expr EQUIV ltl_expr	    { BinEx(EQUIV, $1, $3) }
	| ALWAYS ltl_expr     { UnEx(ALWAYS, $2) }
	| EVENTUALLY ltl_expr { UnEx(EVENTUALLY, $2) }
    | ltl_expr AND ltl_expr         { BinEx(AND, $1, $3) }
    | ltl_expr OR ltl_expr          { BinEx(OR, $1, $3) }
    | FNAME                        
        { let v = new_var $1 in
          (type_tab ())#set_type v (new data_type SpinTypes.TPROPOSITION);
          Var v }
    | FNAME AT FNAME                  { LabelRef($1, $3) }
  /* TODO: implement this later
    | LPAREN expr RPAREN            { }
   */
  /* sorry, next time we support nexttime (hardly ever happens) */
  /*| NEXT ltl_expr       %prec NEG {...} */
	;

claim	: CLAIM	optname	/* { (* if ($2 != ZN)
              {	$1->sym = $2->sym;	(* new 5.3.0 *)
              }
              nclaims++;
              context = $1->sym;
              if (claimproc && !strcmp(claimproc, $1->sym->name))
              {	fatal("claim %s redefined", claimproc);
              }
              claimproc = $1->sym->name; *)
            } */
      body		{ (* (void) ready($1->sym, ZN, $4->sq, 0, ZN, N_CLAIM);
                  context = ZS; *)
                }
    ;

optname : /* empty */	{ (* char tb[32];
              memset(tb, 0, 32);
              sprintf(tb, "never_%d", nclaims);
              $$ = nn(ZN, NAME, ZN, ZN);
              $$->sym = lookup(tb); *)
            }
    | NAME		{ (* $$ = $1; *) }
    ;

events : TRACE	/* { (* context = $1->sym;
              if (eventmap)
                non_fatal("trace %s redefined", eventmap);
              eventmap = $1->sym->name;
              inEventMap++; *)
            } */
      body	{ raise (Not_implemented "TRACE")
            (*
              if (strcmp($1->sym->name, ":trace:") == 0)
              {	(void) ready($1->sym, ZN, $3->sq, 0, ZN, E_TRACE);
              } else
              {	(void) ready($1->sym, ZN, $3->sq, 0, ZN, N_TRACE);
              }
                  context = ZS;
              inEventMap--; *)
            }
    ;

utype	: TYPEDEF NAME	/*	{ (* if (context)
                   fatal("typedef %s must be global",
                        $2->sym->name);
                   owner = $2->sym; *)
                } */
      LCURLY decl_lst LCURLY	{
                raise (Not_implemented "typedef is not supported")
             (* setuname($5); owner = ZS; *) }
    ;

nm	: NAME			{ (* $$ = $1; *) }
    | INAME			{ (* $$ = $1;
                  if (IArgs)
                  fatal("invalid use of '%s'", $1->sym->name); *)
                }
    ;

ns	: INLINE nm LPAREN		/* { (* NamesNotAdded++; *) } */
      args RPAREN		{
                    raise (Not_implemented "inline")
               (* prep_inline($2->sym, $5);
                  NamesNotAdded--; *)
                }
    ;

c_fcts	: ccode			{
                    raise (Not_implemented "c_fcts")
                  (* leaves pseudo-inlines with sym of
                   * type CODE_FRAG or CODE_DECL in global context
                   *)
                }
    | cstate {}
    ;

cstate	: C_STATE STRING STRING	{
                 raise (Not_implemented "c_state")
                (*
                  c_state($2->sym, $3->sym, ZS);
                  has_code = has_state = 1; *)
                }
    | C_TRACK STRING STRING {
                 raise (Not_implemented "c_track")
                 (*
                  c_track($2->sym, $3->sym, ZS);
                  has_code = has_state = 1; *)
                }
    | C_STATE STRING STRING	STRING {
                 raise (Not_implemented "c_state")
                 (*
                  c_state($2->sym, $3->sym, $4->sym);
                  has_code = has_state = 1; *)
                }
    | C_TRACK STRING STRING STRING {
                 raise (Not_implemented "c_track")
                 (*
                  c_track($2->sym, $3->sym, $4->sym);
                  has_code = has_state = 1; *)
                }
    ;

ccode	: C_CODE {
                 raise (Not_implemented "c_code")
                 (* Symbol *s;
                  NamesNotAdded++;
                  s = prep_inline(ZS, ZN);
                  NamesNotAdded--;
                  $$ = nn(ZN, C_CODE, ZN, ZN);
                  $$->sym = s;
                  has_code = 1; *)
                }
    | C_DECL		{
                 raise (Not_implemented "c_decl")
                 (* Symbol *s;
                  NamesNotAdded++;
                  s = prep_inline(ZS, ZN);
                  NamesNotAdded--;
                  s->type = CODE_DECL;
                  $$ = nn(ZN, C_CODE, ZN, ZN);
                  $$->sym = s;
                  has_code = 1; *)
                }
    ;
cexpr	: C_EXPR	{
                 raise (Not_implemented "c_expr")
                 (* Symbol *s;
                  NamesNotAdded++;
                  s = prep_inline(ZS, ZN);
                  NamesNotAdded--;
                  $$ = nn(ZN, C_EXPR, ZN, ZN);
                  $$->sym = s;
                  no_side_effects(s->name);
                  has_code = 1; *)
                }
    ;

body	: LCURLY sequence OS RCURLY    { $2 }
    ;

sequence: step			{ $1 }
    | sequence MS step	{ List.append $1 $3 }
    ;

step    : one_decl		{ $1 }
    | XU vref_lst		{ raise (Not_implemented "XU vref_lst")
        (* setxus($2, $1->val); $$ = ZN; *) }
    | NAME COLON one_decl	{ fatal "label preceding declaration," "" }
    | NAME COLON XU		{ fatal "label predecing xr/xs claim," "" }
    | stmnt			    { $1 }
    | stmnt UNLESS stmnt	{ raise (Not_implemented "unless") }
    ;

vis	: /* empty */	{ HNone }
    | HIDDEN		{ HHide }
    | SHOW			{ HShow }
    | ISLOCAL		{ HTreatLocal }
    | SYMBOLIC      { HSymbolic }
    ;

asgn:	/* empty */ {}
    | ASGN {}
    ;

one_decl: vis TYPE var_list	{
        let fl = $1 and tp = new data_type $2 in
        let add_decl ((v, tp_rhs), init) =
            (* type constraints in the right-hand side *)
            tp#set_nelems tp_rhs#nelems;
            tp#set_nbits tp_rhs#nbits;
            v#add_flag fl;
            (type_tab ())#set_type v tp;
            (top_scope ())#add_symb v#get_name (v :> symb);
            MDecl(fresh_id (), v, init)
        in
        List.map add_decl $3
    }
    | vis UNAME var_list	{
                  raise (Not_implemented "variables of user-defined types")
               (* setutype($3, $2->sym, $1);
                  $$ = expand($3, Expand_Ok); *)
                }
    | vis TYPE asgn LCURLY nlst RCURLY {
                  raise (Not_implemented "mtype = {...}")
                 (*
                  if ($2->val != MTYPE)
                    fatal("malformed declaration", 0);
                  setmtype($5);
                  if ($1)
                    non_fatal("cannot %s mtype (ignored)",
                        $1->sym->name);
                  if (context != ZS)
                    fatal("mtype declaration must be global", 0); *)
                }
    ;

decl_lst: one_decl       	{ $1 }
    | one_decl SEMI
      decl_lst		        { $1 @ $3 }
    ;

decl    : /* empty */		{ [] }
    | decl_lst      	    { $1 }
    ;

vref_lst: varref		{ (* $$ = nn($1, XU, $1, ZN); *) }
    | varref COMMA vref_lst	{ (* $$ = nn($1, XU, $1, $3); *) }
    ;

var_list: ivar              { [$1] }
    | ivar COMMA var_list	{ $1 :: $3 }
    ;

ivar    : vardcl           	{ ($1, Nop "") }
    | vardcl ASGN expr   	{
        ($1, $3)
        (* $$ = $1;
          $1->sym->ini = $3;
          trackvar($1,$3);
          if ($3->ntyp == CONST
          || ($3->ntyp == NAME && $3->sym->context))
          {	has_ini = 2; /* local init */
          } else
          {	has_ini = 1; /* possibly global */
          }
          if (!initialization_ok && split_decl)
          {	nochan_manip($1, $3, 0);
            no_internals($1);
            non_fatal(PART0 "'%s'" PART2, $1->sym->name);
          } *)
        }
    | vardcl ASGN ch_init	{
          raise (Not_implemented "var = ch_init")
       (* $1->sym->ini = $3;
          $$ = $1; has_ini = 1;
          if (!initialization_ok && split_decl)
          {	non_fatal(PART1 "'%s'" PART2, $1->sym->name);
          } *)
        }
    ;

ch_init : LBRACE CONST RBRACE OF
      LCURLY typ_list RCURLY	{
                 raise (Not_implemented "channels")
               (* if ($2->val) u_async++;
                  else u_sync++;
                      {	int i = cnt_mpars($6);
                    Mpars = max(Mpars, i);
                  }
                      $$ = nn(ZN, CHAN, ZN, $6);
                  $$->val = $2->val; *)
                    }
    ;

vardcl  : NAME {
        let v = new_var $1 in
        v#set_proc_name (top_scope ())#tab_name;
        (v, new data_type SpinTypes.TUNDEF)
        }
    | NAME COLON CONST	{
        let v = new_var $1 in
        v#set_proc_name (top_scope ())#tab_name;
        let tp = new data_type SpinTypes.TUNDEF in
        tp#set_nbits $3;
        (v, tp)
        }
    | NAME LBRACE CONST RBRACE	{
        let v = new_var $1 in
        v#set_proc_name (top_scope ())#tab_name;
        let tp = new data_type SpinTypes.TUNDEF in
        tp#set_nelems $3;
        (v, tp)
        }
    ;

varref	: cmpnd		{ $1 (* $$ = mk_explicit($1, Expand_Ok, NAME); *) }
    ;

pfld	: NAME {
            try
                ((top_scope ())#lookup $1)#as_var
            with Symbol_not_found _ ->
                (* XXX: check that the current expression can use that *)
                ((spec_scope ())#lookup $1)#as_var
            }
    | NAME			/* { (* owner = ZS; *) } */
      LBRACE expr RBRACE
            { raise (Not_implemented
                "Array references, e.g., x[y] are not implemented") }
    ;

cmpnd	: pfld			/* { (* Embedded++;
                  if ($1->sym->type == STRUCT)
                    owner = $1->sym->Snm; *)
                } */
      sfld
            {  $1
               (* $$ = $1; $$->rgt = $3;
                  if ($3 && $1->sym->type != STRUCT)
                    $1->sym->type = STRUCT;
                  Embedded--;
                  if (!Embedded && !NamesNotAdded
                  &&  !$1->sym->type)
                   fatal("undeclared variable: %s",
                        $1->sym->name);
                  if ($3) validref($1, $3->lft);
                  owner = ZS; *)
                }
    ;

sfld	: /* empty */		{ }
    | DOT cmpnd %prec DOT	{
         raise (Not_implemented
                "Structure member addressing, e.g., x.y is not implemented")
         (* $$ = nn(ZN, '.', $2, ZN); *) }
    ;

stmnt	: Special		{ $1 (* $$ = $1; initialization_ok = 0; *) }
    | Stmnt			{ $1 (* $$ = $1; initialization_ok = 0;
                  if (inEventMap)
                   non_fatal("not an event", (char * )0); *)
                }
    ;

for_pre : FOR LPAREN			/*	{ (* in_for = 1; *) } */
      varref		{ raise (Not_implemented "for") (* $$ = $4; *) }
    ;

for_post: LCURLY sequence OS RCURLY { raise (Not_implemented "for") } ;

Special :
    | HAVOC LPAREN varref RPAREN { [MHavoc (fresh_id (), $3)]  }
    | varref RCV	/*	{ (* Expand_Ok++; *) } */
      rargs		{ raise (Not_implemented "rcv")
                (* Expand_Ok--; has_io++;
                  $$ = nn($1,  'r', $1, $4);
                  trackchanuse($4, ZN, 'R'); *)
                }
    | varref SND		/* { (* Expand_Ok++; *) } */
      margs		{ raise (Not_implemented "snd")
               (* Expand_Ok--; has_io++;
                  $$ = nn($1, 's', $1, $4);
                  $$->val=0; trackchanuse($4, ZN, 'S');
                  any_runs($4); *)
                }
    | for_pre COLON expr DOTDOT expr RPAREN	/* { (*
                  for_setup($1, $3, $5); in_for = 0; *)
                } */
      for_post	{
          raise (Not_implemented "for_post")
          (* $$ = for_body($1, 1); *)
                }
    | for_pre IN varref RPAREN	/* { (* $$ = for_index($1, $3); in_for = 0; *)
                } */
      for_post	{
          raise (Not_implemented "for_pre")
          (* $$ = for_body($5, 1); *)
                }
    | SELECT LPAREN varref COLON expr DOTDOT expr RPAREN {
                    raise (Not_implemented "select")
                  (* $$ = sel_index($3, $5, $7); *)
                }
    | if_begin options FI	{
                pop_labs ();                
                met_else := false;
                [ MIf (fresh_id (), $2) ]
          }
    | do_begin 		/* one more rule as ocamlyacc does not support multiple
                       actions like this: { (* pushbreak(); *) } */
          options OD {
                (* use of elab/entry_lab is redundant, but we want
                   if/fi and do/od look similar as some algorithms
                   can cut off gotos at the end of an option *)
                let (_, break_lab) = top_labs ()
                    and entry_lab = mk_uniq_label()
                    and opts = $2 in
                met_else := false;
                let do_s =
                    [MLabel (fresh_id (), entry_lab);
                     MIf (fresh_id (), opts);
                     MGoto (fresh_id (), entry_lab);
                     MLabel (fresh_id (), break_lab)]
                in
                pop_labs ();                
                do_s

                (* $$ = nn($1, DO, ZN, ZN);
                  $$->sl = $3->sl;
                  prune_opts($$); *)
                }
    | BREAK     {
                let (_, blab) = top_labs () in
                [MGoto (fresh_id (), blab)]
                (* $$ = nn(ZN, GOTO, ZN, ZN);
                  $$->sym = break_dest(); *)
                }
    | GOTO NAME		{
        try
            let l = (top_scope ())#lookup $2 in
            [MGoto (fresh_id (), l#as_label#get_num)]
        with Symbol_not_found _ ->
            let label_no = mk_uniq_label () in
            Hashtbl.add fwd_labels $2 label_no;
            [MGoto (fresh_id (), label_no)] (* resolve it later *)
     (* $$ = nn($2, GOTO, ZN, ZN);
      if ($2->sym->type != 0
      &&  $2->sym->type != LABEL) {
        non_fatal("bad label-name %s",
        $2->sym->name);
      }
      $2->sym->type = LABEL; *)
    }
| NAME COLON stmnt	{
    let label_no =
        try
            let _ = (top_scope ())#lookup $1 in
            fatal "" (sprintf "Label %s redeclared\n" $1)
        with Symbol_not_found _ ->
            if Hashtbl.mem fwd_labels $1
            then Hashtbl.find fwd_labels $1
            else mk_uniq_label ()
    in
    (top_scope ())#add_symb
        $1 ((new label $1 label_no) :> symb);
    MLabel (fresh_id (), label_no) :: $3
    }
;

Stmnt	: varref ASGN full_expr	{
                    [MExpr (fresh_id (), BinEx(ASGN, Var $1, $3))]
                 (* $$ = nn($1, ASGN, $1, $3);
				  trackvar($1, $3);
				  nochan_manip($1, $3, 0);
				  no_internals($1); *)
				}
	| varref INCR		{
                    let v = Var $1 in
                    [MExpr (fresh_id (), BinEx(ASGN, v, BinEx(PLUS, v, Const 1)))]
                 (* $$ = nn(ZN,CONST, ZN, ZN); $$->val = 1;
				  $$ = nn(ZN,  '+', $1, $$);
				  $$ = nn($1, ASGN, $1, $$);
				  trackvar($1, $1);
				  no_internals($1);
				  if ($1->sym->type == CHAN)
				   fatal("arithmetic on chan", (char * )0); *)
				}
	| varref DECR	{
                    let v = Var $1 in
                    [MExpr (fresh_id (), BinEx(ASGN, v, BinEx(MINUS, v, Const 1)))]
                 (* $$ = nn(ZN,CONST, ZN, ZN); $$->val = 1;
				  $$ = nn(ZN,  '-', $1, $$);
				  $$ = nn($1, ASGN, $1, $$);
				  trackvar($1, $1);
				  no_internals($1);
				  if ($1->sym->type == CHAN)
				   fatal("arithmetic on chan id's", (char * )0); *)
				}
	| PRINT	LPAREN STRING	/* { (* realread = 0; *) } */
	  prargs RPAREN	{
                    [MPrint (fresh_id (), $3, $4)]
                    (* $$ = nn($3, PRINT, $5, ZN); realread = 1; *) }
	| PRINTM LPAREN varref RPAREN	{
                    (* do we actually need it? *)
                    raise (Not_implemented "printm")
                 (* $$ = nn(ZN, PRINTM, $3, ZN); *)
                }
	| PRINTM LPAREN CONST RPAREN	{
                    raise (Not_implemented "printm")
                 (* $$ = nn(ZN, PRINTM, $3, ZN); *)
                }
	| ASSUME full_expr    	{
                    if is_expr_symbolic $2
                    then fatal "active [..] must be constant or symbolic" ""
                    else [MAssume (fresh_id (), $2)] (* FORSYTE ext. *)
                }
	| ASSERT full_expr    	{
                    [MAssert (fresh_id (), $2)]
                (* $$ = nn(ZN, ASSERT, $2, ZN); AST_track($2, 0); *) }
	| ccode			{ raise (Not_implemented "ccode") (* $$ = $1; *) }
	| varref R_RCV		/* { (* Expand_Ok++; *) } */
	  rargs			{
                    raise (Not_implemented "R_RCV")
                (*Expand_Ok--; has_io++;
				  $$ = nn($1,  'r', $1, $4);
				  $$->val = has_random = 1;
				  trackchanuse($4, ZN, 'R'); *)
				}
	| varref RCV		/* { (* Expand_Ok++; *) } */
	  LT rargs GT		{ raise (Not_implemented "rcv")
               (* Expand_Ok--; has_io++;
				  $$ = nn($1, 'r', $1, $5);
				  $$->val = 2;	/* fifo poll */
				  trackchanuse($5, ZN, 'R'); *)
				}
	| varref R_RCV		/* { (* Expand_Ok++; *) } */
	  LT rargs GT		{ raise (Not_implemented "r_rcv")
               (* Expand_Ok--; has_io++;	/* rrcv poll */
				  $$ = nn($1, 'r', $1, $5);
				  $$->val = 3; has_random = 1;
				  trackchanuse($5, ZN, 'R'); *)
				}
	| varref O_SND		/* { (* Expand_Ok++; *) } */
	  margs			{ raise (Not_implemented "o_snd")
               (* Expand_Ok--; has_io++;
				  $$ = nn($1, 's', $1, $4);
				  $$->val = has_sorted = 1;
				  trackchanuse($4, ZN, 'S');
				  any_runs($4); *)
				}
	| full_expr		{ [MExpr (fresh_id (), $1)]
                     (* $$ = nn(ZN, 'c', $1, ZN); count_runs($$); *) }
    | ELSE  		{ met_else := true; [] (* $$ = nn(ZN,ELSE,ZN,ZN); *)
				}
	| ATOMIC   LCURLY sequence OS RCURLY {
              [ MAtomic (fresh_id (), $3) ]
		  }
	| D_STEP LCURLY sequence OS RCURLY {
              [ MD_step (fresh_id (), $3) ]
		  }
	| LCURLY sequence OS RCURLY	{
              $2
	   	  }
	| INAME			/* { (* IArgs++; *) } */
	  LPAREN args RPAREN		/* { (* pickup_inline($1->sym, $4); IArgs--; *) } */
	  Stmnt			{ raise (Not_implemented "inline") (* $$ = $7; *) }
	;

if_begin : IF { push_new_labs () }
;

do_begin : DO { push_new_labs () }
;

options : option		{
            [$1]
            (* $$->sl = seqlist($1->sq, 0); *) }
	| option options	{
            $1 :: $2
            (* $$->sl = seqlist($1->sq, $2->sl); *) }
	;

option_head : SEP   { met_else := false (* open_seq(0); *) }
;

option  : option_head
      sequence OS	{
          if !met_else then MOptElse $2 else MOptGuarded $2
      }
	;

OS	: /* empty */ {}
	| SEMI			{ (* redundant semi at end of sequence *) }
	;

MS	: SEMI			{ (* at least one semi-colon *) }
	| MS SEMI		{ (* but more are okay too   *) }
	;

aname	: NAME		{ $1 }
	| PNAME			{ $1 }
	;

/* should we use full_expr here and then check the tree? */
prop_expr   :
      LPAREN prop_expr RPAREN       { $2 }
    | prop_expr AND prop_expr       { BinEx(AND, $1, $3) }
    | prop_expr OR prop_expr        { BinEx(OR, $1, $3) }
    | NEG prop_expr                 { UnEx(NEG, $2) }
    | NAME AT NAME                  { LabelRef ($1, $3) }
	| prop_arith_expr GT prop_arith_expr		{ BinEx(GT, $1, $3) }
	| prop_arith_expr LT prop_arith_expr		{ BinEx(LT, $1, $3) }
	| prop_arith_expr GE prop_arith_expr		{ BinEx(GE, $1, $3) }
	| prop_arith_expr LE prop_arith_expr		{ BinEx(LE, $1, $3) }
	| prop_arith_expr EQ prop_arith_expr		{ BinEx(EQ, $1, $3) }
	| prop_arith_expr NE prop_arith_expr		{ BinEx(NE, $1, $3) }
    ;

prop_arith_expr    : 
	  LPAREN prop_arith_expr RPAREN		{ $2 }
	| prop_arith_expr PLUS prop_arith_expr		{ BinEx(PLUS, $1, $3) }
	| prop_arith_expr MINUS prop_arith_expr		{ BinEx(MINUS, $1, $3) }
	| prop_arith_expr MULT prop_arith_expr		{ BinEx(MULT, $1, $3) }
	| prop_arith_expr DIV prop_arith_expr		{ BinEx(DIV, $1, $3) }
	| CARD LPAREN prop_expr	RPAREN	{ UnEx(CARD, $3) }
    | NAME /* proctype */ COLON NAME
        {
            let v = new_var $3 in
            v#set_proc_name $1;
            Var (v)
        }
	| NAME
        {
            try
                Var ((global_scope ())#find_or_error $1)#as_var
            with Not_found ->
                fatal "prop_arith_expr: " (sprintf "Undefined global variable %s" $1)
        }
	| CONST { Const $1 }
    ;

expr    : LPAREN expr RPAREN		{ $2 }
	| expr PLUS expr		{ BinEx(PLUS, $1, $3) }
	| expr MINUS expr		{ BinEx(MINUS, $1, $3) }
	| expr MULT expr		{ BinEx(MULT, $1, $3) }
	| expr DIV expr		    { BinEx(DIV, $1, $3) }
	| expr MOD expr		    { BinEx(MOD, $1, $3) }
	| expr BITAND expr		{ BinEx(BITAND, $1, $3) }
	| expr BITXOR expr		{ BinEx(BITXOR, $1, $3) }
	| expr BITOR expr		{ BinEx(BITOR, $1, $3) }
	| expr GT expr		    { BinEx(GT, $1, $3) }
	| expr LT expr		    { BinEx(LT, $1, $3) }
	| expr GE expr		    { BinEx(GE, $1, $3) }
	| expr LE expr		    { BinEx(LE, $1, $3) }
	| expr EQ expr		    { BinEx(EQ, $1, $3) }
	| expr NE expr		    { BinEx(NE, $1, $3) }
	| expr AND expr		    { BinEx(AND, $1, $3) }
	| expr OR  expr		    { BinEx(OR, $1, $3) }
	| expr LSHIFT expr	    { BinEx(LSHIFT, $1, $3) }
	| expr RSHIFT expr	    { BinEx(RSHIFT, $1, $3) }
	| BITNOT expr		    { UnEx(BITNOT, $2) }
	| MINUS expr %prec UMIN	{ UnEx(UMIN, $2) }
	| NEG expr	            { UnEx(NEG, $2) }
    /* our extensions */
    | ALL LPAREN prop_expr RPAREN { UnEx (ALL, $3)  }
    | SOME LPAREN prop_expr RPAREN { UnEx (SOME, $3)  }

    /* not implemented yet */
	| LPAREN expr SEMI expr COLON expr RPAREN {
                  raise (Not_implemented "ternary operator")
                 (*
				  $$ = nn(ZN,  OR, $4, $6);
				  $$ = nn(ZN, '?', $2, $$); *)
				}

	| RUN aname		/* { (* Expand_Ok++;
				  if (!context)
				   fatal("used 'run' outside proctype",
					(char * ) 0); *)
				} */
	  LPAREN args RPAREN
	  Opt_priority		{
                  raise (Not_implemented "run")
               (* Expand_Ok--;
				  $$ = nn($2, RUN, $5, ZN);
				  $$->val = ($7) ? $7->val : 1;
				  trackchanuse($5, $2, 'A'); trackrun($$); *)
				}
	| LEN LPAREN varref RPAREN	{
                  raise (Not_implemented "len")
               (*  $$ = nn($3, LEN, $3, ZN);  *)}
	| ENABLED LPAREN expr RPAREN	{
                  raise (Not_implemented "enabled")
                (* $$ = nn(ZN, ENABLED, $3, ZN);
			 	   has_enabled++; *)
				}
	| varref RCV		/* {(*  Expand_Ok++;  *)} */
	  LBRACE rargs RBRACE		{
                  raise (Not_implemented "rcv")
                (* Expand_Ok--; has_io++;
				      $$ = nn($1, 'R', $1, $5); *)
				}
	| varref R_RCV		/* {(*  Expand_Ok++;  *)} */
	  LBRACE rargs RBRACE		{
                  raise (Not_implemented "r_rcv")
               (* Expand_Ok--; has_io++;
				  $$ = nn($1, 'R', $1, $5);
				  $$->val = has_random = 1; *)
				}
	| varref
        {
            let v = $1 in
            (* TODO: should not be set in printf *)
            v#add_flag HReadOnce;
            Var v
            (*  $$ = $1; trapwonly($1 /*, "varref" */);  *)
        }
	| cexpr			{raise (Not_implemented "cexpr") (*  $$ = $1;  *)}
	| CONST 	{
                    Const $1
               (* $$ = nn(ZN,CONST,ZN,ZN);
				  $$->ismtyp = $1->ismtyp;
				  $$->val = $1->val; *)
				}
	| TIMEOUT		{
                   raise (Not_implemented "timeout")
               (*  $$ = nn(ZN,TIMEOUT, ZN, ZN);  *)}
	| NONPROGRESS		{
                   raise (Not_implemented "nonprogress")
                (* $$ = nn(ZN,NONPROGRESS, ZN, ZN);
				  has_np++; *)
				}
	| PC_VAL LPAREN expr RPAREN	{
                   raise (Not_implemented "pc_value")
                (* $$ = nn(ZN, PC_VAL, $3, ZN);
				  has_pcvalue++; *)
				}
	| PNAME LBRACE expr RBRACE AT NAME
	  			{  raise (Not_implemented "PNAME operations")
                (*  $$ = rem_lab($1->sym, $3, $6->sym);  *)}
	| PNAME LBRACE expr RBRACE COLON pfld
	  			{  raise (Not_implemented "PNAME operations")
                (*  $$ = rem_var($1->sym, $3, $6->sym, $6->lft);  *)}
	| PNAME AT NAME	{
                   raise (Not_implemented "PNAME operations")
                (*  $$ = rem_lab($1->sym, ZN, $3->sym);  *)}
	| PNAME COLON pfld	{
                   raise (Not_implemented "PNAME operations")
                (*  $$ = rem_var($1->sym, ZN, $3->sym, $3->lft);  *)}
    ;

/* FORSYTE extension */
track_ap: /* empty */	{ HNone }
    | HIDDEN		{ HHide }
    | SHOW			{ HShow }
    ;

/* FORSYTE extension */
prop_decl:
    track_ap ATOMIC NAME ASGN atomic_prop {
        let v = new_var($3) in
        v#add_flag $1;
        (type_tab ())#set_type v (new data_type SpinTypes.TPROPOSITION);
        (spec_scope ())#add_symb v#get_name (v :> symb);
        MDeclProp (fresh_id (), v, $5)
    }
    ;

/* FORSYTE extension */
atomic_prop:
      ALL LPAREN prop_expr RPAREN { PropAll ($3)  }
    | SOME LPAREN prop_expr RPAREN { PropSome ($3) }
    | LPAREN prop_expr RPAREN { PropGlob ($2) }
    | LPAREN atomic_prop PAND atomic_prop RPAREN { PropAnd($2, $4) }
    | LPAREN atomic_prop POR atomic_prop RPAREN { PropOr($2, $4) }
    ;

Opt_priority:	/* none */	{(*  $$ = ZN;  *)}
	| PRIORITY CONST	{(*  $$ = $2;  *)}
	;

full_expr:	expr		{ $1 }
	| Expr		{ $1 }
	;

	/* an Expr cannot be negated - to protect Probe expressions */
Expr	: Probe			{raise (Not_implemented "Probe") (*  $$ = $1;  *)}
	| LPAREN Expr RPAREN		{ $2 }
	| Expr AND Expr		{ BinEx(AND, $1, $3) }
	| Expr AND expr		{ BinEx(AND, $1, $3) }
	| expr AND Expr		{ BinEx(AND, $1, $3) }
	| Expr OR  Expr		{ BinEx(OR, $1, $3) }
	| Expr OR  expr		{ BinEx(OR, $1, $3) }
	| expr OR  Expr		{ BinEx(OR, $1, $3) }
	;

Probe	: FULL LPAREN varref RPAREN	{(*  $$ = nn($3,  FULL, $3, ZN);  *)}
	| NFULL LPAREN varref RPAREN	{(*  $$ = nn($3, NFULL, $3, ZN);  *)}
	| EMPTY LPAREN varref RPAREN	{(*  $$ = nn($3, EMPTY, $3, ZN);  *)}
	| NEMPTY LPAREN varref RPAREN	{(*  $$ = nn($3,NEMPTY, $3, ZN);  *)}
	;

Opt_enabler:	/* none */	{(*  $$ = ZN;  *)}
	| PROVIDED LPAREN full_expr RPAREN	{ (* if (!proper_enabler($3))
				  {	non_fatal("invalid PROVIDED clause",
						(char * )0);
					$$ = ZN;
				  } else
					$$ = $3; *)
				 }
	| PROVIDED error	{ (* $$ = ZN;
				  non_fatal("usage: provided ( ..expr.. )",
					(char * )0); *)
				}
	;

basetype: TYPE			{ (* $$->sym = ZS;
				  $$->val = $1->val;
				  if ($$->val == UNSIGNED)
				  fatal("unsigned cannot be used as mesg type", 0); *)
				}
	| UNAME			{ (* $$->sym = $1->sym;
				  $$->val = STRUCT; *)
				}
    | error		{}	/* e.g., unsigned ':' const */
	;

typ_list: basetype		{(*  $$ = nn($1, $1->val, ZN, ZN);  *)}
	| basetype COMMA typ_list	{(*  $$ = nn($1, $1->val, ZN, $3);  *)}
	;

args    : /* empty */		{(*  $$ = ZN;  *)}
	| arg			{(*  $$ = $1;  *)}
	;

prargs  : /* empty */		{ [] (*  $$ = ZN;  *)}
	| COMMA arg		{ $2 (*  $$ = $2;  *)}
	;

margs   : arg			{ (*  $$ = $1;  *)}
	| expr LPAREN arg RPAREN	{(* if ($1->ntyp == ',')
					$$ = tail_add($1, $3);
				  else
				  	$$ = nn(ZN, ',', $1, $3); *)
				}
	;

arg : expr	{ [$1] }
    | expr COMMA arg { $1 :: $3 }
	;

rarg	: varref		{ (* $$ = $1; trackvar($1, $1);
				  trapwonly($1 /*, "rarg" */); *) }
	| EVAL LPAREN expr RPAREN	{ (* $$ = nn(ZN,EVAL,$3,ZN);
				  trapwonly($1 /*, "eval rarg" */); *) }
	| CONST 		{ (* $$ = nn(ZN,CONST,ZN,ZN);
				  $$->ismtyp = $1->ismtyp;
				  $$->val = $1->val; *)
				}
	| MINUS CONST %prec UMIN	{ (* $$ = nn(ZN,CONST,ZN,ZN);
				  $$->val = - ($2->val); *)
				}
	;

rargs	: rarg			{ (* if ($1->ntyp == ',')
					$$ = $1;
				  else
				  	$$ = nn(ZN, ',', $1, ZN); *)
				}
	| rarg COMMA rargs	{ (* if ($1->ntyp == ',')
					$$ = tail_add($1, $3);
				  else
				  	$$ = nn(ZN, ',', $1, $3); *)
				}
	| rarg LPAREN rargs RPAREN	{ (* if ($1->ntyp == ',')
					$$ = tail_add($1, $3);
				  else
				  	$$ = nn(ZN, ',', $1, $3); *)
				}
	| LPAREN rargs RPAREN		{(*  $$ = $2;  *)}
	;

nlst	: NAME			{ (* $$ = nn($1, NAME, ZN, ZN);
				  $$ = nn(ZN, ',', $$, ZN); *) }
	| nlst NAME 		{ (* $$ = nn($2, NAME, ZN, ZN);
				  $$ = nn(ZN, ',', $$, $1); *)
				}
	| nlst COMMA		{ (* $$ = $1; /* commas optional */ *) }
	;
%%

