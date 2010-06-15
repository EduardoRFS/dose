(**************************************************************************************)
(*  Copyright (C) 2009 Pietro Abate <pietro.abate@pps.jussieu.fr>                     *)
(*  Copyright (C) 2009 Mancoosi Project                                               *)
(*                                                                                    *)
(*  This library is free software: you can redistribute it and/or modify              *)
(*  it under the terms of the GNU Lesser General Public License as                    *)
(*  published by the Free Software Foundation, either version 3 of the                *)
(*  License, or (at your option) any later version.  A special linking                *)
(*  exception to the GNU Lesser General Public License applies to this                *)
(*  library, see the COPYING file for more information.                               *)
(**************************************************************************************)

(** Strong Dependencies *)

open ExtLib
open Common
open CudfAdd

(** [strongdeps u l] build the strong dependency graph of all packages in 
    [l] wrt the universe [u] *)
let strongdeps universe pkglist =
  let mdf = Mdf.load_from_universe universe in
  let maps = mdf.Mdf.maps in
  let idlist = List.map maps.map#vartoint pkglist in
  let g = Strongdeps_int.strongdeps mdf idlist in
  Defaultgraphs.intcudf mdf.Mdf.index g

(** [strongdeps_univ u] build the strong dependency graph of 
all packages in the universe [u]*)
let strongdeps_univ ?(transitive=true) universe =
  let mdf = Mdf.load_from_universe universe in
  let g = Strongdeps_int.strongdeps_univ ~transitive mdf in
  Defaultgraphs.intcudf mdf.Mdf.index g

(** compute the impact set of the node [q], that is the list of all 
    packages [p] that strong depends on [q] *)
let impactset graph q =
  let module G = Defaultgraphs.StrongDepGraph.G in
  G.fold_pred (fun p acc -> p :: acc ) graph q []

(** compute the conjunctive dependency graph *)
let conjdeps_univ ?(transitive=false) universe =
  let mdf = Mdf.load_from_universe universe in
  let g = Defaultgraphs.IntPkgGraph.G.create () in
  for id=0 to (Array.length mdf.Mdf.index)-1 do
    Defaultgraphs.IntPkgGraph.conjdepgraph_int ~transitive g mdf.Mdf.index id
  done;
  (* let closure = Defaultgraphs.IntPkgGraph.SO.O.add_transitive_closure g in *)
  Defaultgraphs.intcudf mdf.Mdf.index (* closure *) g

(** compute the conjunctive dependency graph considering only packages in
    [pkglist] *)
let conjdeps ?(transitive=false) universe pkglist =
  let mdf = Mdf.load_from_universe universe in
  let maps = mdf.Mdf.maps in
  let idlist = List.map maps.map#vartoint pkglist in
  let g = Defaultgraphs.IntPkgGraph.G.create () in
  List.iter (fun id ->
    Defaultgraphs.IntPkgGraph.conjdepgraph_int ~transitive g mdf.Mdf.index id
  ) idlist ;
  let clousure = Defaultgraphs.IntPkgGraph.SO.O.add_transitive_closure g in
  Defaultgraphs.intcudf mdf.Mdf.index clousure

