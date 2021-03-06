Require Import String DepList GPUCSL LibTactics TypedTerm.

Fixpoint typ2Coq T ty :=
  match ty with
  | Skel.TBool | Skel.TZ => T
  | Skel.TTup t1 t2 => (typ2Coq T t1 * typ2Coq T t2)
  end%type.

Definition ptrs ty := typ2Coq Z ty.
Definition vars ty := typ2Coq var ty.
Definition vals ty := typ2Coq val ty.
Definition locs ty := typ2Coq loc ty.
Definition ctys ty := typ2Coq (option CTyp) ty.
Definition exps ty := typ2Coq exp ty.
Definition lexps ty := typ2Coq loc_exp ty.
Definition vartys ty := typ2Coq (var * CTyp) ty.

Fixpoint nat2str (n : nat) : string :=
  match n with
  | O => "O"
  | S n => "S" ++ nat2str n
  end%string.

Lemma nat_to_string_inj n m : nat2str n = nat2str m -> n = m.
Proof.
  revert m; induction n; simpl in *; intros [|m]; simpl; try congruence.
  inversion 1. eauto.
Qed.

Open Scope string.
Lemma string_inj2 s1 s2 s1' s2' : s1 = s1' -> s1 ++ s2 = s1' ++ s2' -> s2 = s2'.
Proof.
  revert s1'; induction s1; intros [|? s1']; simpl in *; try congruence; intros.
  inverts H; inverts H0; subst; eauto.
Qed.

Fixpoint nleaf ty :=
  match ty with
  | Skel.TBool | Skel.TZ => 1
  | Skel.TTup t1 t2 => nleaf t1 + nleaf t2
  end.

Fixpoint locals pref ty i : vars ty :=
  match ty return vars ty with
  | Skel.TBool | Skel.TZ => Var (pref ++ nat2str i)
  | Skel.TTup t1 t2 =>
    (locals pref t1 i, locals pref t2 (nleaf t1 + i))
  end.

Definition arr_params' pref ty i := locals pref ty i.
Fixpoint with_PTyp {ty} : vars ty -> vartys ty :=
  match ty return vars ty -> vartys ty with
  | Skel.TBool => fun x => (x, Ptr Bool)
  | Skel.TZ => fun x => (x, Ptr Int)
  | Skel.TTup t1 t2 => fun xs => (with_PTyp (fst xs), with_PTyp (snd xs))
  end.

Definition arr_params pref ty i := with_PTyp (arr_params' pref ty i).

Definition arr_name n (ty : Skel.Typ) :=
  arr_params ("_arrIn" ++ nat2str n) ty 0.

Definition names_of_array grp d := ls_init 0 d (fun i => "arr" ++ grp ++ nat2str i)%string.
Definition name_of_len grp := ("_sh" ++ grp)%string.
Definition names_of_arg grp d := (name_of_len grp, names_of_array grp d).

Definition grpOfInt n := ("In" ++ nat2str n)%string.

Close Scope string.

Definition len_name n := Var (name_of_len (grpOfInt n)).
Definition out_name (ty : Skel.Typ) :=
  arr_params "_arrOut" ty 0.
Definition outArr ty := locals "_arrOut" ty 0.
Definition inp_len_name := Var (name_of_len "Inp").

Fixpoint foldTup {ty : Skel.Typ} {coqTy A : Type} (sing : coqTy -> A) (f : A -> A -> A) : typ2Coq coqTy ty -> A :=
  match ty return typ2Coq coqTy ty -> A with
  | Skel.TBool | Skel.TZ => fun x => sing x
  | Skel.TTup _ _ => fun xs => f (foldTup sing f (fst xs)) (foldTup sing f (snd xs))
  end.

Fixpoint assigns {ty : Skel.Typ} : vars ty -> ctys ty -> exps ty -> cmd := 
  match ty return vars ty -> ctys ty -> exps ty -> cmd with
  | Skel.TBool | Skel.TZ => fun x ty e => x ::T ty ::= e
  | Skel.TTup t1 t2 => fun xs ctys es => 
    assigns (fst xs) (fst ctys) (fst es) ;;
    assigns (snd xs) (snd ctys) (snd es)
  end.

(* A generating function xs := pl arr + ix. pl denotes array is on shared / global memory *)
Fixpoint reads {ty : Skel.Typ} : vars ty -> ctys ty -> lexps ty -> cmd :=
  match ty return vars ty -> ctys ty -> lexps ty -> cmd with
  | Skel.TBool | Skel.TZ => fun x ty e => x ::T ty ::= [e]
  | Skel.TTup t1 t2 => fun xs ctys es => 
    reads (fst xs) (fst ctys) (fst es) ;; reads (snd xs) (snd ctys) (snd es)
  end.

(* A generating function pl arr + ix := es. pl denotes array is on shared / global memory *)
Fixpoint writes {ty : Skel.Typ} : lexps ty -> exps ty -> cmd :=
  match ty return lexps ty -> exps ty -> cmd with
  | Skel.TBool | Skel.TZ => fun le e  => [le] ::= e
  | Skel.TTup t1 t2 => fun les es => 
    writes (fst les) (fst es) ;; writes (snd les) (snd es)
  end.

Fixpoint locs_offset {ty} : lexps ty -> exp -> lexps ty :=
  match ty return lexps ty -> exp -> lexps ty with
  | Skel.TBool | Skel.TZ => loc_offset
  | Skel.TTup t1 t2 => fun l off => (locs_offset (fst l) off, locs_offset (snd l) off)
  end.

Infix "+os" := (locs_offset) (at level 50, left associativity).

Fixpoint maptys {ty T1 T2} (f : T1 -> T2) : typ2Coq T1 ty -> typ2Coq T2 ty :=
  match ty return typ2Coq T1 ty -> typ2Coq T2 ty with
  | Skel.TBool | Skel.TZ => fun x => f x
  | Skel.TTup t1 t2 => fun xs =>
    (maptys f (fst xs), maptys f (snd xs))
  end.

Definition v2e {ty} : vars ty -> exps ty := @maptys ty _ _ Evar.
Definition e2sh {ty} : exps ty -> lexps ty := @maptys ty _ _ Sh.
Definition e2gl {ty} : exps ty -> lexps ty := @maptys ty _ _ Gl.
Definition v2sh {ty} (xs : vars ty) : lexps ty := (e2sh (v2e xs)).
Definition v2gl {ty} (xs : vars ty) : lexps ty := (e2gl (v2e xs)).

Fixpoint ty2ctys ty : ctys ty :=
  match ty return ctys ty with
  | Skel.TBool => Some Bool
  | Skel.TZ => Some Int
  | Skel.TTup t1 t2 => (ty2ctys t1, ty2ctys t2)
  end.

Definition flatTup : forall {ty : Skel.Typ} {T : Type}, typ2Coq T ty -> list T. 
  refine ((fix flatTup (ty : Skel.Typ) (T : Type) := 
  match ty return typ2Coq T ty -> list T with
  | Skel.TBool | Skel.TZ => fun x => x :: nil
  | Skel.TTup _ _ => fun xs => _
  end)).
  refine (flatTup _ _ (fst xs) ++ flatTup _ _ (snd xs)).
Defined.

Definition str_of_var v : string :=
  match v with
    | Var v => v
  end.

Lemma prefix_cat s1 s2 : prefix s1 (s1 ++ s2) = true.
Proof.
  induction s1; destruct s2; simpl; auto;
  rewrite IHs1; destruct Ascii.ascii_dec; congruence.
Qed.  

Lemma locals_pref grp typ i x :
  List.In x (flatTup (locals grp typ i))
  -> exists j, x = Var (grp ++ nat2str j) /\ i <= j < nleaf typ + i.
Proof.
  revert i; induction typ; simpl; introv H;
  try now (destruct H as [H | []]; substs; simpl; eexists; split; eauto; omega).
  rewrite in_app_iff in H; destruct H as [H|H];
  [apply IHtyp1 in H as [j [? ?]] | apply IHtyp2 in H as [j [? ?]]]; auto;
  substs; eexists; split; eauto; omega.
Qed.

Lemma locals_not_in grp typ n m:
  n + (nleaf typ) <= m ->
  ~In (Var (grp ++ nat2str m)) (flatTup (locals grp typ n)).
Proof.
  revert n m; induction typ; simpl; introv Hle Hc;
  try (destruct Hc as [Hc|[]]; inverts Hc as Hc; apply string_inj2 in Hc; eauto;
       apply nat_to_string_inj in Hc; omega).
  rewrite in_app_iff in Hc; destruct Hc as [Hc | Hc]; [apply IHtyp1 in Hc| apply IHtyp2 in Hc];
  eauto; omega.
Qed.
  
Lemma disjoint_list_app T (ls1 : list T) ls2 :
  disjoint_list ls1 -> disjoint_list ls2
  -> (forall x, In x ls1 -> ~ In x ls2)
  -> disjoint_list (ls1 ++ ls2).
Proof.
  induction ls1; simpl; eauto.
  intros [? ?] ? Hdisj12; rewrite in_app_iff; split; eauto.
  intros [? | ?]; firstorder.
Qed.

Lemma locals_disjoint_ls grp typ n : disjoint_list (flatTup (locals grp typ n)).
Proof.
  revert n; induction typ; simpl; introv; try tauto.
  apply disjoint_list_app; eauto.
  introv H Hc; apply locals_pref in H as [j [? ?]]; apply locals_pref in Hc as [j' [? ?]]; substs.
  inverts H1 as H; apply string_inj2, nat_to_string_inj in H; auto; omega.
Qed.

Fixpoint hmake_idx {A : Type} {B : A -> Type} (s : nat) (f : nat -> forall x : A, B x) (ls : list A) : hlist B ls :=
  match ls with
  | Datatypes.nil => HNil
  | x :: ls' => f s x ::: hmake_idx (S s) f ls'
  end.

Definition gen_params (GA : list Skel.Typ) : hlist (fun ty => var * CTyp * vartys ty)%type GA :=
  let f (i : nat) (ty : Skel.Typ) :=
      (len_name i, Int, arr_name i ty) in
  hmake_idx 0 f GA.

Definition remove_typeinfo : forall {GA : list Skel.Typ},
  hlist (fun ty => var * CTyp * vartys ty)%type GA ->
  hlist (fun ty => var * vars ty)%type GA :=
  hmap (fun ty (x : var * CTyp * vartys ty) => let (len, arr) := x in (fst len, maptys fst arr)).

Open Scope string.

Definition lpref n := "l" ++ nat2str n ++ "_". 
Close Scope string.

Fixpoint concat {A : Type} (l : list (list A)) :=
  match l with
  | nil => nil
  | xs :: xss => (xs ++ concat xss)%list
  end.

Definition flatten_param {A : Type} (x : (A * list A)) := fst x :: snd x.
Definition flatten_params {A : Type} (xs : list (A * list A)) := concat (List.map flatten_param xs).

Fixpoint flatten_avars {GA : list Skel.Typ}
         (xs : hlist (fun ty => (var * CTyp * vartys ty)%type) GA) :=
  match xs with
  | HNil => nil
  | HCons x xs => 
    let '(x, ty, ls) := x in
    ((x, ty) :: flatTup ls) ++ flatten_avars xs
  end.

Fixpoint addTyp {ty} : vars ty -> vartys ty :=
  match ty return vars ty -> vartys ty with 
  | Skel.TBool => fun x => (x, Bool)
  | Skel.TZ => fun x => (x, Int)
  | Skel.TTup t1 t2 => fun xs => (addTyp (fst xs), addTyp (snd xs))
  end.

Definition sh_decl len typ pref st :=
  flatTup (maptys (fun sv => Grid.SD (fst sv) (snd sv) len) (addTyp (locals pref typ st))).
