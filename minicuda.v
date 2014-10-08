(**
  Coq Implementation of
  "A Sound and Complete Abstraction for Reasoning about Parallel Prefix Sums"
 *)

Module Minicuda.
  Require Import ssreflect ssrbool ssrnat eqtype seq.
  
  Inductive var := Var of nat.
  Definition var_eq (v1 v2 : var) :=
    match v1, v2 with
      | Var n1, Var n2 => n1 == n2
    end.

  Lemma var_eqP : Equality.axiom var_eq.
  Proof.
    rewrite / Equality.axiom.
    case=>x [] y.
    case: (@eqP _ x y).
    by move=>-> /=; rewrite eq_refl; apply: ReflectT.
    move=>H /=.
    suff: (x == y = false).
    - by move=>->; apply: ReflectF; case.
      by case:eqP.
  Qed.

  Canonical var_eqMixin := EqMixin var_eqP.
  Canonical nat_eqType := EqType var var_eqMixin.
  
  Inductive type :=
  | Int | Bool.
  Inductive a_type :=
  | Array of type.
  
  Inductive op2 : type -> type -> type -> Set :=
  | And : op2 Bool Bool Bool | Or : op2 Bool Bool Bool | Not : op2 Bool Bool Bool
  | Plus : op2 Int Int Int | Mult : op2 Int Int Int | Le : op2 Int Int Bool.

  Inductive expr := 
  | e_bool of bool 
  | e_nat of nat
  | e_var of var
  | e_arr of var & expr
  | e_op2 : forall {typ1 typ2 typ3}, expr -> op2 typ1 typ2 typ3 -> expr -> expr.
  
  Inductive stmt :=
  | s_var_ass of var & expr
  | s_arr_ass of var & expr & expr
  | s_if of expr & stmts & stmts
  | s_while of expr & stmts
  with stmts :=
  | snil
  | sseq of stmt & stmts.

  Fixpoint sapp (ss1 ss2 : stmts) :=
    match ss1 with
      | snil => ss2
      | sseq s ss1 => sseq s (sapp ss1 ss2)
    end.
  
  Scheme stmt_ind' := Induction for stmt Sort Prop
  with   stmts_ind' := Induction for stmts Sort Prop.
  
  Combined Scheme stmt_ind_mul from stmt_ind', stmts_ind'.
  
  Definition context := var -> option type.
  
  Inductive expr_typing (g : context) (ga : context) : expr -> type -> Prop := 
  | T_bool : forall b : bool, expr_typing g ga (e_bool b) Bool
  | T_nat : forall n : nat, expr_typing g ga (e_nat n) Int
  | T_var : forall (v : var) (ty : type), g v = Some ty -> expr_typing g ga (e_var v) ty
  | T_arr : forall (arr : var) (e_i : expr) (typ : type),
              ga arr = Some typ ->
              expr_typing g ga e_i Int ->
              expr_typing g ga (e_arr arr e_i) typ
  | T_op2 : forall (e1 e2  : expr) (typ1 typ2 typ3 : type) (op : op2 typ1 typ2 typ3),
                   expr_typing g ga e1 typ1 -> expr_typing g ga e2 typ2 ->
                   expr_typing g ga (e_op2 e1 op e2) typ3.

  Inductive stmt_typing (g : context) (ga : context) : stmt -> Prop :=
  | T_ass : forall (v : var) (e : expr) (typ : type),
      expr_typing g ga e typ ->
      g v = Some typ ->
      stmt_typing g ga (s_var_ass v e)
  | T_arr_ass : forall (v : var) (e1 e2 : expr) (T : type),
      ga v = Some T ->
      expr_typing g ga e1 Int ->
      expr_typing g ga e2 T ->
      stmt_typing g ga (s_arr_ass v e1 e2)
  | T_ite : forall (e : expr) (ss1 ss2 : stmts),
      expr_typing g ga e Bool ->
      stmts_typing g ga ss1 ->
      stmts_typing g ga ss2 ->
      stmt_typing g ga (s_if e ss1 ss2)
  | T_loop : forall (e : expr) (ss : stmts),
      expr_typing g ga e Bool ->
      stmts_typing g ga ss ->
      stmt_typing g ga (s_while e ss)
  with stmts_typing (g : context) (ga : context) : stmts -> Prop :=
  | T_nil : stmts_typing g ga snil
  | T_seq : forall (s : stmt) (ss : stmts),
              stmt_typing g ga s -> stmts_typing g ga ss -> stmts_typing g ga (sseq s ss).
  
  Scheme stmt_typing_ind' := Induction for stmt_typing Sort Prop
  with   stmts_typing_ind' := Induction for stmts_typing Sort Prop.
  
  Combined Scheme stmt_typing_ind_mul from stmt_typing_ind', stmts_typing_ind'.

  Inductive value :=
  | V_bool of bool
  | V_nat of nat.

  Definition array_store := nat -> value.
  
  Definition store_v := var -> option value.
  Definition store_a := var -> option array_store.

  Reserved Notation "sv '/' sta '/' e '||' v" (at level 40, sta at level 39, e at level 39, v at level 39).

  Inductive eval_expr (sv : store_v) (sa : store_a) : expr -> value -> Prop :=
  | E_bool : forall b,  sv / sa / (e_bool b) || (V_bool b)
  | E_nat : forall n, sv / sa / (e_nat n) || (V_nat n)
  | E_var : forall v val, sv v = Some val ->
                          sv / sa / (e_var v) || val
  | E_arr : forall arr a_v e_i idx val,
              sa arr = Some a_v ->
              sv / sa / e_i || (V_nat idx) ->
              a_v idx = val ->
              sv / sa / (e_arr arr e_i) || val
  | E_and : forall (e1 e2 : expr) (v1 v2 : bool),
              sv / sa / e1 || (V_bool v1) ->
              sv / sa / e2 || (V_bool v2) ->
              sv / sa / (e_op2 e1 And e2) || (V_bool (andb v1 v2))
  | E_or : forall (e1 e2 : expr) (v1 v2 : bool),
              sv / sa / e1 || (V_bool v1) ->
              sv / sa / e2 || (V_bool v2) ->
              sv / sa / (e_op2 e1 Or e2) || (V_bool (orb v1 v2))
  | E_not : forall (e1 e2 : expr) (v1 v2 : bool),
              sv / sa / e1 || (V_bool v1) ->
              sv / sa / e2 || (V_bool v2) ->
              sv / sa / (e_op2 e1 Not e2) || (V_bool (negb v1))
  | E_plus : forall (e1 e2 : expr) (v1 v2 : nat),
              sv / sa / e1 || (V_nat v1) ->
              sv / sa / e2 || (V_nat v2) ->
              sv / sa / (e_op2 e1 Plus e2) || (V_nat (addn v1 v2))
  | E_mult : forall (e1 e2 : expr) (v1 v2 : nat),
               sv / sa / e1 || (V_nat v1) ->
               sv / sa / e2 || (V_nat v2) ->
               sv / sa / (e_op2 e1 Mult e2) || (V_nat (muln v1 v2))
  | E_le : forall (e1 e2 : expr) (v1 v2 : nat),
              sv / sa / e1 || (V_nat v1) ->
              sv / sa / e2 || (V_nat v2) ->
              sv / sa / (e_op2 e1 Le e2) || (V_bool (leq v1 v2))
  where "sv '/' sta '/' e '||' v" := (eval_expr sv sta e v).

  Inductive value_typing : value -> type -> Prop :=
  | same_bool : forall b, value_typing (V_bool b) Bool
  | same_nat : forall n, value_typing (V_nat n) Int.

  Definition array_typing (arr : array_store) (typ : type) : Prop :=
    forall (idx : nat) (v : value), arr idx = v -> value_typing v typ.

  Definition store_typing (g : context) (sv : store_v) :=
    forall (v : var) (typ : type),
      g v = Some typ -> exists val, sv v = Some val /\ value_typing val typ.

  Definition store_a_typing (ga : context) (sa : store_a) : Prop :=
    forall (v : var) (typ : type),
      ga v = Some typ -> exists arr, sa v = Some arr /\ array_typing arr typ.

  Lemma expr_progress (e : expr) (g ga : context) (sv : store_v) (sa : store_a) (typ : type) :
    expr_typing g ga e typ -> store_typing g sv -> store_a_typing ga sa ->
    exists (v : value), sv / sa / e || v /\ value_typing v typ.
  Proof.
    elim.
    - move=>b _ _; exists (V_bool b); split; [apply: E_bool | apply: same_bool].
    - by move=>n _ _; exists (V_nat n); split; [apply: E_nat | apply: same_nat].
    - rewrite / store_typing; move=> v ty Hty Hstore _.
      pose H := (Hstore v ty Hty).
      case: H=> val [Hsv Htyp].
      exists val; split; first by apply E_var.
      by done.
    - move=> arr idx typ0 Htyarr Hidx IH Hs Hsa.
      pose H := (IH Hs Hsa).
      case: H=> idx_v [Hi Hity].
      inversion Hity; subst.
      case: (Hsa arr typ0 Htyarr)=> arr_v [H  Ha].
      rewrite / array_typing in Ha.
      by exists (arr_v n); split; [apply: E_arr | apply: Ha].
    - move=> e1 e2 typ1 typ2 typ3; case;
      move=> Hty1 IH1 Hty2 IH2 Hs Hsa;
      case: (IH1 Hs Hsa)=> v1 [Hv1 Htyv1];
      case: (IH2 Hs Hsa)=> v2 [Hv2 Htyv2];
      inversion Htyv1; subst; inversion Htyv2; subst.
      + exists (V_bool (andb b b0)); split; first by apply: E_and.
        by apply: same_bool.
      + exists (V_bool (orb b b0)); split; first by apply: E_or.
        by apply: same_bool.
      + exists (V_bool (negb b)); split; first by apply: E_not.
        by apply: same_bool.
      + exists (V_nat (n + n0)); split; first by apply: E_plus.
        by apply: same_nat.
      + exists (V_nat (n * n0)); split; first by apply: E_mult.
        by apply: same_nat.
      + exists (V_bool (leq n n0)); split; first by apply E_le.
        by apply: same_bool.
  Qed.

  Definition update_v (var : var) (v : value) (store : store_v) := fun var' =>
    if var' == var then Some v else store var'.
  Definition update_a (arr : var) (i : nat) (v : value) (store_a : store_a) := fun arr' =>
    if arr == arr' then
      if store_a arr is Some val_a then
        Some (fun i' => if i' == i then v
                  else val_a i)
      else None
    else store_a arr'.
  
  Reserved Notation "'[' '==>' '(' stv ',' sta ',' s1 ')'  '(' stv' ',' sta' ',' s2 ')' ']'"
           (at level 40, sta at level 39, e at level 39,
            stv' at level 39).
  
  Inductive stmt_step (stv : store_v) (sta : store_a) :
    stmts -> store_v -> store_a -> stmts -> Prop :=
  | S_Assign : forall (var : var) (e : expr) (val : value) (rest : stmts), 
      stv / sta / e || val ->
      [ ==> (stv, sta, (sseq (s_var_ass var e) rest)) ((update_v var val stv), sta, rest)]
  | S_Array : forall (e_idx e : expr) (idx : nat) (val : value) (a_var : var) (rest : stmts),
      stv / sta / e_idx || (V_nat idx) ->
      stv / sta / e     || val ->
      [ ==> (stv, sta, (sseq (s_arr_ass a_var e_idx e) rest)) (stv, update_a a_var idx val sta, rest)]
  | S_Ife_T : forall (e_cond : expr) (s_then s_else : stmts) (rest : stmts),
      stv / sta / e_cond || (V_bool true) ->
      [ ==> (stv, sta, sseq (s_if e_cond s_then s_else) rest) (stv, sta, sapp s_then rest)]
  | S_Ife_F : forall (e_cond : expr) (s_then s_else rest : stmts),
      stv / sta / e_cond || (V_bool false) ->
      [ ==> (stv, sta, sseq (s_if e_cond s_then s_else) rest) (stv, sta, sapp s_else rest)]
  | S_loop_T : forall (e_cond : expr) (s_body rest : stmts),
      stv / sta / e_cond || (V_bool true) ->
      [ ==> (stv, sta, sseq (s_while e_cond s_body) rest)
            (stv, sta, sapp s_body (sseq (s_while e_cond s_body) rest))]
  | S_loop_F : forall (e_cond : expr) (s_body rest : stmts),
      stv / sta / e_cond || (V_bool false) ->
      [ ==> (stv, sta, sseq (s_while e_cond s_body) rest)
            (stv, sta, rest)]
    where "'[' '==>' '(' stv ',' sta ',' ss1 ')' '(' stv' ',' sta' ',' ss2 ')' ']'" :=
    (stmt_step stv sta ss1 stv' sta' ss2).

  Lemma stmt_progress (ss : stmts) (g ga : context) (stv : store_v) (sta : store_a) :
    stmts_typing g ga ss -> store_typing g stv -> store_a_typing ga sta ->
    ss = snil \/ exists (stv' : store_v) (sta' : store_a) (ss' : stmts),
                   [ ==> (stv, sta, ss) (stv', sta', ss')].
  Proof.
    elim; first by move=> _ _; left.
    move=> s rest.
    elim.
    - move=> var e typ Hety Hgty Htyss IH Htysv Htysa; right. 
      move: (expr_progress e g ga stv sta typ Hety Htysv Htysa)=>[val [Hval Hty]].
      exists (update_v var val stv); exists sta; exists rest.
      by apply: S_Assign.
    - move=> arr_var e_idx e typ HgaT Hidxty Hety Htyss IH Htysv Htysa; right.
      move: (expr_progress e_idx g ga stv sta Int Hidxty Htysv Htysa)=>[v_idx [Hv_idx Hty_idx]].
      move: (expr_progress e g ga stv sta typ Hety Htysv Htysa)=>[v_e [Hv_e Hty_e]].
      inversion Hty_idx; subst.
      exists stv; exists (update_a arr_var n v_e sta); exists rest.
      by apply: S_Array.
    - move=> e_cond s_then s_else Hty_cond Hty_then Hty_else _ _ Htysv Htysa; right.
      move: (expr_progress e_cond g ga stv sta Bool Hty_cond Htysv Htysa)=>[v_cond [Hv_cond Htyv_cond]].
      exists stv; exists sta.
      inversion Htyv_cond as [b_cond H |]; subst.
      case: b_cond Hv_cond {Htyv_cond}.
      + by exists (sapp s_then rest); apply: S_Ife_T.
      + by exists (sapp s_else rest); apply: S_Ife_F.
    - move=> e_cond s_body Hty_cond Hty_body _ _ Htysv Htysa; right.
      exists stv; exists sta.
      move: (expr_progress e_cond g ga stv sta Bool Hty_cond Htysv Htysa)=>[v_cond [Hv_cond Htyv_cond]].
      inversion Htyv_cond as [b_cond H|]; subst.
      case: b_cond Hv_cond {Htyv_cond}.
      + by exists (sapp s_body (sseq (s_while e_cond s_body) rest)); apply S_loop_T.
        by exists rest; apply S_loop_F.
  Qed.