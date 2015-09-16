Require Import GPUCSL.

Section sum_of_number.
Definition X := (Var 1).
Definition T := (Var 2).
Variable n : nat.

Fixpoint sum n := match n with
  | O => O
  | S n => S n + sum n
end.

Lemma sum_Snn_2 (m : nat) : 
  (m * (m + 1)) / 2 = sum m.
Proof.
  induction m; [simpl; auto|].
  cutrewrite (S m * (S m + 1) = m * (m + 1) + S m * 2); [|ring]; rewrite Nat.div_add; auto.
  rewrite IHm; simpl; omega.
Qed.

Open Scope exp_scope.

Definition INV :=
  Ex x, 
    !(X === Enum' x) **
    !(Enum' (sum x) === T) **
    !(pure (x <= n)).

Definition SUM :=
  T ::= Enum' 0 ;;
  X ::= Enum' 0 ;;
  WhileI (INV) (X < Enum' n) (
    X ::= X + Enum 1 ;;
    T ::= (T + X)).

Ltac ptrn x H :=
  lazymatch type of H with
    | ?X _ _ => cutrewrite (X = (nosimpl (fun x => X)) x) in H; [|auto]
  end.

Ltac magic := match goal with _ => idtac end.

Ltac subA_ex H :=
  let t := fresh in
  let Hf := fresh in
  lazymatch type of H with
    | (Ex _, _) _ _ => eapply scEx in H;
       [|intros t ? ? Hf; subA_normalize_in Hf; magic; ptrn t Hf; exact Hf]
  end.

Lemma eta_ex_dep2 {T U : Type} {S : T -> U -> Type} (f : forall (x : T) (y : U) , S x y) :
  (fun x y => f x y) = f.
Admitted.

Variable ntrd : nat.
Variable tid : Fin.t ntrd.
Goal CSL (fun _ => default ntrd) tid emp SUM !(T === Enum' (n * (n + 1) / 2)).
Proof.
  rewrite sum_Snn_2.
  unfold SUM.
  eapply rule_seq; [hoare_forward |].
  intros ? ? H; subA_ex H; exact H.
  simpl; eapply rule_seq; [repeat hoare_forward |].
  intros ? ? H.
  eapply scEx in H.
  Focus 2.
  intros t ? ? Hf. subA_normalize_in Hf.
  pattern t in Hf. pattern s0 in Hf. pattern h0 in Hf. exact Hf.
  simpl in H.
  destruct H. exact H. unfold INV.
  repeat hoare_forward.
  eapply Hbackward.
  Focus 2. intros ? ? H.
  sep_split_in H. destruct H. sep_combine_in H. ex_intro x H; simpl in H. exact H.
  eapply rule_ex; intros x.
  eapply rule_seq; [repeat hoare_forward |].
  intros ? ? H. subA_ex H. destruct H. simpl in H. ex_intro x0 H. simpl in H. exact H.
  eapply rule_ex; intros y; repeat hoare_forward.
  intros ? ? H. subA_ex H; destruct H; simpl in H. exists (S x); sep_split; sep_split_in H.
  { unfold_conn. rewrite Zpos_P_of_succ_nat. omega. }
  { unfold_conn. simpl. rewrite Zpos_P_of_succ_nat. destruct H. rewrite Nat2Z.inj_add. omega. }
  { unfold_conn;  unfold bexp_to_assn in *. simpl in *. split; destruct H; auto. 
    destruct (Z_lt_dec); [omega|congruence]. } 
  { intros s h H. sep_split_in H. destruct H. sep_split_in H.
    unfold_conn; unfold bexp_to_assn in *; simpl in *; split; destruct H; auto.
    assert (x = n) by (destruct Z_lt_dec; simpl in *; (congruence || omega)).
    congruence. }
  { intros; sep_split_in H.
    exists 0; sep_split; simpl in *; auto.
    - unfold_conn; auto.
    - unfold_conn; split; auto. omega. }
Qed.

Section sum_of_number.