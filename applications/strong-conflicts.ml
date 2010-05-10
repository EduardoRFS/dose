(**************************************************************************************)
(*  Copyright (c) 2009 Jaap Boender                                                   *)
(*  Copyright (C) 2009 Mancoosi Project                                               *)
(*                                                                                    *)
(*  This library is free software: you can redistribute it and/or modify              *)
(*  it under the terms of the GNU Lesser General Public License as                    *)
(*  published by the Free Software Foundation, either version 3 of the                *)
(*  License, or (at your option) any later version.  A special linking                *)
(*  exception to the GNU Lesser General Public License applies to this                *)
(*  library, see the COPYING file for more information.                               *)
(**************************************************************************************)

(* attempt at computation of strong conflicts with dose3 (TLFKAlibmancoosi) *)

open Common
open ExtLib
open Cudf
open Cudf_types_pp
open Diagnostic

module DGraph = Defaultgraphs.SyntacticDependencyGraph
module G = DGraph.G
module V = DGraph.PkgV
module E = DGraph.PkgE
module SG = Defaultgraphs.PackageGraph.G

let enable_debug () =
    (* enable the progress bars *)
    Common.Util.Progress.enable "Algo.Strongdep.main" ;
    Common.Util.Progress.enable "SyntacticDependencyGraph.dependency_graph" ;
    Common.Util.set_verbosity Common.Util.Summary
;;


let usage = Printf.sprintf "usage: %s [--debug] [--log file] uri" Sys.argv.(0);;
let logfile = ref (open_out "/dev/null");;
let use_strong_conflicts = ref false;;
let remove_triangles = ref true;;
let oc = ref stdout;;

let options = [
  ("--debug", Arg.Unit enable_debug, "Print debug information");
  ("--log", Arg.String (fun s -> close_out !logfile; logfile := open_out s), "Dump log information in file");
  ("--strong", Arg.Set use_strong_conflicts, "Use strong conflicts");
  ("--no-triangles", Arg.Clear remove_triangles, "Do not remove triangles");
  ("--output", Arg.String (fun s -> oc := open_out s), "Use this file for output")
];;

let log s = 
begin
  output_string !logfile s;
  flush !logfile
end;;

let preceding_packages gr p =
begin
  G.fold_pred_e (fun (v, dt, _) l ->
    match dt with
    | E.DirDepends | E.OrDepends ->
      begin
        match v with
        | V.Pkg p' -> p'::l
        | V.Or _ -> G.fold_pred (fun v' l' ->
          match v' with
          | V.Pkg p'' -> p''::l'
          | V.Or _ -> failwith "Inconsistent dependency graph (Or -> Or)"
        ) gr v l
      end
    | _ -> l
   ) gr p []
end;;

type conflict_type =
  Explicit
| Strong
| Other of reason list;;

let nr_conj_pairs = ref 0;;
let nr_other_pairs = ref 0;;
let nr_tested = ref 0;;
(* let pair_ht = Hashtbl.create 32768;; *)
module PGV = Defaultgraphs.PackageGraph.PkgV
module PGE = struct
  type t = (conflict_type * (package * package)) option

  let compare = Pervasives.compare
  let hash = Hashtbl.hash
  let equal x y = ((compare x y) = 0)
  let default = None
end
module PG = Graph.Imperative.Graph.Concrete(PGV);;
let pair_graph = PG.create ();;

let add_pair (c1: package) (c2: package) (ct: conflict_type) (root: package * package) =
begin
  if not (PG.mem_edge pair_graph c1 c2) then
  begin
  PG.add_edge pair_graph c1 c2;
  (* try
    let c1_ht = Hashtbl.find pair_ht c1 in
    if not (Hashtbl.mem c1_ht c2) then
    begin
      Hashtbl.add c1_ht c2 (ct,root); *)
      match ct with
      | Explicit -> incr nr_conj_pairs
      | Strong -> incr nr_conj_pairs
      | Other _ -> incr nr_other_pairs
  end
  (* with Not_found ->
  begin
    let c1_ht = Hashtbl.create 1024 in
    Hashtbl.add c1_ht c2 (ct,root);
    Hashtbl.add pair_ht c1 c1_ht;
    match ct with
    | Explicit -> incr nr_conj_pairs
    | Strong -> incr nr_conj_pairs
    | Other _ -> incr nr_other_pairs
  end *)
end;;

let add_strong_conflict sc_ht c1 c2 root ct =
begin
  let (i, c1_ht) = try Hashtbl.find sc_ht c1 with Not_found -> (0, Hashtbl.create 256) in
  let c1_list = try Hashtbl.find c1_ht root with Not_found -> [] in
  Hashtbl.replace c1_ht root ((c2, ct)::c1_list);
  Hashtbl.replace sc_ht c1 (i+1, c1_ht);
  let (i, c2_ht) = try Hashtbl.find sc_ht c2 with Not_found -> (0, Hashtbl.create 256) in
  let c2_list = try Hashtbl.find c2_ht root with Not_found -> [] in
  Hashtbl.replace c2_ht root ((c1, ct)::c2_list);
  Hashtbl.replace sc_ht c2 (i+1, c2_ht)
end;;

let add_predecessors u gr sd_gr c_pred_ht pred_ht c =
  let visited = Hashtbl.create 128 in
  let rec visit_conj acc = function
    [] -> acc
  | p::r ->
    if Hashtbl.mem visited p then visit_conj acc r
    else
    begin
      Hashtbl.add visited p true;
      visit_conj (p::acc)
        ((SG.pred sd_gr p) @ r)
    end in
  (* let visit_conj p = SG.pred sd_gr p in *)
  let rec visit_disj acc = function
    [] -> acc
  | p::r ->
    if Hashtbl.mem visited p then visit_disj acc r
    else
    begin
      Hashtbl.add visited p true;
      visit_disj (p::acc) ((preceding_packages gr (V.Pkg p)) @ r)
    end in
begin
  let c_pred = try
    visit_conj [] [c] (* visit_conj c *)
  with Invalid_argument _ -> [] in
    Hashtbl.add c_pred_ht c c_pred;
    Hashtbl.add pred_ht c (visit_disj c_pred (List.fold_left
      (fun l p -> l@preceding_packages gr (V.Pkg p)) [] c_pred))
end;;

(* Yes, the debconf-i18n | debconf-english conflict has its very own special
 * function.
 * The idea is that:
 * - language_env -> debconf-i18n | debconf
 * - debconf -> debconf-i18n | debconf-english
 * - debconf-i18n -> debconf
 * - debconf-english -> debconf 
 * which means that the conflict has no unique predecessor (thanks to
 * language-env, but it can be removed anyway because of the cyclical dep. *)

(* Suddenly I realise that this can probably be solved more easily (and
 * certainly more elegantly) by replacing all cyclical stuff by one package
 * (i.e. debconf, debconf-english and debconf-i18n are concentrated into one
 * package) *)
let debconf_special gr c1 c2 c1preds c2preds =
begin
  log (Printf.sprintf "debconf_special for %s and %s\n" (string_of_pkgname c1.package) (string_of_pkgname c2.package));
  (* the common packages between c1preds and c2preds *)
  let common = List.filter (fun z -> List.mem z c2preds) c1preds in
  match common with 
  | [] -> true (* if there are no common packages, keep the conflict *)
  | _ -> begin
  let c1_rest = List.filter (fun z -> not (List.mem z c2preds)) c1preds
  and c2_rest = List.filter (fun z -> not (List.mem z c1preds)) c2preds in
  (* if c1_rest = [] && c2_rest = [] then (* all preds are common *)
  begin
    log (Printf.sprintf "packages %s and %s have all-common predecessors (%s), ignoring..." (string_of_pkgname c1.package) (string_of_pkgname c2.package)
    (String.concat "," (List.map (fun c -> string_of_pkgname c.package) common)));
    add_pair c1 c2 Explicit (c1,c2);
    List.iter (fun p ->
      add_pair p c1 (Other []) (p,c1);
      add_pair p c2 (Other []) (p,c2);
    ) common;
    false
  end
  else *) if List.fold_left (fun acc pred ->
    (* pred_pred: predecessors of common packages *)
    let pred_pred = preceding_packages gr (V.Pkg pred) in
      if (List.mem c1 pred_pred) && (List.mem c2 pred_pred)
      then
        (* if all packages in c1rest and c2rest are in pred_pred,
         * we can discount this conflict too! *)
        List.fold_left (fun acc' p ->
          acc' && List.mem p pred_pred
        ) acc (c1_rest @ c2_rest)
      else
        false
    ) true common then
    (log (Printf.sprintf "Discounting conflict (%s, %s)\n" (string_of_pkgname c1.package) (string_of_pkgname c2.package));
    add_pair c1 c2 Explicit (c1,c2);
    List.iter (fun p ->
      add_pair p c1 (Other []) (p,c1);
      add_pair p c2 (Other []) (p,c2);
    ) common;
    false)
  else
    true
  end
end;;

let _ =
let uri = ref "" in
begin
  at_exit (fun () -> Util.dump Format.err_formatter);
  let _ =
    try Arg.parse options (fun f -> uri := f) usage
    with Arg.Bad s -> failwith s
  in
  if !uri == "" then
  begin
    Arg.usage options (usage ^ "\nNo input file specified");
    exit 2
  end;

  Printf.eprintf "Parsing...%!";
  (* let timer = Util.Timer.create "Parsing" in
  Util.Timer.start timer; *)
  let u = match Input.parse_uri !uri with
  | ("deb", (_,_,_,_,file),_) ->
    begin
      let l = Debian.Packages.input_raw [file] in
      Debian.Debcudf.load_universe l
    end
  | ("hdlist", (_,_,_,_,file),_) ->
    begin
      let l = Rpm.Packages.Hdlists.input_raw [file] in
      Rpm.Rpmcudf.load_universe l
    end
  | ("synth", (_,_,_,_,file),_) ->
    begin
      let l = Rpm.Packages.Synthesis.input_raw [file] in
      Rpm.Rpmcudf.load_universe l
    end
  | (s, _, _) -> failwith (Printf.sprintf "%s: not supported\n" s) in
  (* ignore (Util.Timer.stop timer ()); *)
  Printf.eprintf "done\n%!";

  Printf.eprintf "Packages: %d\n" (universe_size u);
  let u = Depsolver.trim u in
  let slv = Depsolver.load u in
  Printf.eprintf "Trimmed: %d\n" (universe_size u);

  Printf.eprintf "Generating dependency graphs...%!";
  let gr = DGraph.dependency_graph u in
  let sd_gr = if !use_strong_conflicts then
    Strongdeps.strongdeps_univ u
  else
    Strongdeps.conjdeps_univ u in
  Printf.eprintf "done\n%!";
  Printf.eprintf "Nodes in sd_graph: %d\n%!" (Defaultgraphs.PackageGraph.G.nb_vertex sd_gr);

  Printf.eprintf "Enumerating conflicts...%!";
  let timer = Util.Timer.create "Enumerating conflicts" in
  Util.Timer.start timer;
  let m = CudfAdd.build_maps u in
  let cl = Cudf.fold_packages (fun l p ->
    List.fold_left (fun l' c ->
      if c < p then
      begin
       log (Printf.sprintf "%s <-> %s \n" (string_of_pkgname p.package)
          (string_of_pkgname c.package)
        );
        (c,p)::l'
      end
      else
        l'
    ) l (m.CudfAdd.who_conflicts p)
  ) [] u in
  Printf.eprintf "done\n";
  ignore (Util.Timer.stop timer ());
  Printf.eprintf "Explicit conflicts found: %d\n%!" (List.length cl);

  let clf = if !remove_triangles then
  begin
    Printf.eprintf "Removing triangles...%!";
    let timer = Util.Timer.create "Removing triangles" in
    Util.Timer.start timer;
    let clf = List.filter (fun (c1, c2) ->
      match preceding_packages gr (V.Pkg c1) with
      | [] -> true
      | [c1_pred] ->
        begin
          match preceding_packages gr (V.Pkg c2) with
          | [c2_pred] -> 
            begin
              if c1_pred = c2_pred then
              begin
                log (Printf.sprintf "%s and %s share a unique predecessor.\n"
                (string_of_pkgname c1.package) (string_of_pkgname c2.package));
                add_pair c1 c2 Explicit (c1,c2);
                add_pair c1_pred c1 (Other []) (c1_pred,c1);
                add_pair c2_pred c2 (Other []) (c2_pred,c2);
                false
              end
              else true
            end
          | c2_preds -> debconf_special gr c1 c2 [c1_pred] c2_preds
        end
      | c1preds -> debconf_special gr c1 c2 c1preds (preceding_packages gr (V.Pkg c2))
    ) cl in
    Printf.eprintf "done\n";
    ignore (Util.Timer.stop timer ());
    Printf.eprintf "Explicit conflicts left after triangle removal: %d\n%!" (List.length clf);
    clf
  end
  else
    cl in


  Printf.eprintf "Exploding direct dependencies...%!";
  let timer = Util.Timer.create "Exploding direct dependencies" in
  Util.Timer.start timer;
  let pred_ht = Hashtbl.create (2 * List.length clf) in
  let c_pred_ht = Hashtbl.create (2 * List.length clf) in
  List.iter (fun (c1, c2) ->
    add_predecessors u gr sd_gr c_pred_ht pred_ht c1;
    add_predecessors u gr sd_gr c_pred_ht pred_ht c2;
      List.iter (fun c1p ->
        List.iter (fun c2p ->
          if c1p <> c2p then add_pair c1p c2p Strong (c1,c2)
        ) (Hashtbl.find c_pred_ht c2)
      ) (Hashtbl.find c_pred_ht c1);
    ) clf;
  Printf.eprintf "done\n%!";

  Printf.eprintf "Adding disjunctive candidates...\n%!";
  List.iter (fun (c1, c2) ->
    let c1l = Hashtbl.find pred_ht c1
    and c2l = Hashtbl.find pred_ht c2 in
    List.iter (fun c1p ->
      List.iter (fun c2p ->
        if c1p <> c2p then add_pair c1p c2p (Other []) (c1,c2)
      ) c2l
    ) c1l;
  ) clf;
  Printf.eprintf "done\n%!";
  ignore (Util.Timer.stop timer ());

  Printf.eprintf "Pairs found: %d conjunctive, %d other (to be tested)\n"
    !nr_conj_pairs !nr_other_pairs;
  let p = Util.Progress.create "Checking pairs..." in
  Util.Progress.set_total p (!nr_conj_pairs + !nr_other_pairs);
  let timer = Util.Timer.create "Checking pairs..." in
  Util.Timer.start timer;
  let sc_ht = Hashtbl.create 8192 in
  let nr_sc = ref 0 in
  Util.Progress.enable "Checking pairs...";
  (* Hashtbl.iter (fun c1 c1_ht ->
    Hashtbl.iter (fun c2 (ct, root) ->
      Util.Progress.progress p;
      match ct with
      | Explicit | Strong -> (incr nr_sc; add_strong_conflict sc_ht c1 c2 root ct)
      | Other _ -> 
        if not (SG.mem_edge sd_gr c1 c2 || SG.mem_edge sd_gr c2 c1)
        then let d = Depsolver.edos_coinstall slv [c1;c2] in
          begin
            incr nr_tested;
            match d.result with
            | Failure f ->
              (incr nr_sc; add_strong_conflict sc_ht c1 c2 root (Other (f ())))
            | _ -> () 
          end
    ) c1_ht
  ) pair_ht; *)
  ignore (Util.Timer.stop timer ());

  Printf.eprintf "Finally SAT-tested %d pairs.\n" !nr_tested;
  Printf.eprintf "Found %d strong conflicts.\n%!" !nr_sc;

  Hashtbl.iter (fun c1 (i, c1_ht) ->
    Printf.fprintf !oc "%d %s-%s :\n" i (string_of_pkgname c1.package) (string_of_version c1.version);
    Hashtbl.iter (fun (r1, r2) cl ->
      Printf.fprintf !oc "  %d (%s-%s <-> %s-%s)\n" (List.length cl)
        (string_of_pkgname r1.package) (string_of_version r1.version)
        (string_of_pkgname r2.package) (string_of_version r2.version);
      List.iter (fun (c2, ct) ->
        match ct with
        | Explicit -> Printf.fprintf !oc "    * %s-%s (explicit)\n"
            (string_of_pkgname c2.package) (string_of_version c2.version)
        | Strong -> Printf.fprintf !oc "    * %s-%s (strong-dep)\n"
            (string_of_pkgname c2.package) (string_of_version c2.version)
        | Other f -> Printf.fprintf !oc "    * %s-%s (other-dep)\n%s\n"
            (string_of_pkgname c2.package) (string_of_version c2.version)
          (String.concat "\n" 
            (List.map (function 
              | Dependency (d, l) -> Printf.sprintf
                  "      - dependency: %s-%s -> %s"
                  (string_of_pkgname d.package) (string_of_version c2.version) 
                (String.concat " | " (List.map (fun d' -> Printf.sprintf "%s-%s" (string_of_pkgname d'.package) (string_of_version d'.version)) l))
              | EmptyDependency (d, l) -> Printf.sprintf "     - empty dependency: %s-%s -> %s" (string_of_pkgname d.package) (string_of_version d.version)
                (String.concat " | " (List.map string_of_vpkg l))
              | Conflict (c1', c2') -> Printf.sprintf "      - conflict: %s-%s <-> %s-%s"
                (string_of_pkgname c1'.package) (string_of_version c1'.version)
                (string_of_pkgname c2'.package) (string_of_version c2'.version)
              | _ -> Printf.sprintf "     - aliens ate my distribution"
            ) f)
          )
      ) cl
    ) c1_ht
  ) sc_ht;
end;;
