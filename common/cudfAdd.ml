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

(** additional functions on Cudf data type.  *)

open Cudf
open Cudf_types

let add_properties preamble l =
  List.fold_left (fun pre prop ->
    {pre with Cudf.property = prop :: pre.Cudf.property}
  ) preamble l

let string_of_version pkg =
  try Cudf.lookup_package_property pkg "number"
  with Not_found -> string_of_int pkg.version

(** print a cudf package.
    @param short : only name and version are printed (default true). If the
    cudf package has an extra attribute "Number" then, this is used instead of
    Cudf.version
    *)
let print_package ?(short=true) pkg =
  if short then
    Printf.sprintf "%s (= %s)" pkg.package (string_of_version pkg)
  else
    Cudf_printer.string_of_package pkg

(* I want to hash packages by name/version without considering
   other fields like Installed / keep / etc.  *)
(** compare two cudf packages only using name and version *)
let compare = Cudf.(<%)

(** has a cudf package only using name and version *)
let hash p = Hashtbl.hash (p.Cudf.package,p.Cudf.version)

(** two cudf packages are equal if name and version are the same *)
let equal = Cudf.(=%)

(** specialized Hash table for cudf packages *)
module Cudf_hashtbl =
  Hashtbl.Make(struct
    type t = Cudf.package
    let equal = equal
    let hash = hash
  end)

(** specialized Set for cudf packages *)
module Cudf_set =
  Set.Make(struct
    type t = Cudf.package
    let compare = compare
  end)

open ExtLib

(** maps one to one cudf packages to integers *)
class projection = object(self)

  val vartoint = Cudf_hashtbl.create 1023
  val inttovar = Hashtbl.create 1023
  val mutable counter = 0

  method init = List.iter self#add

  (** add a cudf package to the map *)
  method add (v : Cudf.package) =
    let j = counter in
    Cudf_hashtbl.add vartoint v j ;
    Hashtbl.add inttovar j v ;
    counter <- counter + 1

  (** var -> int *)
  method vartoint (v : Cudf.package) : int =
    try Cudf_hashtbl.find vartoint v
    with Not_found -> assert false
      
  (** int -> var *)
  method inttovar (i : int) : Cudf.package =
    try Hashtbl.find inttovar i 
    with Not_found -> assert false
end 

(** build an hash table that associates (package name, String version) to
 * cudf packages *)
let realversionmap pkglist =
  let h = Hashtbl.create (2 * (List.length pkglist)) in
  List.iter (fun pkg ->
    let version =
      try Cudf.lookup_package_property pkg "Number" 
      with Not_found -> string_of_int pkg.version
    in
    Hashtbl.add h (pkg.package,version) pkg
  ) pkglist ;
  h

(*
 the Cudf library does not consider features of packages that are not
 installed. who_provides is a lookup function that returns all packages
 (installed or not) that implement a given feature 
*)
type maps = {
  (** the list of all packages the explicitely or implicitely
      conflict with the given package *)
  who_conflicts : Cudf.package -> Cudf.package list;

  (** [lookup_virtual feature] the list of all packages that
      explicitely declared [feature] as provide *)
  lookup_virtual : Cudf_types.vpkg -> Cudf.package list ;

  (** [who_provides constr] the list of all packages that satisfy [constr]. 
      A package is provided by real packages or other packages that provide that
      name as a feature. *)
  who_provides : Cudf_types.vpkg -> Cudf.package list ;

  (** assign an integer to each cudf package *)
  map : projection
}

(** build a map from a cudf universe *)
let build_maps universe =
  let size = Cudf.universe_size universe in
  let conflicts = Cudf_hashtbl.create (2 * size) in
  let provides = Hashtbl.create (2 * size) in
  let map = new projection in

  Cudf.iter_packages (fun pkg ->
    map#add pkg; (* associate an integer to each package *)
    List.iter (function
      |name, None -> Hashtbl.add provides name (pkg, None)
      |name, Some (_, ver) -> Hashtbl.add provides name (pkg, (Some ver))
    ) pkg.provides
  ) universe
  ;

  let lookup_virtual (pkgname,constr) =
    List.filter_map (function
      |pkg, None -> Some(pkg)
      |pkg, Some v when Cudf.version_matches v constr -> Some(pkg)
      |_,_ -> None
    ) (Hashtbl.find_all provides pkgname)
  in

  let who_provides (pkgname,constr) =
    let real = Cudf.lookup_packages ~filter:constr universe pkgname in
    let virt = lookup_virtual (pkgname,constr) in
    (real @ virt)
  in

  (* we need to iterate twice on the package list as we need the
   * list of all virtual packages in order to generate the conflict list *)
  Cudf.iter_packages (fun pkg ->
    List.iter (fun (name,constr) ->
      List.iter (fun p ->
        if not(equal p pkg) then begin
          Cudf_hashtbl.add conflicts pkg p ;
          Cudf_hashtbl.add conflicts p pkg
        end
      ) (who_provides (name,constr))
    ) pkg.conflicts
  ) universe
  ;

  let who_conflicts pkg = List.unique ~cmp:equal (Cudf_hashtbl.find_all conflicts pkg) in

  {
    who_conflicts = who_conflicts ;
    who_provides = who_provides ;
    lookup_virtual = lookup_virtual ;
    map = map
  }
;;

let not_allowed = Str.regexp  "[^a-zA-Z0-9@/+().-]" 
let search s =
  try (Str.search_forward not_allowed s 0) >= 0
  with Not_found -> false

let encode s =
  let make_hex chr = Printf.sprintf "%%%x" (Char.code chr) in
  if search s then begin
    let n = String.length s in
    let b = Buffer.create n in
    for i = 0 to n-1 do
      let s' = String.of_char s.[i] in
      if Str.string_match not_allowed s' 0 then
        Buffer.add_string b (make_hex s.[i])
      else
        Buffer.add_string b s'
    done;
    Buffer.contents b
  end else s

let decode s =
  let hex_re = Str.regexp "%[0-9a-f][0-9a-f]" in
  (* if Str.string_match hex_re s 0 then begin *)
    let un s =
      let s = Str.matched_string s in
      let hex = String.sub s 1 2 in
      let n = int_of_string ("0x" ^ hex) in
      String.make 1 (Char.chr n)
    in
    Str.global_substitute hex_re un s
  (* end else s *)

let cudfop = function
  |Some(("<<" | "<"),v) -> Some(`Lt,v)
  |Some((">>" | ">"),v) -> Some(`Gt,v)
  |Some("<=",v) -> Some(`Leq,v)
  |Some(">=",v) -> Some(`Geq,v)
  |Some("=",v) -> Some(`Eq,v)
  |Some("ALL",v) -> None
  |None -> None
  |Some(c,v) -> (Printf.eprintf "%s %s" c v ; assert false)
