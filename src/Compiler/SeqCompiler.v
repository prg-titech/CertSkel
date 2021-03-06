Require Import String.
Require Import Vector.
Require Import DepList.
Require Import ZArith.
Require Import GPUCSL.
Require Import LibTactics.
Require Import Psatz.
Require Import Monad.
Require Import TypedTerm.
Require Import CUDALib.
Require Import CSLTactics CodeGen Correctness.
Require Import mkMap.
Require Import mkReduce.

Section codegen.
  Definition M a := nat -> (a * nat * list cmd).

  Definition bind_M A B (e : M A) (f : A -> M B) : M B:=
    fun n => let '(v, n, c) := e n in 
             let '(v', n', c') := f v n in
             (v', n', c ++ c')%list.

  Definition get : M nat := fun n => (n, n, nil).
  Definition set n : M unit := fun _ => (tt, n, nil).
End codegen.

Instance M_monad : Monad M := {ret := fun _ x n => (x, n, nil);
                               bind := bind_M}.

Definition fresh : M var :=
  do! n <- get in
  do! _ <- set (n + 1) in
  ret (Var (lpref n ++ nat2str 0)).

Definition freshes ty : M (vars ty) :=
  do! n <- get in
  do! _ <- set (n + 1) in
  ret (locals (lpref n) ty 0).

Definition compile_op {t1 t2 t3 : Skel.Typ} (op : Skel.BinOp t1 t2 t3) :=
  match op in Skel.BinOp t1 t2 t3 return vars t1 -> vars t2 -> exps t3 with
  | Skel.Eplus => fun e1 e2 => e1 +C e2
  | Skel.Emult => fun e1 e2 => e1 *C e2
  | Skel.Eminus => fun e1 e2 => e1 -C e2
  | Skel.Ediv => fun e1 e2 => e1 /C e2
  | Skel.Emod => fun e1 e2 => e1 %C e2
  | Skel.Emin => fun e1 e2 => minC e1 e2
  | Skel.BEq => fun e1 e2 => Ebinop OP_eq e1 e2
  | Skel.Blt => fun e1 e2 => Ebinop OP_lt e1 e2
  end.

Definition setI c : M unit := fun n => (tt, n, c :: nil).

Definition LetE (e : exp) : M var :=
  do! r <- fresh in
  do! _ <- setI (r :T Int ::= e) in
  ret r.

Fixpoint LetEs {ty} : exps ty -> M (vars ty) :=
  match ty return exps ty -> M (vars ty) with 
  | Skel.TBool | Skel.TZ => fun e => LetE e
  | Skel.TTup t1 t2 => fun e => 
    do! r1 <- LetEs (fst e) in
    do! r2 <- LetEs (snd e) in
    ret (r1, r2)
  end.

Definition Read (le : loc_exp) : M (var) :=
  do! r <- fresh in 
  do! _ <- setI (r :T Int ::= [le]) in
  ret r.

Fixpoint Reads {ty} : lexps ty -> M (vars ty) :=
  match ty return lexps ty -> M (vars ty) with 
  | Skel.TBool | Skel.TZ => fun e => Read e
  | Skel.TTup t1 t2 => fun e => 
    do! r1 <- Reads (fst e) in
    do! r2 <- Reads (snd e) in
    ret (r1, r2)
  end.

Definition gen_op {t1 t2 t3 : Skel.Typ} (op : Skel.BinOp t1 t2 t3) (x : vars t1) (y : vars t2) : M (vars t3) :=
  LetEs (compile_op op x y).

Fixpoint ctyps_of_typ (ty : Skel.Typ) :=
  match ty with
  | Skel.TBool => Int :: nil
  | Skel.TZ => Int :: nil
  | Skel.TTup t1 t2 => (ctyps_of_typ t1 ++ ctyps_of_typ t2)%list
  end.

Fixpoint nat_of_member {GS : list Skel.Typ} {ty : Skel.Typ}  (mem : member ty GS) : nat :=
  match mem with
  | HFirst => 0
  | HNext m => S (nat_of_member m)
  end.

Definition seqs := List.fold_right Cseq Cskip.

Lemma safe_seqs_app : forall ntrd BS (tid : Fin.t ntrd) (n : nat) (C1 C2 : list cmd) (s : stack) (h : pheap) (P Q : assn),
   safe_nt BS tid n (seqs C1) s h P
   -> (forall s h m, sat s h P -> m <= n -> safe_nt BS tid n (seqs C2) s h Q)
   -> safe_nt BS tid n (seqs (C1 ++ C2)) s h Q.
Proof.
  induction n; [simpl; eauto|].
  introv.
  intros (Hskip & Hab1 & Hstep1) Hsafe2; split; [|splits].
  - Lemma seqs_skip C : seqs C = Cskip -> C = nil.
    Proof.
      induction C; simpl; try congruence.
    Qed.
    intros Hsk; apply seqs_skip, app_eq_nil in Hsk.
    destruct Hsk; substs; simpl in Hskip.
    forwards*: Hskip; forwards*: Hsafe2; simpl in *; jauto.
  - Lemma seqs_app_abort C1 C2 s h :
      aborts (seqs (C1 ++ C2)) (s, h)
      -> aborts (seqs C1) (s, h) \/ (C1 = nil).
    Proof.
      induction C1; simpl; eauto.
      intros Hab; inverts Hab.
      left; constructor; eauto.
    Qed.
    introv Hdis Heq Hab; forwards* [Hab' | ?]: (>>seqs_app_abort Hab); substs.
    simpl in *; forwards*: Hskip; forwards*: Hsafe2.
  - Lemma seqs_app_access_ok C1 C2 s h :
      access_ok (seqs C1) s h 
      -> (C1 = nil -> access_ok (seqs C2) s h)
      -> access_ok (seqs (C1 ++ C2)) s h.
    Proof.
      induction C1; simpl; eauto.
    Qed.
    apply seqs_app_access_ok; jauto.
    intros; substs; simpl.
    forwards*: Hskip.
    forwards*: Hsafe2; simpl in *.
    jauto.
  - Lemma seqs_app_write_ok C1 C2 s h :
      write_ok (seqs C1) s h 
      -> (C1 = nil -> write_ok (seqs C2) s h)
      -> write_ok (seqs (C1 ++ C2)) s h.
    Proof.
      induction C1; simpl; eauto.
    Qed.
    apply seqs_app_write_ok; jauto.
    intros; substs; simpl.
    forwards*: Hskip.
    forwards*: Hsafe2; simpl in *.
    jauto.
  - introv Hdis Heq Hstep.
    Lemma seqs_app_step C1 C2 C' st1 st2 :
      (seqs (C1 ++ C2)) / st1 ==>s C' / st2
      -> (exists C'', (seqs C1) / st1 ==>s (seqs C'') / st2 /\ seqs (C'' ++ C2) = C')  \/
         (C1 = nil).
    Proof.
      induction C1; simpl; eauto.
      intros Hstep; inverts Hstep.
      - left; exists C1; split; constructor; eauto.
      - left; exists (c1' :: C1); split; eauto; constructor; eauto.
    Qed.
    forwards*[(C' & Hstep' & ?) | ?]: (>>seqs_app_step Hstep); substs; jauto.
    + destruct Hstep1 as (? & ? & Hstep1 & _).
      forwards* (h'' & ph' & ? & ?): Hstep1; exists h'' ph'; splits; jauto.
      applys* IHn; intros; forwards*: (>>Hsafe2 n).
      applys (>>safe_mon); eauto.
    + simpl in Hstep.
      forwards*: Hskip; forwards* (? & ? & Hsafe2'): Hsafe2.
  - Lemma seqs_app_wait C1 C2 j c:
      wait (seqs (C1 ++ C2)) = Some (j, c) ->
      (exists c', c = seqs (c' ++ C2) /\ wait (seqs C1) = Some (j, seqs c')) \/
      C1 = nil /\ wait (seqs C2) = Some (j, c).
    Proof.
      induction C1; simpl. eauto.
      destruct (wait a) as [[? ?]|]; intros H; inverts H.
      left; exists (c0 :: C1); eauto.      
    Qed.
    intros; forwards*[(c & Hwait & Heq) | [Heq Hwait]]: seqs_app_wait; substs.
    + destruct Hstep1 as (? & ? & _ & Hstep1).
      forwards*(phP & ph' & ? & ? & ? & ?): Hstep1.
      eexists phP, ph'; splits; jauto.
      intros; applys* IHn; intros; forwards*: Hsafe2.
      applys* (>>safe_mon).
    + simpl in H.
      forwards*: Hskip.
      forwards* (? & ? & ? & Hsafe2'): Hsafe2.
Qed.    

Definition gen_if {ty} (b : vars Skel.TBool) (g1 : M (vars ty)) (g2 : M (vars ty)) : M (vars ty) :=
  fun n => 
    let '(r1, n, c1) := g1 n in
    let '(r2, n, c2) := g2 n in
    let '(res, n, _) := freshes ty n in
    let c := (Cif (Bunary OP_not (b ==C 0%Z)) 
                  (seqs c1 ;; assigns res (ty2ctys _) (v2e r1))
                  (seqs c2 ;; assigns res (ty2ctys _) (v2e r2))) in
    (res, n, c :: nil).

Fixpoint compile_sexp {GA GS : list Skel.Typ} {typ : Skel.Typ}
         (se : Skel.SExp GA GS typ) : 
  hlist (fun ty => var * vars ty)%type GA ->
  hlist (fun ty => vars ty) GS -> M (vars typ) :=
  match se with
  | Skel.EVar _ _ ty v => fun avenv env => ret (hget env v) : M _
  | Skel.ENum _ _ z => fun avenv env => LetE (Enum z : exps Skel.TZ)
  | Skel.ELet _ _ t1 t2 e1 e2 => fun avenv env =>
    do! e1 <- compile_sexp e1 avenv env in
    compile_sexp e2 avenv (HCons e1 env)
  | Skel.EBin _ _ _ _ _ op e1 e2 => fun avenv env =>
    do! x <- compile_sexp e1 avenv env in
    do! y <- compile_sexp e2 avenv env in
    gen_op op x y
  | Skel.EA _ _ typ va e => fun avenv env =>
    do! i <- compile_sexp e avenv env in
    let (_, aname) := hget avenv va in
    Reads (v2gl aname +os i)
  | Skel.ELen _ _ _ xa => fun avenv env =>
    let (l, _) := hget avenv xa in LetE (l : exps Skel.TZ)
  | Skel.EPrj1 _ _ t1 t2 e => fun avenv env =>
    do! tup <- compile_sexp e avenv env in
    ret (fst tup)
  | Skel.EPrj2 _ _ t1 t2 e => fun avenv env =>
    do! tup <- compile_sexp e avenv env in
    ret (snd tup)
  | Skel.ECons _ _ t1 t2 e1 e2 => fun avenv env =>
    do! r1 <- compile_sexp e1 avenv env in
    do! r2 <- compile_sexp e2 avenv env in
    ret (r1, r2)
  | Skel.EIf _ _ ty e1 e2 e3 => fun avenv env =>
    do! b <- compile_sexp e1 avenv env in
    gen_if b (compile_sexp e2 avenv env) (compile_sexp e3 avenv env)
  end%list.

Instance eq_type_nat : eq_type nat := {eq_dec := eq_nat_dec}.

Fixpoint map_opt {A B : Type} (f : A -> option B) (xs : list A) : option (list B) :=
  sequence (map f xs).

Definition opt_def {A : Type} (o : option A) d :=
  match o with
  | Some x => x
  | None => d
  end.

Fixpoint type_of_func (n : nat) :=
  match n with
  | O => (cmd * list exp)%type
  | S n => list var -> type_of_func n
  end.

Definition evalM {a : Type} (m : M a) (n : nat) : cmd * a :=
  let '(x, _, c) := m n in (seqs c, x).

Fixpoint dumy_fun_n n x :=
  match n return type_of_func n with
  | O => x
  | S n => fun y => dumy_fun_n n x
  end.

Definition compile_func {GA fty} (body : Skel.Func GA fty) :
  AVarEnv GA ->
  type_of_ftyp fty :=
  match body in Skel.Func _ fty' return _ -> type_of_ftyp fty' with
  | Skel.F1 _ _ _ body => fun av xs => evalM (compile_sexp body av (HCons xs HNil)) 0
  | Skel.F2 _ _ _ _ body => fun av xs ys => evalM (compile_sexp body av (HCons ys (HCons xs HNil))) 0
  end.

Fixpoint compile_lexp {GA ty} (le : Skel.LExp GA ty) : AVarEnv GA -> exp :=
  match le in Skel.LExp _ ty return AVarEnv GA -> exp with
  | Skel.LNum _ n => fun _ => n
  | Skel.LLen _ _ a => fun aenv => (fst (hget aenv a))
  | Skel.LMin _ e1 e2 => fun aenv => minC (compile_lexp e1 aenv) (compile_lexp e2 aenv) 
  end.

Definition accessor_of_array {GA tyxa} aenv (arr : member tyxa GA) :=
  compile_func (Skel.F1 _ Skel.TZ _ (Skel.EA _ _ _ arr (Skel.EVar _ _ _ HFirst))) aenv.

Definition compile_AE {GA ty} (ae : Skel.AE GA ty) :
  hlist (fun ty => (var * vars ty))%type GA ->
  ((var -> (cmd * vars ty))) :=
  match ae with
  | Skel.DArr _ _ f len => compile_func f
  | Skel.VArr _ _ xa => fun avar_env =>
    let get := accessor_of_array avar_env xa in
    get
  end.

Definition compile_AE_len {GA ty}
           (ae : Skel.AE GA ty) : AVarEnv GA -> exp :=
  match ae in Skel.AE GA ty return AVarEnv GA -> exp with
  | Skel.DArr _ _ f len =>
    fun aenv =>
    let len' := compile_lexp len aenv in
    len'
  | Skel.VArr _ _ xa => fun aenv =>
    (fst (hget aenv xa))
  end.

Definition lvar n m := Var (lpref n ++ nat2str m).

Definition fvOk (xs : list var) n : Prop :=
  List.Forall (fun x => forall m k, x = lvar m k -> m < n) xs.

Lemma fvOk_weaken fvs n m :
  n <= m -> fvOk fvs n -> fvOk fvs m.
Proof.
  unfold fvOk; intros Hnm H; induction H; constructor; eauto.
  intros; forwards*: H; omega.
Qed.

Lemma fvOk_ge n m k xs :
  fvOk xs n -> n <= m -> ~ In (lvar m k) xs.
Proof.
  unfold fvOk; rewrite Forall_forall; intros H ? Hc.
  intros; forwards*: H; omega.
Qed.

Lemma incl_nil_r T (xs : list T) : 
  incl xs nil -> xs = nil.
Proof.
  induction xs; simpl; eauto.
  intros H; unfold incl in H; forwards*: (H a).
Qed.

Lemma incl_nil_l A (l : list A) : incl nil l.
Proof.
  unfold incl; simpl; tauto.
Qed.

Lemma Forall_incl T (xs ys : list T) P :
  List.Forall P xs -> incl ys xs -> List.Forall P ys.
Proof.
  induction 1; simpl; eauto.
  - intros H; apply incl_nil_r in H; substs; eauto.
  - intros Hincl; rewrite Forall_forall in * ; unfold incl in *.
    intros a Hain.
    forwards* Hincl': (>>Hincl Hain); destruct Hincl' as [? | Hincl']; substs; eauto.
Qed.

Lemma fvOk_incl xs ys n :
  fvOk xs n -> incl ys xs -> fvOk ys n.
Proof. unfold fvOk; eauto using Forall_incl. Qed.

Lemma Forall_app T (xs ys : list T) P :
  List.Forall P xs -> List.Forall P ys -> List.Forall P (xs ++ ys).
Proof.
  induction 1; simpl; eauto.
Qed.

Lemma fvOk_app xs ys n : fvOk xs n -> fvOk ys n -> fvOk (xs ++ ys) n. 
Proof. applys* Forall_app. Qed.

Definition assnInv (P : assn) : nat -> Prop := 
  fun n => (exists xs, fv_assn P xs /\ fvOk xs n).

Definition assnOk (P : assn) (C : cmd) (Q : assn) :=
  forall ntrd BS tid, @CSL ntrd BS tid P C Q.

Definition Gsat {T} (P : assn) (gen : M T) (Q : T -> assn) :=
  forall n n' c v,
    assnInv P n 
    -> gen n = (v, n', c) 
    -> n <= n' /\ assnInv (Q v) n' /\ assnOk P (seqs c) (Q v).

Lemma rule_app_seqs ntrd BS (tid : Fin.t ntrd) P Q R st1 st2 :
  CSL BS tid P (seqs st1) Q
  -> CSL BS tid Q (seqs st2) R
  -> CSL BS tid P (seqs (st1 ++ st2)) R.
Proof.
  unfold CSL; intros H1 H2; intros.
  applys* safe_seqs_app.
Qed.

Lemma rule_bind_c T U P (gen : M T) (gen' : T -> M U) Q R :
  Gsat P gen Q
  -> (forall v, Gsat (Q v) (gen' v) R)
  -> Gsat P (bind gen gen') R.
Proof.
  unfold Gsat, assnInv, bind, ret; simpl; unfold bind_M; simpl.
  intros Hgen Hgen' n n' c v v' Heq.
  destruct (gen n) as [[_v _n] _c] eqn:Heq1.
  destruct (gen' _v _n) as [[_v' _n'] _c'] eqn:Heq2.
  inverts Heq.
  forwards*(? & (? & ? & ?) & ?): Hgen.
  forwards*(? & (? & ? & ?) & ?): Hgen'.
  splits; [omega|eexists; splits|]; jauto.
  unfold assnOk; intros; applys* rule_app_seqs.
Qed.

Lemma rule_backward_c T P (gen : M T) Q Q' :
  Gsat P gen Q
  -> (forall v, Q v |= Q' v)
  -> (forall v xs, fv_assn (Q v) xs -> fv_assn (Q' v) xs)
  -> Gsat P gen Q'.
Proof.
  unfold Gsat, assnInv, assnOk; introv ? ? ? ? ?.
  forwards*(? & (xs & ? & ?) & ?): H; splits; [omega|exists xs; splits*|].
  intros; eapply forward; [|eauto]; eauto.
Qed.

Lemma string_app_assoc a b c : ((a ++ b) ++ c = a ++ b ++ c)%string.
Proof.
  induction a; simpl; congruence.
Qed.

Definition char a := String a EmptyString.
Definition str_in s c := exists s1 s2, s = (s1 ++ char c ++ s2)%string.

Lemma sep_var_inj s1 s1' c s2 s2' :
  (s1 ++ char c ++ s2 = s1' ++ char c ++ s2')%string ->
  ~str_in s1 c -> ~str_in s1' c ->
  s1 = s1'.
Proof.
  revert s1' s2 s2'; induction s1; simpl; introv Heq Hin Hin'.
  - destruct s1'; simpl in *; eauto.
    assert (c <> a).
    { intros Hc; substs.
      apply Hin'.
      exists EmptyString (s1'); eauto. }
    inverts Heq; congruence.
  - destruct s1'; simpl in *; inverts Heq.
    { false; apply Hin; exists EmptyString s1; eauto. }
    forwards*: (>>IHs1 s1'); try congruence.
    { intros (t1 & t2 & Heq'); apply Hin; exists (char a0 ++ t1)%string t2; simpl in *; congruence. }
    { intros (t1 & t2 & Heq'); apply Hin'; exists (char a0 ++ t1)%string t2; simpl in *; congruence. }
Qed.

Definition char_of_string s := match s with
                               | String c _ => c
                               | _ => Ascii.zero
                               end.

Lemma nat_to_str_underbar n :
  ~str_in (nat2str n) (char_of_string "_").
Proof.
  induction n; simpl; intros (s1 & s2 & Heq).
  - destruct s1; simpl in *; try congruence.
    inverts Heq.
    destruct s1; simpl in *; try congruence.
  - destruct s1; simpl in *; try congruence.
    inverts Heq.
    apply IHn; exists s1 s2; eauto.
Qed.

Lemma lpref_inj a b c d : (lpref a ++ b = lpref c ++ d -> a = c /\ b = d)%string.
Proof.
  unfold lpref; intros H.
  inverts H as Heq.
  forwards*: (sep_var_inj (nat2str a) (nat2str c)); simpl in *; eauto using nat_to_str_underbar.
  rewrite !string_app_assoc in Heq; simpl in *; eauto.
  forwards*: (>>nat_to_string_inj H); split; eauto.
  substs; apply string_inj2 in Heq; eauto.
Qed.      

Lemma evar_inj x y : Var x = Var y -> x = y. intros H; inverts* H. Qed.

Lemma fvOk_locals n m k ty :
  n < m
  -> fvOk (flatTup (locals (lpref n) ty k)) m.
Proof.
  revert k; induction ty; intros; [
    constructor; eauto; 
    introv Heq; apply evar_inj in Heq; forwards*(? & ?): (>>lpref_inj Heq); 
    omega..|].
  simpl; apply fvOk_app; eauto.
Qed.

Lemma incl_cons_lr A (x : A) xs ys : incl xs ys -> incl (x :: xs) (x :: ys).
Proof. unfold incl; introv; simpl; intuition. Qed.

Lemma rule_fLet_s R (P : Prop) E (e : exp) v :
  (P -> evalExp E e v)
  -> Gsat (Assn R P E)
          (LetE e)
          (fun x => (Assn R P (x |-> v :: E))).
Proof.
  unfold Gsat, assnInv, assnOk, LetE, bind; simpl; unfold bind_M; simpl.
  introv Heval Hfv Heq; inverts Heq.
  splits; [omega|intros..].
  - destruct Hfv as (xs & ? & ?); exists (Var (lpref n ++ nat2str 0)%string :: xs); splits.
    rewrite fv_assn_base_eq in *; simpl.
    apply incl_cons_lr; eauto.
    constructor; [|eapply fvOk_weaken; [|eauto]; omega].
    introv Heq.
    apply evar_inj, lpref_inj in Heq; omega.
  - apply CSL_prop_prem; intros Hp'.
    eapply rule_seq.
    apply rule_assign; eauto.
    eapply backward; [|apply rule_skip].
    prove_imp.
    rewrite remove_var_disjoint; eauto.
    destruct Hfv as (xs & ? & ?).
    apply fv_assn_base_eq in H3.
    intros Hin.
    forwards*: H3.
    unfold fvOk in H4. 
    rewrite List.Forall_forall in H4.
    forwards*: (>>H4 H5 n 0).
    omega.
Qed.

Lemma rule_ret_s T (v : T) P Q :
  (P |= Q v)
  -> (forall xs, fv_assn P xs -> fv_assn (Q v) xs)
  -> Gsat P (ret v) Q.
Proof.
  unfold Gsat, assnInv, assnOk; introv ? ? ? Heq.
  inverts Heq.
  forwards* (xs & ? & ?): H1.
  splits; [omega|exists xs; splits*|].
  intros; eapply forward; [|apply rule_skip]; eauto.
Qed.

Lemma rule_fLets_s' ty R (P : Prop) E (e : exps ty) v E' :
  (P -> evalExps E e v)
  -> Gsat (Assn R P (E' ++ E))
          (LetEs e)
          (fun x => (Assn R P (x |=> v ++ (E' ++ E)))).
Proof.
  revert E'; induction ty; intros; try now (apply rule_fLet_s; intros; applys* evalExp_app_ig).
  simpl.
  eapply rule_bind_c.
  applys* IHty1.
  { intros; forwards*H': H. }
  introv.
  eapply rule_bind_c.
  rewrite app_assoc.
  applys* IHty2.
  { intros; forwards*: H. }
  intros.
  apply rule_ret_s.
  prove_imp.
  introv; rewrite! fv_assn_base_eq; rewrite <-!app_assoc, !map_app.
  unfold incl; intros Hin a; specialize (Hin a); rewrite !in_app_iff in *; intuition.
Qed.

Lemma rule_fLets_s ty R (P : Prop) E (e : exps ty) v :
  (P -> evalExps E e v)
  -> Gsat (Assn R P E)
          (LetEs e)
          (fun x => (Assn R P (x |=> v ++ E))).
Proof. 
  intros.
  apply (rule_fLets_s' _ _ _ _ _ _ (@nil entry)); jauto.
Qed.

Lemma rule_Read_s R R' (P : Prop) E p l le v :
  (P -> evalLExp E le l)
  -> (P -> R |=R l |->p (p, v) *** R')
  -> Gsat (Assn R P E)
          (Read le)
          (fun x => (Assn R P (x |-> v :: E))).
Proof.
  unfold Gsat, assnInv, assnOk, LetE, bind; simpl; unfold bind_M; simpl.
  introv Heval Hres Hfv Heq; inverts Heq.
  splits; [omega|intros..].
  - destruct Hfv as (xs & ? & ?); exists (Var (lpref n ++ nat2str 0)%string :: xs); splits.
    rewrite fv_assn_base_eq in *; simpl.
    apply incl_cons_lr; eauto.
    constructor; [|eapply fvOk_weaken; [|eauto]; omega].
    introv Heq.
    apply evar_inj, lpref_inj in Heq; omega.
  - apply CSL_prop_prem; intros Hp'.
    eapply rule_seq.
    applys* rule_read; eauto.
    eapply backward; [|apply rule_skip].
    prove_imp.
    rewrite remove_var_disjoint; eauto.
    destruct Hfv as (xs & ? & ?).
    apply fv_assn_base_eq in H3.
    intros Hin.
    forwards*: H3.
    unfold fvOk in H4. 
    rewrite List.Forall_forall in H4.
    forwards*: (>>H4 H5 n 0).
    omega.
Qed.

Lemma rule_Reads_s' ty R R' (P : Prop) E E' p l (le : lexps ty) v :
  (P -> evalLExps E le l)
  -> (P -> R |=R l |=>p (p, v) *** R')
  -> Gsat (Assn R P (E' ++ E))
          (Reads le)
          (fun x => (Assn R P (x |=> v ++ (E' ++ E)))).
Proof.
  revert E' R'; induction ty; intros; try now (applys* rule_Read_s; intros; applys* evalLExp_app_ig).
  simpl.
  eapply rule_bind_c.
  applys* IHty1.
  { intros; forwards*: H. }
  { simpl in H0.
    intros; forwards*: H0.
    rewrite <-res_assoc in H3; apply H3. }
  introv.
  eapply rule_bind_c.
  rewrite app_assoc.
  applys* IHty2.
  { simpl in H; intros; forwards*: H. }
  { intros; simpl in H0; forwards*: H0.
    rewrite <-res_assoc, res_CA in H3; apply H3. }
  intros.
  apply rule_ret_s.
  prove_imp.
  introv; rewrite! fv_assn_base_eq; rewrite <-!app_assoc, !map_app.
  unfold incl; intros Hin a; specialize (Hin a); rewrite !in_app_iff in *; intuition.
Qed.

Lemma rule_Reads_s ty R R' (P : Prop) E p l (le : lexps ty) v :
  (P -> evalLExps E le l)
  -> (P -> R |=R l |=>p (p, v) *** R')
  -> Gsat (Assn R P E)
          (Reads le)
          (fun x => (Assn R P (x |=> v ++ E))).
Proof.
  intros; eapply (rule_Reads_s' _ _ _ _ _ nil); eauto.
Qed.

Lemma incl_app_iff A (xs ys zs : list A) :
  incl (xs ++ ys) zs <-> incl xs zs /\ incl ys zs.
Proof.
  split.
  - induction xs; intros; splits; eauto using incl_nil_l.
    intros x Hin; specialize (H x); simpl in *; rewrite in_app_iff in *; eauto.
    apply H; destruct Hin; eauto.
    forwards*: IHxs.
    intros x Hin; specialize (H x); simpl in *; rewrite in_app_iff in *; eauto.
  - intros; apply incl_app; jauto.
Qed.

Lemma map_flatTup typ (xs : vars typ) vs : 
  map ent_e (xs |=> vs) = flatTup xs.
Proof.
  induction typ; simpl; eauto.
  rewrite map_app, IHtyp1, IHtyp2; eauto.
Qed.

Lemma rule_gen_if ty R (P : Prop) E (b : var) v v1 v2 (g1 : M (vars ty)) g2 R1 R2 P1 P2 E1 E2 :
  (P -> evalExp E b v)
  -> Gsat (Assn R (P /\ (v <> 0%Z)) E) g1 (fun x => Assn R1 P1 (x |=> v1 ++ E1))
  -> Gsat (Assn R (P /\ (v = 0%Z)) E) g2 (fun x => Assn R2 P2 (x |=> v2 ++ E2))
  -> Gsat (Assn R P E) (gen_if b g1 g2) (fun x => Assn R1 P1 (x |=> v1 ++ E1) \\// Assn R2 P2 (x |=> v2 ++ E2) ).
Proof.
  unfold Gsat, assnInv, assnOk, gen_if; introv Heval Hgen1 Hgen2 Hfv Heq.
  destruct (g1 n) as [[r1 n1] c1] eqn:Heq1.
  destruct (g2 n1) as [[r2 n2] c2] eqn:Heq2.
  destruct (freshes ty n2) as [[res n3] ?] eqn:Heq3.
  inverts Heq.
  forwards (xs & ? & ?): Hfv.
  forwards*(? & (xs1 & ? & ?) & ?): Hgen1; [exists xs; splits; jauto|].
  rewrites* fv_assn_base_eq in *.
  forwards*(? & (xs2 & ? & ?) & ?): Hgen2.
  exists xs; splits.
  rewrites* fv_assn_base_eq in *.
  eapply fvOk_weaken; [|eauto]; omega.
  unfold freshes, bind in *; simpl in *; unfold bind_M in *; simpl in *.
  inverts Heq3.
  splits; [omega|..].
  - exists (flatTup (locals (lpref n2) ty 0) ++ xs1 ++ xs2).
    rewrite fv_assn_disj_eq.
    splits.
    exists (flatTup (locals (lpref n2) ty 0) ++ xs1) (flatTup (locals (lpref n2) ty 0) ++ xs2).
    splits; [rewrite !fv_assn_base_eq, map_app, map_flatTup, incl_app_iff in *; 
              splits; [apply incl_appl|apply incl_appr]; jauto..|].
    intros x; rewrite !in_app_iff; splits; [intros [?|[?|?]]|intros [[? | ?]|[? | ?]]]; jauto.
    repeat apply fvOk_app.
    apply fvOk_locals; omega.
    eapply fvOk_weaken; [|eauto]; omega.
    eapply fvOk_weaken; [|eauto]; omega.
  - intros.
    eapply rule_seq.
    { apply CSL_prop_prem; intros Hp'.
      eapply rule_if_disj; [do 2 constructor; eauto; constructor|..].
      - eapply rule_seq; [eauto|].
        eapply forwardR; [eapply rule_assigns|].
        { rewrite fvEs_v2e.
          rewrite fv_assn_base_eq, map_app, incl_app_iff in H2.
          apply not_in_disjoint.
          intros ? ? ?.
          apply locals_pref in H9 as (? & ? & ?); substs.
          destruct H2 as [Hin ?].
          rewrite map_flatTup in Hin; apply Hin in H10.
          unfold fvOk in H3; rewrite Forall_forall in H3.
          forwards*: (>>H3 H10).
          omega. }
        { apply locals_disjoint_ls. }
        { evalExps. }
        rewrites remove_vars_disjoint; [eauto|].
        apply not_in_disjoint; intros x ? ?.
        rewrite fv_assn_base_eq in H2; forwards*: H2.
        apply locals_pref in H10 as (? & ? & ?); substs.
        unfold fvOk in H3; rewrite Forall_forall in H3; forwards*: (>>H3 H11); omega.
      - eapply rule_seq; [simpl; eauto|].
        eapply backward.
        { instantiate (1 := Assn R (P /\ v = 0%Z) E).
          prove_imp. }
        eauto.
        eapply forwardR; [eapply rule_assigns|].
        { rewrite fvEs_v2e.
          rewrite fv_assn_base_eq, map_app, incl_app_iff in H6.
          apply not_in_disjoint.
          intros ? ? ?.
          apply locals_pref in H9 as (? & ? & ?); substs.
          destruct H6 as [Hin ?].
          rewrite map_flatTup in Hin; apply Hin in H10.
          unfold fvOk in H7; rewrite Forall_forall in H7.
          forwards*: (>>H7 H10).
          omega. }
        { apply locals_disjoint_ls. }
        { evalExps. } 
        rewrites remove_vars_disjoint; [eauto|].
        apply not_in_disjoint; intros x ? ?.
        rewrite fv_assn_base_eq in H6; forwards*: H6.
        apply locals_pref in H10 as (? & ? & ?); substs.
        unfold fvOk in H7; rewrite Forall_forall in H7; forwards*: (>>H7 H11); omega. }
    eapply forward; [|apply rule_skip].
    intros s h [Hsat|Hsat]; fold_sat_in Hsat; [left | right]; fold_sat; revert s h Hsat; prove_imp.
    all: rewrites remove_vars_disjoint; [rewrite in_app_iff; eauto|].
Qed.

Require Import Program.

Lemma scInv_incl GS e (svar_env : SVarEnv GS) seval_env ty (m : member ty GS) :
  In e ((hget svar_env m) |=> sc2CUDA (hget seval_env m)) ->
  In e (scInv svar_env seval_env).
Proof.
  unfold scInv; induction GS; simpl in *;
  dependent destruction m; dependent destruction svar_env; dependent destruction seval_env;
  simpl in *; rewrite in_app_iff; eauto.
Qed.

Lemma incl_cons_iff A (x : A) xs ys :
  incl (x :: xs) ys <-> In x ys /\ incl xs ys.
Proof.
  unfold incl; simpl; intuition.
  substs; eauto.
Qed.

Ltac prove_fv_assn := 
  repeat (first [rewrite fv_assn_base_eq | 
                 rewrite map_app |
                 rewrite incl_app_iff |
                 rewrite incl_cons_iff |
                 rewrite map_flatTup]; simpl); jauto.

Lemma compile_op_ok E ty1 ty2 ty3 (op : Skel.BinOp ty1 ty2 ty3) v1 (x1 : vars ty1) v2 (x2 : vars ty2) :
  evalExps E (v2e x1) (sc2CUDA v1)
  -> evalExps E (v2e x2) (sc2CUDA v2)
  -> evalExps E (compile_op op x1 x2) (sc2CUDA (Skel.opDenote _ _ _ op v1 v2)).
Proof.
  induction op; simpl; intros; try (econstructor; eauto).
  equates 1; [econstructor; eauto|]; simpl.
  destruct (Z.eqb_spec v1 v2), eq_dec; omega.
  equates 1; [econstructor; eauto|]; simpl.
  destruct (Z.ltb_spec v1 v2), Z_lt_dec; omega.
Qed.

Lemma aname_eval GA (avar_env : AVarEnv GA) (aptr_env : APtrEnv GA) (aeval_env : AEvalEnv GA)
      ty (m : member ty GA) len aname :
  hget avar_env m = (len, aname) ->
  evalLExps (arrInvVar avar_env aptr_env aeval_env) (v2gl aname) (val2gl (hget aptr_env m)).
Proof.
  unfold arrInvVar; induction GA;
  dependent destruction m;
  dependent destruction avar_env;
  dependent destruction aptr_env; 
  dependent destruction aeval_env; simpl; intros; substs.
  
  apply evalLExps_gl.

  apply evalExps_vars.
  repeat rewrite <-app_assoc; simpl.
  apply incl_cons_ig.
  apply incl_appl; eauto.
  
  destruct p; simpl.

  apply evalLExps_cons_ig, evalLExps_app_ig; eauto.
Qed.

Require Import SetoidClass.

Lemma arrInvRes_unfold GA (aptr_env : APtrEnv GA) (aeval_env : AEvalEnv GA)
      ty (m : member ty GA) p :
  exists R,
        (arrInvRes aptr_env aeval_env p ==
        (arrays (val2gl (hget aptr_env m)) (arr2CUDA (hget aeval_env m)) p *** R))%type.
Proof.
  unfold arrInvRes; induction GA; 
  dependent destruction m;
  dependent destruction aptr_env;
  dependent destruction aeval_env; simpl.
  - eexists; reflexivity.
  - forwards*(R & Heq): (>>IHGA m).
    eexists.
    rewrite Heq.
    rewrite res_CA.
    reflexivity.
Qed.

Lemma nth_error_lt' A (arr : list A) i v : 
  List.nth_error arr i = Some v -> i < length arr.
Proof.
  revert i v; induction arr; intros i v; destruct i; simpl; inversion 1; try omega.
  forwards*: IHarr; omega.
Qed.

Lemma nth_error_lt A (arr : list A) i v : 
  SkelLib.nth_error arr i = Some v -> (0 <= i /\ i < SkelLib.len arr)%Z.
Proof.
  unfold SkelLib.nth_error, SkelLib.Z_to_nat_error.
  destruct Z_le_dec; try now inversion 1.
  unfold ret; simpl; unfold bind_opt.
  intros H; apply nth_error_lt' in H.
  rewrite Nat2Z.inj_lt in H.
  rewrite !Z2Nat.id in H; unfold SkelLib.len; omega.
Qed.

Lemma nth_error_lt_nat A (arr : list A) i v : 
  SkelLib.nth_error arr i = Some v
  -> exists i', Zn i' = i /\ (0 <= i' /\ i' < length arr).
Proof.
  intros; exists (Z.to_nat i).
  forwards*: nth_error_lt.
  rewrites Z2Nat.id; [|lia].
  unfold SkelLib.len in *.
  zify; rewrite Z2Nat.id in *; [|lia..].
  lia.
Qed.

Lemma alen_in GA ty (avar_env : AVarEnv GA) (aptr_env : APtrEnv GA) (aeval_env : AEvalEnv GA) 
  (m : member ty GA) len (arr : vars ty) :
  hget avar_env m = (len, arr) 
  -> In (len |-> Zn (length (hget aeval_env m))) (arrInvVar avar_env aptr_env aeval_env).
Proof.
  unfold arrInvVar; induction GA; 
  dependent destruction m;
  dependent destruction avar_env;
  dependent destruction aptr_env;
  dependent destruction aeval_env; simpl; intros; substs; eauto;
  repeat rewrite <-app_assoc; simpl; eauto.
  destruct p; simpl.
  rewrite in_app_iff; eauto.
Qed.

Class hasDefval A := HD {default : A}.
Global Instance val_hasDefval : hasDefval val := {default := 0%Z}.
Global Instance vals_hasDefval T ty (d : hasDefval T) : hasDefval (typ2Coq T ty) :=
  {default := (fix f ty := match ty return typ2Coq T ty with Skel.TZ | Skel.TBool => default |
                                   Skel.TTup t1 t2 => (f t1, f t2)
                           end) ty}.
Global Instance listA_hasDefval A : hasDefval (list A) := {default := nil}.

Definition get_opt {T} `{_ : hasDefval T} (v : option T) :=
  match v with Some v => v | None => default end. 

Lemma get_opt_eq T (defval : hasDefval T) (opt : option T) v :
  opt = Some v -> v = (get_opt opt).
Proof. intros; substs*. Qed.

Global Instance skelVal_hasDefval (t : Skel.Typ) : hasDefval (Skel.typDenote t) :=
  {| default := defval' |}.

Arguments Skel.sexpDenote {GA GS t} _ _ _.

Ltac unfoldM := unfold bind, ret; simpl; unfold bind_opt, ret.
Ltac unfoldM_in H := unfold bind, ret in H; simpl in H; unfold bind_opt, ret in H; simpl in H.
Ltac destructM H :=
  unfoldM_in H;
  match type of H with
  | None = Some _ => inversion H
  | Some _ = Some _ => inversion H
  | ret _ = Some _ => inversion H
  | match ?t with
    | Some x => _
    | None => _
    end = Some _ => let Heq := fresh "Heq" in destruct t eqn:Heq; simpl in H; destructM H
  | _ => idtac
  end.

Lemma rule_prop_weaken T R (P P' : Prop) E (g : M T) Q :
  (P' -> P)
  -> Gsat (Assn R P E) g Q 
  -> Gsat (Assn R P' E) g Q.
Proof.
  unfold Gsat, assnInv, assnOk; intros.
  destruct H1 as (xs & ? & ?).
  forwards*(? & ? & ?): H0; [exists xs; rewrite fv_assn_base_eq in *; jauto|].
  splits; jauto.
  intros; forwards*: (>>H6 ntrd BS tid).
  eapply backward; [|eauto]; prove_imp.
Qed.

Lemma rule_forward_c T P P' (gen : M T) Q :
  Gsat P gen Q
  -> (P' |= P)
  -> (forall xs, fv_assn P' xs -> fv_assn P xs)
  -> Gsat P' gen Q.
Proof.
  unfold Gsat, assnInv, assnOk; introv ? ? ? ? ?.
  destruct H2 as (xs & ? & ?).
  forwards*(? & (xs' & ? & ?) & ?): H; splits; [omega|exists xs'; splits*|].
  intros; eapply backward; [|eauto]; eauto.
Qed.

Lemma scInv_in_var GS ty (svenv : SVarEnv GS) (seenv : SEvalEnv GS) (m : member ty GS) :
  incl (flatTup (hget svenv m)) (map ent_e (scInv svenv seenv)).
Proof.
  unfold scInv; dependent induction m; simpl in *;
  dependent destruction svenv;
  dependent destruction seenv; simpl; rewrite map_app, map_flatTup.
  - apply incl_appl; eauto.
  - apply incl_appr; eauto.
Qed.

Lemma compile_sexpOk (GA GS : list Skel.Typ) (typ : Skel.Typ)
      (se : Skel.SExp GA GS typ) 
      (svenv : SVarEnv GS)
      (seenv : SEvalEnv GS)
      (avenv : AVarEnv GA)
      (apenv : APtrEnv GA)
      (aeenv : AEvalEnv GA) p resEnv R (P : Prop) :
  (P -> exists v, Skel.sexpDenote se aeenv seenv = Some v)
  -> Gsat (sexpInv svenv seenv avenv apenv aeenv R P resEnv p)
       (compile_sexp se avenv svenv)
       (fun es => sexpInv svenv seenv avenv apenv aeenv R P (es |=> sc2CUDA (get_opt (Skel.sexpDenote se aeenv seenv)) ++ resEnv) p).
Proof.
  unfold sexpInv.
  revert typ se seenv svenv R P resEnv.
  induction se; introv Heval; simpl.
  - apply rule_ret_s.
    { simpl; prove_imp.
      eauto using scInv_incl. }
    introv. 
    prove_fv_assn.
    intros (? & ? & ?); splits; jauto.
    splits; jauto.
    eapply incl_tran; [|apply H0].
    apply scInv_in_var.
  - eapply rule_backward_c.
    apply rule_fLet_s.
    { intros; evalExp. }
    { simpl; intros ?; prove_imp. }
    introv; simpl.
    prove_fv_assn.
  - simpl in Heval.
    eapply rule_bind_c; eauto.
    { eapply IHse1.
      intros; forwards*(? & He): Heval.
      destructM He; jauto. }
    introv.
    eapply rule_bind_c; eauto.
    { eapply IHse2. 
      intros; forwards*(? & He): Heval.
      destructM He; jauto. }
    introv.
    eapply rule_backward_c.
    { apply rule_fLets_s.
      intros; apply compile_op_ok; evalExps. }
    + simpl; intros ?; prove_imp.
      intros; forwards*(? & He): Heval.
      destructM He; jauto.
    + introv; prove_fv_assn.
  - simpl in Heval.
    forwards*(R' & Heq'): (>> arrInvRes_unfold apenv aeenv m p).
    eapply rule_bind_c; eauto.
    { apply IHse; intros; forwards*(v & He): Heval.
      destructM He; jauto. }
    introv; simpl.
    destruct (hget avenv m) as [alen aname] eqn:Heq.
    eapply rule_backward_c.
    { eapply rule_Reads_s.
      { intros; apply eval_locs_off; [|evalExp].
        apply evalLExps_cons_ig, evalLExps_app_ig, evalLExps_app_ig. 
        applys* aname_eval. }
      intros; forwards*(? & He): Heval.
      destructM He.
      rewrite Heq' in H0.
      forwards*(i & ? & ?): nth_error_lt_nat.
      assert (i = Z.to_nat (get_opt (Skel.sexpDenote se aeenv seenv))).
      { rewrite Heq0, <-H1; simpl; rewrite Nat2Z.id; eauto. }
      rewrites (>>arrays_unfold i) in H0.
      { unfold arr2CUDA; rewrite map_length; omega. }
      rewrite <-!res_assoc in *.
      rewrite res_CA in H0; substs. 
      apply H0. }
    { intros ?; simpl; prove_imp.
      { forwards*(? & He): Heval.
        destructM He.
        forwards*(i & ? & ?): nth_error_lt_nat; substs.
        unfold arr2CUDA; rewrites (>>Utils.nth_map (@defval t)); simpl; try omega.
        rewrite Nat2Z.id; omega.
        unfold SkelLib.nth_error, SkelLib.Z_to_nat_error in *.
        unfold bind, ret in *; simpl in *; unfold bind_opt in *.
        destruct Z_le_dec; try omega.
        rewrite Nat2Z.id in *.
        rewrites* (>>SkelLib.nth_error_some (@defval' t)). } }
    { introv; prove_fv_assn. }
  - destruct (hget avenv m) as [l aname] eqn:Heq.
    eapply rule_backward_c; [apply rule_fLet_s|..].
    { intros; evalExp; forwards*: alen_in. }
    intros ?; simpl; prove_imp.
    introv; prove_fv_assn.
  - simpl in Heval.
    eapply rule_bind_c; [applys* IHse1|]. 
    { intros; forwards*(? & He): Heval.
      destructM He; jauto. }
    introv; simpl.
    eapply rule_backward_c.
    { eapply rule_gen_if; [intros; evalExp |..].
      - eapply rule_prop_weaken.
        { intros.
          assert (H': P /\ get_opt (Skel.sexpDenote se1 aeenv seenv) = true); [|apply H'].
          destruct (get_opt _); splits; jauto. }
        assert (P /\ get_opt (Skel.sexpDenote se1 aeenv seenv) = true
                -> exists v2, Skel.sexpDenote se2 aeenv seenv = Some v2).
        { intros; forwards*(? & He): Heval.
          destructM He; simpl in *.
          destruct H; substs; jauto. }
        eapply rule_backward_c.
        rewrite app_comm_cons.
        applys* IHse2.
        { intros ?; simpl. 
          instantiate (3 := P /\ get_opt (Skel.sexpDenote se1 aeenv seenv) = true).
          instantiate (1 := resEnv ++ scInv svenv seenv ++ arrInvVar avenv apenv aeenv).
          prove_imp; eauto. }
        { introv; prove_fv_assn. }
      - eapply rule_prop_weaken.
        { intros.
          assert (H': P /\ get_opt (Skel.sexpDenote se1 aeenv seenv) = false); [|apply H'].
          destruct (get_opt _); splits; jauto; omega. }
        assert (P /\ get_opt (Skel.sexpDenote se1 aeenv seenv) = false
                -> exists v3, Skel.sexpDenote se3 aeenv seenv = Some v3).
        { intros; forwards*(? & He): Heval.
          destructM He; simpl in *.
          destruct H; substs; jauto. }
        eapply rule_backward_c.
        rewrite app_comm_cons.
        applys* IHse3.
        { intros ?; simpl.
          instantiate (3 := P /\ get_opt (Skel.sexpDenote se1 aeenv seenv) = false).
          instantiate (1 := resEnv ++ scInv svenv seenv ++ arrInvVar avenv apenv aeenv).
          prove_imp; eauto. }
        { introv; prove_fv_assn. } }
    intros ?; simpl.
    prove_imp.
    { forwards*(? & He): Heval; destructM He; simpl in *.
      destruct H0; destruct t0; try congruence; rewrites* He. }
    { forwards*(? & He): Heval; destructM He; simpl in *.
      destruct H0; destruct t0; try congruence; rewrites* He. }
    introv; simpl; prove_fv_assn.
    rewrite fv_assn_disj_eq; intros (? & ? & ? & ? & ?).
    revert H H0; prove_fv_assn.
    assert (forall ys, incl ys x \/ incl ys x0 -> incl ys xs).
    { unfold incl; intros ? [? | ?] ?.
      specialize (H a); specialize (H1 a); intuition.
      specialize (H a); specialize (H1 a); intuition. }
    intros; intuition.
  - eapply rule_bind_c. 
    { apply IHse1.
      intros; forwards*(? & He): Heval; destructM He; eexists; eauto. }
    introv.
    eapply rule_bind_c.
    { apply IHse2.
      intros; forwards*(? & He): Heval; destructM He; eexists; eauto. }
    introv. 
    eapply rule_ret_s.
    { prove_imp; 
      intros; forwards*(? & He): Heval; destructM He; substs; eauto. }
    { introv.
      prove_fv_assn. }
  - eapply rule_bind_c.
    { apply IHse.
      intros; forwards*(? & He): Heval; destructM He; eexists; eauto. }
    introv. 
    eapply rule_ret_s.
    { prove_imp; 
      intros; forwards*(? & He): Heval; destructM He; substs; eauto. }
    { introv.
      prove_fv_assn. }
  - eapply rule_bind_c.
    { apply IHse.
      intros; forwards*(? & He): Heval; destructM He; eexists; eauto. }
    introv. 
    eapply rule_ret_s.
    { prove_imp; 
      intros; forwards*(? & He): Heval; destructM He; substs; eauto. }
    { introv.
      prove_fv_assn. }
  - eapply rule_bind_c.
    { apply IHse1.
      intros; forwards*(? & He): Heval; destructM He; substs; eauto. }
    introv.
    eapply rule_backward_c.

    eapply rule_forward_c.
    applys (>>IHse2 aeenv (get_opt (Skel.sexpDenote se1 aeenv seenv) ::: seenv) P resEnv).
    intros; forwards*(?&He): Heval; destructM He; jauto.
    simpl; prove_imp; eauto.
    unfold scInv in *; simpl in *; rewrite in_app_iff in *; intuition.
    
    unfold scInv; simpl.    
    introv; prove_fv_assn.
    unfold scInv; simpl.

    intros ?; prove_imp.
    forwards* (? & He): Heval; destructM He; jauto.

    unfold scInv; simpl.
    introv; prove_fv_assn.
Qed.

Lemma writes_var_seqs_app c1 c2 l :
  In l (writes_var (seqs (c1 ++ c2))) <-> 
  In l (writes_var (seqs c1)) \/ In l (writes_var (seqs c2)).
Proof.
  induction c1; simpl; splits; try tauto.
  all: rewrite !in_app_iff in *.
  all: rewrite IHc1; intuition.
Qed.

Ltac compile_sexp_des Hceq :=
  repeat match type of Hceq with
  | (_, _, _) = (_, _, _) => inverts Hceq
  | context [compile_sexp ?se ?aenv ?senv ?n] => destruct (compile_sexp se aenv senv n) as [[? ?] ?] eqn:?
  | context [LetE ?E ?n] => destruct (LetE E n) as [[? ?] ?] eqn:?
  | context [LetEs ?E ?n] => destruct (LetEs E n) as [[? ?] ?] eqn:?
  | context [Reads ?E ?n] => destruct (Reads E n) as [[? ?] ?] eqn:?
  | context [Read ?E ?n] => destruct (Read E n) as [[? ?] ?] eqn:?
  | context [gen_op ?op ?v1 ?v2] => destruct (gen_op op v1 v2) as [[? ?] ?] eqn:?
  | context [hget ?ls ?m] => destruct (hget ls m) as [? ?] eqn:?
  | context [freshes ?ty ?n] => destruct (freshes ty n) as [? ?] eqn:?
  end.

Lemma LetE_wr_local e n v m c:
  LetE e n = (v, m, c)
  -> forall l, In l (writes_var (seqs c)) -> is_local l.
Proof.
  unfold is_local; intros Heq; inverts Heq; simpl.
  introv [<- | []]; simpl; apply prefix_nil.
Qed.

Lemma LetEs_wr_local T (e : exps T) n v m c:
  LetEs e n = (v, m, c)
  -> forall l, In l (writes_var (seqs c)) -> is_local l.
Proof.
  revert e n m c v.
  induction T; simpl; intros; try now forwards*: LetE_wr_local.
  unfold ret, bind in H; simpl in H; unfold bind_M in H.
  destruct (LetEs (fst e) n) as [[? ?] ?] eqn:Heq1.
  destruct (LetEs (snd e) n0) as [[? ?] ?] eqn:Heq2.
  inverts H.
  rewrite !writes_var_seqs_app in H0; simpl in H0.
  destruct H0 as [? | [? | []]].
  forwards*: IHT1.
  forwards*: IHT2.
Qed.

Lemma Read_wr_local e n v m c:
  Read e n = (v, m, c)
  -> forall l, In l (writes_var (seqs c)) -> is_local l.
Proof.
  unfold is_local; intros Heq; inverts Heq; simpl.
  introv [<- | []]; simpl; apply prefix_nil.
Qed.

Lemma Reads_wr_local T (e : lexps T) n v m c:
  Reads e n = (v, m, c)
  -> forall l, In l (writes_var (seqs c)) -> is_local l.
Proof.
  revert e n m c v.
  induction T; simpl; intros; try now forwards*: Read_wr_local.
  unfold ret, bind in H; simpl in H; unfold bind_M in H.
  destruct (Reads (fst e) n) as [[? ?] ?] eqn:Heq1.
  destruct (Reads (snd e) n0) as [[? ?] ?] eqn:Heq2.
  inverts H.
  rewrite !writes_var_seqs_app in H0; simpl in H0.
  destruct H0 as [? | [? | []]].
  forwards*: IHT1.
  forwards*: IHT2.
Qed.

Lemma LetE_ret_local e n v m c:
  LetE e n = (v, m, c) -> is_local v.
Proof.
  unfold is_local; intros Heq; inverts Heq; simpl.
  apply prefix_nil.
Qed.

Lemma LetEs_ret_local T (e : exps T) n v m c:
  LetEs e n = (v, m, c)
  -> forall l, In l (flatTup v) -> is_local l.
Proof.
  revert e n m c v.
  induction T; simpl; try now (introv Heq [?|[]]; substs; applys* LetE_ret_local).
  introv Heq Hin.
  unfold ret, bind in Heq; simpl in Heq; unfold bind_M in Heq.
  destruct (LetEs (fst e) n) as [[? ?] ?] eqn:Heq1.
  destruct (LetEs (snd e) n0) as [[? ?] ?] eqn:Heq2.
  inverts Heq.
  rewrite in_app_iff in Hin.
  destruct Hin as [? | ?].
  forwards*: IHT1.
  forwards*: IHT2.
Qed.

Lemma Read_ret_local e n v m c:
  Read e n = (v, m, c) -> is_local v.
Proof.
  unfold is_local; intros Heq; inverts Heq; simpl.
  apply prefix_nil.
Qed.

Lemma Reads_ret_local T (e : lexps T) n v m c:
  Reads e n = (v, m, c)
  -> forall l, In l (flatTup v) -> is_local l.
Proof.
  revert e n m c v.
  induction T; simpl; try now (introv Heq [?|[]]; substs; applys* Read_ret_local).
  introv Heq Hin.
  unfold ret, bind in Heq; simpl in Heq; unfold bind_M in Heq.
  destruct (Reads (fst e) n) as [[? ?] ?] eqn:Heq1.
  destruct (Reads (snd e) n0) as [[? ?] ?] eqn:Heq2.
  inverts Heq.
  rewrite in_app_iff in Hin.
  destruct Hin as [? | ?].
  forwards*: IHT1.
  forwards*: IHT2.
Qed.

Lemma barriers_seqs_app c1 c2 :
  barriers (seqs (c1 ++ c2)) = nil
  <-> (barriers (seqs c1) = nil /\ barriers (seqs c2) = nil).
Proof.
  induction c1; simpl; splits; try tauto.
  intros H; apply app_eq_nil in H as [-> ?].
  tauto.
  intros [H ?]; apply app_eq_nil in H as [-> ?].
  tauto.
Qed.

Lemma LetE_barrier e n v m c :
  LetE e n = (v, m, c)
  -> barriers (seqs c) = nil.
Proof.
  inversion 1; simpl; eauto.
Qed.

Lemma LetEs_barrier T (e : exps T) n v m c :
  LetEs e n = (v, m, c)
  -> barriers (seqs c) = nil.
Proof.
  revert e n m c v.
  induction T; simpl; eauto using LetE_barrier.
  introv Heq.
  unfold ret, bind in Heq; simpl in Heq; unfold bind_M in Heq.
  compile_sexp_des Heq.
  rewrite !barriers_seqs_app; splits; jauto.
Qed.

Lemma Read_barrier e n v m c :
  Read e n = (v, m, c)
  -> barriers (seqs c) = nil.
Proof.
  inversion 1; simpl; eauto.
Qed.

Lemma Reads_barrier T (e : lexps T) n v m c :
  Reads e n = (v, m, c)
  -> barriers (seqs c) = nil.
Proof.
  revert e n m c v.
  induction T; simpl; eauto using Read_barrier.
  introv Heq.
  unfold ret, bind in Heq; simpl in Heq; unfold bind_M in Heq.
  compile_sexp_des Heq.
  rewrite !barriers_seqs_app; splits; jauto.
Qed.

Lemma compile_sexp_wr_vars GA GS typ (se : Skel.SExp GA GS typ) avenv svenv :
  forall n m v c, 
    compile_sexp se avenv svenv n = (v, m, c)
    -> forall l, In l (writes_var (seqs c)) -> is_local l.
Proof.
  induction se; simpl; unfold bind, ret, gen_if; simpl; unfold bind_M; simpl in *; introv Heq;
  compile_sexp_des Heq; simpl.

  all: introv; repeat (first [rewrite in_app_iff | rewrite writes_var_seqs_app]; simpl).
  all: intros Hdis; des_disj Hdis.
  all: try first [tauto | now forwards*: IHse | now forwards*: IHse1 | 
                  now forwards*: IHse2 | now forwards*: IHse3 |
                  now forwards*: LetEs_wr_local | now forwards*: LetE_wr_local |
                  now forwards*: Reads_wr_local].
  all: rewrites* assigns_writes in *.
  all: forwards*(? & ? & ?): locals_pref; substs; unfold is_local; simpl; apply prefix_nil.
Qed.  

Definition vars_of_svenv {GS} (svenv : SVarEnv GS) :=
  fold_hlist GS (@app var) [] (fun x m => flatTup (hget svenv m)).

Lemma vars_of_svenv_in_var GS ty (svenv : SVarEnv GS) (m : member ty GS) :
  incl (flatTup (hget svenv m)) (vars_of_svenv svenv).
Proof.
  unfold vars_of_svenv; dependent induction m; simpl in *;
  dependent destruction svenv;
  simpl.
  - apply incl_appl; eauto.
  - apply incl_appr; eauto.
Qed.

Lemma compile_sexp_ret_vars GA GS typ (se : Skel.SExp GA GS typ) avenv svenv :
  forall n m v c, 
    compile_sexp se avenv svenv n = (v, m, c)
    -> forall l, In l (flatTup v) -> is_local l \/ In l (vars_of_svenv svenv).
Proof.
  induction se; simpl; unfold bind, ret, gen_if; simpl; unfold bind_M; simpl in *; introv Heq;
  compile_sexp_des Heq; simpl.

  all: introv; repeat (first [rewrite in_app_iff ]; simpl).
  all: intros Hdis; des_disj Hdis; substs.
  all: try first [tauto | now forwards*: IHse | now forwards*: IHse1 | 
                  now forwards*: IHse2 | now forwards*: IHse3 |
                  now forwards*: LetEs_ret_local | now forwards*: LetE_ret_local |
                  now forwards*: Reads_ret_local].
  all: try now (left; forwards*(? & ? & ?): locals_pref; substs; unfold is_local; simpl; apply prefix_nil).
  all: try now (forwards*: IHse; rewrites in_app_iff; eauto).
  right; forwards*: vars_of_svenv_in_var.
  forwards*: IHse2; unfold vars_of_svenv in *; simpl in *.
  rewrite in_app_iff in *; destruct H as [? | [? | ?]]; eauto.
Qed.

Ltac no_side_cond tac :=
  tac; [now auto_star..|idtac].

Lemma compile_sexp_no_barriers GA GS typ (se : Skel.SExp GA GS typ) avenv svenv :
  forall n m v c, 
    compile_sexp se avenv svenv n = (v, m, c)
    -> barriers (seqs c) = nil.
Proof.
  induction se; simpl; unfold bind, ret, gen_if, gen_op; simpl; unfold bind_M; simpl in *; introv Heq;
  compile_sexp_des Heq; simpl; eauto.
  all: repeat (rewrite barriers_seqs_app; simpl).
  rewrites* (>>LetE_barrier).
  repeat rewrites* (>>IHse1 l).
  repeat rewrites* (>>IHse2 l0).
  rewrites* (>>LetEs_barrier).
  rewrites* (>>IHse).
  rewrites* (>>Reads_barrier).
  rewrites* (>>LetE_barrier).
  repeat rewrites* (>>IHse1 l).
  repeat rewrites* (>>IHse2 l0).
  repeat rewrites* (>>IHse3 l1).
  repeat rewrites* (>>assigns_no_barriers).

  rewrites* (>>IHse1 l).
  repeat rewrites* (>>IHse l).
  repeat rewrites* (>>IHse l).
  repeat rewrites* (>>IHse1 l).
Qed.

Lemma evalExps_env n (tid : Fin.t n)  ty (xs : vars ty) vs R R' P P' Env Env' C BS :
  evalExps Env (v2e xs) vs
  -> CSL BS tid (Assn R P ((xs |=> vs) ++ Env)) C (Assn R' P' Env')
  -> CSL BS tid (Assn R P Env) C (Assn R' P' Env').
Proof.
  intros.
  eapply backwardR; eauto.
  unfold sat; simpl; intros; splits; jauto.
  rewrite env_assns_app; split; jauto.
  destruct H1 as (? & ? & HP0).
  clear H0.
  induction ty; simpl in *; try now forwards*: evalExp_ok.
  apply env_assns_app; split; jauto.
Qed.

Lemma evalExps_app ty Env1 Env2 (es : exps ty) (vs : vals ty) :
  evalExps Env1 es vs -> evalExps (Env1 ++ Env2) es vs.
Proof.
  induction ty; simpl; eauto using evalExp_app1; intros [? ?]; eauto.
Qed.

Lemma compile_func_ok GA fty (f : Skel.Func GA fty) (func : type_of_ftyp fty) (avar_env : AVarEnv GA) : 
  compile_func f avar_env = func -> func_ok avar_env f func.
Proof.
  destruct fty; intros Hcp; simpl in *; substs; dependent destruction f; simpl;
  repeat split; introv; unfold evalM.
  - destruct compile_sexp as [[? ?] ?]eqn:Heq.
    intros; forwards*: compile_sexp_wr_vars.
  - destruct compile_sexp as [[? ?] ?]eqn:Heq.
    intros; simpl; forwards*: compile_sexp_ret_vars.
    unfold vars_of_svenv in *; simpl in *; rewrite in_app_iff in *; simpl in *; tauto.
  - intros; destruct compile_sexp as [[? ?] ?]eqn:Heq.
    applys* (>>evalExps_env xs); try evalExps.
    apply evalExps_app; jauto.
    forwards*Hok: (>>compile_sexpOk s (xs ::: HNil) (vs ::: HNil) avar_env aptr_env aeval_env 
                  p resEnv R P).
    unfold Gsat in *; forwards*(? & ? & Hok'): Hok.
    { unfold assnInv, sexpInv; eexists.
      rewrite fv_assn_base_eq.
      splits; eauto.
      unfold fvOk; rewrite Forall_forall; introv; rewrite !map_app, !in_app_iff.
      unfold is_local, lvar in *.
      intros [? | [? | ?]]; intros.
      (* + rewrite map_flatTup in H4; substs. *)
      (*   forwards*: H0; simpl in *.  *)
      (*   rewrite prefix_nil in H5; congruence. *)
      + apply in_map_iff in H4 as ([? ?] & ? & ?); substs.
        simpl in *; substs.
        forwards*: H1; simpl in *; rewrite prefix_nil in *; congruence.
      + unfold scInv in H4; simpl in H4.
        rewrite map_app, in_app_iff in H4; destruct H4 as [|[]].
        rewrite map_flatTup in H4; substs.
        forwards*: H0; simpl in *.
        rewrite prefix_nil in *; congruence.
      + substs.
        apply in_map_iff in H4 as ([? ?] & ? & ?); substs; simpl in *; substs.
        forwards*: aenv_ok_params; simpl in *; congruence. }
    unfold assnOk in Hok'.
    eapply rule_conseq; [apply Hok'|unfold kernelInv, sexpInv; prove_imp..].
    unfold scInv in *; simpl in *; rewrite in_app_iff in *; simpl in *; tauto.
    simpl in *; rewrites H3; simpl; eauto.
  - intros; destruct compile_sexp as [[? ?] ?] eqn:Heq; simpl.
    forwards*: compile_sexp_no_barriers.
  - destruct compile_sexp as [[? ?] ?]eqn:Heq.
    intros; forwards*: compile_sexp_wr_vars.
  - destruct compile_sexp as [[? ?] ?]eqn:Heq.
    intros; forwards*: compile_sexp_ret_vars.
    unfold vars_of_svenv in *; simpl in *; rewrite !in_app_iff in *; simpl in *; tauto.
  - intros; destruct compile_sexp as [[? ?] ?]eqn:Heq.
    applys* (>>evalExps_env xs); try evalExps.
    apply evalExps_app; jauto.
    applys* (>>evalExps_env ys); try evalExps.
    apply evalExps_app_inv2, evalExps_app; jauto.
    forwards*Hok: (>>compile_sexpOk s (ys ::: xs ::: HNil) (vs2 ::: vs1 ::: HNil) avar_env aptr_env aeval_env 
                  p resEnv R P).
    unfold Gsat in *; forwards*(? & ? & Hok'): Hok.
    { unfold assnInv, sexpInv; eexists.
      rewrite fv_assn_base_eq.
      splits; eauto.
      unfold fvOk; rewrite Forall_forall; introv; rewrite !map_app, !in_app_iff.
      unfold is_local, lvar in *.
      intros [? | [? | ?]]; intros.
      (* + rewrite map_flatTup in H4; substs. *)
      (*   forwards*: H0; simpl in *.  *)
      (*   rewrite prefix_nil in H5; congruence. *)
      + apply in_map_iff in H6 as ([? ?] & ? & ?); substs.
        simpl in *; substs.
        forwards*: H2; simpl in *; rewrite prefix_nil in *; congruence.
      + unfold scInv in H6; simpl in H6.
        rewrite !map_app, !in_app_iff in H6; destruct H6 as [|[|[]]].
        * rewrite map_flatTup in H6; substs.
          forwards*: H1; simpl in *.
          rewrite prefix_nil in *; congruence.
        * rewrite map_flatTup in H6; substs.
          forwards*: H0; simpl in *.
          rewrite prefix_nil in *; congruence.
      + substs.
        apply in_map_iff in H6 as ([? ?] & ? & ?); substs; simpl in *; substs.
        forwards*: aenv_ok_params; simpl in *; congruence. }
    unfold assnOk in Hok'.
    eapply rule_conseq; [apply Hok'|unfold kernelInv, sexpInv; prove_imp..].
    unfold scInv in *; simpl in *; rewrite !in_app_iff in *; simpl in *. tauto.
    simpl in *; rewrites H5; simpl; eauto.
  - intros; destruct compile_sexp as [[? ?] ?] eqn:Heq; simpl.
    forwards*: compile_sexp_no_barriers. 
Qed.

Lemma nth_error_some T (ls : list T) i d :
  i < length ls
  -> List.nth_error ls i = Some (nth i ls d).
Proof.
  revert ls; induction i; simpl; destruct ls; simpl in *; intros; try omega.
  reflexivity.
  intuition.
Qed.

Lemma nth_error_some' T (ls : list T) (i : Z) d :
  (0 <= i < Zn (length ls))%Z
  -> SkelLib.nth_error ls i = Some (nth (Z.to_nat i) ls d).
Proof.
  unfold SkelLib.nth_error; simpl; unfoldM; unfold Monad.bind_opt.
  intros.
  unfold SkelLib.Z_to_nat_error; destruct Z_le_dec; try lia; simpl.
  apply nth_error_some.
  zify; rewrite Z2Nat.id; lia.
Qed.

Lemma mapM_some A B (xs : list A) (ys : list B) i d1 d2 f :
    mapM f xs = Some ys ->
    Some (nth i ys d2) = if lt_dec i (length xs) then f (nth i xs d1) else Some d2.
Proof.
  unfold mapM; revert i ys; induction xs; simpl; introv Heq;
  destruct i, ys; try inverts Heq; simpl; eauto.
  - unfold Monad.bind_opt in *.
    destruct (f a) eqn:Heq1; inverts H0.
    destruct (sequence _); inverts H1.
  - unfold Monad.bind_opt in *.
    destruct (f a) eqn:Heq1; inverts H0.
    destruct (sequence _) eqn:Heq2; inverts H1; eauto.
  - unfold Monad.bind_opt in *.
    destruct (f a) eqn:Heq1; inverts H0.
    destruct (sequence _) eqn:Heq2; inverts H1; eauto.
  - unfold Monad.bind_opt in *.
    destruct (f a) eqn:Heq1; inverts H0.
    destruct (sequence _) eqn:Heq2; inverts H1; eauto.
    erewrite IHxs; destruct (lt_dec i (length xs)), (lt_dec (S i) (S (length xs))); try lia;
    eauto.
Qed.

Lemma mapM_length A B (xs : list A) (ys : list B) f :
  mapM f xs = Some ys -> length ys = length xs.
Proof.
  revert ys; unfold mapM; induction xs; introv.
  - inversion 1; eauto.
  - simpl.
    unfold Monad.bind_opt; destruct (f a), (@sequence _ _ _); simpl;
    destruct ys; inversion 1; substs; simpl; rewrite IHxs; eauto.
Qed.

Lemma compile_AE_ok GA ty (ae : Skel.AE GA ty) (arr : var -> cmd * vars ty) (avar_env : AVarEnv GA) :
  compile_AE ae avar_env = arr -> ae_ok avar_env ae arr.
Proof.
  unfold ae_ok; destruct ae; simpl; intros Hceq Haok.
  - unfold accessor_of_array in Hceq.
    forwards*Hok: (>>compile_func_ok (Skel.Fun1 Skel.TZ t) arr Hceq Haok).
    simpl in *; unfold func_ok1 in *; repeat split; jauto.
    destruct Hok as (? & ? & Hok & ?).
    intros; forwards*: H0.
    intros; applys* Hok.
    introv [? | []]; substs; eauto.
    intros. 
    inverts H2.
    unfold bind, ret; simpl.
    erewrite nth_error_some'.
    rewrite Nat2Z.id.
    reflexivity.
    forwards*: H3; lia.
  - forwards*: (>>compile_func_ok (Skel.Fun1 Skel.TZ cod) Hceq Haok).
    unfold func_ok, func_ok1 in *; simpl in *.
    destruct H as (H1 & H2 & H3 & H4).
    repeat split; [apply H1| intros; forwards*: H2 | idtac | apply H4].
    intros; applys* H3.
    intros ? [? | []]; substs; eauto.
    destruct Z_le_dec; try congruence.

    rewrites* (>>mapM_some i (@defval' cod) H6).
    forwards*: mapM_length.
    
    repeat rewrite SkelLib.seq_length in *.
    destruct lt_dec; try lia.
    repeat rewrite SkelLib.seq_nth.
    destruct lt_dec; eauto.
    intros; forwards*: H7; eauto.
    lia.
Qed.